@echo off
cd /d "%~dp0"
echo Foxhole Vivox Fix - restore routes for the current Ethernet or Wi-Fi connection.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Foxhole-Vivox-Fix.ps1" -Action Refresh
if errorlevel 1 (echo Restore failed. See README.html.) else (echo Done. Reconnect voice in Foxhole.)
pause
