# ============================================================
# Remove-RelayClient.ps1
# Desinstala el servicio proxy Agent-VM-Client del PC cliente.
# Deshace todo lo que hizo Install-RelayClient.ps1.
#
# Uso:
#   .\Remove-RelayClient.ps1 -MachineName "srv01"
#   .\Remove-RelayClient.ps1 -MachineName "srv01" -KeepBinary
#   .\Remove-RelayClient.ps1 -MachineName "srv01" -Force
#   .\Remove-RelayClient.ps1 -All    # Desinstala TODOS los servicios AgentVMClient-*
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$MachineName,
    [string]$InstallPath = 'C:\AgentVMClient',
    [switch]$KeepBinary,
    [switch]$Force,
    [switch]$All
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

function Remove-ClientService {
    param([string]$SvcName, [string]$MachDir)

    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Running') {
            Write-Log "Deteniendo servicio '$SvcName'..."
            Stop-Service -Name $SvcName -Force
            Start-Sleep -Seconds 2
        }
        Write-Log "Eliminando servicio '$SvcName'..."
        sc.exe delete $SvcName | Out-Null
        Write-Log "Servicio eliminado" 'OK'
    } else {
        Write-Log "Servicio '$SvcName' no encontrado (puede que ya estuviera eliminado)." 'WARN'
    }

    if (-not $KeepBinary -and (Test-Path $MachDir)) {
        Write-Log "Eliminando configuracion en $MachDir..."
        Remove-Item -Path $MachDir -Recurse -Force
        Write-Log "Configuracion eliminada" 'OK'
    }
}

# -------------------------------------------------------
# Modo -All: desinstalar todos los servicios AgentVMClient-*
# -------------------------------------------------------
if ($All) {
    $services = Get-Service -Name 'AgentVMClient-*' -ErrorAction SilentlyContinue
    if (-not $services) {
        Write-Log "No se encontraron servicios AgentVMClient-* instalados." 'WARN'
        exit 0
    }
    if (-not $Force) {
        Write-Host "`nServicios a eliminar:" -ForegroundColor Yellow
        $services | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Yellow }
        $confirm = Read-Host "Confirmar eliminacion de todos los servicios? [s/N]"
        if ($confirm -notmatch '^[sS]$') { Write-Log "Cancelado." 'WARN'; exit 0 }
    }
    foreach ($svc in $services) {
        $mName = $svc.Name -replace '^AgentVMClient-', ''
        $mDir  = Join-Path $InstallPath $mName
        Remove-ClientService -SvcName $svc.Name -MachDir $mDir
    }
} else {
    # -------------------------------------------------------
    # Modo individual: desinstalar una maquina
    # -------------------------------------------------------
    if (-not $MachineName) {
        Write-Log "Debes indicar -MachineName <nombre> o usar -All para eliminar todos." 'ERROR'
        exit 1
    }
    $ServiceName = "AgentVMClient-$MachineName"
    $machineDir  = Join-Path $InstallPath $MachineName

    if (-not $Force) {
        $confirm = Read-Host "Esto eliminara el servicio '$ServiceName' y su config. Continuar? [s/N]"
        if ($confirm -notmatch '^[sS]$') { Write-Log "Cancelado." 'WARN'; exit 0 }
    }
    Remove-ClientService -SvcName $ServiceName -MachDir $machineDir
}

# -------------------------------------------------------
# Eliminar binario compartido si no quedan servicios
# -------------------------------------------------------
if (-not $KeepBinary) {
    $remaining = Get-Service -Name 'AgentVMClient-*' -ErrorAction SilentlyContinue
    if (-not $remaining) {
        $exePath = Join-Path $InstallPath 'azbridge.exe'
        if (Test-Path $exePath) {
            Write-Log "No quedan servicios AgentVMClient. Eliminando binario azbridge.exe..."
            Remove-Item $exePath -Force -ErrorAction SilentlyContinue
        }
        # Eliminar el directorio base si esta vacio
        if ((Test-Path $InstallPath) -and (-not (Get-ChildItem $InstallPath))) {
            Remove-Item $InstallPath -Force
        }
    }
}

Write-Log "Desinstalacion completada" 'OK'
