# ============================================================
# configure-winrm-target.ps1
# Configura WinRM en el equipo DESTINO (el que recibirá conexiones).
#
# Logica de protocolo:
#   - Si existe certificado valido en LocalMachine\My -> HTTPS (5986)
#   - Si no hay certificado -> crea uno autofirmado y activa HTTPS
#   - HTTP (5985) siempre se activa como fallback
#
# Uso:
#   .\configure-winrm-target.ps1
#   .\configure-winrm-target.ps1 -HttpOnly                     # Solo HTTP, sin HTTPS
#   .\configure-winrm-target.ps1 -ClientHost "192.168.1.10"    # Añade cliente a TrustedHosts
#   .\configure-winrm-target.ps1 -ClientHost "*"               # Confiar en todos (laboratorio)
#   .\configure-winrm-target.ps1 -CertThumbprint <thumbprint>  # Usar cert existente
#
# Requiere: Ejecutar como Administrador
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$HttpOnly,
    [string]$CertThumbprint,
    [string]$ClientHost        # IP o nombre del equipo cliente que se conectara a este target
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

# -------------------------------------------------------
# Verificacion de version de PowerShell
# -------------------------------------------------------
$psVersion = $PSVersionTable.PSVersion
Write-Log "PowerShell detectado: $($psVersion.Major).$($psVersion.Minor)"

if ($psVersion.Major -lt 3) {
    Write-Log "PowerShell 3.0 o superior requerido. Version actual: $psVersion" 'ERROR'
    Write-Log "Descarga WMF 5.1: https://aka.ms/wmf51" 'ERROR'
    exit 1
}

# New-SelfSignedCertificate con parametros avanzados requiere PS 5.0+
$script:advancedCertSupported = ($psVersion.Major -ge 5)

$hostname = $env:COMPUTERNAME
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Configuracion WinRM - Equipo: $hostname" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# -------------------------------------------------------
# 1. Habilitar WinRM y configuración base
# -------------------------------------------------------
Write-Log "Habilitando WinRM..."
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Write-Log "PSRemoting habilitado" 'OK'
} catch {
    Write-Log "Enable-PSRemoting falló, intentando con winrm quickconfig..." 'WARN'
    winrm quickconfig -quiet -force 2>&1 | Out-Null
}

# Asegurar que el servicio WinRM está iniciado y en arranque automático
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM -EA SilentlyContinue
Write-Log "Servicio WinRM: $(Get-Service WinRM | Select-Object -ExpandProperty Status)" 'OK'

# -------------------------------------------------------
# 2. Configuración general de WinRM
# -------------------------------------------------------
Write-Log "Aplicando configuracion general..."
winrm set winrm/config '@{MaxTimeoutms="60000"}' | Out-Null
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}' | Out-Null
winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="100"}' | Out-Null

# Autenticación: habilitar Negotiate (Kerberos en dominio, NTLM en workgroup) y Basic
winrm set winrm/config/service/auth '@{Negotiate="true"}' | Out-Null
winrm set winrm/config/service/auth '@{Kerberos="true"}'  | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}'     | Out-Null

# Detectar si está en dominio o workgroup
$domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
$isDomain = $domainRole -in @(1, 2, 3, 4, 5)  # 0=standalone workstation, 1=member workstation, etc.
if ($isDomain) {
    Write-Log "Entorno detectado: DOMINIO ($((Get-WmiObject Win32_ComputerSystem).Domain))" 'OK'
    # En dominio, AllowUnencrypted puede quedar en false
    winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
} else {
    Write-Log "Entorno detectado: WORKGROUP" 'OK'
    # En workgroup, Basic auth necesita AllowUnencrypted para HTTP
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
}

# -------------------------------------------------------
# 3. Listener HTTP (5985) — siempre activo como fallback
# -------------------------------------------------------
Write-Log "Configurando listener HTTP (5985)..."
$httpListener = winrm enumerate winrm/config/listener 2>&1 | Select-String "Transport = HTTP$"
if (-not $httpListener) {
    winrm create winrm/config/listener?Address=*+Transport=HTTP | Out-Null
    Write-Log "Listener HTTP creado" 'OK'
} else {
    Write-Log "Listener HTTP ya existe" 'OK'
}

# Regla de firewall HTTP
$fwHttp = Get-NetFirewallRule -DisplayName "WinRM HTTP (5985)" -EA SilentlyContinue
if (-not $fwHttp) {
    New-NetFirewallRule -DisplayName "WinRM HTTP (5985)" `
        -Direction Inbound -Protocol TCP -LocalPort 5985 `
        -Action Allow -Profile Domain,Private | Out-Null
    Write-Log "Regla firewall HTTP (5985) creada" 'OK'
} else {
    Write-Log "Regla firewall HTTP (5985) ya existe" 'OK'
}

# -------------------------------------------------------
# 4. Listener HTTPS (5986) — si hay o se puede crear certificado
# -------------------------------------------------------
if (-not $HttpOnly) {
    Write-Log "Buscando certificado para HTTPS..."

    $cert = $null

    # 4a. Usar thumbprint explícito si se proporcionó
    if ($CertThumbprint) {
        $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -EA SilentlyContinue
        if ($cert) {
            Write-Log "Usando certificado proporcionado: $($cert.Subject)" 'OK'
        } else {
            Write-Log "Thumbprint no encontrado en LocalMachine\My: $CertThumbprint" 'WARN'
        }
    }

    # 4b. Buscar certificado válido existente que coincida con el hostname
    if (-not $cert) {
        $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object {
                $_.Subject -match [regex]::Escape($hostname) -and
                $_.NotAfter -gt (Get-Date) -and
                $_.HasPrivateKey
            } | Sort-Object NotAfter -Descending | Select-Object -First 1

        if ($cert) {
            Write-Log "Certificado existente encontrado: $($cert.Subject) (expira: $($cert.NotAfter.ToString('yyyy-MM-dd')))" 'OK'
        }
    }

    # 4c. Crear certificado autofirmado si no hay ninguno
    if (-not $cert) {
        Write-Log "No se encontró certificado. Creando certificado autofirmado para $hostname..." 'WARN'

        if ($script:advancedCertSupported) {
            # PS 5.0+ — parámetros completos
            $cert = New-SelfSignedCertificate `
                -DnsName $hostname, "localhost" `
                -CertStoreLocation "Cert:\LocalMachine\My" `
                -NotAfter (Get-Date).AddYears(5) `
                -KeyUsage DigitalSignature, KeyEncipherment `
                -KeyAlgorithm RSA -KeyLength 2048
        } else {
            # PS 3.0/4.0 — parámetros básicos (Windows Server 2012/2012 R2)
            Write-Log "PS $($psVersion.Major).$($psVersion.Minor): usando New-SelfSignedCertificate básico" 'WARN'
            $cert = New-SelfSignedCertificate `
                -DnsName $hostname `
                -CertStoreLocation "Cert:\LocalMachine\My"
        }

        Write-Log "Certificado autofirmado creado: Thumbprint=$($cert.Thumbprint)" 'OK'
        Write-Log "NOTA: Para máxima seguridad, reemplázalo por un certificado de CA de confianza." 'WARN'
    }

    # 4d. Crear listener HTTPS
    $httpsListener = winrm enumerate winrm/config/listener 2>&1 | Select-String "Transport = HTTPS$"
    if ($httpsListener) {
        Write-Log "Eliminando listener HTTPS existente para recrearlo..." 'WARN'
        winrm delete winrm/config/listener?Address=*+Transport=HTTPS 2>&1 | Out-Null
    }

    winrm create winrm/config/listener?Address=*+Transport=HTTPS `
        "@{Hostname=`"$hostname`";CertificateThumbprint=`"$($cert.Thumbprint)`"}" | Out-Null
    Write-Log "Listener HTTPS (5986) configurado con thumbprint $($cert.Thumbprint)" 'OK'

    # Regla de firewall HTTPS
    $fwHttps = Get-NetFirewallRule -DisplayName "WinRM HTTPS (5986)" -EA SilentlyContinue
    if (-not $fwHttps) {
        New-NetFirewallRule -DisplayName "WinRM HTTPS (5986)" `
            -Direction Inbound -Protocol TCP -LocalPort 5986 `
            -Action Allow -Profile Domain,Private | Out-Null
        Write-Log "Regla firewall HTTPS (5986) creada" 'OK'
    } else {
        Write-Log "Regla firewall HTTPS (5986) ya existe" 'OK'
    }

    # Exportar certificado autofirmado para que el cliente pueda confiar en él
    if ($cert.Issuer -eq $cert.Subject) {
        $exportPath = "$env:USERPROFILE\Desktop\winrm-cert-$hostname.cer"
        Export-Certificate -Cert $cert -FilePath $exportPath -Type CERT | Out-Null
        Write-Log "Certificado exportado a: $exportPath" 'OK'
        Write-Log "Copia este .cer al equipo CLIENTE y ejecuta configure-winrm-client.ps1" 'WARN'
    }
}

# -------------------------------------------------------
# 5. TrustedHosts — añadir el cliente a la lista de confianza
# -------------------------------------------------------
if ($ClientHost) {
    Write-Log "Configurando TrustedHosts para el cliente: $ClientHost"
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value

    if ($current -eq '*') {
        Write-Log "TrustedHosts ya es '*' (confía en todos)" 'OK'
    } elseif ($ClientHost -eq '*') {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
        Write-Log "TrustedHosts establecido a '*' (confía en todos)" 'OK'
    } elseif ($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $ClientHost }) {
        Write-Log "'$ClientHost' ya estaba en TrustedHosts" 'OK'
    } else {
        $newValue = if ([string]::IsNullOrWhiteSpace($current)) { $ClientHost } else { "$current,$ClientHost" }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
        Write-Log "TrustedHosts actualizado: $newValue" 'OK'
    }
} else {
    Write-Log "TrustedHosts no modificado (usa -ClientHost <IP> para añadir el equipo cliente)" 'WARN'
}

# -------------------------------------------------------
# 6. Resumen final
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Configuracion completada en: $hostname" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

$listeners = winrm enumerate winrm/config/listener 2>&1
Write-Host "Listeners activos:" -ForegroundColor Cyan
$listeners | Select-String "(Transport|Port|Enabled|CertificateThumbprint)" | ForEach-Object {
    Write-Host "  $_"
}

Write-Host ""
Write-Log "Para conectarte desde otro equipo, ejecuta alli configure-winrm-client.ps1" 'OK'
Write-Host ""
