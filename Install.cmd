@echo off
cd /d "%~dp0"
echo Foxhole Vivox Fix - install direct routes and automatic restore.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Foxhole-Vivox-Fix.ps1" -Action Install
if errorlevel 1 (echo Installation failed. See README.html.) else (echo Done. Reconnect voice in Foxhole.)
pause
