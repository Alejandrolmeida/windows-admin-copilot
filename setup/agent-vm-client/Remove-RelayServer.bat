@echo off
:: Remove-RelayServer.bat
:: Desinstala el servidor de administracion Azure Relay de este equipo.
:: Ejecutar como Administrador.

echo ============================================================
echo  Remove-RelayServer - Desinstalar servidor de administracion
echo ============================================================
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0Remove-RelayServer.ps1"
pause
