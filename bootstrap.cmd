@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  Reach Dev Environment Bootstrap (Standalone Edition)
::  - No repo clone required
::  - Downloads install.ps1 dynamically from GitHub
:: ============================================================

:: ---------------------------------------
:: Admin Check
:: ---------------------------------------
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if NOT "%errorlevel%"=="0" (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ---------------------------------------
:: Variables
:: ---------------------------------------
set INSTALL_URL=https://raw.githubusercontent.com/withreach/sysinit/main/install.ps1

set LOGDIR=%USERPROFILE%\ReachSetup
set LOGFILE=%LOGDIR%\install_%DATE:/=-%_%TIME::=-%.log
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo Starting installer... >> "%LOGFILE%"
echo %DATE% %TIME% >> "%LOGFILE%"

:: ---------------------------------------
:: Menu
:: ---------------------------------------
:MENU
cls
echo ============================================================
echo          Reach Developer Environment Installer
echo ============================================================
echo.
echo  1^) Full Install  (Extras ON, Ubuntu-24.04)
echo  2^) Minimal Install  (Extras OFF, Ubuntu-24.04)
echo  3^) Custom Distro + Full Install
echo  4^) Custom Distro + Minimal Install
echo  5^) Full Install + SSH Sync
echo  6^) Minimal Install + SSH Sync
echo  7^) Exit
echo.
set /p CHOICE="Enter choice (1-7): "

if "%CHOICE%"=="1" set FLAGS=-InstallExtras:$true -WSLDistro Ubuntu-24.04& goto RUN
if "%CHOICE%"=="2" set FLAGS=-InstallExtras:$false -WSLDistro Ubuntu-24.04& goto RUN
if "%CHOICE%"=="3" goto CUSTOM_FULL
if "%CHOICE%"=="4" goto CUSTOM_MIN
if "%CHOICE%"=="5" set FLAGS=-InstallExtras:$true -WSLDistro Ubuntu-24.04 -SyncSSHKeys:$true& goto RUN
if "%CHOICE%"=="6" set FLAGS=-InstallExtras:$false -WSLDistro Ubuntu-24.04 -SyncSSHKeys:$true& goto RUN
if "%CHOICE%"=="7" exit /b 0

echo Invalid selection.
pause
goto MENU

:CUSTOM_FULL
set /p DISTRO="Enter distro name: "
set FLAGS=-InstallExtras:$true -WSLDistro "%DISTRO%"
goto RUN

:CUSTOM_MIN
set /p DISTRO="Enter distro name: "
set FLAGS=-InstallExtras:$false -WSLDistro "%DISTRO%"
goto RUN

:: ---------------------------------------
:: Run Installer
:: ---------------------------------------
:RUN
cls
echo Running installer with flags:
echo   %FLAGS%
echo Logging to: %LOGFILE%
echo.

(
    echo Downloading install.ps1 from %INSTALL_URL%
    powershell -NoProfile -ExecutionPolicy Bypass ^
        -Command "irm '%INSTALL_URL%' | iex; install.ps1 %FLAGS%"
) >> "%LOGFILE%" 2>&1

echo.
echo ============================================================
echo Installation complete.
echo Log file: %LOGFILE%
echo ============================================================

pause
exit /b 0

