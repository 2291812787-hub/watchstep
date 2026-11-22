@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Public\reinstall_watch.ps1" %1
