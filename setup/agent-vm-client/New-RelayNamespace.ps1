# ============================================================
# New-RelayNamespace.ps1
# Crea el Azure Relay Namespace + Hybrid Connections + SAS tokens
# para exponer WinRM de una o varias maquinas remotas.
#
# Requisitos:
#   - Azure CLI (az) instalado y autenticado (az login)
#   - Permisos de Contributor en la suscripcion / resource group
#
# Uso:
#   .\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Location "westeurope" `
#       -Namespace "relay-cliente01" -Machines "srv01","srv02","srv03"
#
#   .\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Namespace "relay-cliente01" `
#       -Machines "srv01" -OutputPath "C:\relay-configs"
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string[]]$Machines,
    [string]$Location   = 'westeurope',
    [string]$OutputPath = '.',
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
# 3. Hybrid Connection + SAS keys por maquina
# -------------------------------------------------------
$OutputPath = Resolve-Path $OutputPath -ErrorAction SilentlyContinue
if (-not $OutputPath) { $OutputPath = $PWD.Path }

$summary = @()

foreach ($machine in $Machines) {
    $hcName = "winrm-$($machine.ToLower())"
    Write-Log "Procesando Hybrid Connection '$hcName' para '$machine'..."

    # Crear Hybrid Connection
    $hc = az relay hyco show `
        --resource-group $ResourceGroup `
        --namespace-name $Namespace `
        --name $hcName 2>$null | ConvertFrom-Json

    if (-not $hc) {
        az relay hyco create `
            --resource-group $ResourceGroup `
            --namespace-name $Namespace `
            --name $hcName `
            --requires-client-authorization true `
            --output none
        Write-Log "  Hybrid Connection '$hcName' creada" 'OK'
    } else {
        Write-Log "  Hybrid Connection '$hcName' ya existe, reutilizando" 'WARN'
    }

    # SAS rule para el TARGET (Listen)
    $listenRule = "listen-$($machine.ToLower())"
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

    # SAS rule para el CLIENTE (Send)
    $sendRule = "send-$($machine.ToLower())"
    az relay hyco authorization-rule create `
        --resource-group $ResourceGroup `
        --namespace-name $Namespace `
        --hybrid-connection-name $hcName `
        --name $sendRule `
        --rights Send `
        --output none 2>$null

    $sendKeys = az relay hyco authorization-rule keys list `
        --resource-group $ResourceGroup `
        --namespace-name $Namespace `
        --hybrid-connection-name $hcName `
        --name $sendRule | ConvertFrom-Json

    # Generar config YAML para el TARGET
    $targetConfig = @"
# azbridge config para TARGET: $machine
# Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
AzureRelayConnectionString: "$($listenKeys.primaryConnectionString)"
RemoteForward:
  - RelayName: "$hcName"
    HostName: localhost
    HostPort: 5985
"@

    # Generar config YAML para el CLIENTE
    $clientConfig = @"
# azbridge config para CLIENTE -> $machine
# Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
AzureRelayConnectionString: "$($sendKeys.primaryConnectionString)"
LocalForward:
  - RelayName: "$hcName"
    BindAddress: localhost
    BindPort: 15985
"@

    $targetFile = Join-Path $OutputPath "target-$($machine.ToLower()).yml"
    $clientFile = Join-Path $OutputPath "client-$($machine.ToLower()).yml"

    $targetConfig | Set-Content -Path $targetFile -Encoding UTF8
    $clientConfig | Set-Content -Path $clientFile -Encoding UTF8

    Write-Log "  Config target  -> $targetFile" 'OK'
    Write-Log "  Config cliente -> $clientFile" 'OK'

    $summary += [PSCustomObject]@{
        Machine    = $machine
        HybridConn = $hcName
        TargetYml  = $targetFile
        ClientYml  = $clientFile
    }
}

# -------------------------------------------------------
# 4. Resumen
# -------------------------------------------------------
Write-Host "`n========== RESUMEN ==========" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

Write-Host @"

PROXIMOS PASOS:
  1. Copia target-<maquina>.yml al equipo remoto y ejecuta (como Admin):
       .\Install-RelayAgent.ps1 -ConfigFile "target-<maquina>.yml"

  2. En tu PC, para conectarte:
       .\Connect-RelaySession.ps1 -ConfigFile "client-<maquina>.yml" -Username "DOMINIO\usuario"

COSTE ESTIMADO Azure Relay:
  - Por Hybrid Connection activa: ~$0.013/hora
  - $($Machines.Count) maquinas 24/7: ~$($([math]::Round($Machines.Count * 0.013 * 730, 2)))/mes
  - $($Machines.Count) maquinas 8h/dia laboral: ~$($([math]::Round($Machines.Count * 0.013 * 160, 2)))/mes
"@ -ForegroundColor Yellow
