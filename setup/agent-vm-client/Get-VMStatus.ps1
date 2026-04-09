# ============================================================
# Get-VMStatus.ps1
# Consulta el estado de las maquinas remotas registradas en Azure Relay.
# Muestra cuales tienen el agente conectado (listener activo) y cuales no.
#
# Requisitos:
#   - Azure CLI (az) instalado y autenticado (az login)
#   - Permisos de Reader sobre el Relay namespace
#
# Uso:
#   .\Get-VMStatus.ps1 -ResourceGroup "rg-sre-agent-proxy" -Namespace "relay-sre-agent-proxy"
#   .\Get-VMStatus.ps1 -ResourceGroup "rg-sre-agent-proxy" -Namespace "relay-sre-agent-proxy" -ShowAll
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Namespace,
    [switch]$ShowAll   # Incluye Hybrid Connections que no sean winrm-*
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
# 0. Verificar Az CLI y sesion activa
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
$subscriptionId = $account.id

# -------------------------------------------------------
# 1. Obtener lista de Hybrid Connections
# -------------------------------------------------------
Write-Log "Consultando Hybrid Connections en namespace '$Namespace'..."
$hcs = az relay hyco list `
    --resource-group $ResourceGroup `
    --namespace-name $Namespace `
    2>$null | ConvertFrom-Json

if (-not $hcs -or $hcs.Count -eq 0) {
    Write-Log "No se encontraron Hybrid Connections en '$Namespace'." 'WARN'
    Write-Log "Crea clientes con: .\Add-RelayClient.ps1 -ResourceGroup <rg> -Namespace <ns> -MachineName <nombre>" 'INFO'
    exit 0
}

# -------------------------------------------------------
# 2. Consultar estado (listenerCount) via ARM API
# -------------------------------------------------------
$results = @()

foreach ($hc in $hcs) {
    if (-not $ShowAll -and $hc.name -notmatch '^winrm-') { continue }

    # Llamada a la ARM REST API para obtener listenerCount en tiempo real
    $armUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup" +
              "/providers/Microsoft.Relay/namespaces/$Namespace/hybridConnections/$($hc.name)" +
              "?api-version=2021-11-01"

    $details = az rest --method get --url $armUrl 2>$null | ConvertFrom-Json
    $listenerCount = if ($details.properties.listenerCount) { $details.properties.listenerCount } else { 0 }

    $machineName = $hc.name -replace '^winrm-', ''
    $statusText  = if ($listenerCount -gt 0) { 'Conectado' } else { 'Desconectado' }
    $statusIcon  = if ($listenerCount -gt 0) { '[OK]' } else { '[--]' }

    $results += [PSCustomObject]@{
        Estado       = "$statusIcon $statusText"
        Maquina      = $machineName
        Listeners    = $listenerCount
        HybridConn   = $hc.name
        Creado       = ([datetime]$hc.createdAt).ToString('yyyy-MM-dd HH:mm')
    }
}

# -------------------------------------------------------
# 3. Mostrar resultado
# -------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Log "No hay maquinas registradas (con prefijo winrm-). Usa -ShowAll para ver todas." 'WARN'
    Write-Log "Registra clientes con: .\Add-RelayClient.ps1 -ResourceGroup <rg> -Namespace <ns> -MachineName <nombre>" 'INFO'
}

$connected    = ($results | Where-Object { $_.Listeners -gt 0 }).Count
$disconnected = ($results | Where-Object { $_.Listeners -eq 0 }).Count

Write-Host "`n========== ESTADO DE MAQUINAS REMOTAS ==========" -ForegroundColor Cyan
Write-Host "  Namespace : $Namespace" -ForegroundColor Gray
Write-Host "  Fecha     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray

$results | Sort-Object Maquina | Format-Table Estado, Maquina, Listeners, HybridConn, Creado -AutoSize

Write-Host "  Resumen: " -NoNewline
Write-Host "$connected conectadas" -ForegroundColor Green -NoNewline
Write-Host " | " -NoNewline
Write-Host "$disconnected desconectadas" -ForegroundColor Red -NoNewline
Write-Host " | $($results.Count) total`n" -ForegroundColor Gray
