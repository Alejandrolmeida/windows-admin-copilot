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
    [string]$ConfigPath     = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.config'),
    [string]$RegistryFile   = '',
    [string]$ServerTaskName = 'RelayAdminServer',
    [switch]$ShowListeners
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $RegistryFile) { $RegistryFile = Join-Path $ConfigPath 'server-registry.json' }

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
$serverTask    = Get-ScheduledTask -TaskName $ServerTaskName 2>$null
$azProcs       = @(Get-Process -Name 'azbridge' -ErrorAction SilentlyContinue)
$azProcRunning = $azProcs.Count -gt 0

# Detectar si la tarea existe pero es SYSTEM (no visible sin admin).
# schtasks devuelve "Acceso denegado" (ES) o "Access is denied" (EN) si la tarea
# EXISTE pero no tenemos permisos para leerla, a diferencia de "no se encontro el archivo"
# cuando la tarea no existe en absoluto.
$taskIsSystemLevel = $false
if (-not $serverTask) {
    $schtasksOut = (schtasks.exe /Query /TN $ServerTaskName 2>&1) -join ' '
    if ($schtasksOut -match 'Acceso denegado|Access is denied') {
        $taskIsSystemLevel = $true
    }
}

if ($serverTask) {
    $serverState = $serverTask.State
    $serverOk    = $serverState -eq "Running"
    $serverIcon  = if ($serverOk) { "✅" } else { "⚠️" }
    $serverColor = if ($serverOk) { 'Green' } else { 'Yellow' }
    $serverLabel = "Tarea '$ServerTaskName' — $serverState"
} elseif ($taskIsSystemLevel -and $azProcRunning) {
    $pids = ($azProcs | ForEach-Object { $_.Id }) -join ", "
    $serverOk    = $true
    $serverIcon  = "✅"
    $serverColor = 'Green'
    $serverLabel = "Tarea '$ServerTaskName' (SYSTEM) — Running [PID: $pids]"
} elseif ($taskIsSystemLevel) {
    $serverOk    = $false
    $serverIcon  = "⚠️"
    $serverColor = 'Yellow'
    $serverLabel = "Tarea '$ServerTaskName' (SYSTEM) — No está ejecutando"
} elseif ($azProcRunning) {
    $pids = ($azProcs | ForEach-Object { $_.Id }) -join ", "
    $serverOk    = $true
    $serverIcon  = "⚠️"
    $serverColor = 'Yellow'
    $serverLabel = "Proceso manual (sin tarea) — Running [PID: $pids]"
} else {
    $serverOk    = $false
    $serverIcon  = "❌"
    $serverColor = 'Red'
    $serverLabel = "Tarea '$ServerTaskName' — No instalada"
}

Write-Host "  Namespace   : $($registry.namespace)" -ForegroundColor White
Write-Host "  Endpoint    : $($registry.endpoint)" -ForegroundColor DarkGray
Write-Host "  Generado    : $($registry.generatedAt)" -ForegroundColor DarkGray
Write-Host "  Servidor    : $serverIcon $serverLabel" -ForegroundColor $serverColor
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
    # Resolver az: verificar que funciona (puede apuntar a Python incorrecto), con fallback a python.exe
    $azResolved = $null

    $azOk = Get-Command az -ErrorAction SilentlyContinue
    if ($azOk) {
        az account show --output none 2>$null
        if ($LASTEXITCODE -eq 0) { $azResolved = 'az' }
    }

    if (-not $azResolved) {
        # Fallback: buscar python.exe con azure.cli instalado (ej. coexistencia Python 3.13 + 3.14)
        $pyPaths = @(
            "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\python.exe",
            "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python312\python.exe"
        )
        foreach ($py in $pyPaths) {
            if (Test-Path $py) {
                & $py -m azure.cli account show --output none 2>$null
                if ($LASTEXITCODE -eq 0) { $azResolved = $py; break }
            }
        }
    }

    if ($azResolved) {
        $hcsJson = if ($azResolved -eq 'az') {
            az relay hyco list --resource-group $registry.resourceGroup --namespace-name $registry.namespace --output json 2>$null
        } else {
            & $azResolved -m azure.cli relay hyco list --resource-group $registry.resourceGroup --namespace-name $registry.namespace --output json 2>$null
        }
        $hcs = $hcsJson | ConvertFrom-Json
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

if (-not $serverTask -and -not $taskIsSystemLevel -and $azProcRunning) {
    Write-Host "  ⚠️  El relay funciona como proceso manual." -ForegroundColor Yellow
    Write-Host "     Para instalar como tarea persistente (arranque automatico), ejecuta como Admin:" -ForegroundColor DarkGray
    Write-Host "     .\Install-RelayServer.ps1" -ForegroundColor Cyan
    Write-Host ""
}
