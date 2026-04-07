# ============================================================
# install-mcp-servers.ps1
# Clona, compila e instala todos los servidores MCP
# ============================================================
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$mcpRoot = "C:\mcp-servers"
New-Item -ItemType Directory -Path $mcpRoot -Force | Out-Null

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

Write-Host "=== Instalando servidores MCP ===" -ForegroundColor Cyan

# ----------------------------------------------------------
# 0. Verificar y preparar pip
# ----------------------------------------------------------
Write-Host "`n[0/5] Verificando Python y pip..." -ForegroundColor Yellow

# Verificar que Python está instalado
if (-not (Get-Command python -EA SilentlyContinue)) {
    Write-Host "Python no encontrado. Instalando..." -ForegroundColor Yellow
    winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

$pyVersion = python --version 2>&1
Write-Host "Python: $pyVersion" -ForegroundColor Green

# Asegurar que pip está disponible y actualizado
Write-Host "Actualizando pip..." -ForegroundColor Yellow
python -m ensurepip --upgrade 2>&1 | Out-Null
python -m pip install --upgrade pip --quiet

# Crear alias de función para usar siempre "python -m pip"
function pip { python -m pip @args }

$pipVersion = python -m pip --version 2>&1
Write-Host "pip: $pipVersion" -ForegroundColor Green

# ----------------------------------------------------------
# 1. PowerShell.MCP (PSGallery)
# ----------------------------------------------------------
Write-Host "`n[1/5] PowerShell.MCP..." -ForegroundColor Yellow
if (-not (Get-Module PowerShell.MCP -ListAvailable)) {
    Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository
}
Write-Host "PowerShell.MCP OK" -ForegroundColor Green

# Actualizar mcp-config.json con la ruta real del proxy
$proxyPath = & "C:\Program Files\PowerShell\7\pwsh.exe" -NonInteractive -Command "Import-Module PowerShell.MCP; Get-MCPProxyPath" 2>$null | Where-Object { $_ -match '\.exe' }
if ($proxyPath) {
    $mcpConfigPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "..\\.copilot\\mcp-config.json"
    $mcpConfigPath = (Resolve-Path $mcpConfigPath -EA SilentlyContinue)?.Path
    if ($mcpConfigPath) {
        $cfg = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
        $cfg.'powershell-mcp'.command = $proxyPath.Trim()
        $cfg.'powershell-mcp'.args = @()
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $mcpConfigPath -Encoding UTF8
        Write-Host "powershell-mcp proxy actualizado: $proxyPath" -ForegroundColor Green
    }
}

# ----------------------------------------------------------
# 2. win-cli-mcp-server (mhprol fork)
# ----------------------------------------------------------
Write-Host "`n[2/5] win-cli-mcp-server..." -ForegroundColor Yellow
$dest = "$mcpRoot\win-cli-mcp-server"
if (-not (Test-Path $dest)) {
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
Write-Host "`n[3/5] windows-admin-mcp..." -ForegroundColor Yellow
$dest = "$mcpRoot\windows-admin-mcp"
if (-not (Test-Path $dest)) {
    git clone https://github.com/Cosmicjedi/windows-admin-mcp.git $dest
}
Push-Location $dest
python -m pip install -r requirements.txt --quiet
Pop-Location
Write-Host "windows-admin-mcp OK -> $dest\windows_admin_server.py" -ForegroundColor Green

# ----------------------------------------------------------
# 4. Azure MCP (@azure/mcp - oficial Microsoft)
# ----------------------------------------------------------
Write-Host "`n[4/5] Azure MCP (@azure/mcp)..." -ForegroundColor Yellow
npm install -g @azure/mcp@latest --quiet
Write-Host "Azure MCP OK (npx @azure/mcp@latest)" -ForegroundColor Green

# ----------------------------------------------------------
# 5. VMware vSphere MCP (giuliolibrando)
# ----------------------------------------------------------
Write-Host "`n[5/5] VMware vSphere MCP..." -ForegroundColor Yellow
$dest = "$mcpRoot\vmware-vsphere-mcp-server"
if (-not (Test-Path $dest)) {
    git clone https://github.com/giuliolibrando/vmware-vsphere-mcp-server.git $dest
}
Push-Location $dest
if (Test-Path "requirements.txt") {
    python -m pip install -r requirements.txt --quiet
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
# Copiar mcp-config.json al perfil del usuario actual
# ----------------------------------------------------------
Write-Host "`n=== Copiando configuracion MCP ===" -ForegroundColor Cyan
$copilotDir = "$env:USERPROFILE\.copilot"
New-Item -ItemType Directory -Path $copilotDir -Force | Out-Null
$configSrc = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "..\\.copilot\\mcp-config.json"
$configSrc = (Resolve-Path $configSrc -EA SilentlyContinue)?.Path
if ($configSrc -and (Test-Path $configSrc)) {
    Copy-Item $configSrc "$copilotDir\mcp-config.json" -Force
    Write-Host "mcp-config.json copiado a $copilotDir" -ForegroundColor Green
    Write-Host "IMPORTANTE: Edita $copilotDir\mcp-config.json con tus credenciales de servidores" -ForegroundColor Yellow
}

Write-Host "`n=== Todos los MCP instalados correctamente ===" -ForegroundColor Green
