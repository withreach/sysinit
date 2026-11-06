@echo off
:: Reach dev bootstrap: elevates, then runs install.ps1 from GitHub.
:: Pass install.ps1 parameters through, e.g. bootstrap.cmd -SyncSSHKeys
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if NOT "%errorlevel%"=="0" (
    powershell -Command "Start-Process '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/withreach/sysinit/main/install.ps1'))) %*"
pause
