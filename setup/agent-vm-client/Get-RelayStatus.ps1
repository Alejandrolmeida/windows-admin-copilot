# ============================================================
# Get-RelayStatus.ps1
# Muestra el estado de todos los clientes registrados en el
# servicio Azure Relay de este repositorio.
#
# Ejecutar en el equipo SERVIDOR (admin machine).
#
# Uso:
#   .\Get-RelayStatus.ps1
#   .\Get-RelayStatus.ps1 -RegistryFile "C:\MiSetup\server-registry.json"
#   .\Get-RelayStatus.ps1 -ShowListeners  # consulta Azure API (requiere az login)
# ============================================================

[CmdletBinding()]
param(
    [string]$RegistryFile   = '.\server-registry.json',
    [string]$ServerTaskName = 'RelayAdminServer',
    [switch]$ShowListeners
)

$ErrorActionPreference = 'SilentlyContinue'

# -------------------------------------------------------
# Colores y helpers
# -------------------------------------------------------
function icon { param($ok) if ($ok) { "✅" } else { "❌" } }

Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   Azure Relay — Estado de clientes registrados" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------
# 1. Leer registry
# -------------------------------------------------------
if (-not (Test-Path $RegistryFile)) {
    Write-Host "❌ No se encontro el fichero de registry: $RegistryFile" -ForegroundColor Red
    Write-Host "   Ejecuta primero New-RelayNamespace.ps1 para inicializar el servidor." -ForegroundColor Yellow
    exit 1
}

$registry = [System.IO.File]::ReadAllText((Resolve-Path $RegistryFile)) | ConvertFrom-Json
$clients  = @($registry.clients | Where-Object { $_ -ne $null })

# -------------------------------------------------------
# 2. Estado de la tarea del servidor
# -------------------------------------------------------
$serverTask  = Get-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
$serverState = if ($serverTask) { $serverTask.State } else { "No instalada" }
$serverOk    = $serverState -eq "Running"

Write-Host "  Namespace   : $($registry.namespace)" -ForegroundColor White
Write-Host "  Endpoint    : $($registry.endpoint)" -ForegroundColor DarkGray
Write-Host "  Generado    : $($registry.generatedAt)" -ForegroundColor DarkGray
Write-Host "  Servidor    : $(icon $serverOk) Tarea '$ServerTaskName' — $serverState" -ForegroundColor $(if ($serverOk) { 'Green' } else { 'Red' })
Write-Host "  Clientes    : $($clients.Count) registrados" -ForegroundColor White
Write-Host ""

if ($clients.Count -eq 0) {
    Write-Host "  (Sin clientes registrados. Usa Add-RelayClient.ps1 para agregar uno.)" -ForegroundColor Yellow
    exit 0
}

# -------------------------------------------------------
# 3. Listeners en Azure (opcional, requiere az CLI)
# -------------------------------------------------------
$listenerMap = @{}
if ($ShowListeners) {
    $azOk = Get-Command az -ErrorAction SilentlyContinue
    if ($azOk) {
        $hcs = az relay hyco list `
            --resource-group $registry.resourceGroup `
            --namespace-name  $registry.namespace `
            --output json 2>$null | ConvertFrom-Json
        foreach ($hc in $hcs) { $listenerMap[$hc.name] = $hc.listenerCount }
    } else {
        Write-Host "  ⚠️  az CLI no disponible — omitiendo consulta de listeners en Azure." -ForegroundColor Yellow
    }
}

# -------------------------------------------------------
# 4. Tabla de clientes
# -------------------------------------------------------
$rows = foreach ($client in $clients) {
    $port    = [int]$client.bindPort
    $host_   = if ($client.localAddress) { $client.localAddress } else { 'localhost' }
    $tcpOk   = Test-NetConnection -ComputerName $host_ -Port $port `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    $listeners = if ($listenerMap.ContainsKey($client.relayName)) { $listenerMap[$client.relayName] } else { "—" }

    [PSCustomObject]@{
        "VM / Cliente"      = $client.name
        "Hybrid Connection" = $client.relayName
        "Loopback IP"       = $host_
        "Puerto"            = $port
        "Listeners"         = $listeners
        "Tunel TCP"         = "$(icon $tcpOk) $(if ($tcpOk) {'Activo'} else {'Caido'})"
        "Estado"            = if ($tcpOk) { "CONECTADO" } else { "DESCONECTADO" }
        "Registrado"        = $client.addedAt
    }
}

$rows | Format-Table -AutoSize

# -------------------------------------------------------
# 5. Resumen
# -------------------------------------------------------
$connected    = @($rows | Where-Object { $_.Estado -eq "CONECTADO" }).Count
$disconnected = $clients.Count - $connected

Write-Host "──────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Resumen: $connected conectados  |  $disconnected desconectados  |  $($clients.Count) total" -ForegroundColor $(if ($disconnected -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ""

if (-not $ShowListeners -and $clients.Count -gt 0) {
    Write-Host "  💡 Usa -ShowListeners para consultar contadores de listeners en Azure." -ForegroundColor DarkGray
    Write-Host ""
}
