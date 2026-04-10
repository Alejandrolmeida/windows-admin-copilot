# ============================================================
# Register-RelayClient.ps1
# Registra ESTE EQUIPO como cliente gestionado via Azure Relay.
# Se ejecuta en el equipo CLIENTE (managed machine).
# El YAML de configuracion lo genera Add-RelayClient.ps1 en el servidor.
#
# Requisitos:
#   - Ejecutar como Administrador
#   - client-<maquina>.yml copiado desde el servidor de administracion
#
# Uso:
#   .\Register-RelayClient.ps1 -ConfigFile "client-pc-juan.yml"
# ============================================================
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$InstallPath = 'C:\RelayClient',
    [string]$ServiceName = 'RelayClient',
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
    Write-Log "El YAML lo genera el servidor con: .\Add-RelayClient.ps1 -MachineName <nombre>" 'WARN'
    exit 1
}

# Validar que el YAML contiene RemoteForward (no LocalForward — eso seria del servidor)
$yamlContent = Get-Content $ConfigFile -Raw
if ($yamlContent -notmatch 'RemoteForward') {
    Write-Log "El fichero de configuracion no parece ser un config de CLIENTE (falta RemoteForward)." 'ERROR'
    Write-Log "Los clientes usan RemoteForward. Comprueba que el YAML correcto es para este equipo." 'WARN'
    exit 1
}
if ($yamlContent -match 'LocalForward') {
    Write-Log "El fichero contiene LocalForward (config de SERVIDOR). No ejecutes este script en el servidor." 'ERROR'
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
# 4. Leer puerto de destino del YAML (HostPort = puerto WinRM del cliente)
# -------------------------------------------------------
$yamlContent = Get-Content $destConfig -Raw
$targetPort  = 5985   # valor por defecto
if ($yamlContent -match 'HostPort:\s*(\d+)') {
    $targetPort = [int]$Matches[1]
}
Write-Log "Puerto WinRM destino (HostPort): $targetPort" 'OK'

# -------------------------------------------------------
# 5. Asegurar que WinRM esta habilitado en el puerto correcto
# -------------------------------------------------------
Write-Log "Configurando WinRM en puerto $targetPort..."
$wmResult = winrm qc /quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "winrm qc devolvio: $wmResult" 'WARN'
}

$winrmService = Get-Service -Name 'WinRM' -ErrorAction SilentlyContinue
if ($winrmService -and $winrmService.Status -ne 'Running') {
    Set-Service -Name 'WinRM' -StartupType Automatic
    Start-Service -Name 'WinRM'
}

# Habilitar Basic auth y trafico no cifrado (el cifrado lo aporta el tunel Azure Relay)
Set-Item WSMan:\localhost\Service\Auth\Basic       $true  -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted $true  -Force

# Reubicar el listener HTTP al puerto que espera el servidor (HostPort del YAML)
$existingListener = Get-ChildItem WSMan:\localhost\Listener | Where-Object {
    (Get-ChildItem $_.PSPath | Where-Object { $_.Name -eq 'Transport' }).Value -eq 'HTTP'
}
$currentPort = if ($existingListener) {
    [int](Get-ChildItem $existingListener.PSPath | Where-Object { $_.Name -eq 'Port' }).Value
} else { 0 }

if ($currentPort -ne $targetPort) {
    Write-Log "Cambiando WinRM del puerto $currentPort al $targetPort..."
    if ($existingListener) {
        Remove-Item -Path $existingListener.PSPath -Recurse -Force
    }
    New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Port $targetPort -Force | Out-Null
    Restart-Service WinRM -Force
    Start-Sleep -Seconds 3
    Write-Log "WinRM configurado en puerto $targetPort" 'OK'
} else {
    Write-Log "WinRM ya esta en el puerto correcto ($targetPort)" 'OK'
}

# Añadir regla de firewall para el puerto WinRM
New-NetFirewallRule -Name "WINRM-$targetPort" -DisplayName "WinRM $targetPort (Azure Relay)" `
    -Protocol TCP -LocalPort $targetPort -Direction Inbound -Action Allow -Enabled True `
    -ErrorAction SilentlyContinue | Out-Null
Write-Log "Regla de firewall para puerto $targetPort OK" 'OK'

# -------------------------------------------------------
# 6. Registrar como Scheduled Task (inicio automatico SYSTEM)
# Usa argumentos CLI en lugar de YAML para compatibilidad con azbridge v0.16.1
# -------------------------------------------------------
Write-Log "Registrando tarea programada '$ServiceName'..."

# Extraer connection string del YAML para los argumentos CLI
$connStr = if ($yamlContent -match "AzureRelayConnectionString:\s*[`"']?([^`"'\n]+)[`"']?") {
    $Matches[1].Trim()
} else { '' }

$relayName = if ($yamlContent -match 'RelayName:\s*[''"]?([^''"#\n]+)[''"]?') {
    $Matches[1].Trim()
} else { '' }

if (-not $connStr -or -not $relayName) {
    Write-Log "No se pudo extraer la conexion del YAML. Usando modo -f <config>" 'WARN'
    $taskArgs = "-f `"$destConfig`""
} else {
    # Modo CLI: -x <connStr> -T <relayName>:localhost:<targetPort>
    $taskArgs = "-x `"$connStr`" -T `"${relayName}:localhost:${targetPort}`""
    Write-Log "Modo CLI: -T ${relayName}:localhost:${targetPort}" 'OK'
}

$existingTask = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Log "Tarea '$ServiceName' ya existe. Actualizando..." 'WARN'
    Stop-ScheduledTask  -TaskName $ServiceName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute $exePath -Argument $taskArgs -WorkingDirectory $InstallPath
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
    -Description 'Azure Relay Client: expone WinRM de este equipo al servidor de administracion via Relay.' | Out-Null

Write-Log "Tarea '$ServiceName' registrada (inicio automatico al arrancar, SYSTEM)" 'OK'

# -------------------------------------------------------
# 6. Arrancar la tarea ahora
# -------------------------------------------------------
Write-Log "Arrancando tarea '$ServiceName'..."
Start-ScheduledTask -TaskName $ServiceName
Start-Sleep -Seconds 6

$task = Get-ScheduledTask    -TaskName $ServiceName
$info = Get-ScheduledTaskInfo -TaskName $ServiceName
if ($task.State -eq 'Running') {
    Write-Log "Cliente Relay corriendo correctamente" 'OK'
} else {
    Write-Log "Estado: $($task.State) | LastResult: $($info.LastTaskResult)" 'WARN'
    Write-Log "Intentando verificar proceso azbridge..." 'INFO'
    Start-Sleep -Seconds 3
    $azbridgeProc = Get-Process azbridge -ErrorAction SilentlyContinue
    if ($azbridgeProc) {
        Write-Log "azbridge corriendo (PID=$($azbridgeProc.Id)). Tarea Ready es comportamiento normal." 'OK'
    }
}

# -------------------------------------------------------
# 8. Resumen
# -------------------------------------------------------
Write-Host "`n========== CLIENTE RELAY REGISTRADO ==========" -ForegroundColor Green
Write-Host @"
  Tarea      : $ServiceName ($($task.State))
  Binario    : $exePath
  Config     : $destConfig
  WinRM      : puerto $targetPort
  Inicio     : Automatico al arrancar Windows (SYSTEM)

  Este equipo expone WinRM en puerto $targetPort a traves de Azure Relay.
  El servidor de administracion puede conectar con:
    .\Connect-RelaySession.ps1 -MachineName "<nombre>" -Username "<usuario>"

  Para desinstalar:
    .\Remove-RelayClient.ps1
"@ -ForegroundColor Cyan
