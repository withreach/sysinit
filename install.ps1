<#
  Reach Windows Developer Bootstrap (Windows 10/11)

  Enables WSL2, installs a Debian/Ubuntu distro and runs the Linux install.sh
  inside it. -SSHKey <path> installs that private key (ed25519 or RSA) into WSL.
  -Dev also sets up the Reach dev environment: repos and config in WSL, plus
  mkcert (CA trust, shared with WSL) and the rch.local hosts entries on Windows.

  Run from a regular (non-elevated) PowerShell. WSL distros, the SSH key and the
  mkcert CA are per Windows user, so they are installed as the user running the
  script; only the machine-wide steps (Windows features, WSL update, mkcert
  binary, hosts file) run in an elevated child process via a UAC prompt.

  Run from a local clone, the install.sh next to this script is used; otherwise
  install.sh is downloaded from the same -Ref (branch or tag) as this script.
#>

param(
    [string]$WSLDistro = "Ubuntu-24.04",
    # WSL instance name; defaults to rch-<distro>, e.g. rch-ubuntu
    [string]$WSLName = "",
    [string]$SSHKey = "",
    [switch]$Dev = $false,
    # sysinit branch or tag to download install.ps1/install.sh from (pin a tag for reproducible installs)
    [string]$Ref = "main",
    # git identity for WSL; defaults to your Windows git config, otherwise you are asked
    [string]$GitName = "",
    [string]$GitEmail = "",
    # Internal: set on the elevated child that performs the machine-wide steps
    [switch]$AdminPhase = $false
)

$RawBase = "https://raw.githubusercontent.com/withreach/sysinit/$Ref"
$ScriptUrl = "$RawBase/install.ps1"
$HostsFile = "$env:windir\System32\drivers\etc\hosts"
$HostsBegin = "# BEGIN reach dev hosts"
$HostsEnd = "# END reach dev hosts"
$LegacyHostsMarker = "# Engine aliases v1"
$DevHosts = @(
    "admin.rch.local", "admin-api.rch.local", "checkout.rch.local", "portal.rch.local",
    "reports.rch.local", "stash.rch.local", "redirect.rch.local", "vue.admin.rch.local"
)
$AdminLog = Join-Path $env:ProgramData "ReachSysinit\admin.log"
$RebootExitCode = 3010
$RebootRequired = $false
$LocalInstallSh = if ($PSCommandPath) { Join-Path (Split-Path $PSCommandPath) "install.sh" } else { "" }
if ($LocalInstallSh -and -not (Test-Path -LiteralPath $LocalInstallSh)) { $LocalInstallSh = "" }

$Me = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = ([Security.Principal.WindowsPrincipal]$Me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Ref -notmatch '^[A-Za-z0-9._/-]+$') {
    Write-Host "ERROR: -Ref may only contain letters, digits, '.', '_', '/' and '-': $Ref" -ForegroundColor Red
    exit 1
}

# wsl.exe emits UTF-16; strip NULs so name matching works
function Get-WslDistros {
    (wsl.exe --list --quiet 2>$null) -replace "`0", "" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
}

function Refresh-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Quote-PS([string]$Value) { "'" + ($Value -replace "'", "''") + "'" }

# =======================================================================
# Machine-wide steps (require Administrator)
# =======================================================================

# mkcert (direct from the official GitHub release, checked against the release's SHA-256 digest)
function Install-Mkcert {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        Write-Host "mkcert already installed."
        return
    }

    Write-Host "Installing mkcert..." -ForegroundColor Yellow
    $Tmp = Join-Path $env:TEMP "mkcert-$([guid]::NewGuid()).exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/FiloSottile/mkcert/releases/latest" -Headers @{ "User-Agent" = "sysinit" }
        $Asset = $Release.assets | Where-Object { $_.name -like "*-windows-$Arch.exe" } | Select-Object -First 1
        if (-not $Asset) { throw "no windows-$Arch asset in release $($Release.tag_name)" }
        if ("$($Asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') {
            $Expected = $Matches[1]
        } else {
            throw "release asset $($Asset.name) has no SHA-256 digest"
        }

        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Tmp -UseBasicParsing
        $Actual = (Get-FileHash -LiteralPath $Tmp -Algorithm SHA256).Hash
        if ($Actual -ne $Expected) { throw "checksum mismatch for $($Asset.name): expected $Expected, got $Actual" }

        $Dir = Join-Path $env:ProgramFiles "mkcert"
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Move-Item -LiteralPath $Tmp -Destination (Join-Path $Dir "mkcert.exe") -Force

        $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if (($MachinePath -split ";") -notcontains $Dir) {
            [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$Dir", "Machine")
        }
        Refresh-EnvPath
    } catch {
        Write-Host "WARNING: failed to install mkcert: $_" -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
    }
}

function Enable-WslFeatures {
    foreach ($Feature in "Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform") {
        $State = (Get-WindowsOptionalFeature -Online -FeatureName $Feature).State
        if ($State -eq "EnablePending") {
            $script:RebootRequired = $true
        } elseif ($State -ne "Enabled") {
            dism.exe /online /enable-feature /featurename:$Feature /all /norestart
            if ($LASTEXITCODE -eq 3010) {
                $script:RebootRequired = $true
            } elseif ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: could not enable $Feature (dism exit $LASTEXITCODE)." -ForegroundColor Red
                exit 1
            }
        }
    }
    if ($RebootRequired) { return }

    # Features are on; the hypervisor must also be running (needs firmware virtualization)
    $Cs = Get-CimInstance Win32_ComputerSystem
    if (-not $Cs.HypervisorPresent) {
        $FwEnabled = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
        if (-not $FwEnabled) {
            Write-Host "ERROR: virtualization is disabled. Enable Intel VT-x / AMD-V (SVM) in BIOS/UEFI," -ForegroundColor Red
            Write-Host "or, inside a VM, enable nested virtualization. Then re-run this script." -ForegroundColor Red
            exit 1
        }
        bcdedit.exe /set hypervisorlaunchtype auto | Out-Null
        $script:RebootRequired = $true
    }
}

# The inbox wsl.exe lacks --name/--no-launch; update to the current WSL package from GitHub, not the Store
# (often blocked on managed laptops)
function Update-Wsl {
    Write-Host "Updating WSL..." -ForegroundColor Yellow
    wsl.exe --update --web-download
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: 'wsl --update --web-download' failed (exit $LASTEXITCODE); continuing with the installed WSL." -ForegroundColor Red
    }
}

# Replace the managed block (and the legacy "Engine aliases v1" entries) so host list changes are picked up.
# Single write, retried because AV/other tools can lock the file.
function Update-HostsFile {
    $Lines = @(Get-Content -LiteralPath $HostsFile)
    $Kept = New-Object System.Collections.Generic.List[string]
    $InBlock = $false
    foreach ($Line in $Lines) {
        if ($Line -eq $HostsBegin) { $InBlock = $true; continue }
        if ($InBlock) { if ($Line -eq $HostsEnd) { $InBlock = $false }; continue }
        if ($Line -eq $LegacyHostsMarker) { continue }
        if ($Line -match '^\s*127\.0\.0\.1\s+(\S+)\s*$' -and $DevHosts -contains $Matches[1]) { continue }
        $Kept.Add($Line)
    }
    while ($Kept.Count -gt 0 -and -not $Kept[$Kept.Count - 1].Trim()) { $Kept.RemoveAt($Kept.Count - 1) }
    $New = @($Kept) + @("", $HostsBegin) + @($DevHosts | ForEach-Object { "127.0.0.1 $_" }) + @($HostsEnd)

    if (($Lines -join "`n") -eq ($New -join "`n")) {
        Write-Host "hosts file already up to date."
        return
    }
    foreach ($Attempt in 1..5) {
        try {
            Set-Content -LiteralPath $HostsFile -Value $New -Encoding ASCII -ErrorAction Stop
            Write-Host "hosts file updated."
            return
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-Host "WARNING: could not update $HostsFile (locked by another process). Re-run this script." -ForegroundColor Red
}

function Invoke-AdminSetup {
    Write-Host "`n===== Machine-wide setup (Administrator) =====" -ForegroundColor Cyan
    if ($Dev) { Install-Mkcert }
    Enable-WslFeatures
    Update-Wsl
    if ($Dev) { Update-HostsFile }
}

if ($AdminPhase) {
    New-Item -ItemType Directory -Force -Path (Split-Path $AdminLog) | Out-Null
    Start-Transcript -Path $AdminLog -Force | Out-Null
    Invoke-AdminSetup
    Stop-Transcript | Out-Null
    exit $(if ($RebootRequired) { $RebootExitCode } else { 0 })
}

# =======================================================================
# Per-user steps (run as the invoking user)
# =======================================================================

if ($SSHKey) {
    if (-not (Test-Path -LiteralPath $SSHKey -PathType Leaf)) {
        Write-Host "ERROR: -SSHKey file not found: $SSHKey" -ForegroundColor Red
        exit 1
    }
    $SSHKey = (Resolve-Path -LiteralPath $SSHKey).Path
}

# e.g. "Ubuntu-24.04" -> "rch-ubuntu"
$EffectiveDistroName = if ($WSLName) { $WSLName } else { "rch-" + ($WSLDistro -split '-')[0].ToLower() }
if ($EffectiveDistroName -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Host "ERROR: -WSLName may only contain letters, digits, '.', '_' and '-': $EffectiveDistroName" -ForegroundColor Red
    exit 1
}

# Ask up front, so the long unattended part is not interrupted later
if (Get-Command git -ErrorAction SilentlyContinue) {
    if (-not $GitName) { $GitName = "$(git config --global user.name 2>$null)".Trim() }
    if (-not $GitEmail) { $GitEmail = "$(git config --global user.email 2>$null)".Trim() }
}
if (-not $GitName) { $GitName = (Read-Host "Your full name for git commits (Enter to keep the one already in WSL)").Trim() }
if (-not $GitEmail) { $GitEmail = (Read-Host "Your work email for git commits (Enter to keep the one already in WSL)").Trim() }

Write-Host "`n===== Reach Windows Dev Setup Starting =====" -ForegroundColor Cyan
Write-Host "Windows user: $($Me.Name)" -ForegroundColor Cyan
Write-Host "WSL Distro: $WSLDistro" -ForegroundColor Cyan
Write-Host "Distro Name: $EffectiveDistroName" -ForegroundColor Cyan
Write-Host "SSH key: $(if ($SSHKey) { $SSHKey } else { '(none)' })" -ForegroundColor Cyan
Write-Host "Dev environment: $Dev" -ForegroundColor Cyan
Write-Host "install.sh: $(if ($LocalInstallSh) { $LocalInstallSh } else { "$RawBase/install.sh" })" -ForegroundColor Cyan

if (Test-Path (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")) {
    Write-Host "NOTE: Docker Desktop is installed. If its WSL integration is enabled for $EffectiveDistroName," -ForegroundColor Yellow
    Write-Host "install.sh skips docker-ce; disable the integration for that distro to use docker-ce instead." -ForegroundColor Yellow
}

if ($IsAdmin) {
    # An elevated prompt opened with a different admin account would install WSL for that account
    $ConsoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($ConsoleUser -and $ConsoleUser -ne $Me.Name) {
        Write-Host "ERROR: this PowerShell runs as $($Me.Name), but you are logged in as $ConsoleUser." -ForegroundColor Red
        Write-Host "WSL would be installed for $($Me.Name) only. Run the script from a regular (non-admin) PowerShell." -ForegroundColor Red
        exit 1
    }
    Invoke-AdminSetup
} else {
    Write-Host "`nRequesting Administrator rights for machine-wide setup (UAC prompt)..." -ForegroundColor Yellow
    $ChildArgs = @("-AdminPhase", "-Ref", $Ref) + $(if ($Dev) { @("-Dev") } else { @() })
    if ($PSCommandPath) {
        $ArgList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $ChildArgs
    } else {
        $ChildCmd = "& ([scriptblock]::Create((irm $ScriptUrl))) $($ChildArgs -join ' ')"
        $ArgList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
                     [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildCmd)))
    }
    try {
        $Child = Start-Process powershell.exe -Verb RunAs -ArgumentList $ArgList -Wait -PassThru -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Administrator rights are required for machine-wide setup (UAC was declined)." -ForegroundColor Red
        exit 1
    }
    if ($Child.ExitCode -eq $RebootExitCode) {
        $RebootRequired = $true
    } elseif ($Child.ExitCode -ne 0) {
        Write-Host "ERROR: machine-wide setup failed (exit $($Child.ExitCode)). See $AdminLog" -ForegroundColor Red
        exit 1
    }
    Refresh-EnvPath
}

# ------------------------------#
# WSL HELPERS
# ------------------------------#

# Run a bash script in the distro. It is shipped base64-encoded, so the command line has no $, quotes or ;
# for the WSL shell to expand; the script deletes itself once bash has opened it.
function Invoke-WslScript([string]$Script, [string]$User = "") {
    $Tmp = "/tmp/sysinit-$([guid]::NewGuid().ToString('N')).sh"
    $B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("rm -f -- `"`$0`"`n" + ($Script -replace "`r", "")))
    $UserArgs = if ($User) { @("-u", $User) } else { @() }
    wsl.exe -d $EffectiveDistroName @UserArgs -- bash -c "echo $B64 | base64 -d > $Tmp && bash $Tmp"
}

# WSL global settings: mirrored networking and DNS tunneling avoid most corporate VPN/proxy problems
# (Windows 11 22H2+). An existing .wslconfig is left alone.
function Set-WslConfig {
    $WslConfig = Join-Path $env:USERPROFILE ".wslconfig"
    if ([Environment]::OSVersion.Version.Build -lt 22621) { return }
    if (Test-Path -LiteralPath $WslConfig) {
        if (-not (Select-String -LiteralPath $WslConfig -Pattern '^\s*networkingMode\s*=' -Quiet)) {
            Write-Host "NOTE: $WslConfig exists without networkingMode; consider networkingMode=mirrored and dnsTunneling=true if WSL has network problems on VPN." -ForegroundColor Yellow
        }
        return
    }
    Set-Content -LiteralPath $WslConfig -Encoding ASCII -Value @(
        "[wsl2]",
        "networkingMode=mirrored",
        "dnsTunneling=true",
        "autoProxy=true"
    )
    Write-Host "Wrote $WslConfig (mirrored networking, DNS tunneling)."
    if (Get-WslDistros) {
        Write-Host "NOTE: run 'wsl --shutdown' to apply it to WSL instances that are already running." -ForegroundColor Yellow
    }
}

# ------------------------------#
# INSTALL DISTRO
# ------------------------------#
function Install-Distro {
    if (Get-WslDistros | Where-Object { $_ -eq $EffectiveDistroName }) {
        Write-Host "$EffectiveDistroName already installed."
        return
    }

    # --no-launch: no first-run shell that waits for the user to type 'exit'; the user is created below instead
    wsl.exe --install -d $WSLDistro --name $EffectiveDistroName --web-download --no-launch
    $InstallExit = $LASTEXITCODE

    if (-not (Get-WslDistros | Where-Object { $_ -eq $EffectiveDistroName })) {
        if ($InstallExit -ne 0) {
            Write-Host "ERROR: $EffectiveDistroName was not installed (wsl exit $InstallExit). See the output above." -ForegroundColor Red
            exit 1
        }
        # wsl --install succeeded but the distro only appears after the features it enabled take effect
        Write-Host "WSL distro installed but requires a reboot to become available." -ForegroundColor Yellow
        $script:RebootRequired = $true
    }
}

# Sets key=value in a section of /etc/wsl.conf; returns 0 only if the file changed
$WslConfFn = @'
set_conf() {
  f=/etc/wsl.conf
  touch "$f"
  awk -v s="[$1]" -v kv="$2=$3" '$0==s{i=1;next} /^\[/{i=0} i&&$0==kv{found=1} END{exit !found}' "$f" && return 1
  sed -i "/^[[:space:]]*$2[[:space:]]*=/d" "$f"
  if grep -qxF "[$1]" "$f"; then sed -i "/^\[$1\]\$/a $2=$3" "$f"; else printf '\n[%s]\n%s=%s\n' "$1" "$2" "$3" >>"$f"; fi
}
'@

# As root: tools needed before install.sh (curl, ssh-keygen, sudo are missing from minimal images),
# systemd (off by default on Debian), and a default user (none exists after --no-launch)
function Initialize-Distro {
    Write-Host "`n===== Preparing $EffectiveDistroName =====" -ForegroundColor Cyan
    $Changed = $false

    $Prep = $WslConfFn + @'
set -e
if ! command -v curl >/dev/null || ! command -v ssh-keygen >/dev/null || ! command -v sudo >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl openssh-client sudo
fi
set_conf boot systemd true && exit 100
exit 0
'@
    Invoke-WslScript $Prep "root"
    if ($LASTEXITCODE -eq 100) { $Changed = $true }
    elseif ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: could not prepare $EffectiveDistroName (exit $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }

    wsl.exe -d $EffectiveDistroName -u root -- getent passwd 1000 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $Default = ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', '')
        if ($Default -notmatch '^[a-z_]') { $Default = "dev" }
        do {
            $LinuxUser = (Read-Host "Linux username for $EffectiveDistroName [$Default]").Trim()
            if (-not $LinuxUser) { $LinuxUser = $Default }
        } until ($LinuxUser -match '^[a-z_][a-z0-9_-]{0,31}$')

        $AddUser = $WslConfFn + @'
set -e
useradd -m -s /bin/bash -G sudo __USER__
set_conf user default __USER__ || true
'@
        Invoke-WslScript $AddUser.Replace("__USER__", $LinuxUser) "root"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: could not create user $LinuxUser (exit $LASTEXITCODE)." -ForegroundColor Red
            exit 1
        }
        Write-Host "Set a password for $LinuxUser (used for sudo):"
        foreach ($Attempt in 1..3) {
            wsl.exe -d $EffectiveDistroName -u root -- passwd $LinuxUser
            if ($LASTEXITCODE -eq 0) { break }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: password not set. Run: wsl -d $EffectiveDistroName -u root -- passwd $LinuxUser" -ForegroundColor Red
            exit 1
        }
        $Changed = $true
    }

    # The distro's first-run setup (OOBE) would otherwise ask to create another user on first interactive launch
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue | ForEach-Object {
        $Props = Get-ItemProperty $_.PSPath
        if ($Props.DistributionName -eq $EffectiveDistroName -and $null -ne $Props.RunOOBE -and $Props.RunOOBE -ne 0) {
            Set-ItemProperty $_.PSPath -Name RunOOBE -Value 0
        }
    }

    if ($Changed) {
        # /etc/wsl.conf (systemd, default user) is read when the instance starts
        wsl.exe --terminate $EffectiveDistroName | Out-Null
    }
}

Write-Host "`n===== Setting Up WSL =====" -ForegroundColor Cyan
if ($RebootRequired) {
    Write-Host "Skipping distro install - reboot required first." -ForegroundColor Yellow
} else {
    Set-WslConfig
    wsl.exe --set-default-version 2
    Install-Distro
    if (-not $RebootRequired) { Initialize-Distro }
}

# =======================================================================
# SSH KEY (only with -SSHKey <path>)
# =======================================================================
if ($RebootRequired) {
    Write-Host "`nSkipping SSH key install - reboot required first." -ForegroundColor Yellow
} elseif ($SSHKey) {
    Write-Host "`n===== Installing SSH key into WSL =====" -ForegroundColor Cyan

    # Copy via /mnt/c, detect the key type with ssh-keygen (prompts for a passphrase if the key has one),
    # install it as ~/.ssh/id_ed25519 or id_rsa (backing up a different existing key) and write the matching .pub
    $Src = (wsl.exe -d $EffectiveDistroName -- wslpath -u ($SSHKey -replace '\\', '/')).Trim()
    $KeyScript = @'
set -e
trap 'rm -f ~/.ssh/.sysinit-key' EXIT
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cp '__SRC__' ~/.ssh/.sysinit-key
chmod 600 ~/.ssh/.sysinit-key
pub=$(ssh-keygen -y -f ~/.ssh/.sysinit-key)
case $pub in
  ssh-ed25519*) n=id_ed25519 ;;
  ssh-rsa*) n=id_rsa ;;
  *) echo 'unsupported key type (need ed25519 or rsa)' >&2; exit 1 ;;
esac
if [ -f ~/.ssh/$n ] && ! cmp -s ~/.ssh/.sysinit-key ~/.ssh/$n; then
  bak=~/.ssh/$n.bak-$(date +%Y%m%d%H%M%S)
  mv ~/.ssh/$n "$bak"
  if [ -f ~/.ssh/$n.pub ]; then mv ~/.ssh/$n.pub "$bak.pub"; fi
  echo "Backed up the existing ~/.ssh/$n to $bak"
fi
mv ~/.ssh/.sysinit-key ~/.ssh/$n
echo "$pub" > ~/.ssh/$n.pub
chmod 644 ~/.ssh/$n.pub
echo "Installed ~/.ssh/$n"
'@
    Invoke-WslScript $KeyScript.Replace('__SRC__', ($Src -replace "'", "'\''"))
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: SSH key install failed (see above)." -ForegroundColor Red
    } else {
        Write-Host "SSH key installed." -ForegroundColor Green
    }
}
else {
    Write-Host "`nSkipping SSH key install (no -SSHKey given)" -ForegroundColor Yellow
}

# mkcert CA trust goes into the current user's certificate store. install.sh copies the same CA into WSL, where
# reach-devops signs the *.rch.local certificate with it, so Windows browsers trust that certificate.
$CARoot = ""
if ($Dev -and -not $RebootRequired) {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        mkcert -install
        $CARoot = "$(mkcert -CAROOT)".Trim()
    } else {
        Write-Host "WARNING: mkcert not found - skipping CA install. Re-run this script." -ForegroundColor Red
    }
}

# ------------------------------#
# Run sysinit inside WSL
# ------------------------------#
$SysinitFailed = $false
if ($RebootRequired) {
    Write-Host "`nSkipping WSL sysinit - reboot required first." -ForegroundColor Yellow
} else {
    Write-Host "`nRunning Reach sysinit inside $EffectiveDistroName..." -ForegroundColor Cyan
    $DevArg = if ($Dev) { "--dev" } else { "" }

    # Hand values to WSL through WSLENV (/u: Windows to WSL only, /p: translate the path)
    $env:SYSINIT_REF = $Ref
    $env:GIT_USER_NAME = $GitName
    $env:GIT_USER_EMAIL = $GitEmail
    $WslEnv = @("SYSINIT_REF/u", "GIT_USER_NAME/u", "GIT_USER_EMAIL/u")
    # Not CAROOT itself: reach-devops expects the CA in ~/.local/share/mkcert, so install.sh copies it there
    if ($CARoot) { $env:SYSINIT_WIN_CAROOT = $CARoot; $WslEnv += "SYSINIT_WIN_CAROOT/up" }
    $env:WSLENV = (@($env:WSLENV) + $WslEnv | Where-Object { $_ }) -join ":"

    if ($LocalInstallSh) {
        $ShPath = (wsl.exe -d $EffectiveDistroName -- wslpath -u ($LocalInstallSh -replace '\\', '/')).Trim()
        $Run = "bash '" + ($ShPath -replace "'", "'\''") + "' $DevArg"
    } else {
        # Download to a file first: with `curl | bash` a failed download runs an empty script and "succeeds"
        $Run = "f=`$(mktemp)`ntrap 'rm -f `"`$f`"' EXIT`ncurl -fsSL '$RawBase/install.sh' -o `"`$f`"`nbash `"`$f`" $DevArg"
    }
    Invoke-WslScript "set -e`n$Run"
    if ($LASTEXITCODE -ne 0) {
        $SysinitFailed = $true
        Write-Host "`nERROR: install.sh failed inside $EffectiveDistroName (exit $LASTEXITCODE) - see the output above." -ForegroundColor Red
        Write-Host "Fix the cause, then re-run this script (steps already done are skipped)." -ForegroundColor Yellow
    } else {
        Write-Host "sysinit complete." -ForegroundColor Green
    }
}

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro name: $EffectiveDistroName"
Write-Host "SSH key: $(if ($SSHKey) { $SSHKey } else { '(none)' })"
Write-Host "Dev environment: $Dev"

if ($RebootRequired) {
    Write-Host "`n*** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "Windows features or the WSL distro were just installed and need a reboot to activate." -ForegroundColor Yellow

    # Resume at this user's next logon via HKCU RunOnce (removed by Windows once it runs)
    $RerunArgs = "-WSLDistro $(Quote-PS $WSLDistro) -WSLName $(Quote-PS $EffectiveDistroName) -Ref $(Quote-PS $Ref)"
    if ($SSHKey) { $RerunArgs += " -SSHKey $(Quote-PS $SSHKey)" }
    if ($GitName) { $RerunArgs += " -GitName $(Quote-PS $GitName)" }
    if ($GitEmail) { $RerunArgs += " -GitEmail $(Quote-PS $GitEmail)" }
    if ($Dev) { $RerunArgs += " -Dev" }
    $Rerun = if ($PSCommandPath) { "& $(Quote-PS $PSCommandPath) $RerunArgs" } else { "& ([scriptblock]::Create((irm $ScriptUrl))) $RerunArgs" }

    $ResumeDir = Join-Path $env:LOCALAPPDATA "ReachSysinit"
    $ResumeScript = Join-Path $ResumeDir "resume.ps1"
    New-Item -ItemType Directory -Force -Path $ResumeDir | Out-Null
    # Wait for the network (HTTPS through the system proxy; github.com does not answer ping), at most ~5 minutes
    Set-Content -Path $ResumeScript -Value @(
        "Start-Transcript -Path $(Quote-PS (Join-Path $ResumeDir 'resume.log')) -Force | Out-Null",
        "foreach (`$i in 1..60) {",
        "    try { Invoke-WebRequest -Uri https://github.com -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null; break }",
        "    catch { Write-Host 'Waiting for network...'; Start-Sleep -Seconds 5 }",
        "}",
        $Rerun
    )
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReachSysinitResume" `
        -Value "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$ResumeScript`""

    Write-Host "Setup resumes automatically after you log in. To run it manually instead:" -ForegroundColor Yellow
    Write-Host "  $Rerun" -ForegroundColor White
    $Answer = Read-Host "`nSave your work in other apps. Reboot now? [Y/n]"
    if ($Answer -match '^\s*n') {
        Write-Host "Reboot when you are ready; setup continues after you log in." -ForegroundColor Yellow
    } else {
        Write-Host "Rebooting in 30 seconds (cancel with: shutdown /a)." -ForegroundColor Yellow
        shutdown.exe /r /t 30 /c "Reach sysinit: reboot to finish WSL setup"
    }
} elseif ($SysinitFailed) {
    Write-Host "`nSetup did NOT complete: install.sh failed in WSL (see the error above)." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Reach sysinit ready."
}
