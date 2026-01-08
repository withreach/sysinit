<#
  Reach Windows Developer Bootstrap

  Features:
    - winget
    - Dev apps (Git, AWS CLI/SSM, Mkcert)
    - Optional dev apps (VSCode, Slack, Postman, Meld...)
    - WSL enabled + WSL2 default
    - Distro selection (default Ubuntu-24.04)
    - Run Reach sysinit bootstrap inside WSL
    - SSH Sync, Controlled by -SyncSSHKeys (disabled by default)
    - mkcert install + CA trust
    - hosts file updates
#>

param(
    [switch]$InstallExtras = $false,
    [string]$WSLDistro = "Ubuntu-24.04",
    [string]$DistroName = "",
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
Write-Host "Install Extras: $InstallExtras" -ForegroundColor Cyan
Write-Host "WSL Distro: $WSLDistro" -ForegroundColor Cyan
Write-Host "Sync SSH Keys: $SyncSSHKeys" -ForegroundColor Cyan

# Set the effective distro name 
# Use custom name if provided, otherwise generate rch-[os] from the distro name
if ($DistroName) {
    $EffectiveDistroName = $DistroName
} else {
    # Extract OS name from distro (e.g., "Ubuntu-24.04" -> "ubuntu", "Debian" -> "debian")
    $OsName = ($WSLDistro -split '-')[0].ToLower()
    $EffectiveDistroName = "rch-$OsName"
}

Write-Host "Distro Name: $EffectiveDistroName" -ForegroundColor Cyan

# ------------------------------#
# Variables
# ------------------------------#
$HostsFile  = "$env:windir\System32\drivers\etc\hosts"
$HostsMarker = "# Engine aliases v1"
$WinSSH    = Join-Path $env:USERPROFILE ".ssh"
$WSLSSH    = "/home/$env:USERNAME/.ssh"

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
    winget install --silent -e --accept-source-agreements --accept-package-agreements --id $WingetId
}

# ------------------------------#
# REQUIRED APPS
# ------------------------------#
Write-Host "`nInstalling required developer applications..." -ForegroundColor Cyan

Install-App -Name "Git" -CheckCommand "git" -WingetId "Git.Git"
Install-App -Name "AWS CLI" -CheckCommand "aws" -WingetId "Amazon.AWSCLI"
Install-App -Name "AWS SSM Session Manager Plugin" -CheckCommand "session-manager-plugin" -WingetId "Amazon.SessionManagerPlugin"
Install-App -Name "Mkcert" -CheckCommand "mkcert" -WingetId "FiloSottile.mkcert"

# ------------------------------#
# OPTIONAL EXTRAS
# ------------------------------#
if ($InstallExtras) {
    Write-Host "`nInstalling extra developer applications..." -ForegroundColor Cyan

    Install-App -Name "Postman" -CheckCommand "" -WingetId "Postman.Postman"
    Install-App -Name "Visual Studio Code" -CheckCommand "code" -WingetId "Microsoft.VisualStudioCode"
    Install-App -Name "Slack" -CheckCommand "" -WingetId "SlackTechnologies.Slack"
    Install-App -Name "Meld" -CheckCommand "meld" -WingetId "Meld.Meld"
}
else {
    Write-Host "`nSkipping extra developer applications (--InstallExtras:$false)" -ForegroundColor Yellow
}

# ------------------------------#
# WSL SETUP
# ------------------------------#
Write-Host "`n===== Setting Up WSL =====" -ForegroundColor Cyan

function Ensure-WSL {
    wsl.exe --status 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "WSL already installed."
        return
    }

    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

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
}

Install-distro

# ------------------------------#
# Run sysinit inside WSL
# ------------------------------#
Write-Host "`nRunning Reach sysinit inside $EffectiveDistroName..." -ForegroundColor Cyan

# Detect package manager and install wget based on distro
wsl.exe -d $EffectiveDistroName -- bash -c "if command -v apt-get > /dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y wget; elif command -v dnf > /dev/null 2>&1; then sudo dnf install -y wget; elif command -v yum > /dev/null 2>&1; then sudo yum install -y wget; elif command -v pacman > /dev/null 2>&1; then sudo pacman -Sy --noconfirm wget; elif command -v zypper > /dev/null 2>&1; then sudo zypper install -y wget; elif command -v apk > /dev/null 2>&1; then sudo apk add --no-cache wget; else echo 'Unable to detect package manager. Please install wget manually.'; exit 1; fi && wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash"

Write-Host "sysinit complete." -ForegroundColor Green

# =======================================================================
# SSH SYNC (controlled by -SyncSSHKeys flag)
# =======================================================================
if ($SyncSSHKeys) {

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
            wsl.exe -d $EffectiveDistroName -- bash -c 'chmod 600 $WSLSSH/$Key || true'
        }
    }

    wsl.exe -d $EffectiveDistroName -- bash -c 'chmod 700 $WSLSSH; chmod 600 $WSLSSH/* 2>/dev/null || true'

    Write-Host "SSH key sync complete." -ForegroundColor Green
}
else {
    Write-Host "`nSkipping SSH key sync (SyncSSHKeys disabled)" -ForegroundColor Yellow
}

# =======================================================================
# mkcert CA Install
# =======================================================================
mkcert -install

# =======================================================================
# hosts File Update
# =======================================================================
$HostsContent = Get-Content $HostsFile
if ($HostsContent -notcontains $HostsMarker) {
    Add-Content $HostsFile "`n$HostsMarker"
    foreach ($entry in @(
        "127.0.0.1 admin.rch.local",
        "127.0.0.1 admin-api.rch.local",
        "127.0.0.1 checkout.rch.local",
        "127.0.0.1 portal.rch.local",
        "127.0.0.1 reports.rch.local",
        "127.0.0.1 stash.rch.local",
        "127.0.0.1 redirect.rch.local",
        "127.0.0.1 vue.admin.rch.local"
    )) {
        Add-Content $HostsFile $entry
    }
}

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro name: $EffectiveDistroName"
Write-Host "SSH Sync: $SyncSSHKeys"
Write-Host "Extras installed: $InstallExtras"
Write-Host "Reach sysinit ready."

