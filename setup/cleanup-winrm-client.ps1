# ============================================================
# cleanup-winrm-client.ps1
# Deshace la configuracion aplicada por configure-winrm-client.ps1:
#   - Elimina el host de TrustedHosts
#   - Elimina el certificado del servidor de los almacenes de confianza
#   - Cierra sesiones PSSession abiertas con ese host
#   - Opcionalmente detiene el servicio WinRM (-StopWinRM)
#
# Uso:
#   .\cleanup-winrm-client.ps1 -RemoteHost "servidor01"
#   .\cleanup-winrm-client.ps1 -RemoteHost "servidor01" -CertThumbprint "ABC123..."
#   .\cleanup-winrm-client.ps1 -RemoteHost "servidor01" -StopWinRM
#   .\cleanup-winrm-client.ps1 -ClearAllTrustedHosts   # Borra todos los TrustedHosts
#
# Requiere: Ejecutar como Administrador
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RemoteHost,

    [string]$CertThumbprint,     # Thumbprint especifico a eliminar (opcional)

    [switch]$StopWinRM,          # Detener y deshabilitar el servicio WinRM al finalizar
    [switch]$ClearAllTrustedHosts, # Borrar todos los TrustedHosts (no solo el host indicado)
    [switch]$Force               # No pedir confirmacion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

if (-not $RemoteHost -and -not $ClearAllTrustedHosts) {
    Write-Log "Debes indicar -RemoteHost <nombre> o -ClearAllTrustedHosts" 'ERROR'
    Write-Host ""
    Write-Host "Uso: .\cleanup-winrm-client.ps1 -RemoteHost 'servidor01'" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Limpieza WinRM cliente - $(if ($RemoteHost) { $RemoteHost } else { 'TODOS' })" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# -------------------------------------------------------
# 1. Cerrar sesiones PSSession abiertas con el host
# -------------------------------------------------------
if ($RemoteHost) {
    Write-Log "Cerrando sesiones PSSession abiertas con $RemoteHost..."
    $sessions = Get-PSSession | Where-Object { $_.ComputerName -eq $RemoteHost }
    if ($sessions) {
        $sessions | Remove-PSSession
        Write-Log "$($sessions.Count) sesion(es) cerrada(s)" 'OK'
    } else {
        Write-Log "No hay sesiones abiertas con $RemoteHost" 'OK'
    }
}

# -------------------------------------------------------
# 2. Eliminar de TrustedHosts
# -------------------------------------------------------
Write-Log "Actualizando TrustedHosts..."

$current = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value

if ([string]::IsNullOrWhiteSpace($current)) {
    Write-Log "TrustedHosts ya está vacío" 'OK'
} elseif ($ClearAllTrustedHosts) {
    if ($Force -or $PSCmdlet.ShouldProcess("TrustedHosts", "Borrar todos los hosts")) {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "" -Force
        Write-Log "TrustedHosts vaciado completamente" 'OK'
    }
} else {
    $hosts = $current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne $RemoteHost -and $_ -ne '' }
    $newValue = $hosts -join ','
    if ($newValue -ne $current) {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
        Write-Log "'$RemoteHost' eliminado de TrustedHosts" 'OK'
        if ($newValue) {
            Write-Log "TrustedHosts restante: $newValue" 'OK'
        } else {
            Write-Log "TrustedHosts ahora está vacío" 'OK'
        }
    } else {
        Write-Log "'$RemoteHost' no estaba en TrustedHosts" 'OK'
    }
}

# -------------------------------------------------------
# 3. Eliminar certificados del servidor de los almacenes de confianza
# -------------------------------------------------------
Write-Log "Buscando certificados del servidor en almacenes de confianza..."

$stores = @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPeople')
$removed = 0

foreach ($store in $stores) {
    # Buscar por thumbprint explícito
    if ($CertThumbprint) {
        $cert = Get-Item "$store\$CertThumbprint" -EA SilentlyContinue
        if ($cert) {
            if ($Force -or $PSCmdlet.ShouldProcess("$store\$CertThumbprint", "Eliminar certificado")) {
                Remove-Item "$store\$CertThumbprint" -Force
                Write-Log "Eliminado de $store : $CertThumbprint" 'OK'
                $removed++
            }
        }
    } elseif ($RemoteHost) {
        # Buscar por nombre del host en Subject o DnsNameList
        $certs = Get-ChildItem $store -EA SilentlyContinue | Where-Object {
            ($_.Subject -match [regex]::Escape($RemoteHost)) -or
            ($_.DnsNameList -and ($_.DnsNameList.Unicode -contains $RemoteHost))
        }
        foreach ($cert in $certs) {
            if ($Force -or $PSCmdlet.ShouldProcess("$store\$($cert.Thumbprint)", "Eliminar certificado '$($cert.Subject)'")) {
                Remove-Item "$store\$($cert.Thumbprint)" -Force
                Write-Log "Eliminado de $store : $($cert.Subject) [$($cert.Thumbprint)]" 'OK'
                $removed++
            }
        }
    }
}

if ($removed -eq 0) {
    Write-Log "No se encontraron certificados relacionados con '$RemoteHost' en los almacenes de confianza" 'OK'
} else {
    Write-Log "$removed certificado(s) eliminado(s) de los almacenes de confianza" 'OK'
}

# -------------------------------------------------------
# 4. Detener WinRM (opcional)
# -------------------------------------------------------
if ($StopWinRM) {
    Write-Log "Deteniendo y deshabilitando el servicio WinRM..."
    # Solo deshabilitar si no hay ningún TrustedHost restante y no hay sesiones abiertas
    $remainingTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value
    $remainingSessions = Get-PSSession -EA SilentlyContinue

    if ($remainingTrusted -or $remainingSessions) {
        Write-Log "Hay TrustedHosts o sesiones activas — WinRM no se detendrá para no interrumpir otras conexiones" 'WARN'
        Write-Log "Usa -ClearAllTrustedHosts junto con -StopWinRM para forzarlo" 'WARN'
    } else {
        if ($Force -or $PSCmdlet.ShouldProcess("WinRM", "Detener y deshabilitar servicio")) {
            Stop-Service WinRM -Force
            Set-Service WinRM -StartupType Manual
            Write-Log "Servicio WinRM detenido y establecido en inicio Manual" 'OK'
        }
    }
}

# -------------------------------------------------------
# 5. Resumen
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Limpieza completada" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

$trustedFinal = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value
$wmrmStatus   = (Get-Service WinRM -EA SilentlyContinue).Status

Write-Log "TrustedHosts: $(if ($trustedFinal) { $trustedFinal } else { '(vacío)' })" 'OK'
Write-Log "Servicio WinRM: $wmrmStatus" 'OK'
Write-Host ""
