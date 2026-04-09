@echo off
:: Register-RelayClient.bat
:: Registra ESTE equipo como cliente gestionado via Azure Relay.
:: Ejecutar en el equipo CLIENTE, como Administrador.
::
:: Uso: Register-RelayClient.bat <ConfigFile>
:: Ejemplo: Register-RelayClient.bat client-pc-juan.yml

echo ============================================================
echo  Register-RelayClient - Registrar este equipo como cliente
echo ============================================================
echo.

if "%~1"=="" (
    echo USAGE: Register-RelayClient.bat ^<ConfigFile^>
    echo EXAMPLE: Register-RelayClient.bat client-pc-juan.yml
    echo.
    echo El fichero YAML lo genera el servidor con:
    echo   Add-RelayClient.bat ^<ResourceGroup^> ^<Namespace^> ^<nombre-de-este-equipo^>
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%~dp0Register-RelayClient.ps1" -ConfigFile "%~1"
pause
