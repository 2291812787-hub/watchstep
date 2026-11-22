@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Public\when_expire.ps1"
pause
