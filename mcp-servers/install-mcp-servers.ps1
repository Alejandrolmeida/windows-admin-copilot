# ============================================================
# install-mcp-servers.ps1
# Clona, compila e instala todos los servidores MCP
# ============================================================
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$mcpRoot = "C:\mcp-servers"
New-Item -ItemType Directory -Path $mcpRoot -Force | Out-Null

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# Resolución robusta de nombre de usuario (evita $env:USERNAME vacío en sesiones elevadas)
$script:resolvedUser = $env:USERNAME
if ([string]::IsNullOrWhiteSpace($script:resolvedUser)) {
    $script:resolvedUser = Split-Path $env:USERPROFILE -Leaf
}

Write-Host "=== Instalando servidores MCP ===" -ForegroundColor Cyan
Write-Host "Usuario: $script:resolvedUser | Perfil: $env:USERPROFILE" -ForegroundColor Gray

# ----------------------------------------------------------
# 0. Verificar y preparar Python y pip
# ----------------------------------------------------------
Write-Host "`n[0/5] Verificando Python y pip..." -ForegroundColor Yellow

# Buscar Python en rutas conocidas — prioridad: Miniconda > Anaconda > Python estándar
# Se evita el alias stub del Windows Store (no es un Python real)
$pythonCandidates = @(
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

$script:pythonExe = $null
foreach ($candidate in $pythonCandidates) {
    if (Test-Path $candidate) {
        $script:pythonExe = $candidate
        break
    }
}

# Si no se encontró, intentar 'python' del PATH pero verificar que no sea el stub del Store
if (-not $script:pythonExe) {
    $pyCmd = Get-Command python -EA SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -notlike "*WindowsApps*") {
        $testOutput = & $pyCmd.Source --version 2>&1
        if ($testOutput -match 'Python \d') {
            $script:pythonExe = $pyCmd.Source
        }
    }
}

# Si aún no hay Python, instalar Miniconda3 (preferido) con fallback a Python estándar
if (-not $script:pythonExe) {
    Write-Host "Python no encontrado. Instalando Miniconda3 via winget..." -ForegroundColor Yellow
    winget install --id Anaconda.Miniconda3 --silent --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    if (Test-Path "$env:USERPROFILE\miniconda3\python.exe") {
        $script:pythonExe = "$env:USERPROFILE\miniconda3\python.exe"
    } else {
        Write-Host "Miniconda no disponible, instalando Python 3.13 via winget..." -ForegroundColor Yellow
        winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
        $script:pythonExe = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
    }
}

Write-Host "Python encontrado: $script:pythonExe" -ForegroundColor Green
$pyVersion = & $script:pythonExe --version 2>&1
Write-Host "Version: $pyVersion" -ForegroundColor Green

# Asegurar que pip está disponible y actualizado
Write-Host "Actualizando pip..." -ForegroundColor Yellow
& $script:pythonExe -m ensurepip --upgrade 2>&1 | Out-Null
& $script:pythonExe -m pip install --upgrade pip --quiet

$pipVersion = & $script:pythonExe -m pip --version 2>&1
Write-Host "pip: $pipVersion" -ForegroundColor Green

# ----------------------------------------------------------
# 1. PowerShell.MCP (PSGallery) — instalar o actualizar
# ----------------------------------------------------------
Write-Host "`n[1/6] PowerShell.MCP..." -ForegroundColor Yellow
$existingMCP = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $existingMCP) {
    Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository
} else {
    Write-Host "Actualizando PowerShell.MCP (instalado: $($existingMCP.Version))..." -ForegroundColor Gray
    Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository -Reinstall -EA SilentlyContinue
}
$newMCP = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
Write-Host "PowerShell.MCP OK (version: $($newMCP.Version))" -ForegroundColor Green

# Obtener la ruta real del proxy
$script:proxyPath = $null
try {
    $script:proxyPath = & "C:\Program Files\PowerShell\7\pwsh.exe" -NonInteractive -Command `
        "Import-Module PowerShell.MCP -EA SilentlyContinue; if (Get-Command Get-MCPProxyPath -EA SilentlyContinue) { Get-MCPProxyPath }" `
        2>$null | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
    if ($script:proxyPath) { $script:proxyPath = $script:proxyPath.Trim() }
    if ($script:proxyPath) { Write-Host "Proxy path detectado: $script:proxyPath" -ForegroundColor Green }
} catch {
    Write-Host "No se pudo obtener la ruta del proxy (no crítico)" -ForegroundColor Yellow
}

# ----------------------------------------------------------
# 2. win-cli-mcp-server (mhprol fork)
# ----------------------------------------------------------
Write-Host "`n[2/6] win-cli-mcp-server..." -ForegroundColor Yellow
$dest = "$mcpRoot\win-cli-mcp-server"
if (Test-Path "$dest\.git") {
    Write-Host "Actualizando repositorio existente..." -ForegroundColor Gray
    Push-Location $dest; git pull --quiet; Pop-Location
} elseif (-not (Test-Path $dest)) {
    git clone https://github.com/mhprol/win-cli-mcp-server.git $dest
}
Push-Location $dest
npm install
npm run build
Pop-Location
# Copiar config de ejemplo
if (-not (Test-Path "$dest\config.json")) {
    Copy-Item "$dest\config.example.json" "$dest\config.json"
}
Write-Host "win-cli-mcp-server OK -> $dest\dist\index.js" -ForegroundColor Green

# ----------------------------------------------------------
# 3. windows-admin-mcp (Cosmicjedi)
# ----------------------------------------------------------
Write-Host "`n[3/6] windows-admin-mcp..." -ForegroundColor Yellow
$dest = "$mcpRoot\windows-admin-mcp"
if (Test-Path "$dest\.git") {
    Write-Host "Actualizando repositorio existente..." -ForegroundColor Gray
    Push-Location $dest; git pull --quiet; Pop-Location
} elseif (-not (Test-Path $dest)) {
    git clone https://github.com/Cosmicjedi/windows-admin-mcp.git $dest
}
Push-Location $dest
& $script:pythonExe -m pip install -r requirements.txt --upgrade --quiet
Pop-Location
Write-Host "windows-admin-mcp OK -> $dest\windows_admin_server.py" -ForegroundColor Green

# ----------------------------------------------------------
# 4. Azure MCP (@azure/mcp - oficial Microsoft)
# ----------------------------------------------------------
Write-Host "`n[4/6] Azure MCP (@azure/mcp)..." -ForegroundColor Yellow
npm install -g @azure/mcp@latest --quiet
Write-Host "Azure MCP OK (npx @azure/mcp@latest)" -ForegroundColor Green

# ----------------------------------------------------------
# 5. MCP Memory (@modelcontextprotocol/server-memory)
# ----------------------------------------------------------
Write-Host "`n[5/6] MCP Memory (@modelcontextprotocol/server-memory)..." -ForegroundColor Yellow
$memoryDir = "$mcpRoot\memory"
New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null
npm install -g @modelcontextprotocol/server-memory --quiet
Write-Host "MCP Memory OK -> MEMORY_FILE_PATH=$memoryDir\memory.json" -ForegroundColor Green

# ----------------------------------------------------------
# 6. VMware vSphere MCP (giuliolibrando)
# ----------------------------------------------------------
Write-Host "`n[6/6] VMware vSphere MCP..." -ForegroundColor Yellow
$dest = "$mcpRoot\vmware-vsphere-mcp-server"
if (Test-Path "$dest\.git") {
    Write-Host "Actualizando repositorio existente..." -ForegroundColor Gray
    Push-Location $dest; git pull --quiet; Pop-Location
} elseif (-not (Test-Path $dest)) {
    git clone https://github.com/giuliolibrando/vmware-vsphere-mcp-server.git $dest
}
Push-Location $dest
if (Test-Path "requirements.txt") {
    & $script:pythonExe -m pip install -r requirements.txt --upgrade --quiet
}
Pop-Location

# Create stdio wrapper (server.py uses relative imports and HTTP transport by default)
$wrapperPath = "$dest\run_server_stdio.py"
if (-not (Test-Path $wrapperPath)) {
    @'
"""Wrapper to run vsphere_mcp_server with stdio transport for GitHub Copilot CLI."""
import sys
import os

# Add src directory to path to resolve relative imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from vsphere_mcp_server.server import mcp

if __name__ == "__main__":
    mcp.run(transport="stdio")
'@ | Set-Content $wrapperPath -Encoding UTF8
}
Write-Host "VMware vSphere MCP OK -> $wrapperPath" -ForegroundColor Green

# ----------------------------------------------------------
# Copiar y configurar mcp-config.json al perfil del usuario
# ----------------------------------------------------------
Write-Host "`n=== Configurando mcp-config.json ===" -ForegroundColor Cyan
$copilotDir = "$env:USERPROFILE\.copilot"
New-Item -ItemType Directory -Path $copilotDir -Force | Out-Null
$configSrc = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "..\\.copilot\\mcp-config.json"
$configSrc = (Resolve-Path $configSrc -EA SilentlyContinue)?.Path
$configDst = "$copilotDir\mcp-config.json"
if ($configSrc -and (Test-Path $configSrc)) {
    # Backup si ya existe
    if (Test-Path $configDst) {
        $backup = "$configDst.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $configDst $backup
        Write-Host "Backup guardado: $backup" -ForegroundColor Gray
    }
    # Leer template, resolver variables de entorno Windows (%VAR%) con valores reales.
    # ConvertFrom-Json NO expande %VAR%, por lo que hay que sustituir antes de parsear.
    # Los backslashes deben estar doblados para que el JSON resultante sea válido.
    $configContent = Get-Content $configSrc -Raw
    $configContent = $configContent.Replace('%USERNAME%', $script:resolvedUser)
    $configContent = $configContent.Replace('%APPDATA%', $env:APPDATA.Replace('\', '\\'))
    $config = $configContent | ConvertFrom-Json

    # Escribir ruta real de Python en ambos servidores Python
    $config.mcpServers.'windows-admin-mcp'.command  = $script:pythonExe
    $config.mcpServers.'vmware-vsphere-mcp'.command = $script:pythonExe
    Write-Host "Python path: $script:pythonExe" -ForegroundColor Green

    # Resolver path real del servidor memory (npm install -g puede cambiar la ubicación)
    $npmGlobalModules = (npm root -g 2>$null | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    if ($npmGlobalModules) { $npmGlobalModules = $npmGlobalModules.Trim() }
    $memoryJsPath = if ($npmGlobalModules) {
        Join-Path $npmGlobalModules "@modelcontextprotocol\server-memory\dist\index.js"
    } else {
        Join-Path $env:APPDATA "npm\node_modules\@modelcontextprotocol\server-memory\dist\index.js"
    }
    if (Test-Path $memoryJsPath) {
        $config.mcpServers.'memory'.args = @($memoryJsPath)
        Write-Host "memory path: $memoryJsPath" -ForegroundColor Green
    } else {
        Write-Host "AVISO: memory server no encontrado en $memoryJsPath" -ForegroundColor Yellow
    }

    # Actualizar proxy de PowerShell.MCP si se detectó
    if ($script:proxyPath -and (Test-Path $script:proxyPath)) {
        $config.mcpServers.'powershell-mcp'.command = $script:proxyPath
        Write-Host "powershell-mcp proxy: $script:proxyPath" -ForegroundColor Green
    }

    $config | ConvertTo-Json -Depth 10 | Out-File $configDst -Encoding UTF8
    Write-Host "mcp-config.json instalado en $configDst" -ForegroundColor Green
    Write-Host "IMPORTANTE: Edita $configDst con tus credenciales de servidores" -ForegroundColor Yellow
}

Write-Host "`n=== Todos los MCP instalados correctamente ===" -ForegroundColor Green

# Verificación rápida de ejecutables
$finalCfg = Get-Content $configDst -Raw | ConvertFrom-Json
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
