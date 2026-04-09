@echo off
:: Muestra el estado de conexion de las maquinas registradas en Azure Relay
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-VMStatus.ps1" %*
pause
