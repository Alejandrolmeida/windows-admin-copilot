@echo off
:: Abre una sesion WinRM remota a traves de Azure Relay
:: Uso: Connect-RelaySession.bat -ConfigFile client-mivm.yml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-RelaySession.ps1" %*
