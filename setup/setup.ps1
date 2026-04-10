#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Admin Copilot - Setup unificado

.DESCRIPTION
    Instala y configura todo el entorno: herramientas, servidores MCP y WinRM.

.PARAMETER Action
    Accion a realizar:
      all           - Setup completo (default): instala herramientas + servidores MCP
      install       - Solo instala PowerShell 7, Copilot CLI y dependencias
      winrm-target  - Configura este equipo como destino WinRM
      winrm-client  - Configura este equipo como cliente WinRM
      winrm-cleanup - Deshace la configuracion de cliente WinRM

.PARAMETER RemoteHost
    (winrm-client / winrm-cleanup) Nombre o IP del servidor remoto.

.PARAMETER CertPath
    (winrm-client) Ruta al .cer exportado por la accion winrm-target.

.PARAMETER CertThumbprint
    (winrm-target) Thumbprint de un certificado existente a usar para HTTPS.
    (winrm-cleanup) Thumbprint especifico a eliminar.

.PARAMETER Username
    (winrm-client) Usuario para probar la sesion remota.

.PARAMETER Password
    (winrm-client) Contrasena del usuario remoto (si no se indica, se pide de forma segura).

.PARAMETER ClientHost
    (winrm-target) IP o nombre del equipo cliente que se conectara a este target.

.PARAMETER HttpOnly
    (winrm-target / winrm-client) Solo HTTP; no configurar ni probar HTTPS.

.PARAMETER Test
    (winrm-client) Solo probar conectividad, sin modificar configuracion.

.PARAMETER StopWinRM
    (winrm-cleanup) Detiene y deshabilita el servicio WinRM al finalizar.

.PARAMETER ClearAllTrustedHosts
    (winrm-cleanup) Borra todos los TrustedHosts, no solo el host indicado.

.PARAMETER Force
    (winrm-cleanup) No pedir confirmacion en operaciones destructivas.

.EXAMPLE
    .\setup.ps1

.EXAMPLE
    .\setup.ps1 -Action install

.EXAMPLE
    .\setup.ps1 -Action winrm-target -ClientHost "192.168.1.10"

.EXAMPLE
    .\setup.ps1 -Action winrm-client -RemoteHost "servidor01" -CertPath "C:\winrm-cert-srv01.cer"

.EXAMPLE
    .\setup.ps1 -Action winrm-client -RemoteHost "servidor01" -Test

.EXAMPLE
    .\setup.ps1 -Action winrm-cleanup -RemoteHost "servidor01"

.EXAMPLE
    .\setup.ps1 -Action winrm-cleanup -ClearAllTrustedHosts -StopWinRM
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'install', 'winrm-target', 'winrm-client', 'winrm-cleanup')]
    [string]$Action = 'all',

    # --- WinRM: cliente y cleanup ---
    [string]$RemoteHost,
    [string]$CertPath,
    [string]$CertThumbprint,
    [string]$Username,
    [string]$Password,

    # --- WinRM: target ---
    [string]$ClientHost,

    # --- Flags compartidos ---
    [switch]$HttpOnly,

    # --- Flags cliente ---
    [switch]$Test,

    # --- Flags cleanup ---
    [switch]$StopWinRM,
    [switch]$ClearAllTrustedHosts,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path $MyInvocation.MyCommand.Path

# ================================================================
# Helpers
# ================================================================

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

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

function Find-PythonExe {
    $candidates = @(
        "$env:USERPROFILE\miniconda3\python.exe",
        "$env:USERPROFILE\miniconda3\envs\base\python.exe",
        "$env:USERPROFILE\anaconda3\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $pyCmd = Get-Command python -EA SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -notlike '*WindowsApps*') {
        if ((& $pyCmd.Source --version 2>&1) -match 'Python \d') { return $pyCmd.Source }
    }
    return $null
}

# ================================================================
# ACCION: install  (PowerShell 7 + Copilot CLI + dependencias)
# ================================================================

function Invoke-Install {

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  Windows Admin Copilot - Instalacion' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    # --- [1/3] Python ---
    Write-Host ''
    Write-Host '[1/3] Comprobando Python...' -ForegroundColor Yellow

    $pythonExe = Find-PythonExe
    if (-not $pythonExe) {
        Write-Log 'Python no encontrado. Instalando Miniconda3...' 'WARN'
        winget install --id Anaconda.Miniconda3 --silent --accept-source-agreements --accept-package-agreements
        Refresh-Path
        $pythonExe = Find-PythonExe
    }

    if (-not $pythonExe) {
        Write-Log 'Miniconda3 no disponible. Intentando Python 3.13...' 'WARN'
        winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
        Refresh-Path
        $pythonExe = Find-PythonExe
    }

    if ($pythonExe) {
        Write-Log "Python: $pythonExe ($( & $pythonExe --version 2>&1))" 'OK'
        & $pythonExe -m ensurepip --upgrade 2>&1 | Out-Null
        & $pythonExe -m pip install --upgrade pip --quiet
        Write-Log "pip: $( & $pythonExe -m pip --version 2>&1)" 'OK'
    } else {
        Write-Log 'No se pudo instalar Python. Los servidores MCP que lo requieren no funcionaran.' 'ERROR'
    }

    # --- [2/3] PowerShell 7 ---
    Write-Host ''
    Write-Host '[2/3] Instalando PowerShell 7...' -ForegroundColor Yellow

    if (Get-Command winget -EA SilentlyContinue) {
        winget install --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
    } else {
        $url = 'https://aka.ms/install-powershell.ps1'
        Invoke-Expression "& { $(Invoke-RestMethod $url) } -UseMSI -Quiet"
    }

    Refresh-Path

    $pwsh = Get-Command pwsh -EA SilentlyContinue
    if ($pwsh) {
        Write-Log "PowerShell $( & pwsh -NoProfile -Command '$PSVersionTable.PSVersion') instalado" 'OK'
    } else {
        Write-Log 'Reinicia la terminal y verifica con: pwsh --version' 'WARN'
    }

    # --- [3/3] Copilot CLI y dependencias ---
    Write-Host ''
    Write-Host '[3/3] Instalando Copilot CLI, Node.js y Git...' -ForegroundColor Yellow

    if (-not (Get-Command node -EA SilentlyContinue)) {
        Write-Log 'Instalando Node.js...' 'WARN'
        winget install --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
    }

    if (-not (Get-Command git -EA SilentlyContinue)) {
        Write-Log 'Instalando Git...' 'WARN'
        winget install --id Git.Git --silent --accept-source-agreements --accept-package-agreements
    }

    Write-Log 'Instalando GitHub Copilot CLI...' 'INFO'
    winget install --id GitHub.Copilot --silent --accept-source-agreements --accept-package-agreements

    Refresh-Path

    Write-Host ''
    Write-Host '=== Verificacion ===' -ForegroundColor Cyan
    Write-Host "Python  : $( if ($pythonExe) { & $pythonExe --version 2>&1 } else { 'NO ENCONTRADO' })"
    Write-Host "Node.js : $(node  --version 2>&1)"
    Write-Host "Git     : $(git   --version 2>&1)"
    Write-Host "Copilot : $(copilot --version 2>&1)"
    Write-Host ''
    Write-Log "Ejecuta 'copilot' y usa /login para autenticarte con GitHub" 'OK'
}

# ================================================================
# ACCION: all  (install + MCP servers)
# ================================================================

function Invoke-SetupAll {

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  Windows Admin Copilot - Setup Completo' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    Invoke-Install

    Write-Host ''
    Write-Host '[+] Configurando servidores MCP...' -ForegroundColor Yellow

    $mcpScript = Join-Path $script:Root '..\mcp-servers\install-mcp-servers.ps1'
    if (Test-Path $mcpScript) {
        & $mcpScript
    } else {
        Write-Log "No se encontro install-mcp-servers.ps1 en: $mcpScript" 'ERROR'
        exit 1
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  Setup completado. Proximos pasos:' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host "1. El mcp-config.json fue copiado a $env:USERPROFILE\.copilot\"
    Write-Host "2. Edita $env:USERPROFILE\.copilot\mcp-config.json con tus credenciales"
    Write-Host "3. Ejecuta 'copilot' y usa /login para autenticarte"
    Write-Host "4. Usa /mcp para verificar los servidores MCP activos"
    Write-Host ''
    Write-Host 'Para futuras actualizaciones:' -ForegroundColor Cyan
    Write-Host "  git pull && .\setup\setup.ps1" -ForegroundColor Cyan
}

# ================================================================
# ACCION: winrm-target
# ================================================================

function Invoke-WinRMTarget {

    $psVersion = $PSVersionTable.PSVersion
    Write-Log "PowerShell detectado: $($psVersion.Major).$($psVersion.Minor)"

    if ($psVersion.Major -lt 3) {
        Write-Log "PowerShell 3.0+ requerido. Version actual: $psVersion" 'ERROR'
        Write-Log 'Descarga WMF 5.1: https://aka.ms/wmf51' 'ERROR'
        exit 1
    }

    $advancedCert = ($psVersion.Major -ge 5)
    $hostname     = $env:COMPUTERNAME

    Write-Host ''
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host "  Configuracion WinRM - Equipo: $hostname"   -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''

    # 1. Habilitar WinRM
    Write-Log 'Habilitando WinRM...'
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
        Write-Log 'PSRemoting habilitado' 'OK'
    } catch {
        Write-Log 'Enable-PSRemoting fallo — usando winrm quickconfig...' 'WARN'
        winrm quickconfig -quiet -force 2>&1 | Out-Null
    }

    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM -EA SilentlyContinue
    Write-Log "Servicio WinRM: $(Get-Service WinRM | Select-Object -ExpandProperty Status)" 'OK'

    # 2. Configuracion general
    Write-Log 'Aplicando configuracion general...'
    winrm set winrm/config '@{MaxTimeoutms="60000"}' | Out-Null
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}' | Out-Null
    winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="100"}' | Out-Null
    winrm set winrm/config/service/auth '@{Negotiate="true"}' | Out-Null
    winrm set winrm/config/service/auth '@{Kerberos="true"}'  | Out-Null
    winrm set winrm/config/service/auth '@{Basic="true"}'     | Out-Null

    $domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
    $isDomain   = $domainRole -in @(1, 2, 3, 4, 5)

    if ($isDomain) {
        Write-Log "Entorno: DOMINIO ($((Get-WmiObject Win32_ComputerSystem).Domain))" 'OK'
        winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
    } else {
        Write-Log 'Entorno: WORKGROUP' 'OK'
        winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
    }

    # 3. Listener HTTP
    Write-Log 'Configurando listener HTTP (5985)...'
    $httpListener = winrm enumerate winrm/config/listener 2>&1 | Select-String 'Transport = HTTP$'
    if (-not $httpListener) {
        winrm create winrm/config/listener?Address=*+Transport=HTTP | Out-Null
        Write-Log 'Listener HTTP creado' 'OK'
    } else {
        Write-Log 'Listener HTTP ya existe' 'OK'
    }

    $fwHttp = Get-NetFirewallRule -DisplayName 'WinRM HTTP (5985)' -EA SilentlyContinue
    if (-not $fwHttp) {
        New-NetFirewallRule -DisplayName 'WinRM HTTP (5985)' `
            -Direction Inbound -Protocol TCP -LocalPort 5985 `
            -Action Allow -Profile Domain,Private | Out-Null
        Write-Log 'Regla firewall HTTP (5985) creada' 'OK'
    } else {
        Write-Log 'Regla firewall HTTP (5985) ya existe' 'OK'
    }

    # 4. Listener HTTPS
    if (-not $HttpOnly) {
        Write-Log 'Buscando certificado para HTTPS...'
        $cert = $null

        if ($CertThumbprint) {
            $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -EA SilentlyContinue
            if ($cert) {
                Write-Log "Usando certificado proporcionado: $($cert.Subject)" 'OK'
            } else {
                Write-Log "Thumbprint no encontrado en LocalMachine\My: $CertThumbprint" 'WARN'
            }
        }

        if (-not $cert) {
            $cert = Get-ChildItem Cert:\LocalMachine\My |
                Where-Object {
                    $_.Subject -match [regex]::Escape($hostname) -and
                    $_.NotAfter -gt (Get-Date) -and
                    $_.HasPrivateKey
                } | Sort-Object NotAfter -Descending | Select-Object -First 1

            if ($cert) {
                Write-Log "Certificado existente: $($cert.Subject) (expira: $($cert.NotAfter.ToString('yyyy-MM-dd')))" 'OK'
            }
        }

        if (-not $cert) {
            Write-Log "Creando certificado autofirmado para $hostname..." 'WARN'
            if ($advancedCert) {
                $cert = New-SelfSignedCertificate `
                    -DnsName $hostname, 'localhost' `
                    -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -NotAfter (Get-Date).AddYears(5) `
                    -KeyUsage DigitalSignature, KeyEncipherment `
                    -KeyAlgorithm RSA -KeyLength 2048
            } else {
                Write-Log "PS $($psVersion.Major).$($psVersion.Minor): usando New-SelfSignedCertificate basico" 'WARN'
                $cert = New-SelfSignedCertificate `
                    -DnsName $hostname `
                    -CertStoreLocation 'Cert:\LocalMachine\My'
            }
            Write-Log "Certificado autofirmado creado: $($cert.Thumbprint)" 'OK'
            Write-Log 'Para produccion, reemplazalo por un certificado de CA.' 'WARN'
        }

        $httpsListener = winrm enumerate winrm/config/listener 2>&1 | Select-String 'Transport = HTTPS$'
        if ($httpsListener) {
            Write-Log 'Eliminando listener HTTPS existente para recrearlo...' 'WARN'
            winrm delete winrm/config/listener?Address=*+Transport=HTTPS 2>&1 | Out-Null
        }

        winrm create winrm/config/listener?Address=*+Transport=HTTPS `
            "@{Hostname=`"$hostname`";CertificateThumbprint=`"$($cert.Thumbprint)`"}" | Out-Null
        Write-Log "Listener HTTPS (5986) configurado con thumbprint $($cert.Thumbprint)" 'OK'

        $fwHttps = Get-NetFirewallRule -DisplayName 'WinRM HTTPS (5986)' -EA SilentlyContinue
        if (-not $fwHttps) {
            New-NetFirewallRule -DisplayName 'WinRM HTTPS (5986)' `
                -Direction Inbound -Protocol TCP -LocalPort 5986 `
                -Action Allow -Profile Domain,Private | Out-Null
            Write-Log 'Regla firewall HTTPS (5986) creada' 'OK'
        } else {
            Write-Log 'Regla firewall HTTPS (5986) ya existe' 'OK'
        }

        if ($cert.Issuer -eq $cert.Subject) {
            $exportPath = "$env:USERPROFILE\Desktop\winrm-cert-$hostname.cer"
            Export-Certificate -Cert $cert -FilePath $exportPath -Type CERT | Out-Null
            Write-Log "Certificado exportado: $exportPath" 'OK'
            Write-Log 'Copia este .cer al equipo cliente y ejecuta: .\setup.ps1 -Action winrm-client -CertPath <ruta>' 'WARN'
        }
    }

    # 5. TrustedHosts en el target
    if ($ClientHost) {
        Write-Log "Configurando TrustedHosts para el cliente: $ClientHost"
        $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value

        if ($current -eq '*') {
            Write-Log "TrustedHosts ya es '*' (confia en todos)" 'OK'
        } elseif ($ClientHost -eq '*') {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
            Write-Log "TrustedHosts establecido a '*'" 'OK'
        } elseif ($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $ClientHost }) {
            Write-Log "'$ClientHost' ya estaba en TrustedHosts" 'OK'
        } else {
            $newValue = if ([string]::IsNullOrWhiteSpace($current)) { $ClientHost } else { "$current,$ClientHost" }
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
            Write-Log "TrustedHosts actualizado: $newValue" 'OK'
        }
    } else {
        Write-Log 'TrustedHosts no modificado (usa -ClientHost <IP> para anadir el equipo cliente)' 'WARN'
    }

    # Resumen
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host "  Configuracion completada en: $hostname" -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host ''

    $listeners = winrm enumerate winrm/config/listener 2>&1
    Write-Host 'Listeners activos:' -ForegroundColor Cyan
    $listeners | Select-String '(Transport|Port|Enabled|CertificateThumbprint)' | ForEach-Object {
        Write-Host "  $_"
    }
    Write-Host ''
    Write-Log 'Para conectarte desde otro equipo, ejecuta: .\setup.ps1 -Action winrm-client -RemoteHost <IP>' 'OK'
    Write-Host ''
}

# ================================================================
# ACCION: winrm-client
# ================================================================

function Invoke-WinRMClient {

    Write-Host ''
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host '  Configuracion WinRM - Equipo LOCAL'        -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''

    # 1. Asegurar que el cliente WinRM está activo
    Write-Log 'Verificando servicio WinRM local...'
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM -EA SilentlyContinue
    Write-Log "Servicio WinRM: $(Get-Service WinRM | Select-Object -ExpandProperty Status)" 'OK'

    # 2. TrustedHosts
    if ($RemoteHost -and $RemoteHost -ne '*') {
        $current       = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
        $alreadyTrusted = ($current -eq '*') -or
                          ($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $RemoteHost })

        if ($Test -and -not $alreadyTrusted) {
            Write-Log "'$RemoteHost' NO esta en TrustedHosts — las conexiones HTTP fallaran" 'WARN'
            Write-Log 'Ejecuta el script SIN -Test primero para configurarlo' 'WARN'
        }

        if (-not $Test) {
            if ($current -eq '*') {
                Write-Log "TrustedHosts ya es '*' (confia en todos)" 'OK'
            } elseif ($alreadyTrusted) {
                Write-Log "'$RemoteHost' ya esta en TrustedHosts" 'OK'
            } else {
                $newValue = if ([string]::IsNullOrWhiteSpace($current)) { $RemoteHost } else { "$current,$RemoteHost" }
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
                Write-Log "TrustedHosts actualizado: $newValue" 'OK'
            }
            Write-Log "TrustedHosts actual: $((Get-Item WSMan:\localhost\Client\TrustedHosts).Value)" 'OK'
        }
    }

    # 3. Importar certificado del servidor
    if (-not $Test -and $CertPath) {
        if (Test-Path $CertPath) {
            Write-Log "Importando certificado: $CertPath"
            Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\Root         | Out-Null
            Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
            Write-Log 'Certificado importado en LocalMachine\Root y LocalMachine\TrustedPeople' 'OK'
        } else {
            Write-Log "No se encontro el archivo de certificado: $CertPath" 'ERROR'
            exit 1
        }
    }

    # 4. Prueba de conectividad
    if ($RemoteHost -and $RemoteHost -ne '*') {
        Write-Host ''
        Write-Log "Probando conectividad con $RemoteHost..."

        $ping = Test-Connection -ComputerName $RemoteHost -Count 1 -Quiet -EA SilentlyContinue
        if ($ping) { Write-Log 'Ping OK' 'OK' } else { Write-Log 'Ping fallo (puede ser bloqueado por firewall)' 'WARN' }

        $http = Test-NetConnection -ComputerName $RemoteHost -Port 5985 -InformationLevel Quiet -EA SilentlyContinue
        if ($http) { Write-Log 'Puerto 5985 (HTTP) ABIERTO' 'OK' } else { Write-Log 'Puerto 5985 (HTTP) CERRADO' 'WARN' }

        if (-not $HttpOnly) {
            $https = Test-NetConnection -ComputerName $RemoteHost -Port 5986 -InformationLevel Quiet -EA SilentlyContinue
            if ($https) { Write-Log 'Puerto 5986 (HTTPS) ABIERTO' 'OK' } else { Write-Log 'Puerto 5986 (HTTPS) CERRADO' 'WARN' }
        }

        $wsmanOk = Test-WSMan -ComputerName $RemoteHost -EA SilentlyContinue
        if ($wsmanOk) {
            Write-Log "WSMan responde correctamente en $RemoteHost" 'OK'
        } else {
            Write-Log "WSMan NO responde en $RemoteHost" 'WARN'
        }

        if ($Username -or $Test) {
            Write-Host ''
            Write-Log 'Probando sesion remota PowerShell...'

            $cred = $null
            if ($Username) {
                if ($Password) {
                    $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
                    $cred   = New-Object PSCredential($Username, $secPwd)
                } else {
                    $cred = Get-Credential -UserName $Username -Message "Contrasena para $RemoteHost"
                }
            }

            $connected = $false

            if (-not $HttpOnly) {
                try {
                    $soParams = @{ ComputerName = $RemoteHost; Port = 5986; UseSSL = $true
                                   SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck }
                    if ($cred) { $soParams.Credential = $cred }
                    $session = New-PSSession @soParams -EA Stop
                    Write-Log "Sesion HTTPS establecida con $RemoteHost" 'OK'
                    $osInfo = Invoke-Command -Session $session {
                        "$env:COMPUTERNAME - $(Get-WmiObject Win32_OperatingSystem | Select-Object -ExpandProperty Caption)"
                    }
                    Write-Log "Host remoto: $osInfo" 'OK'
                    Remove-PSSession $session
                    $connected = $true
                } catch {
                    Write-Log "HTTPS fallo: $_" 'WARN'
                }
            }

            if (-not $connected) {
                try {
                    $soParams = @{ ComputerName = $RemoteHost; Port = 5985 }
                    if ($cred) { $soParams.Credential = $cred }
                    $session = New-PSSession @soParams -EA Stop
                    Write-Log "Sesion HTTP establecida con $RemoteHost" 'OK'
                    $osInfo = Invoke-Command -Session $session {
                        "$env:COMPUTERNAME - $(Get-WmiObject Win32_OperatingSystem | Select-Object -ExpandProperty Caption)"
                    }
                    Write-Log "Host remoto: $osInfo" 'OK'
                    Remove-PSSession $session
                    $connected = $true
                } catch {
                    Write-Log "HTTP fallo: $_" 'ERROR'
                }
            }

            if (-not $connected) {
                Write-Log 'No se pudo establecer sesion remota. Revisa credenciales y configuracion del target.' 'ERROR'
            }
        }
    }

    # Resumen
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host '  Configuracion LOCAL completada' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green

    if ($RemoteHost -and $RemoteHost -ne '*') {
        Write-Host ''
        Write-Host "Ejemplos de conexion a ${RemoteHost}:" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  # PowerShell remoting (HTTPS — recomendado):' -ForegroundColor Gray
        Write-Host "  `$s = New-PSSession -ComputerName $RemoteHost -Port 5986 -UseSSL ``"
        Write-Host '        -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck)'
        Write-Host '  Invoke-Command -Session $s { Get-Process }'
        Write-Host ''
        Write-Host '  # PowerShell remoting (HTTP):' -ForegroundColor Gray
        Write-Host "  Enter-PSSession -ComputerName $RemoteHost -Port 5985"
        Write-Host ''
        Write-Host '  # WinRM directo:' -ForegroundColor Gray
        Write-Host "  Test-WSMan -ComputerName $RemoteHost"
        Write-Host ''
    }
}

# ================================================================
# ACCION: winrm-cleanup
# ================================================================

function Invoke-WinRMCleanup {

    if (-not $RemoteHost -and -not $ClearAllTrustedHosts) {
        Write-Log 'Debes indicar -RemoteHost <nombre> o -ClearAllTrustedHosts' 'ERROR'
        Write-Host ''
        Write-Host "Uso: .\setup.ps1 -Action winrm-cleanup -RemoteHost 'servidor01'" -ForegroundColor Yellow
        exit 1
    }

    Write-Host ''
    Write-Host '============================================' -ForegroundColor Cyan
    $label = if ($RemoteHost) { $RemoteHost } else { 'TODOS' }
    Write-Host "  Limpieza WinRM cliente - $label" -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''

    # 1. Cerrar sesiones PSSession
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

    # 2. TrustedHosts
    Write-Log 'Actualizando TrustedHosts...'
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value

    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Log 'TrustedHosts ya esta vacio' 'OK'
    } elseif ($ClearAllTrustedHosts) {
        if ($Force -or $PSCmdlet.ShouldProcess('TrustedHosts', 'Borrar todos los hosts')) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value '' -Force
            Write-Log 'TrustedHosts vaciado completamente' 'OK'
        }
    } else {
        $hosts    = $current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne $RemoteHost -and $_ -ne '' }
        $newValue = $hosts -join ','
        if ($newValue -ne $current) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force
            Write-Log "'$RemoteHost' eliminado de TrustedHosts" 'OK'
            Write-Log "TrustedHosts restante: $(if ($newValue) { $newValue } else { '(vacio)' })" 'OK'
        } else {
            Write-Log "'$RemoteHost' no estaba en TrustedHosts" 'OK'
        }
    }

    # 3. Certificados
    Write-Log 'Buscando certificados del servidor en almacenes de confianza...'
    $stores  = @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPeople')
    $removed = 0

    foreach ($store in $stores) {
        if ($CertThumbprint) {
            $cert = Get-Item "$store\$CertThumbprint" -EA SilentlyContinue
            if ($cert) {
                if ($Force -or $PSCmdlet.ShouldProcess("$store\$CertThumbprint", 'Eliminar certificado')) {
                    Remove-Item "$store\$CertThumbprint" -Force
                    Write-Log "Eliminado de ${store}: $CertThumbprint" 'OK'
                    $removed++
                }
            }
        } elseif ($RemoteHost) {
            $certs = Get-ChildItem $store -EA SilentlyContinue | Where-Object {
                ($_.Subject -match [regex]::Escape($RemoteHost)) -or
                ($_.DnsNameList -and ($_.DnsNameList.Unicode -contains $RemoteHost))
            }
            foreach ($cert in $certs) {
                if ($Force -or $PSCmdlet.ShouldProcess("$store\$($cert.Thumbprint)", "Eliminar '$($cert.Subject)'")) {
                    Remove-Item "$store\$($cert.Thumbprint)" -Force
                    Write-Log "Eliminado de ${store}: $($cert.Subject) [$($cert.Thumbprint)]" 'OK'
                    $removed++
                }
            }
        }
    }

    if ($removed -eq 0) {
        Write-Log "No se encontraron certificados relacionados con '$RemoteHost'" 'OK'
    } else {
        Write-Log "$removed certificado(s) eliminado(s)" 'OK'
    }

    # 4. Detener WinRM (opcional)
    if ($StopWinRM) {
        Write-Log 'Deteniendo servicio WinRM...'
        $remainingTrusted  = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value
        $remainingSessions = Get-PSSession -EA SilentlyContinue

        if ($remainingTrusted -or $remainingSessions) {
            Write-Log 'Hay TrustedHosts o sesiones activas — WinRM no se detendra' 'WARN'
            Write-Log 'Usa -ClearAllTrustedHosts junto con -StopWinRM para forzarlo' 'WARN'
        } else {
            if ($Force -or $PSCmdlet.ShouldProcess('WinRM', 'Detener y deshabilitar servicio')) {
                Stop-Service WinRM -Force
                Set-Service WinRM -StartupType Manual
                Write-Log 'Servicio WinRM detenido y establecido en inicio Manual' 'OK'
            }
        }
    }

    # Resumen
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host '  Limpieza completada' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host ''

    $trustedFinal = (Get-Item WSMan:\localhost\Client\TrustedHosts -EA SilentlyContinue).Value
    $winrmStatus  = (Get-Service WinRM -EA SilentlyContinue).Status

    Write-Log "TrustedHosts : $(if ($trustedFinal) { $trustedFinal } else { '(vacio)' })" 'OK'
    Write-Log "Servicio WinRM: $winrmStatus" 'OK'
    Write-Host ''
}

# ================================================================
# Router principal
# ================================================================

switch ($Action) {
    'all'           { Invoke-SetupAll   }
    'install'       { Invoke-Install    }
    'winrm-target'  { Invoke-WinRMTarget }
    'winrm-client'  { Invoke-WinRMClient }
    'winrm-cleanup' { Invoke-WinRMCleanup }
}
