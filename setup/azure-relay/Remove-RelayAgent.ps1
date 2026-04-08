# ============================================================
# Remove-RelayAgent.ps1
# Desinstala el agente azbridge del equipo DESTINO.
# Deshace todo lo que hizo Install-RelayAgent.ps1.
#
# Uso:
#   .\Remove-RelayAgent.ps1
#   .\Remove-RelayAgent.ps1 -InstallPath "D:\azbridge" -ServiceName "AzRelayBridge"
#   .\Remove-RelayAgent.ps1 -KeepBinary    # Solo para el servicio, deja el exe
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = 'C:\azbridge',
    [string]$ServiceName = 'AzRelayBridge',
    [switch]$KeepBinary,
    [switch]$Force
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

if (-not $Force) {
    $confirm = Read-Host "Esto eliminara el servicio '$ServiceName' y los ficheros en '$InstallPath'. Continuar? [s/N]"
    if ($confirm -notmatch '^[sS]$') {
        Write-Log "Cancelado por el usuario." 'WARN'
        exit 0
    }
}

# -------------------------------------------------------
# 1. Detener y eliminar el servicio
# -------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Write-Log "Deteniendo servicio '$ServiceName'..."
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2
    }
    Write-Log "Eliminando servicio '$ServiceName'..."
    sc.exe delete $ServiceName | Out-Null
    Write-Log "Servicio eliminado" 'OK'
} else {
    Write-Log "Servicio '$ServiceName' no encontrado (puede que ya estuviera eliminado)." 'WARN'
}

# -------------------------------------------------------
# 2. Eliminar ficheros de instalacion
# -------------------------------------------------------
if (-not $KeepBinary) {
    if (Test-Path $InstallPath) {
        Write-Log "Eliminando directorio $InstallPath..."
        Remove-Item -Path $InstallPath -Recurse -Force
        Write-Log "Directorio eliminado" 'OK'
    } else {
        Write-Log "Directorio $InstallPath no encontrado." 'WARN'
    }
} else {
    Write-Log "Conservando binario en $InstallPath (-KeepBinary activo)" 'WARN'
    $configFile = Join-Path $InstallPath 'azbridge.config.yml'
    if (Test-Path $configFile) {
        Remove-Item $configFile -Force
        Write-Log "Config eliminada (el binario se conserva)" 'OK'
    }
}

Write-Log "Desinstalacion completada" 'OK'
