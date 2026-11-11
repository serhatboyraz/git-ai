@echo off
rem Intune Win32 / SCCM kurulum komutu. Parametreler Install-GitAi.ps1'e aktarilir.
rem Ornek: install.cmd -ApiBase https://gitai.sirket.local -ApiKey XXXX
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Install-GitAi.ps1" %*
exit /b %ERRORLEVEL%
