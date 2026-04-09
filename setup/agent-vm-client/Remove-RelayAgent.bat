@echo off
:: Desinstala el agente destino (AgentVMTarget) de esta maquina
:: Requiere ejecutar como Administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Este script requiere permisos de Administrador.
    echo Haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-RelayAgent.ps1" %*
pause
