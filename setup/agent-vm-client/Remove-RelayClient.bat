@echo off
:: Desinstala el cliente proxy (AgentVMClient-<maquina> o todos con -All)
:: Requiere ejecutar como Administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Este script requiere permisos de Administrador.
    echo Haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-RelayClient.ps1" %*
pause
