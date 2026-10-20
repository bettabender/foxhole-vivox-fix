@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Foxhole-Vivox-Fix.ps1" -Action Status
pause
