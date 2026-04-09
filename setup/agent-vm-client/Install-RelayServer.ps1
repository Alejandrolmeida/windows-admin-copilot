# ============================================================
# Install-RelayServer.ps1
# Instala el servidor de administracion Azure Relay en ESTE EQUIPO.
# Se ejecuta UNA SOLA VEZ. Gestiona todos los clientes registrados
# a traves de una unica instancia de azbridge.
#
# Requisitos:
#   - Ejecutar como Administrador
#   - server-relay.yml generado por New-RelayNamespace.ps1
#
# Uso:
#   .\Install-RelayServer.ps1 -ConfigFile "server-relay.yml"
#   .\Install-RelayServer.ps1 -ConfigFile "server-relay.yml" -InstallPath "D:\RelayAdminServer"
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$InstallPath = 'C:\RelayAdminServer',
    [string]$ServiceName = 'RelayAdminServer',
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
    Write-Log "Genera el fichero con: .\New-RelayNamespace.ps1 -ResourceGroup <rg> -Namespace <ns>" 'WARN'
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
# 4. Registrar como Scheduled Task (inicio automatico SYSTEM)
# -------------------------------------------------------
Write-Log "Registrando tarea programada '$ServiceName'..."

$existingTask = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Log "Tarea '$ServiceName' ya existe. Actualizando..." 'WARN'
    Stop-ScheduledTask  -TaskName $ServiceName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute $exePath -Argument "-f `"$destConfig`"" -WorkingDirectory $InstallPath
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $ServiceName `
    -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Azure Relay Admin Server: proxy de administracion para todos los clientes registrados.' | Out-Null

Write-Log "Tarea '$ServiceName' registrada (inicio automatico al arrancar, SYSTEM)" 'OK'

# -------------------------------------------------------
# 5. Arrancar la tarea ahora
# -------------------------------------------------------
Write-Log "Arrancando tarea '$ServiceName'..."
Start-ScheduledTask -TaskName $ServiceName
Start-Sleep -Seconds 5

$task = Get-ScheduledTask    -TaskName $ServiceName
$info = Get-ScheduledTaskInfo -TaskName $ServiceName
if ($task.State -eq 'Running') {
    Write-Log "Servidor corriendo correctamente" 'OK'
} else {
    Write-Log "Estado: $($task.State) | LastResult: $($info.LastTaskResult)" 'WARN'
}

# -------------------------------------------------------
# 6. Resumen
# -------------------------------------------------------
Write-Host "`n========== SERVIDOR INSTALADO ==========" -ForegroundColor Green
Write-Host @"
  Tarea    : $ServiceName ($($task.State))
  Binario  : $exePath
  Config   : $destConfig
  Inicio   : Automatico al arrancar Windows (SYSTEM)

  Para registrar un nuevo cliente (en el servidor):
    .\Add-RelayClient.ps1 -ResourceGroup <rg> -Namespace <ns> -MachineName "pc-nuevo"

  Para ver estado de los clientes:
    .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>

  Para desinstalar el servidor:
    .\Remove-RelayServer.ps1
"@ -ForegroundColor Cyan
