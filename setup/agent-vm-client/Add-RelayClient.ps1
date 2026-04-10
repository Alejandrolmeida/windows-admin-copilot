# ============================================================
# Add-RelayClient.ps1
# Registra un nuevo equipo cliente en el Azure Relay existente.
# Crea la Hybrid Connection, genera el YAML para el cliente y
# actualiza automaticamente la config del servidor.
#
# Ejecutar en el equipo de ADMINISTRACION (servidor).
# Requisitos:
#   - Azure CLI (az) instalado y autenticado (az login)
#   - server-relay.yml y server-registry.json generados por New-RelayNamespace.ps1
#
# Uso:
#   .\Add-RelayClient.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -MachineName "pc-juan"
#   .\Add-RelayClient.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -MachineName "srv-contabilidad" -WinRMPort 5985
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$MachineName,
    [int]   $WinRMPort          = 5985,
    [int]   $BasePort           = 15985,
    [string]$ServerConfigFile   = '.\server-relay.yml',
    [string]$ServerRegistryFile = '.\server-registry.json',
    [string]$OutputPath         = '.',
    [string]$ServerInstallPath  = 'C:\RelayAdminServer',
    [string]$ServerTaskName     = 'RelayAdminServer'
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
# 0. Verificar Az CLI
# -------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Log "Azure CLI no encontrado. Instala desde https://aka.ms/installazurecliwindows" 'ERROR'
    exit 1
}
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Log "No hay sesion activa. Ejecuta: az login" 'ERROR'
    exit 1
}
Write-Log "Suscripcion: $($account.name)" 'OK'

# -------------------------------------------------------
# 1. Verificar archivos del servidor
# -------------------------------------------------------
foreach ($f in @($ServerConfigFile, $ServerRegistryFile)) {
    if (-not (Test-Path $f)) {
        Write-Log "No se encontro '$f'. Ejecuta primero: .\New-RelayNamespace.ps1" 'ERROR'
        exit 1
    }
}
$ServerConfigFile   = (Resolve-Path $ServerConfigFile).Path
$ServerRegistryFile = (Resolve-Path $ServerRegistryFile).Path

$registry     = Get-Content $ServerRegistryFile -Raw | ConvertFrom-Json
$machineLower = $MachineName.ToLower()
$hcName       = "winrm-$machineLower"

# Verificar que el cliente no este ya registrado
$existing = $registry.clients | Where-Object { $_.name -eq $machineLower }
if ($existing) {
    Write-Log "El cliente '$machineLower' ya esta registrado (puerto $($existing.bindPort))." 'WARN'
    Write-Log "Para eliminarlo del servidor: actualiza manualmente server-registry.json" 'WARN'
    exit 0
}

# -------------------------------------------------------
# 2. Crear Hybrid Connection
# -------------------------------------------------------
Write-Log "Verificando Hybrid Connection '$hcName'..."
$hc = az relay hyco show `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    --name $hcName 2>$null | ConvertFrom-Json

if (-not $hc) {
    Write-Log "Creando Hybrid Connection '$hcName'..."
    az relay hyco create `
        --resource-group $ResourceGroup `
        --namespace-name $Namespace `
        --name $hcName `
        --requires-client-authorization true `
        --output none
    Write-Log "Hybrid Connection '$hcName' creada" 'OK'
} else {
    Write-Log "Hybrid Connection '$hcName' ya existe, reutilizando" 'WARN'
}

# -------------------------------------------------------
# 3. Clave SAS Listen para el cliente
# -------------------------------------------------------
$listenRule = "listen-$machineLower"
az relay hyco authorization-rule create `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    --hybrid-connection-name $hcName `
    --name $listenRule `
    --rights Listen `
    --output none 2>$null

$listenKeys = az relay hyco authorization-rule keys list `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    --hybrid-connection-name $hcName `
    --name $listenRule | ConvertFrom-Json

Write-Log "Clave Listen generada para '$machineLower'" 'OK'

# -------------------------------------------------------
# 4. Calcular puerto local y dirección loopback única
# -------------------------------------------------------
$usedPorts     = @($registry.clients | ForEach-Object { $_.bindPort })
$bindPort      = $BasePort
while ($usedPorts -contains $bindPort) { $bindPort++ }

$usedAddresses = @($registry.clients | ForEach-Object { $_.localAddress } | Where-Object { $_ })
$loopbackIndex = 2
while ($usedAddresses -contains "127.0.0.$loopbackIndex") { $loopbackIndex++ }
$localAddress  = "127.0.0.$loopbackIndex"

Write-Log "Puerto asignado: $bindPort | Dirección loopback: $localAddress" 'OK'

# -------------------------------------------------------
# 5. Generar YAML para el cliente
# -------------------------------------------------------
$outDir = if ($OutputPath -eq '.') { Split-Path $ServerConfigFile } else { $OutputPath }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$clientYmlPath = Join-Path $outDir "client-$machineLower.yml"

$clientYml = @"
# azbridge config para CLIENTE: $MachineName
# Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Puerto WinRM del cliente (debe coincidir con BindPort del servidor): $bindPort
# Ejecutar en el equipo cliente con: .\Register-RelayClient.ps1 -ConfigFile "client-$machineLower.yml"
AzureRelayConnectionString: "$($listenKeys.primaryConnectionString)"
RemoteForward:
  - RelayName: "$hcName"
    Host: "localhost"
    HostPort: $bindPort
"@
$clientYml | Set-Content -Path $clientYmlPath -Encoding UTF8
Write-Log "YAML cliente generado -> $clientYmlPath" 'OK'

# -------------------------------------------------------
# 6. Actualizar server-registry.json
# -------------------------------------------------------
$newClient = [PSCustomObject]@{
    name         = $machineLower
    relayName    = $hcName
    bindPort     = $bindPort
    localAddress = $localAddress
    winrmPort    = $WinRMPort
    addedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
$clients = [System.Collections.ArrayList]@($registry.clients)
$clients.Add($newClient) | Out-Null
$registry.clients = $clients.ToArray()
$registry | ConvertTo-Json -Depth 5 | Set-Content -Path $ServerRegistryFile -Encoding UTF8
Write-Log "server-registry.json actualizado" 'OK'

# Agregar entrada de hosts para el cliente (alias de loopback único)
$hostsFile    = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsFile -Raw
$hostsEntry   = "$localAddress`t$machineLower"
if ($hostsContent -notmatch [regex]::Escape($machineLower)) {
    Add-Content -Path $hostsFile -Value "`n$hostsEntry" -Encoding ASCII
    Write-Log "Hosts: añadida entrada '$hostsEntry'" 'OK'
} else {
    Write-Log "Hosts: '$machineLower' ya existe, omitiendo" 'WARN'
}

# -------------------------------------------------------
# 7. Reconstruir server-relay.yml con todos los clientes
# -------------------------------------------------------
$connString = (Get-Content $ServerConfigFile -Raw) -match 'AzureRelayConnectionString:\s*"([^"]+)"'
$connStr    = $Matches[1]

$localForwards = $registry.clients | ForEach-Object {
    $addr = if ($_.localAddress) { $_.name } else { "localhost" }
    "  - RelayName: `"$($_.relayName)`"`n    BindAddress: `"$addr`"`n    BindPort: $($_.bindPort)"
}
$localForwardsBlock = if ($localForwards) { $localForwards -join "`n" } else { "[]" }

$newServerYml = @"
# Azure Relay - Config del Servidor de Administracion
# Namespace: $Namespace
# Actualizado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# GESTIONADO AUTOMATICAMENTE por Add-RelayClient.ps1 -- NO editar manualmente
#
AzureRelayConnectionString: "$connStr"
LocalForward:
$localForwardsBlock
"@
$newServerYml | Set-Content -Path $ServerConfigFile -Encoding UTF8
Write-Log "server-relay.yml actualizado ($($registry.clients.Count) clientes)" 'OK'

# -------------------------------------------------------
# 8. Si el servidor esta instalado, propagar config y reiniciar
# -------------------------------------------------------
$installedConfig = Join-Path $ServerInstallPath 'azbridge.config.yml'
if (Test-Path $installedConfig) {
    Write-Log "Propagando config a servidor instalado en $ServerInstallPath..."
    Copy-Item $ServerConfigFile $installedConfig -Force

    $task = Get-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Write-Log "Reiniciando '$ServerTaskName' para aplicar el nuevo cliente..."
        Stop-ScheduledTask  -TaskName $ServerTaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-ScheduledTask -TaskName $ServerTaskName
        Start-Sleep -Seconds 5
        $task = Get-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
        Write-Log "Estado del servidor: $($task.State)" 'OK'
    }
}

# -------------------------------------------------------
# 9. Resumen
# -------------------------------------------------------
Write-Host "`n========== CLIENTE REGISTRADO ==========" -ForegroundColor Green
Write-Host @"

  Maquina      : $MachineName
  HC Relay     : $hcName
  Puerto local : $localAddress ($machineLower) : $bindPort -> Azure Relay -> ${MachineName}:$bindPort
  YAML cliente : $clientYmlPath

  PROXIMOS PASOS:
    1. Copia '$clientYmlPath' al equipo '$MachineName'
    2. En el equipo '$MachineName' (como Administrador):
         .\Register-RelayClient.ps1 -ConfigFile "client-$machineLower.yml"
    3. Conectar desde el servidor:
         .\Connect-RelaySession.ps1 -MachineName "$machineLower" -Username "DOMINIO\admin"

  NOTA: WinRM en el cliente se configurará automaticamente en el puerto $bindPort (Register-RelayClient.ps1)

"@ -ForegroundColor Cyan
