# ============================================================
# configure-winrm-client.ps1
# Configura el equipo LOCAL para conectarse via WinRM a equipos remotos.
#
# Uso:
#   .\configure-winrm-client.ps1 -RemoteHost "servidor01"
#   .\configure-winrm-client.ps1 -RemoteHost "192.168.1.50"
#   .\configure-winrm-client.ps1 -RemoteHost "srv01" -CertPath "C:\winrm-cert-srv01.cer"
#   .\configure-winrm-client.ps1 -RemoteHost "*"     # Confiar en todos (solo laboratorio)
#   .\configure-winrm-client.ps1 -Test               # Solo probar conexiones existentes
#
# Requiere: Ejecutar como Administrador
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RemoteHost,

    [string]$CertPath,       # Ruta al .cer exportado por configure-winrm-target.ps1

    [string]$Username,       # Usuario remoto (si no se indica, usa credencial interactiva)
    [string]$Password,       # Contraseña (opcional; si no se da, se pide de forma segura)

    [switch]$Test,           # Solo probar, no modificar configuración
    [switch]$HttpOnly        # Probar solo HTTP (no HTTPS)
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

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Configuracion WinRM - Equipo LOCAL"        -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# -------------------------------------------------------
# 1. Asegurar que el cliente WinRM está activo
# -------------------------------------------------------
Write-Log "Verificando servicio WinRM local..."
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM -EA SilentlyContinue
Write-Log "Servicio WinRM: $(Get-Service WinRM | Select-Object -ExpandProperty Status)" 'OK'

# -------------------------------------------------------
# 2. Configurar TrustedHosts
# -------------------------------------------------------
if ($RemoteHost -and $RemoteHost -ne '*') {

    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    $alreadyTrusted = ($current -eq '*') -or
                      ($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $RemoteHost })

    if ($Test -and -not $alreadyTrusted) {
        Write-Log "'$RemoteHost' NO está en TrustedHosts — las conexiones HTTP a IPs fallarán" 'WARN'
        Write-Log "Ejecuta el script SIN -Test primero para configurarlo, luego vuelve a probar" 'WARN'
    }

    if (-not $Test) {
        if ($current -eq '*') {
            Write-Log "TrustedHosts ya es '*' (confía en todos)" 'OK'
        } elseif ($alreadyTrusted) {
            Write-Log "'$RemoteHost' ya está en TrustedHosts" 'OK'
        } else {
            $newValue = if ([string]::IsNullOrWhiteSpace($current)) { $RemoteHost } else { "$current,$RemoteHost" }
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
            Write-Log "TrustedHosts actualizado: $newValue" 'OK'
        }

        # Mostrar valor actual
        $trusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
        Write-Log "TrustedHosts actual: $trusted" 'OK'
    }
}

# -------------------------------------------------------
# 3. Importar certificado autofirmado del servidor (para HTTPS)
# -------------------------------------------------------
if (-not $Test -and $CertPath) {
    if (Test-Path $CertPath) {
        Write-Log "Importando certificado: $CertPath"

        # Importar a Root (CA raíz de confianza) y a TrustedPeople
        Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
        Write-Log "Certificado importado en LocalMachine\Root y LocalMachine\TrustedPeople" 'OK'
    } else {
        Write-Log "No se encontró el archivo de certificado: $CertPath" 'ERROR'
        exit 1
    }
}

# -------------------------------------------------------
# 4. Modo -Test: probar conectividad con el host remoto
# -------------------------------------------------------
if ($RemoteHost -and $RemoteHost -ne '*') {

    Write-Host ""
    Write-Log "Probando conectividad con $RemoteHost..."

    # 4a. Ping básico
    $ping = Test-Connection -ComputerName $RemoteHost -Count 1 -Quiet -EA SilentlyContinue
    if ($ping) {
        Write-Log "Ping OK" 'OK'
    } else {
        Write-Log "Ping FALLÓ (puede ser bloqueado por firewall, no es crítico)" 'WARN'
    }

    # 4b. Test puerto HTTP (5985)
    $http = Test-NetConnection -ComputerName $RemoteHost -Port 5985 -InformationLevel Quiet -EA SilentlyContinue
    if ($http) {
        Write-Log "Puerto 5985 (HTTP) ABIERTO" 'OK'
    } else {
        Write-Log "Puerto 5985 (HTTP) CERRADO o inaccesible" 'WARN'
    }

    # 4c. Test puerto HTTPS (5986)
    if (-not $HttpOnly) {
        $https = Test-NetConnection -ComputerName $RemoteHost -Port 5986 -InformationLevel Quiet -EA SilentlyContinue
        if ($https) {
            Write-Log "Puerto 5986 (HTTPS) ABIERTO" 'OK'
        } else {
            Write-Log "Puerto 5986 (HTTPS) CERRADO o inaccesible" 'WARN'
        }
    }

    # 4d. Test WSMan
    $wsmanOk = Test-WSMan -ComputerName $RemoteHost -EA SilentlyContinue
    if ($wsmanOk) {
        Write-Log "WSMan responde correctamente en $RemoteHost" 'OK'
    } else {
        Write-Log "WSMan NO responde en $RemoteHost (WinRM no configurado o bloqueado)" 'WARN'
    }

    # 4e. Test de sesión real (si se proporcionaron credenciales o se piden)
    if ($Username -or $Test) {
        Write-Host ""
        Write-Log "Probando sesión remota PowerShell..."

        $cred = $null
        if ($Username) {
            if ($Password) {
                $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
                $cred   = New-Object PSCredential($Username, $secPwd)
            } else {
                $cred = Get-Credential -UserName $Username -Message "Contraseña para $RemoteHost"
            }
        }

        # Intentar primero HTTPS, luego HTTP
        $connected = $false

        if (-not $HttpOnly) {
            try {
                $soParams = @{ ComputerName = $RemoteHost; Port = 5986; UseSSL = $true
                               SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck }
                if ($cred) { $soParams.Credential = $cred }
                $session = New-PSSession @soParams -EA Stop
                Write-Log "Sesion HTTPS establecida correctamente con $RemoteHost" 'OK'
                $osInfo = Invoke-Command -Session $session { "$env:COMPUTERNAME — $(Get-WmiObject Win32_OperatingSystem | Select-Object -ExpandProperty Caption)" }
                Write-Log "Host remoto: $osInfo" 'OK'
                Remove-PSSession $session
                $connected = $true
            } catch {
                Write-Log "HTTPS falló: $_" 'WARN'
            }
        }

        if (-not $connected) {
            try {
                $soParams = @{ ComputerName = $RemoteHost; Port = 5985 }
                if ($cred) { $soParams.Credential = $cred }
                $session = New-PSSession @soParams -EA Stop
                Write-Log "Sesion HTTP establecida correctamente con $RemoteHost" 'OK'
                $osInfo = Invoke-Command -Session $session { "$env:COMPUTERNAME — $(Get-WmiObject Win32_OperatingSystem | Select-Object -ExpandProperty Caption)" }
                Write-Log "Host remoto: $osInfo" 'OK'
                Remove-PSSession $session
                $connected = $true
            } catch {
                Write-Log "HTTP falló: $_" 'ERROR'
            }
        }

        if (-not $connected) {
            Write-Log "No se pudo establecer sesión remota. Revisa las credenciales y la configuración del target." 'ERROR'
        }
    }
}

# -------------------------------------------------------
# 5. Resumen y ejemplos de uso
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Configuracion LOCAL completada" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

if ($RemoteHost -and $RemoteHost -ne '*') {
    Write-Host ""
    Write-Host "Ejemplos de conexion a $RemoteHost :" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  # PowerShell remoting (HTTPS — recomendado):" -ForegroundColor Gray
    Write-Host "  `$s = New-PSSession -ComputerName $RemoteHost -Port 5986 -UseSSL ``"
    Write-Host "        -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck)"
    Write-Host "  Invoke-Command -Session `$s { Get-Process }"
    Write-Host ""
    Write-Host "  # PowerShell remoting (HTTP):" -ForegroundColor Gray
    Write-Host "  Enter-PSSession -ComputerName $RemoteHost -Port 5985"
    Write-Host ""
    Write-Host "  # WinRM directo:" -ForegroundColor Gray
    Write-Host "  Test-WSMan -ComputerName $RemoteHost"
    Write-Host ""
}
