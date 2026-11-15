@echo off
rem Double-click to deploy Nocturne to Azure. Extra arguments are passed through, e.g.
rem   Deploy-NocturneAzure.cmd -Domain nocturne.example.com
rem   Deploy-NocturneAzure.cmd -TenantId <tenant-id>
rem   Deploy-NocturneAzure.cmd -Action Remove
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-NocturneAzure.ps1" %*
echo.
pause
