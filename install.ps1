<#
  Reach Windows Developer Bootstrap (Windows 10/11)

  Enables WSL2, installs a Debian/Ubuntu distro and runs the Linux install.sh
  inside it. -SyncSSHKeys copies Windows SSH keys into WSL.
  -Dev also sets up the Reach dev environment: repos and config in WSL, plus
  mkcert (CA trust) and the rch.local hosts entries on Windows.
#>

param(
    [string]$WSLDistro = "Ubuntu-24.04",
    [switch]$SyncSSHKeys = $false,
    [switch]$Dev = $false
)

# ------------------------------#
# Admin Check
# ------------------------------#
If (-NOT ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell → Run as Administrator"
    exit 1
}

# Remove the post-reboot resume task if this run was started by it
Unregister-ScheduledTask -TaskName "ReachSysinitResume" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "`n===== Reach Windows Dev Setup Starting =====" -ForegroundColor Cyan
Write-Host "WSL Distro: $WSLDistro" -ForegroundColor Cyan
Write-Host "Sync SSH Keys: $SyncSSHKeys" -ForegroundColor Cyan
Write-Host "Dev environment: $Dev" -ForegroundColor Cyan

# e.g. "Ubuntu-24.04" -> "rch-ubuntu"
$EffectiveDistroName = "rch-" + ($WSLDistro -split '-')[0].ToLower()
Write-Host "Distro Name: $EffectiveDistroName" -ForegroundColor Cyan

# ------------------------------#
# Variables
# ------------------------------#
$HostsFile      = "$env:windir\System32\drivers\etc\hosts"
$HostsMarker    = "# Engine aliases v1"
$WinSSH         = Join-Path $env:USERPROFILE ".ssh"
$RebootRequired = $false

# wsl.exe emits UTF-16; strip NULs so name matching works
function Get-WslDistros {
    (wsl.exe --list --quiet 2>$null) -replace "`0", "" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
}

# ------------------------------#
# PATH Refresh
# ------------------------------#
function Refresh-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ------------------------------#
# mkcert (direct from the official GitHub release; winget is unreliable here)
# ------------------------------#
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

if ($Dev) { Install-Mkcert }

# ------------------------------#
# WSL SETUP
# ------------------------------#
Write-Host "`n===== Setting Up WSL =====" -ForegroundColor Cyan

function Ensure-WSL {
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
        return
    }

    wsl.exe --set-default-version 2
}

Ensure-WSL

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

if ($RebootRequired) {
    Write-Host "Skipping distro install - reboot required first." -ForegroundColor Yellow
} else {
    Install-distro
}

# =======================================================================
# SSH SYNC (controlled by -SyncSSHKeys flag)
# =======================================================================
if ($RebootRequired) {
    Write-Host "`nSkipping SSH key sync — reboot required first." -ForegroundColor Yellow
} elseif ($SyncSSHKeys) {

    Write-Host "`n===== Syncing SSH Keys from Windows -> WSL =====" -ForegroundColor Cyan

    if (!(Test-Path $WinSSH)) {
        Write-Host "No SSH keys found - creating new ed25519 keys..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $WinSSH | Out-Null
        ssh-keygen -t ed25519 -f "$WinSSH\id_ed25519" -N '""'  # PowerShell 5.1 drops a bare empty-string argument
    }

    wsl.exe -d $EffectiveDistroName -- bash -c "mkdir -p ~/.ssh; chmod 700 ~/.ssh"

    $KeyFiles = @(
        "id_rsa", "id_rsa.pub",
        "id_ed25519", "id_ed25519.pub",
        "known_hosts", "config"
    )

    $Copied = 0
    foreach ($Key in $KeyFiles) {
        $WinKeyPath = Join-Path $WinSSH $Key
        if (Test-Path $WinKeyPath) {
            $Copied++
            Write-Host "Copying $Key -> WSL..." -ForegroundColor Cyan
            $Src = (wsl.exe -d $EffectiveDistroName -- wslpath -u ($WinKeyPath -replace '\\', '/')).Trim()
            wsl.exe -d $EffectiveDistroName -- bash -c "cp '$Src' ~/.ssh/$Key"
        }
    }

    wsl.exe -d $EffectiveDistroName -- bash -c "chmod 700 ~/.ssh; chmod 600 ~/.ssh/*"

    if ($Copied -eq 0) {
        Write-Host "WARNING: none of $($KeyFiles -join ', ') found in $WinSSH - nothing was synced (rename e.g. id_rsa.pem to id_rsa)." -ForegroundColor Red
    } else {
        Write-Host "SSH key sync complete." -ForegroundColor Green
    }
}
else {
    Write-Host "`nSkipping SSH key sync (SyncSSHKeys disabled)" -ForegroundColor Yellow
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

if ($Dev) {
    # =======================================================================
    # mkcert CA Install
    # =======================================================================
    Refresh-EnvPath
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        mkcert -install
    } else {
        Write-Host "WARNING: mkcert not found - skipping CA install. Re-run this script." -ForegroundColor Red
    }

    # =======================================================================
    # hosts File Update (single write; retried because AV/other tools can lock it)
    # =======================================================================
    if ((Get-Content $HostsFile) -notcontains $HostsMarker) {
        $HostsBlock = @($HostsMarker) + (@(
            "admin.rch.local", "admin-api.rch.local", "checkout.rch.local", "portal.rch.local",
            "reports.rch.local", "stash.rch.local", "redirect.rch.local", "vue.admin.rch.local"
        ) | ForEach-Object { "127.0.0.1 $_" })

        $HostsUpdated = $false
        foreach ($Attempt in 1..5) {
            try {
                Add-Content -Path $HostsFile -Value (@("") + $HostsBlock) -ErrorAction Stop
                $HostsUpdated = $true
                break
            } catch {
                Start-Sleep -Seconds 2
            }
        }
        if (-not $HostsUpdated) {
            Write-Host "WARNING: could not update $HostsFile (locked by another process). Re-run this script." -ForegroundColor Red
        }
    }
}

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro name: $EffectiveDistroName"
Write-Host "SSH Sync: $SyncSSHKeys"
Write-Host "Dev environment: $Dev"

if ($RebootRequired) {
    Write-Host "`n*** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "Windows features or the WSL distro were just installed and need a reboot to activate." -ForegroundColor Yellow

    # Resume at next logon via an elevated scheduled task (no UAC prompt), then reboot
    $Rerun = "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -WSLDistro $WSLDistro"
    if ($SyncSSHKeys) { $Rerun += " -SyncSSHKeys" }
    if ($Dev) { $Rerun += " -Dev" }
    $ResumeLog = Join-Path $env:ProgramData "ReachSysinit\resume.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $ResumeLog) | Out-Null
    $ResumeCmd = "Start-Transcript -Path '$ResumeLog' -Force | Out-Null; " +
                 "while (-not (Test-Connection -ComputerName github.com -Count 1 -Quiet)) { Start-Sleep -Seconds 3 }; $Rerun"
    $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ResumeCmd))
    $Me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit -ExecutionPolicy Bypass -EncodedCommand $Encoded"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Me
    $Principal = New-ScheduledTaskPrincipal -UserId $Me -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName "ReachSysinitResume" -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null

    Write-Host "Setup resumes automatically after you log in. Rebooting in 10 seconds (cancel with: shutdown /a)." -ForegroundColor Yellow
    Write-Host "To run it manually instead:" -ForegroundColor Yellow
    Write-Host "  $Rerun" -ForegroundColor White
    shutdown.exe /r /t 10 /c "Reach sysinit: reboot to finish WSL setup"
} else {
    Write-Host "Reach sysinit ready."
}
