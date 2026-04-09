# ============================================================
# repair-mcp-config.ps1
# Repara el mcp-config.json instalado en ~/.copilot/
# resolviendo variables de entorno Windows (%APPDATA%, etc.)
# que pueden haber quedado sin expandir en versiones anteriores.
#
# Usar cuando algún servidor MCP falla por path no resuelto,
# sin necesidad de reinstalar todo desde install-mcp-servers.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$configPath = "$env:USERPROFILE\.copilot\mcp-config.json"

if (-not (Test-Path $configPath)) {
    Write-Host "No se encontró $configPath" -ForegroundColor Red
    Write-Host "Ejecuta primero install-mcp-servers.ps1" -ForegroundColor Yellow
    exit 1
}

# Backup antes de tocar nada
$backup = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $configPath $backup
Write-Host "Backup guardado: $backup" -ForegroundColor Gray

$cfg     = Get-Content $configPath -Raw | ConvertFrom-Json
$changed = @()

# ----------------------------------------------------------
# 1. Resolver %APPDATA% en cualquier arg/command que lo tenga
# ----------------------------------------------------------
$cfg.mcpServers.PSObject.Properties | ForEach-Object {
    $name   = $_.Name
    $server = $_.Value

    if ($server.command -and $server.command -match '%\w+%') {
        $resolved = [System.Environment]::ExpandEnvironmentVariables($server.command)
        $server.command = $resolved
        $changed += "$name.command -> $resolved"
    }

    if ($server.args) {
        $newArgs = $server.args | ForEach-Object {
            if ($_ -match '%\w+%') {
                $resolved = [System.Environment]::ExpandEnvironmentVariables($_)
                $changed += "$name.args -> $resolved"
                $resolved
            } else { $_ }
        }
        $server.args = $newArgs
    }
}

# ----------------------------------------------------------
# 2. Resolver path real del servidor memory via npm root -g
#    (más fiable que %APPDATA% cuando npm usa otro directorio)
# ----------------------------------------------------------
$memoryServer = $cfg.mcpServers.PSObject.Properties |
    Where-Object { $_.Name -eq 'memory' } |
    Select-Object -ExpandProperty Value

if ($memoryServer) {
    $npmRoot = (npm root -g 2>$null | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    if ($npmRoot) { $npmRoot = $npmRoot.Trim() }
    $memoryJs = if ($npmRoot) {
        Join-Path $npmRoot "@modelcontextprotocol\server-memory\dist\index.js"
    } else {
        Join-Path $env:APPDATA "npm\node_modules\@modelcontextprotocol\server-memory\dist\index.js"
    }
    if (Test-Path $memoryJs) {
        $memoryServer.args = @($memoryJs)
        $changed += "memory.args (npm root -g) -> $memoryJs"
    }
}

# ----------------------------------------------------------
# Guardar si hubo cambios
# ----------------------------------------------------------
if ($changed.Count -gt 0) {
    $cfg | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
    Write-Host "`nCambios aplicados:" -ForegroundColor Green
    $changed | ForEach-Object { Write-Host "  ✅ $_" -ForegroundColor Green }
    Write-Host "`nmcp-config.json reparado en $configPath" -ForegroundColor Cyan
} else {
    Remove-Item $backup -EA SilentlyContinue
    Write-Host "`nNo se encontraron variables sin resolver. Config OK." -ForegroundColor Green
}

# ----------------------------------------------------------
# Verificación final: comprobar que los ejecutables existen
# ----------------------------------------------------------
Write-Host "`n=== Verificación de paths ===" -ForegroundColor Cyan
$finalCfg = Get-Content $configPath -Raw | ConvertFrom-Json
$finalCfg.mcpServers.PSObject.Properties | ForEach-Object {
    $name = $_.Name
    $cmd  = $_.Value.command
    if ($cmd) {
        $exists = if ([System.IO.Path]::IsPathRooted($cmd)) {
            Test-Path $cmd -EA SilentlyContinue
        } else {
            $null -ne (Get-Command $cmd -EA SilentlyContinue)
        }
        $icon = if ($exists) { '✅' } else { '⚠️  NO ENCONTRADO' }
        Write-Host "  $icon  $name -> $cmd"
    }
}
