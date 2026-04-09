# ============================================================
# Install-RelayClient.ps1
# Instala el proxy Agent-VM-Client como Windows Service en TU PC.
# Permite conectarse a maquinas remotas sin arrancar el proxy manualmente.
# El servicio arranca automaticamente con Windows.
#
# Requisitos:
#   - Ejecutar como Administrador
#   - Fichero YAML de cliente generado por New-RelayNamespace.ps1
#
# Uso:
#   .\Install-RelayClient.ps1 -ConfigFile "client-srv01.yml"
#   .\Install-RelayClient.ps1 -ConfigFile "client-srv01.yml" -LocalPort 15986
#   .\Install-RelayClient.ps1 -ConfigFile "client-srv01.yml" -MachineName "miservidor"
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$MachineName,
    [int]   $LocalPort   = 15985,
    [string]$InstallPath = 'C:\AgentVMClient',
    [string]$Version     = '0.16.1'
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
# 0. Verificar config file y auto-detectar nombre maquina
# -------------------------------------------------------
if (-not (Test-Path $ConfigFile)) {
    Write-Log "Fichero de configuracion no encontrado: $ConfigFile" 'ERROR'
    exit 1
}
$ConfigFile = (Resolve-Path $ConfigFile).Path

if (-not $MachineName) {
    $MachineName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile) -replace '^client-', ''
}
$ServiceName = "AgentVMClient-$MachineName"
Write-Log "Maquina: $MachineName | Servicio: $ServiceName | Puerto local: $LocalPort"

# Verificar que el config tiene LocalForward
$configContent = Get-Content $ConfigFile -Raw
if ($configContent -notmatch 'BindPort') {
    Write-Log "El fichero no parece un config de cliente (falta BindPort/LocalForward)." 'ERROR'
    exit 1
}

# -------------------------------------------------------
# 1. Crear directorio de instalacion
# -------------------------------------------------------
$machineInstallPath = Join-Path $InstallPath $MachineName
Write-Log "Directorio de instalacion: $machineInstallPath"
New-Item -ItemType Directory -Path $machineInstallPath -Force | Out-Null

# -------------------------------------------------------
# 2. Descargar azbridge si no existe
# -------------------------------------------------------
$exePath = Join-Path $InstallPath 'azbridge.exe'

if (Test-Path $exePath) {
    Write-Log "azbridge.exe ya existe en $InstallPath, omitiendo descarga." 'WARN'
} else {
    $arch   = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $zipUrl = "https://github.com/Azure/azure-relay-bridge/releases/download/v$Version/azbridge.$Version.win-$arch.zip"
    $zipPath = Join-Path $env:TEMP "azbridge-$Version.zip"

    Write-Log "Descargando azbridge v$Version ($arch) desde GitHub..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Write-Log "Extrayendo en $InstallPath..."
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
    Remove-Item $zipPath -Force
    Write-Log "azbridge.exe instalado" 'OK'
}

# -------------------------------------------------------
# 3. Copiar config YAML (ajustando BindPort si es necesario)
# -------------------------------------------------------
$destConfig = Join-Path $machineInstallPath 'azbridge.config.yml'

# Actualizar el BindPort en el config con el LocalPort especificado
$configContent = $configContent -replace 'BindPort:\s*\d+', "BindPort: $LocalPort"
$configContent | Set-Content -Path $destConfig -Encoding UTF8

Write-Log "Config copiada a $destConfig (BindPort=$LocalPort)" 'OK'

# -------------------------------------------------------
# 4. Registrar como Windows Service
# -------------------------------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "Servicio '$ServiceName' ya existe. Actualizando..." 'WARN'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

$binPath = "`"$exePath`" -f `"$destConfig`""
New-Service -Name $ServiceName `
    -BinaryPathName $binPath `
    -DisplayName "Agent-VM-Client: $MachineName" `
    -Description "Proxy Agent-VM-Client para $MachineName. Expone localhost:$LocalPort -> Azure Relay -> WinRM remoto." `
    -StartupType Automatic | Out-Null

Write-Log "Servicio '$ServiceName' registrado con inicio automatico" 'OK'

# -------------------------------------------------------
# 5. Arrancar el servicio
# -------------------------------------------------------
Write-Log "Arrancando servicio..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3

$svc = Get-Service -Name $ServiceName
if ($svc.Status -eq 'Running') {
    Write-Log "Servicio corriendo correctamente" 'OK'
} else {
    Write-Log "El servicio no arranco (estado: $($svc.Status)). Revisa el Event Viewer." 'ERROR'
    Write-Log "Comando: Get-EventLog -LogName Application -Source '$ServiceName' -Newest 10" 'WARN'
    exit 1
}

# -------------------------------------------------------
# 6. Verificar que el puerto local esta escuchando
# -------------------------------------------------------
Start-Sleep -Seconds 2
$listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
if ($listener) {
    Write-Log "Puerto local $LocalPort escuchando correctamente" 'OK'
} else {
    Write-Log "Puerto $LocalPort no detectado aun (puede tardar unos segundos en conectar a Azure Relay)." 'WARN'
}

# -------------------------------------------------------
# 7. Resumen
# -------------------------------------------------------
Write-Host "`n========== INSTALACION COMPLETADA ==========" -ForegroundColor Green
Write-Host @"
  Servicio : $ServiceName ($($svc.Status))
  Maquina  : $MachineName
  Puerto   : localhost:$LocalPort -> Azure Relay -> WinRM
  Config   : $destConfig
  Inicio   : Automatico (arranca con Windows)

  Para conectarte:
    .\Connect-RelaySession.ps1 -ConfigFile "$ConfigFile" -Username "DOMINIO\usuario"

  Para ver estado de todas las maquinas:
    .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>

  Para desinstalar:
    .\Remove-RelayClient.ps1 -MachineName "$MachineName"
"@ -ForegroundColor Cyan
