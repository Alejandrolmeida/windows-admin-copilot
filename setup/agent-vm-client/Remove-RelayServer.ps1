# ============================================================
# Remove-RelayServer.ps1
# Desinstala el servidor de administracion Azure Relay de ESTE EQUIPO.
# NO elimina nada en Azure.
#
# Requisitos:
#   - Ejecutar como Administrador
#
# Uso:
#   .\Remove-RelayServer.ps1
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\RelayAdminServer',
    [string]$ServiceName = 'RelayAdminServer'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $color
}

# -------------------------------------------------------
# 1. Detener y eliminar Scheduled Task
# -------------------------------------------------------
$task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') {
        Write-Log "Deteniendo tarea '$ServiceName'..."
        Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
    Write-Log "Tarea '$ServiceName' eliminada" 'OK'
} else {
    Write-Log "Tarea '$ServiceName' no encontrada (posiblemente ya eliminada)" 'WARN'
}

# -------------------------------------------------------
# 2. Eliminar directorio de instalacion
# -------------------------------------------------------
if (Test-Path $InstallPath) {
    Remove-Item -Path $InstallPath -Recurse -Force
    Write-Log "Directorio '$InstallPath' eliminado" 'OK'
} else {
    Write-Log "Directorio '$InstallPath' no encontrado" 'WARN'
}

Write-Log "Servidor de administracion desinstalado correctamente" 'OK'
Write-Host "`nNOTA: server-relay.yml y server-registry.json NO han sido eliminados." -ForegroundColor Yellow
Write-Host "      Reinstala con: .\Install-RelayServer.ps1 -ConfigFile server-relay.yml" -ForegroundColor Yellow
