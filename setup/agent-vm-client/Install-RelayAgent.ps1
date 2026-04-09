# ============================================================
# Install-RelayAgent.ps1
# Instala el agente Agent-VM-Client (azbridge) como Windows Service
# en el equipo DESTINO (maquina remota del cliente).
# Ejecutar en el equipo remoto (via RDP, una sola vez).
#
# Requisitos:
#   - Ejecutar como Administrador
#   - Fichero YAML generado por New-RelayNamespace.ps1
#   - Acceso a internet saliente HTTPS (443)
#
# Uso:
#   .\Install-RelayAgent.ps1 -ConfigFile "target-srv01.yml"
#   .\Install-RelayAgent.ps1 -ConfigFile "target-srv01.yml" -InstallPath "D:\AgentVMClient"
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$InstallPath = 'C:\AgentVMClient',
    [string]$ServiceName = 'AgentVMTarget',
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
# 0. Verificar config file
# -------------------------------------------------------
if (-not (Test-Path $ConfigFile)) {
    Write-Log "Fichero de configuracion no encontrado: $ConfigFile" 'ERROR'
    Write-Log "Genera el fichero con New-RelayNamespace.ps1 en tu PC y copia el target-*.yml aqui." 'WARN'
    exit 1
}
$ConfigFile = (Resolve-Path $ConfigFile).Path
Write-Log "Config: $ConfigFile" 'OK'

# -------------------------------------------------------
# 1. Crear directorio de instalacion
# -------------------------------------------------------
Write-Log "Directorio de instalacion: $InstallPath"
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

# -------------------------------------------------------
# 2. Descargar azbridge si no existe
# -------------------------------------------------------
$exePath = Join-Path $InstallPath 'azbridge.exe'
$zipPath = Join-Path $env:TEMP "azbridge-$Version.zip"

if (Test-Path $exePath) {
    Write-Log "azbridge.exe ya existe en $InstallPath, omitiendo descarga." 'WARN'
} else {
    $arch   = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $zipUrl = "https://github.com/Azure/azure-relay-bridge/releases/download/v$Version/azbridge.$Version.win-$arch.zip"

    Write-Log "Descargando azbridge v$Version ($arch) desde GitHub..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Write-Log "Extrayendo en $InstallPath..."
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
    Remove-Item $zipPath -Force
    Write-Log "azbridge.exe instalado" 'OK'
}

# -------------------------------------------------------
# 3. Copiar config YAML
# -------------------------------------------------------
$destConfig = Join-Path $InstallPath 'azbridge.config.yml'
Copy-Item $ConfigFile $destConfig -Force
Write-Log "Config copiada a $destConfig" 'OK'

# -------------------------------------------------------
# 4. Registrar como Windows Service
# -------------------------------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "Servicio '$ServiceName' ya existe. Deteniendolo para actualizar..." 'WARN'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

$binPath = "`"$exePath`" -f `"$destConfig`""
New-Service -Name $ServiceName `
    -BinaryPathName $binPath `
    -DisplayName 'Agent-VM-Client Target (WinRM Relay)' `
    -Description 'Agente Agent-VM-Client: tunel inverso Azure Relay para acceso WinRM remoto sin puertos entrantes.' `
    -StartupType Automatic | Out-Null

Write-Log "Servicio '$ServiceName' registrado" 'OK'

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
    Write-Log "Log: Get-EventLog -LogName Application -Source '$ServiceName' -Newest 10" 'WARN'
    exit 1
}

# -------------------------------------------------------
# 6. Resumen
# -------------------------------------------------------
Write-Host "`n========== INSTALACION COMPLETADA ==========" -ForegroundColor Green
Write-Host @"
  Servicio : $ServiceName ($($svc.Status))
  Binario  : $exePath
  Config   : $destConfig
  Inicio   : Automatico (arranca con Windows)

  Para verificar estado:
    Get-Service $ServiceName
  Para ver logs:
    Get-EventLog -LogName Application -Source '$ServiceName' -Newest 20
  Para desinstalar:
    .\Remove-RelayAgent.ps1
  Para consultar estado de todas las maquinas:
    .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>
"@ -ForegroundColor Cyan
