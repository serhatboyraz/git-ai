@echo off
rem Intune Win32 / SCCM kaldirma komutu. Tum veriyi silmek icin: uninstall.cmd -Purge
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Uninstall-GitAi.ps1" %*
exit /b %ERRORLEVEL%
