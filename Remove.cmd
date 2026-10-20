@echo off
cd /d "%~dp0"
echo Foxhole Vivox Fix - remove owned routes and automatic restore.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Foxhole-Vivox-Fix.ps1" -Action Remove
if errorlevel 1 (echo Removal failed. See README.html.) else (echo Done.)
pause
