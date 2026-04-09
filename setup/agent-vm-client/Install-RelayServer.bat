@echo off
:: Install-RelayServer.bat
:: Instala el servidor de administracion Azure Relay en ESTE equipo.
:: Ejecutar como Administrador.
::
:: Uso: Install-RelayServer.bat <ConfigFile>
:: Ejemplo: Install-RelayServer.bat server-relay.yml

echo ============================================================
echo  Install-RelayServer - Instalar servidor de administracion
echo ============================================================
echo.

if "%~1"=="" (
    echo USAGE: Install-RelayServer.bat ^<ConfigFile^>
    echo EXAMPLE: Install-RelayServer.bat server-relay.yml
    echo.
    echo Genera server-relay.yml primero con:
    echo   New-RelayNamespace.bat ^<ResourceGroup^> ^<Namespace^>
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%~dp0Install-RelayServer.ps1" -ConfigFile "%~1"
pause
