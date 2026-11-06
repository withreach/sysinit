<#
  Reach Windows Developer Bootstrap (Windows 10/11)

  Installs Git and mkcert (winget), enables WSL2, installs a Debian/Ubuntu
  distro, runs the Linux install.sh inside it, trusts the mkcert CA and
  adds the Reach hosts entries. -SyncSSHKeys copies Windows SSH keys into WSL.
#>

param(
    [string]$WSLDistro = "Ubuntu-24.04",
    [switch]$SyncSSHKeys = $false
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

Write-Host "`n===== Reach Windows Dev Setup Starting =====" -ForegroundColor Cyan
Write-Host "WSL Distro: $WSLDistro" -ForegroundColor Cyan
Write-Host "Sync SSH Keys: $SyncSSHKeys" -ForegroundColor Cyan

# e.g. "Ubuntu-24.04" -> "rch-ubuntu"
$EffectiveDistroName = "rch-" + ($WSLDistro -split '-')[0].ToLower()
Write-Host "Distro Name: $EffectiveDistroName" -ForegroundColor Cyan

# ------------------------------#
# Variables
# ------------------------------#
$HostsFile      = "$env:windir\System32\drivers\etc\hosts"
$HostsMarker    = "# Engine aliases v1"
$WinSSH         = Join-Path $env:USERPROFILE ".ssh"
$WSLSSH         = "/home/$env:USERNAME/.ssh"
$RebootRequired = $false

# ------------------------------#
# PATH Refresh
# ------------------------------#
function Refresh-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ------------------------------#
# winget
# ------------------------------#
function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "winget OK."
        return
    }

    Write-Host "Installing winget..." -ForegroundColor Yellow
    $WingetUrl = "https://aka.ms/getwinget"
    $Installer = "$env:TEMP\winget.msixbundle"

    Invoke-WebRequest -Uri $WingetUrl -OutFile $Installer -UseBasicParsing
    Add-AppxPackage -Path $Installer
    Remove-Item $Installer -Force
}

Ensure-Winget

# ------------------------------#
# App Installer Helper
# ------------------------------#
function Install-App {
    param (
        [string]$Name,
        [string]$CheckCommand,
        [string]$WingetId
    )

    if ($CheckCommand -and (Get-Command $CheckCommand -ErrorAction SilentlyContinue)) {
        Write-Host "$Name already installed."
        return
    }

    Write-Host "Installing $Name..." -ForegroundColor Yellow
    # --source winget avoids the msstore source (fails with 0x8a15000f on some machines)
    $WingetArgs = @("install", "--silent", "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--id", $WingetId)
    winget @WingetArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "winget failed; resetting sources and retrying once..." -ForegroundColor Yellow
        winget source reset --force
        winget source update
        winget @WingetArgs
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: failed to install $Name (winget exit $LASTEXITCODE)" -ForegroundColor Red
    }
}

# ------------------------------#
# APPS
# ------------------------------#
Write-Host "`nInstalling developer applications..." -ForegroundColor Cyan

Install-App -Name "Git" -CheckCommand "git" -WingetId "Git.Git"
Install-App -Name "Mkcert" -CheckCommand "mkcert" -WingetId "FiloSottile.mkcert"

# Refresh PATH so winget-installed binaries are available in this session
Refresh-EnvPath

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
    $Existing = wsl.exe --list --quiet 2>$null | Select-String -Pattern "^$EffectiveDistroName"
    if ($Existing) {
        Write-Host "$EffectiveDistroName already installed."
        return
    }

    wsl.exe --install -d $WSLDistro --name $EffectiveDistroName

    $Verify = wsl.exe --list --quiet 2>$null | Select-String -Pattern "^$EffectiveDistroName"
    if (-not $Verify) {
        Write-Host "ERROR: $EffectiveDistroName was not installed (wsl exit $LASTEXITCODE). See the output above." -ForegroundColor Red
        exit 1
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
        ssh-keygen -t ed25519 -f "$WinSSH\id_ed25519" -N ""
    }

    wsl.exe -d $EffectiveDistroName -- bash -c "mkdir -p $WSLSSH; chmod 700 $WSLSSH"

    $KeyFiles = @(
        "id_rsa", "id_rsa.pub",
        "id_ed25519", "id_ed25519.pub",
        "known_hosts", "config"
    )

    foreach ($Key in $KeyFiles) {
        $WinKeyPath = Join-Path $WinSSH $Key
        if (Test-Path $WinKeyPath) {
            Write-Host "Copying $Key -> WSL..." -ForegroundColor Cyan
            Get-Content $WinKeyPath -Raw | wsl.exe -d $EffectiveDistroName -- bash -c "cat > $WSLSSH/$Key"
            wsl.exe -d $EffectiveDistroName -- bash -c "chmod 600 $WSLSSH/$Key"
        }
    }

    wsl.exe -d $EffectiveDistroName -- bash -c "chmod 700 $WSLSSH; chmod 600 $WSLSSH/*"

    Write-Host "SSH key sync complete." -ForegroundColor Green
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

    wsl.exe -d $EffectiveDistroName -- bash -c "sudo apt-get update -y && sudo apt-get install -y wget && wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash"

    Write-Host "sysinit complete." -ForegroundColor Green
}

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

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro name: $EffectiveDistroName"
Write-Host "SSH Sync: $SyncSSHKeys"

if ($RebootRequired) {
    Write-Host "`n*** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "Windows features or the WSL distro were just installed and need a reboot to activate." -ForegroundColor Yellow

    # Resume automatically at next logon (UAC prompt, since setup needs admin)
    $Rerun = "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.ps1))) -WSLDistro $WSLDistro"
    if ($SyncSSHKeys) { $Rerun += " -SyncSSHKeys" }
    $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Rerun))
    $RunOnce = "powershell -NoProfile -WindowStyle Hidden -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -ExecutionPolicy Bypass -EncodedCommand $Encoded'`""
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "ReachSysinit" -Value $RunOnce
    Write-Host "Setup will resume automatically (admin prompt) after you reboot and log in." -ForegroundColor Yellow
    Write-Host "To run it manually instead:" -ForegroundColor Yellow
    Write-Host "  $Rerun" -ForegroundColor White
} else {
    Write-Host "Reach sysinit ready."
}
