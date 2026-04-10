# ============================================================
# New-RelayNamespace.ps1
# Crea o valida el Azure Relay Namespace y genera los archivos
# de configuracion del servidor (server-relay.yml, server-registry.json).
# Se ejecuta UNA SOLA VEZ por entorno.
#
# Los clientes se agregan posteriormente con Add-RelayClient.ps1.
#
# Requisitos:
#   - Azure CLI (az) instalado y autenticado (az login)
#   - Permisos de Contributor en la suscripcion / resource group
#
# Uso:
#   .\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa"
#   .\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -CreateResourceGroup -Location "westeurope"
#   .\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -OutputPath "C:\relay-configs"
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Namespace,
    [string]$Location   = 'westeurope',
    [string]$ConfigPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.config'),
    [string]$OutputPath = '',
    [switch]$CreateResourceGroup
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
Write-Log "Verificando Azure CLI..."
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Log "Azure CLI no encontrado. Instala desde https://aka.ms/installazurecliwindows" 'ERROR'
    exit 1
}
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Log "No hay sesion activa. Ejecuta: az login" 'ERROR'
    exit 1
}
Write-Log "Suscripcion: $($account.name) ($($account.id))" 'OK'

# -------------------------------------------------------
# 1. Resource Group
# -------------------------------------------------------
if ($CreateResourceGroup) {
    Write-Log "Creando resource group '$ResourceGroup' en '$Location'..."
    az group create --name $ResourceGroup --location $Location --output none
    Write-Log "Resource group creado" 'OK'
} else {
    $rg = az group show --name $ResourceGroup 2>$null | ConvertFrom-Json
    if (-not $rg) {
        Write-Log "Resource group '$ResourceGroup' no existe. Usa -CreateResourceGroup para crearlo." 'ERROR'
        exit 1
    }
}

# -------------------------------------------------------
# 2. Azure Relay Namespace
# -------------------------------------------------------
Write-Log "Verificando namespace '$Namespace'..."
$existing = az relay namespace show --resource-group $ResourceGroup --name $Namespace 2>$null | ConvertFrom-Json
if ($existing) {
    Write-Log "Namespace ya existe, reutilizando." 'WARN'
} else {
    Write-Log "Creando namespace '$Namespace' (puede tardar ~30s)..."
    az relay namespace create `
        --resource-group $ResourceGroup `
        --name $Namespace `
        --location $Location `
        --output none
    Write-Log "Namespace creado" 'OK'
}

# -------------------------------------------------------
# 3. SAS rule a nivel de namespace para el servidor (Send a todas las HCs)
# -------------------------------------------------------
Write-Log "Configurando SAS key 'send-all-clients' a nivel namespace..."
az relay namespace authorization-rule create `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    --name 'send-all-clients' `
    --rights Send `
    --output none 2>$null

$nsKeys = az relay namespace authorization-rule keys list `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    --name 'send-all-clients' | ConvertFrom-Json

Write-Log "SAS key 'send-all-clients' lista" 'OK'

# -------------------------------------------------------
# 4. Obtener endpoint del namespace
# -------------------------------------------------------
$nsDetails = az relay namespace show `
    --resource-group $ResourceGroup `
    --name $Namespace | ConvertFrom-Json
$nsEndpoint = "sb://$($nsDetails.serviceBusEndpoint -replace 'https?://|/$','')"

# -------------------------------------------------------
# 5. Generar server-relay.yml + server-registry.json
# -------------------------------------------------------
$outDir = if ($OutputPath) { $OutputPath } else { $ConfigPath }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$serverYmlPath      = Join-Path $outDir 'server-relay.yml'
$serverRegistryPath = Join-Path $outDir 'server-registry.json'

# Si ya existe el registry, respetar los clientes existentes
$existingRegistry = $null
if (Test-Path $serverRegistryPath) {
    $existingRegistry = Get-Content $serverRegistryPath -Raw | ConvertFrom-Json
    Write-Log "server-registry.json existente detectado ($($existingRegistry.clients.Count) clientes)" 'WARN'
}

$existingClients = if ($existingRegistry) { 
    @($existingRegistry.clients | Where-Object { $_ -ne $null })
} else { @() }

# Reconstruir server-relay.yml con todos los clientes existentes
$localForwardLines = $existingClients | ForEach-Object {
    "  - RelayName: `"$($_.relayName)`"`n    BindAddress: localhost`n    BindPort: $($_.bindPort)"
}
$localForwardBlock = if ($localForwardLines) { $localForwardLines -join "`n" } else { "[]" }

$serverYml = @"
# Azure Relay - Config del Servidor de Administracion
# Namespace: $Namespace
# Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# GESTIONADO AUTOMATICAMENTE por Add-RelayClient.ps1 -- NO editar manualmente
#
AzureRelayConnectionString: "$($nsKeys.primaryConnectionString)"
LocalForward:
$localForwardBlock
"@
$serverYml | Set-Content -Path $serverYmlPath -Encoding UTF8
Write-Log "server-relay.yml generado -> $serverYmlPath" 'OK'

$registry = [PSCustomObject]@{
    namespace   = $Namespace
    resourceGroup = $ResourceGroup
    endpoint    = $nsEndpoint
    generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    clients     = $existingClients
}
$registry | ConvertTo-Json -Depth 5 | Set-Content -Path $serverRegistryPath -Encoding UTF8
Write-Log "server-registry.json generado -> $serverRegistryPath" 'OK'

# -------------------------------------------------------
# 6. Resumen
# -------------------------------------------------------
Write-Host "`n========== NAMESPACE LISTO ==========" -ForegroundColor Green
Write-Host @"
  Namespace : $Namespace
  Endpoint  : $nsEndpoint
  Config    : $serverYmlPath
  Registry  : $serverRegistryPath
  Clientes  : $($existingClients.Count) registrados

  PROXIMOS PASOS:
    1. Instalar el servidor de administracion (UNA VEZ, en este equipo):
         .\Install-RelayServer.ps1 -ConfigFile "server-relay.yml"

    2. Registrar cada cliente (por cada equipo gestionado):
         .\Add-RelayClient.ps1 -ResourceGroup "$ResourceGroup" -Namespace "$Namespace" -MachineName "pc-juan"

  COSTE ESTIMADO Azure Relay:
    - Por Hybrid Connection activa: ~`$0.013/hora
    - Por namespace: ~`$0.10/hora
"@ -ForegroundColor Cyan
