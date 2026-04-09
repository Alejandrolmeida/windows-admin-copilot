# ============================================================
# install-mcp-servers.ps1
# Instala, actualiza y repara todos los servidores MCP.
# Válido para primera instalación, reinstalación y actualización.
# Las credenciales existentes (Azure, VMware) se preservan siempre.
#
# Parámetros:
#   -ConfigOnly   Solo regenerar mcp-config.json (omite fases 0-6)
#   -Force        Sin confirmaciones interactivas
# ============================================================
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ConfigOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mcpRoot    = "C:\mcp-servers"
$configPath = "$env:USERPROFILE\.copilot\mcp-config.json"
$repoRoot   = Split-Path (Split-Path $MyInvocation.MyCommand.Path)
$repoConfig = (Resolve-Path (Join-Path $repoRoot ".copilot\mcp-config.json") -EA SilentlyContinue)?.Path

# Resolución robusta del nombre de usuario (evita %USERNAME% vacío en sesiones elevadas)
$resolvedUser = $env:USERNAME
if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
    $resolvedUser = Split-Path $env:USERPROFILE -Leaf
}

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User")

# -------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $color
}

function Find-PythonExe {
    $candidates = @(
        "$env:USERPROFILE\miniconda3\python.exe",
        "$env:USERPROFILE\miniconda3\envs\base\python.exe",
        "$env:USERPROFILE\anaconda3\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $pyCmd = Get-Command python -EA SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -notlike "*WindowsApps*") {
    if ((& $pyCmd.Source --version 2>&1) -match 'Python \d') { return $pyCmd.Source }
    }
    return $null
}

# -------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Windows Admin Copilot — MCP Setup/Update  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Log "Usuario: $resolvedUser | Perfil: $env:USERPROFILE"

if (-not $repoConfig -or -not (Test-Path $repoConfig)) {
    Write-Log "Template no encontrado: $repoConfig" 'ERROR'
    Write-Log "Ejecuta este script desde dentro del repositorio clonado." 'ERROR'
    exit 1
}

# Detectar si es primera instalación o actualización
$isFirstInstall = -not (Test-Path $configPath)
$backupPath     = $null

if ($isFirstInstall) {
    Write-Log "Primera instalacion detectada." 'OK'
} else {
    Write-Log "Instalacion existente detectada — se preservaran credenciales." 'OK'
}

# ----------------------------------------------------------
# Preservar credenciales del config actual (si existe)
# ----------------------------------------------------------
$azureCreds  = $null; $hasAzureCreds  = $false
$vmwareCreds = $null; $hasVmwareCreds = $false

if (-not $isFirstInstall) {
    $current = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($current.mcpServers.'azure-mcp'?.env) {
        $azureCreds    = $current.mcpServers.'azure-mcp'.env
        $hasAzureCreds = (-not [string]::IsNullOrWhiteSpace($azureCreds.AZURE_SUBSCRIPTION_ID))
        if ($hasAzureCreds) { Write-Log "Credenciales Azure detectadas — se preservaran" 'OK' }
    }
    if ($current.mcpServers.'vmware-vsphere-mcp'?.env) {
        $vmwareCreds    = $current.mcpServers.'vmware-vsphere-mcp'.env
        $hasVmwareCreds = (-not [string]::IsNullOrWhiteSpace($vmwareCreds.VCENTER_HOST))
        if ($hasVmwareCreds) { Write-Log "Credenciales VMware detectadas — se preservaran" 'OK' }
    }
}

# ----------------------------------------------------------
# FASE 0 — Python y pip
# ----------------------------------------------------------
Write-Host "`n--- Fase 0: Python y pip ---" -ForegroundColor Magenta

$pythonExe = Find-PythonExe
if (-not $pythonExe -and -not $ConfigOnly) {
    Write-Log "Python no encontrado. Instalando Miniconda3 via winget..." 'WARN'
    try {
        winget install --id Anaconda.Miniconda3 --silent --accept-source-agreements --accept-package-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
        if (Test-Path "$env:USERPROFILE\miniconda3\python.exe") {
            $pythonExe = "$env:USERPROFILE\miniconda3\python.exe"
        }
    } catch {
        Write-Log "Miniconda no disponible, intentando Python 3.13 via winget..." 'WARN'
        try {
            winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
            $pythonExe = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
        } catch {
            Write-Log "No se pudo instalar Python automaticamente. Instalalo manualmente." 'WARN'
        }
    }
}

if ($pythonExe) {
    $pyVersion = & $pythonExe --version 2>&1
    Write-Log "Python: $pythonExe ($pyVersion)" 'OK'
    if (-not $ConfigOnly) {
        & $pythonExe -m ensurepip --upgrade 2>&1 | Out-Null
        & $pythonExe -m pip install --upgrade pip --quiet
        Write-Log "pip: $(& $pythonExe -m pip --version 2>&1)" 'OK'
    }
} else {
    Write-Log "Python no disponible — servidores Python no se instalarán/actualizarán" 'WARN'
}

# ----------------------------------------------------------
# FASE 1 — PowerShell.MCP
# ----------------------------------------------------------
Write-Host "`n--- Fase 1: PowerShell.MCP ---" -ForegroundColor Magenta

$proxyPath = $null
if (-not $ConfigOnly) {
    try {
        $installed = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) {
            Write-Log "Actualizando PowerShell.MCP (version actual: $($installed.Version))..."
            Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository -Reinstall -EA SilentlyContinue 2>$null
        } else {
            Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository
        }
        $updated = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        Write-Log "PowerShell.MCP OK (version: $($updated.Version))" 'OK'
    } catch {
        Write-Log "PowerShell.MCP no se pudo actualizar (puede estar en uso). Version actual sigue activa." 'WARN'
    }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# Detectar ruta del proxy (siempre, independientemente de -ConfigOnly)
try {
    $proxyPath = & "C:\Program Files\PowerShell\7\pwsh.exe" -NonInteractive -Command `
        "Import-Module PowerShell.MCP -EA SilentlyContinue; if (Get-Command Get-MCPProxyPath -EA SilentlyContinue) { Get-MCPProxyPath }" `
        2>$null | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
    if ($proxyPath) { $proxyPath = $proxyPath.Trim() }
    if ($proxyPath) { Write-Log "Proxy detectado: $proxyPath" 'OK' }
} catch { }

# ----------------------------------------------------------
# FASE 2 — win-cli-mcp-server (Node.js)
# ----------------------------------------------------------
Write-Host "`n--- Fase 2: win-cli-mcp-server ---" -ForegroundColor Magenta
New-Item -ItemType Directory -Path $mcpRoot -Force | Out-Null

if (-not $ConfigOnly) {
    $dest = "$mcpRoot\win-cli-mcp-server"
    try {
        if (Test-Path "$dest\.git") {
            Write-Log "Actualizando repositorio..."
            Push-Location $dest
            try { git pull --quiet } finally { Pop-Location }
        } elseif (-not (Test-Path $dest)) {
            git clone https://github.com/mhprol/win-cli-mcp-server.git $dest
        }
        Push-Location $dest
        try {
            npm install
            npm run build
        } finally { Pop-Location }
        if (-not (Test-Path "$dest\config.json")) { Copy-Item "$dest\config.example.json" "$dest\config.json" }
        Write-Log "win-cli-mcp-server OK" 'OK'
    } catch { Write-Log "Error en win-cli-mcp-server: $_" 'WARN' }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# ----------------------------------------------------------
# FASE 3 — windows-admin-mcp (Python)
# ----------------------------------------------------------
Write-Host "`n--- Fase 3: windows-admin-mcp ---" -ForegroundColor Magenta

if (-not $ConfigOnly) {
    $dest = "$mcpRoot\windows-admin-mcp"
    try {
        if (Test-Path "$dest\.git") {
            Write-Log "Actualizando repositorio..."
            Push-Location $dest
            try { git pull --quiet } finally { Pop-Location }
        } elseif (-not (Test-Path $dest)) {
            git clone https://github.com/Cosmicjedi/windows-admin-mcp.git $dest
        }
        if ($pythonExe) {
            Push-Location $dest
            try { & $pythonExe -m pip install -r requirements.txt --upgrade --quiet } finally { Pop-Location }
            Write-Log "windows-admin-mcp OK" 'OK'
        } else { Write-Log "Python no disponible — dependencias no actualizadas" 'WARN' }
    } catch { Write-Log "Error en windows-admin-mcp: $_" 'WARN' }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# ----------------------------------------------------------
# FASE 4 — Azure MCP (@azure/mcp)
# ----------------------------------------------------------
Write-Host "`n--- Fase 4: Azure MCP ---" -ForegroundColor Magenta

if (-not $ConfigOnly) {
    try {
        npm install -g @azure/mcp@latest --quiet 2>&1 | Out-Null
        Write-Log "Azure MCP OK" 'OK'
    } catch { Write-Log "Error actualizando @azure/mcp: $_" 'WARN' }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# ----------------------------------------------------------
# FASE 5 — MCP Memory (@modelcontextprotocol/server-memory)
# ----------------------------------------------------------
Write-Host "`n--- Fase 5: MCP Memory ---" -ForegroundColor Magenta

if (-not $ConfigOnly) {
    try {
        New-Item -ItemType Directory -Path "$mcpRoot\memory" -Force | Out-Null
        npm install -g @modelcontextprotocol/server-memory --quiet 2>&1 | Out-Null
        Write-Log "MCP Memory OK" 'OK'
    } catch { Write-Log "Error actualizando MCP Memory: $_" 'WARN' }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# ----------------------------------------------------------
# FASE 6 — VMware vSphere MCP (Python)
# ----------------------------------------------------------
Write-Host "`n--- Fase 6: VMware vSphere MCP ---" -ForegroundColor Magenta

if (-not $ConfigOnly) {
    $dest = "$mcpRoot\vmware-vsphere-mcp-server"
    try {
        if (Test-Path "$dest\.git") {
            Write-Log "Actualizando repositorio..."
            Push-Location $dest
            try { git pull --quiet } finally { Pop-Location }
        } elseif (-not (Test-Path $dest)) {
            git clone https://github.com/giuliolibrando/vmware-vsphere-mcp-server.git $dest
        }
        if ($pythonExe -and (Test-Path "$dest\requirements.txt")) {
            Push-Location $dest
            try { & $pythonExe -m pip install -r requirements.txt --upgrade --quiet } finally { Pop-Location }
        }
        $wrapperPath = "$dest\run_server_stdio.py"
        if (-not (Test-Path $wrapperPath)) {
            @'
"""Wrapper to run vsphere_mcp_server with stdio transport for GitHub Copilot CLI."""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from vsphere_mcp_server.server import mcp

if __name__ == "__main__":
    mcp.run(transport="stdio")
'@ | Set-Content $wrapperPath -Encoding UTF8
        }
        Write-Log "VMware vSphere MCP OK" 'OK'
    } catch { Write-Log "Error en vmware-vsphere-mcp: $_" 'WARN' }
} else { Write-Log "Omitida (-ConfigOnly)" 'WARN' }

# ----------------------------------------------------------
# FASE 7 — Generar/actualizar mcp-config.json
# ----------------------------------------------------------
Write-Host "`n--- Fase 7: mcp-config.json ---" -ForegroundColor Magenta
New-Item -ItemType Directory -Path "$env:USERPROFILE\.copilot" -Force | Out-Null

if (Test-Path $configPath) {
    $backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $configPath $backupPath
    Write-Log "Backup: $backupPath" 'OK'
}

# Cargar template y resolver variables de entorno Windows (%VAR%).
# ConvertFrom-Json NO expande %VAR% — sustituir en el raw string antes de parsear.
# Los backslashes se doblan para mantener el JSON válido.
$configContent = Get-Content $repoConfig -Raw
$configContent = $configContent.Replace('%USERNAME%', $resolvedUser)
$configContent = $configContent.Replace('%APPDATA%', $env:APPDATA.Replace('\', '\\'))
$newConfig     = $configContent | ConvertFrom-Json

# Escribir rutas reales de Python
if ($pythonExe) {
    $newConfig.mcpServers.'windows-admin-mcp'.command  = $pythonExe
    $newConfig.mcpServers.'vmware-vsphere-mcp'.command = $pythonExe
    Write-Log "Python path: $pythonExe" 'OK'
} else {
    Write-Log "Python no encontrado — windows-admin-mcp y vmware-vsphere-mcp pueden no funcionar" 'WARN'
}

# Resolver path real del servidor memory via npm root -g
$npmGlobalModules = (npm root -g 2>$null | Where-Object { $_ -match '\S' } | Select-Object -First 1)
if ($npmGlobalModules) { $npmGlobalModules = $npmGlobalModules.Trim() }
$memoryJsPath = if ($npmGlobalModules) {
    Join-Path $npmGlobalModules "@modelcontextprotocol\server-memory\dist\index.js"
} else {
    Join-Path $env:APPDATA "npm\node_modules\@modelcontextprotocol\server-memory\dist\index.js"
}
if (Test-Path $memoryJsPath) {
    $newConfig.mcpServers.'memory'.args = @($memoryJsPath)
    Write-Log "memory path: $memoryJsPath" 'OK'
} else {
    Write-Log "memory server no encontrado en $memoryJsPath" 'WARN'
}

# Actualizar proxy de PowerShell.MCP
if ($proxyPath -and (Test-Path $proxyPath)) {
    $newConfig.mcpServers.'powershell-mcp'.command = $proxyPath
    Write-Log "powershell-mcp proxy: $proxyPath" 'OK'
}

# Restaurar credenciales preservadas
if ($hasAzureCreds) {
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_SUBSCRIPTION_ID = $azureCreds.AZURE_SUBSCRIPTION_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_TENANT_ID       = $azureCreds.AZURE_TENANT_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_CLIENT_ID       = $azureCreds.AZURE_CLIENT_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_CLIENT_SECRET   = $azureCreds.AZURE_CLIENT_SECRET
    Write-Log "Credenciales Azure restauradas" 'OK'
}
if ($hasVmwareCreds) {
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_HOST     = $vmwareCreds.VCENTER_HOST
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_USER     = $vmwareCreds.VCENTER_USER
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_PASSWORD = $vmwareCreds.VCENTER_PASSWORD
    Write-Log "Credenciales VMware restauradas" 'OK'
}

$newConfig | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
Write-Log "mcp-config.json escrito en $configPath" 'OK'
if ($isFirstInstall) {
    Write-Log "IMPORTANTE: Edita $configPath con tus credenciales de servidores" 'WARN'
}

# Copiar instrucciones de Copilot CLI al perfil de usuario
$instrSrc  = Join-Path $repoRoot ".copilot\copilot-instructions.md"
$instrDest = "$env:USERPROFILE\.copilot\copilot-instructions.md"
if (Test-Path $instrSrc) {
    Copy-Item $instrSrc $instrDest -Force
    Write-Log "copilot-instructions.md copiado a $instrDest" 'OK'
} else {
    Write-Log "No se encontro $instrSrc — instrucciones no configuradas" 'WARN'
}

# ----------------------------------------------------------
# FASE 8 — Verificación final
# ----------------------------------------------------------
Write-Host "`n--- Fase 8: Verificacion ---" -ForegroundColor Magenta

$finalCfg = Get-Content $configPath -Raw | ConvertFrom-Json
$finalCfg.mcpServers.PSObject.Properties | ForEach-Object {
    $name = $_.Name; $cmd = $_.Value.command
    if ($cmd) {
        $exists = if ([System.IO.Path]::IsPathRooted($cmd)) {
            Test-Path $cmd -EA SilentlyContinue
        } else {
            $null -ne (Get-Command $cmd -EA SilentlyContinue)
        }
        $status = if ($exists) { '  ✅' } else { '  ⚠️  NO ENCONTRADO' }
        Write-Host "$status  $name -> $cmd"
    }
}

Write-Host ""
$modeLabel = if ($isFirstInstall) { 'Primera instalacion' } else { 'Actualizacion' }
Write-Log "$modeLabel completada." 'OK'

if (-not $pythonExe) {
    Write-Log "PENDIENTE: Instala Python/Miniconda3 y vuelve a ejecutar para activar windows-admin-mcp y vmware-vsphere-mcp" 'WARN'
    Write-Host "  winget install --id Anaconda.Miniconda3 --silent --accept-source-agreements --accept-package-agreements"
}
if ($backupPath) {
    Write-Log "Para revertir config: Copy-Item '$backupPath' '$configPath' -Force" 'INFO'
}
Write-Host ""

