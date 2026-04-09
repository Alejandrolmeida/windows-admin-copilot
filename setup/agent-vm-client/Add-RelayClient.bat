@echo off
:: Add-RelayClient.bat
:: Registra un nuevo equipo cliente en Azure Relay.
:: Ejecutar en el equipo de ADMINISTRACION.
::
:: Uso: Add-RelayClient.bat <ResourceGroup> <Namespace> <MachineName>
:: Ejemplo: Add-RelayClient.bat rg-relay relay-empresa pc-juan

echo ============================================================
echo  Add-RelayClient - Registrar nuevo cliente en Azure Relay
echo ============================================================
echo.

if "%~3"=="" (
    echo USAGE: Add-RelayClient.bat ^<ResourceGroup^> ^<Namespace^> ^<MachineName^>
    echo EXAMPLE: Add-RelayClient.bat rg-relay relay-empresa pc-juan
    echo.
    echo Para opciones avanzadas, ejecuta directamente:
    echo   powershell -ExecutionPolicy Bypass -File Add-RelayClient.ps1 -ResourceGroup ^<rg^> -Namespace ^<ns^> -MachineName ^<nombre^>
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%~dp0Add-RelayClient.ps1" -ResourceGroup "%~1" -Namespace "%~2" -MachineName "%~3"
pause
