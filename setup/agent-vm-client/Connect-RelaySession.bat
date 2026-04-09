@echo off
:: Abre una sesion WinRM remota a traves de Azure Relay
:: Uso: Connect-RelaySession.bat -MachineName pc-juan -Username DOMINIO\admin
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-RelaySession.ps1" %*
