@echo off
:: Instala el agente destino (AgentVMTarget) en esta maquina
:: Requiere ejecutar como Administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Este instalador requiere permisos de Administrador.
    echo Haz clic derecho y selecciona "Ejecutar como administrador".
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RelayAgent.ps1" %*
pause
