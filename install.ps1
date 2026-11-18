<#
  Reach Windows Developer Bootstrap (Windows 10/11)

  Enables WSL2, installs a Debian/Ubuntu distro and runs the Linux install.sh
  inside it. -SSHKey <path> installs that private key (ed25519 or RSA) into WSL.
  -Dev also sets up the Reach dev environment: repos and config in WSL, plus
  mkcert (CA trust) and the rch.local hosts entries on Windows.

  Run from a regular (non-elevated) PowerShell. WSL distros, the SSH key and the
  mkcert CA are per Windows user, so they are installed as the user running the
  script; only the machine-wide steps (Windows features, hypervisor, mkcert
  binary, hosts file) run in an elevated child process via a UAC prompt.
#>

param(
    [string]$WSLDistro = "Ubuntu-24.04",
    # WSL instance name; defaults to rch-<distro>, e.g. rch-ubuntu
    [string]$WSLName = "",
    [string]$SSHKey = "",
    [switch]$Dev = $false,
    # Internal: set on the elevated child that performs the machine-wide steps
    [switch]$AdminPhase = $false
)

$ScriptUrl = "https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1"
$HostsFile = "$env:windir\System32\drivers\etc\hosts"
$HostsMarker = "# Engine aliases v1"
$AdminLog = Join-Path $env:ProgramData "ReachSysinit\admin.log"
$RebootExitCode = 3010
$RebootRequired = $false

$Me = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = ([Security.Principal.WindowsPrincipal]$Me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# wsl.exe emits UTF-16; strip NULs so name matching works
function Get-WslDistros {
    (wsl.exe --list --quiet 2>$null) -replace "`0", "" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
}

function Refresh-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# =======================================================================
# Machine-wide steps (require Administrator)
# =======================================================================

# mkcert (direct from the official GitHub release; winget is unreliable here)
function Install-Mkcert {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        Write-Host "mkcert already installed."
        return
    }

    Write-Host "Installing mkcert..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/FiloSottile/mkcert/releases/latest" -Headers @{ "User-Agent" = "sysinit" }
        $Asset = $Release.assets | Where-Object { $_.name -like "*-windows-$Arch.exe" } | Select-Object -First 1
        if (-not $Asset) { throw "no windows-$Arch asset in release $($Release.tag_name)" }

        $Dir = Join-Path $env:ProgramFiles "mkcert"
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile (Join-Path $Dir "mkcert.exe") -UseBasicParsing

        $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if (($MachinePath -split ";") -notcontains $Dir) {
            [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$Dir", "Machine")
        }
        Refresh-EnvPath
    } catch {
        Write-Host "WARNING: failed to install mkcert: $_" -ForegroundColor Red
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

# hosts file update (single write; retried because AV/other tools can lock it)
function Update-HostsFile {
    if ((Get-Content $HostsFile) -contains $HostsMarker) { return }

    $HostsBlock = @($HostsMarker) + (@(
        "admin.rch.local", "admin-api.rch.local", "checkout.rch.local", "portal.rch.local",
        "reports.rch.local", "stash.rch.local", "redirect.rch.local", "vue.admin.rch.local"
    ) | ForEach-Object { "127.0.0.1 $_" })

    foreach ($Attempt in 1..5) {
        try {
            Add-Content -Path $HostsFile -Value (@("") + $HostsBlock) -ErrorAction Stop
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

Write-Host "`n===== Reach Windows Dev Setup Starting =====" -ForegroundColor Cyan
Write-Host "Windows user: $($Me.Name)" -ForegroundColor Cyan
Write-Host "WSL Distro: $WSLDistro" -ForegroundColor Cyan
Write-Host "Distro Name: $EffectiveDistroName" -ForegroundColor Cyan
Write-Host "SSH key: $(if ($SSHKey) { $SSHKey } else { '(none)' })" -ForegroundColor Cyan
Write-Host "Dev environment: $Dev" -ForegroundColor Cyan

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
    $ChildArgs = @("-AdminPhase") + $(if ($Dev) { @("-Dev") } else { @() })
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
# INSTALL DISTRO
# ------------------------------#
function Install-distro {
    if (Get-WslDistros | Where-Object { $_ -eq $EffectiveDistroName }) {
        Write-Host "$EffectiveDistroName already installed."
        return
    }

    wsl.exe --install -d $WSLDistro --name $EffectiveDistroName
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

Write-Host "`n===== Setting Up WSL =====" -ForegroundColor Cyan
if ($RebootRequired) {
    Write-Host "Skipping distro install - reboot required first." -ForegroundColor Yellow
} else {
    wsl.exe --set-default-version 2
    Install-distro
}

# =======================================================================
# SSH KEY (only with -SSHKey <path>)
# =======================================================================
if ($RebootRequired) {
    Write-Host "`nSkipping SSH key install - reboot required first." -ForegroundColor Yellow
} elseif ($SSHKey) {
    Write-Host "`n===== Installing SSH key into WSL =====" -ForegroundColor Cyan

    # Copy via /mnt/c, detect the key type with ssh-keygen (prompts for a passphrase if the key has one),
    # install it as ~/.ssh/id_ed25519 or id_rsa and write the matching .pub
    $Src = (wsl.exe -d $EffectiveDistroName -- wslpath -u ($SSHKey -replace '\\', '/')).Trim()
    $KeyScript = 'set -e; trap ''rm -f ~/.ssh/.sysinit-key'' EXIT; mkdir -p ~/.ssh; chmod 700 ~/.ssh; ' +
        'cp ''__SRC__'' ~/.ssh/.sysinit-key; chmod 600 ~/.ssh/.sysinit-key; ' +
        'pub=$(ssh-keygen -y -f ~/.ssh/.sysinit-key); ' +
        'case $pub in ssh-ed25519*) n=id_ed25519;; ssh-rsa*) n=id_rsa;; *) echo ''unsupported key type (need ed25519 or rsa)'' >&2; exit 1;; esac; ' +
        'mv ~/.ssh/.sysinit-key ~/.ssh/$n; echo $pub > ~/.ssh/$n.pub; chmod 644 ~/.ssh/$n.pub; echo Installed ~/.ssh/$n'
    # Ship the script base64-encoded: the command line then has no $, quotes or ; for the WSL shell to expand
    $B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($KeyScript.Replace('__SRC__', $Src)))
    wsl.exe -d $EffectiveDistroName -- bash -c "echo $B64 | base64 -d > /tmp/.sysinit-key.sh && bash /tmp/.sysinit-key.sh && rm -f /tmp/.sysinit-key.sh"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: SSH key install failed (see above)." -ForegroundColor Red
    } else {
        Write-Host "SSH key installed." -ForegroundColor Green
    }
}
else {
    Write-Host "`nSkipping SSH key install (no -SSHKey given)" -ForegroundColor Yellow
}

# ------------------------------#
# Run sysinit inside WSL
# ------------------------------#
if ($RebootRequired) {
    Write-Host "`nSkipping WSL sysinit - reboot required first." -ForegroundColor Yellow
} else {
    Write-Host "`nRunning Reach sysinit inside $EffectiveDistroName..." -ForegroundColor Cyan
    $DevArg = if ($Dev) { "--dev" } else { "" }

    wsl.exe -d $EffectiveDistroName -- bash -c "sudo apt-get update -y && sudo apt-get install -y wget && wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash -s -- $DevArg"

    Write-Host "sysinit complete." -ForegroundColor Green
}

# mkcert CA trust goes into the current user's certificate store
if ($Dev) {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        mkcert -install
    } else {
        Write-Host "WARNING: mkcert not found - skipping CA install. Re-run this script." -ForegroundColor Red
    }
}

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro name: $EffectiveDistroName"
Write-Host "SSH key: $(if ($SSHKey) { $SSHKey } else { '(none)' })"
Write-Host "Dev environment: $Dev"

if ($RebootRequired) {
    Write-Host "`n*** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "Windows features or the WSL distro were just installed and need a reboot to activate." -ForegroundColor Yellow

    # Resume at this user's next logon via HKCU RunOnce (removed by Windows once it runs), then reboot
    $Rerun = "& ([scriptblock]::Create((irm $ScriptUrl))) -WSLDistro $WSLDistro -WSLName $EffectiveDistroName"
    if ($SSHKey) { $Rerun += " -SSHKey '" + ($SSHKey -replace "'", "''") + "'" }
    if ($Dev) { $Rerun += " -Dev" }
    $ResumeDir = Join-Path $env:LOCALAPPDATA "ReachSysinit"
    $ResumeScript = Join-Path $ResumeDir "resume.ps1"
    New-Item -ItemType Directory -Force -Path $ResumeDir | Out-Null
    Set-Content -Path $ResumeScript -Value @(
        "Start-Transcript -Path '$(Join-Path $ResumeDir 'resume.log')' -Force | Out-Null",
        "while (-not (Test-Connection -ComputerName github.com -Count 1 -Quiet)) { Start-Sleep -Seconds 3 }",
        $Rerun
    )
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReachSysinitResume" `
        -Value "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$ResumeScript`""

    Write-Host "Setup resumes automatically after you log in. Rebooting in 10 seconds (cancel with: shutdown /a)." -ForegroundColor Yellow
    Write-Host "To run it manually instead:" -ForegroundColor Yellow
    Write-Host "  $Rerun" -ForegroundColor White
    shutdown.exe /r /t 10 /c "Reach sysinit: reboot to finish WSL setup"
} else {
    Write-Host "Reach sysinit ready."
}
