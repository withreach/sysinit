<#
  Reach Windows Developer Bootstrap

  Features:
    - winget (if missing)
    - Optional dev apps (Git, AWS CLI, VSCode, Slack, Postman, Meld...)
    - WSL enabled + WSL2 default
    - Ubuntu distro selection (default Ubuntu-24.04)
    - Auto-install Ubuntu-24.04 when selected
    - Run Reach sysinit bootstrap inside WSL
    - SSH Sync (Option A): Controlled by -SyncSSHKeys (disabled by default)
    - mkcert install + CA trust
    - rch.local + *.rch.local certificate generation
    - hosts file updates
    - Windows Terminal Reach profile
#>

param(
    [switch]$InstallExtras = $true,
    [string]$WSLDistro = "Ubuntu-24.04",
    [switch]$SyncSSHKeys = $false    # <--- NEW FLAG
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

# ------------------------------#
# Variables
# ------------------------------#
$HostsFile  = "$env:windir\System32\drivers\etc\hosts"
$HostsMarker = "# Engine aliases v1"
$CertDir   = Join-Path $env:USERPROFILE "dev\certs"
$CertFile  = Join-Path $CertDir "rch.local.crt"
$KeyFile   = Join-Path $CertDir "rch.local.key"
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
# OPTIONAL EXTRAS
# ------------------------------#
if ($InstallExtras) {
    Write-Host "`nInstalling extra developer applications..." -ForegroundColor Cyan

    Install-App -Name "Git" -CheckCommand "git" -WingetId "Git.Git"
    Install-App -Name "AWS CLI" -CheckCommand "aws" -WingetId "Amazon.AWSCLI"
    Install-App -Name "AWS SSM Session Manager Plugin" -CheckCommand "session-manager-plugin" -WingetId "Amazon.SessionManagerPlugin"
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
# INSTALL UBUNTU BASED ON FLAG
# ------------------------------#
function Install-Ubuntu {
    $Distro = $WSLDistro

    $Existing = wsl.exe --list --quiet 2>$null | Select-String -Pattern "^$Distro$"
    if ($Existing) {
        Write-Host "$Distro already installed."
        return
    }

    if ($Distro -eq "Ubuntu-24.04") {
        Write-Host "Installing Ubuntu-24.04..." -ForegroundColor Yellow
        winget install --silent -e --accept-package-agreements --accept-source-agreements `
            --id Canonical.Ubuntu.2404
    }
    else {
        Write-Host "Custom distro '$Distro' selected; please install manually." -ForegroundColor Yellow
        return
    }
}

Install-Ubuntu

# ------------------------------#
# Run sysinit inside WSL
# ------------------------------#
Write-Host "`nRunning Reach sysinit inside $WSLDistro..." -ForegroundColor Cyan

wsl.exe -d $WSLDistro -- bash -c "wget -O - https://raw.githubusercontent.com/withreach/sysinit/refs/heads/main/install.sh | bash"

Write-Host "sysinit complete." -ForegroundColor Green

# =======================================================================
# SSH SYNC (controlled by -SyncSSHKeys flag)
# =======================================================================
if ($SyncSSHKeys) {

    Write-Host "`n===== Syncing SSH Keys from Windows → WSL =====" -ForegroundColor Cyan

    if (!(Test-Path $WinSSH)) {
        Write-Host "No SSH keys found — creating new ed25519 keys..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $WinSSH | Out-Null
        ssh-keygen -t ed25519 -f "$WinSSH\id_ed25519" -N ""
    }

    wsl.exe -d $WSLDistro -- bash -c "mkdir -p $WSLSSH && chmod 700 $WSLSSH"

    $KeyFiles = @(
        "id_rsa", "id_rsa.pub",
        "id_ed25519", "id_ed25519.pub",
        "known_hosts", "config"
    )

    foreach ($Key in $KeyFiles) {
        $WinKeyPath = Join-Path $WinSSH $Key
        if (Test-Path $WinKeyPath) {
            Write-Host "Copying $Key → WSL..." -ForegroundColor Cyan
            wsl.exe -d $WSLDistro -- bash -c "cat > $WSLSSH/$Key" < $WinKeyPath
            wsl.exe -d $WSLDistro -- bash -c "chmod 600 $WSLSSH/$Key || true"
        }
    }

    wsl.exe -d $WSLDistro -- bash -c "chmod 700 $WSLSSH; chmod 600 $WSLSSH/* 2>/dev/null || true"

    Write-Host "SSH key sync complete." -ForegroundColor Green
}
else {
    Write-Host "`nSkipping SSH key sync (--SyncSSHKeys disabled)" -ForegroundColor Yellow
}

# =======================================================================
# mkcert
# =======================================================================
function Ensure-Mkcert {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        return
    }

    winget install --silent --accept-source-agreements --accept-package-agreements `
        --id FiloSottile.mkcert
}

Ensure-Mkcert

mkcert -install

Write-Host "`nGenerating certs..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
mkcert -cert-file $CertFile -key-file $KeyFile "rch.local" "*.rch.local"

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

# =======================================================================
# Windows Terminal Profile
# =======================================================================
$WTSettingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

if (Test-Path $WTSettingsPath) {

    $WTSettings = Get-Content $WTSettingsPath -Raw | ConvertFrom-Json
    $ProfileGuid = "{c1b0f0e9-f31a-4b4c-9d73-reach0002404}"

    $Existing = $WTSettings.profiles.list | Where-Object { $_.guid -eq $ProfileGuid }

    if (-not $Existing) {
        $NewProfile = [ordered]@{
            name              = "$WSLDistro (Reach)"
            guid              = $ProfileGuid
            commandline       = "wsl.exe -d $WSLDistro"
            startingDirectory = "//wsl$/$WSLDistro/home/$env:USERNAME"
            hidden            = $false
            # icon              = "https://raw.githubusercontent.com/withreach/sysinit/main/assets/reach-icon.png"
        }

        $WTSettings.profiles.list += $NewProfile
        $WTSettings | ConvertTo-Json -Depth 10 | Set-Content $WTSettingsPath -Encoding utf8
    }
}

Write-Host "`n======== DONE ========" -ForegroundColor Green
Write-Host "WSL distro: $WSLDistro"
Write-Host "SSH Sync: $SyncSSHKeys"
Write-Host "Extras installed: $InstallExtras"
Write-Host "Certs: $CertDir"
Write-Host "Reach sysinit ready."

