# ============================================================
# update-mcp-config.ps1
# Actualiza servidores MCP y mcp-config.json preservando
# credenciales existentes (Azure, VMware, SSH).
#
# Fases:
#   0 - Actualiza el módulo PowerShell.MCP
#   1 - git pull + reinstala dependencias de cada servidor MCP
#   2 - Actualiza mcp-config.json (preserva credenciales)
#   3 - Verificacion final
#
# Parametros:
#   -Force      Sobreescribir config sin pedir confirmacion
#   -ConfigOnly Solo actualizar config (omite fases 0 y 1)
# ============================================================
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$ConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $pyCmd = Get-Command python -EA SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -notlike "*WindowsApps*") {
        $v = & $pyCmd.Source --version 2>&1
        if ($v -match 'Python \d') { return $pyCmd.Source }
    }
    return $null
}

# -------------------------------------------------------
# Configuracion de rutas
# -------------------------------------------------------
$mcpRoot    = "C:\mcp-servers"
$configPath = "$env:USERPROFILE\.copilot\mcp-config.json"
$repoRoot   = Split-Path (Split-Path $MyInvocation.MyCommand.Path)   # setup/../ = raiz del repo
$repoConfig = (Resolve-Path (Join-Path $repoRoot ".copilot\mcp-config.json") -EA SilentlyContinue)?.Path

# Resolución robusta de nombre de usuario
$resolvedUser = $env:USERNAME
if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
    $resolvedUser = Split-Path $env:USERPROFILE -Leaf
}

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Windows Admin Copilot - Update Completo   " -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan
Write-Log "Usuario: $resolvedUser | Perfil: $env:USERPROFILE"

if (-not (Test-Path $configPath)) {
    Write-Log "No se encontro $configPath" 'WARN'
    Write-Log "Parece instalacion nueva. Ejecuta mcp-servers\install-mcp-servers.ps1" 'WARN'
    exit 0
}

if (-not $repoConfig -or -not (Test-Path $repoConfig)) {
    Write-Log "Template del repo no encontrado: $repoConfig" 'ERROR'
    Write-Log "Ejecuta este script desde dentro del repositorio clonado." 'ERROR'
    exit 1
}

# ============================================================
# FASE 0 — Actualizar modulo PowerShell.MCP
# ============================================================
Write-Host "`n--- Fase 0: PowerShell.MCP ---" -ForegroundColor Magenta

$proxyPath = $null
if (-not $ConfigOnly) {
    try {
        $installed = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) {
            Write-Log "Actualizando PowerShell.MCP (version actual: $($installed.Version))..."
            # -EA SilentlyContinue por si el módulo está en uso (no-crítico)
            Install-PSResource -Name PowerShell.MCP -Repository PSGallery -Scope AllUsers -TrustRepository -Reinstall -EA SilentlyContinue 2>$null
            $updated = Get-Module PowerShell.MCP -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
            Write-Log "PowerShell.MCP: $($updated.Version)" 'OK'
        } else {
            Write-Log "PowerShell.MCP no esta instalado. Ejecuta install-mcp-servers.ps1 primero." 'WARN'
        }
    } catch {
        Write-Log "PowerShell.MCP no se pudo actualizar ahora (puede estar en uso). Versión actual sigue activa." 'WARN'
    }
} else {
    Write-Log "Fase omitida (-ConfigOnly)" 'WARN'
}

# Detectar ruta del proxy independientemente de si se actualizo
try {
    $proxyPath = & "C:\Program Files\PowerShell\7\pwsh.exe" -NonInteractive -Command `
        "Import-Module PowerShell.MCP -EA SilentlyContinue; if (Get-Command Get-MCPProxyPath -EA SilentlyContinue) { Get-MCPProxyPath }" `
        2>$null | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
    if ($proxyPath) { $proxyPath = $proxyPath.Trim() }
} catch { }

# ============================================================
# FASE 1 — Actualizar repositorios de servidores MCP
# ============================================================
Write-Host "`n--- Fase 1: Actualizar repositorios MCP ---" -ForegroundColor Magenta

if (-not $ConfigOnly) {

    # 1a. win-cli-mcp-server (Node.js)
    $dest = "$mcpRoot\win-cli-mcp-server"
    if (Test-Path "$dest\.git") {
        Write-Log "win-cli-mcp-server: actualizando..."
        Push-Location $dest
        try {
            git pull --quiet
            npm install --quiet 2>&1 | Out-Null
            npm run build --quiet 2>&1 | Out-Null
            Write-Log "win-cli-mcp-server OK" 'OK'
        } catch {
            Write-Log "Error en win-cli-mcp-server: $_" 'WARN'
        } finally { Pop-Location }
    } else {
        Write-Log "win-cli-mcp-server no encontrado en $dest — omitido" 'WARN'
    }

    # 1b. windows-admin-mcp (Python)
    $dest = "$mcpRoot\windows-admin-mcp"
    if (Test-Path "$dest\.git") {
        Write-Log "windows-admin-mcp: actualizando..."
        Push-Location $dest
        try {
            git pull --quiet
            $py = Find-PythonExe
            if ($py) {
                & $py -m pip install -r requirements.txt --upgrade --quiet
                Write-Log "windows-admin-mcp OK" 'OK'
            } else {
                Write-Log "Python no encontrado — dependencias no actualizadas" 'WARN'
            }
        } catch {
            Write-Log "Error en windows-admin-mcp: $_" 'WARN'
        } finally { Pop-Location }
    } else {
        Write-Log "windows-admin-mcp no encontrado en $dest — omitido" 'WARN'
    }

    # 1c. vmware-vsphere-mcp-server (Python)
    $dest = "$mcpRoot\vmware-vsphere-mcp-server"
    if (Test-Path "$dest\.git") {
        Write-Log "vmware-vsphere-mcp-server: actualizando..."
        Push-Location $dest
        try {
            git pull --quiet
            $py = Find-PythonExe
            if ($py -and (Test-Path "requirements.txt")) {
                & $py -m pip install -r requirements.txt --upgrade --quiet
                Write-Log "vmware-vsphere-mcp-server OK" 'OK'
            } else {
                Write-Log "Python no encontrado o sin requirements.txt — dependencias no actualizadas" 'WARN'
            }
        } catch {
            Write-Log "Error en vmware-vsphere-mcp-server: $_" 'WARN'
        } finally { Pop-Location }
    } else {
        Write-Log "vmware-vsphere-mcp-server no encontrado en $dest — omitido" 'WARN'
    }

    # 1d. Azure MCP (npm global)
    Write-Log "Azure MCP (@azure/mcp): actualizando..."
    try {
        npm install -g @azure/mcp@latest --quiet 2>&1 | Out-Null
        Write-Log "Azure MCP OK" 'OK'
    } catch {
        Write-Log "Error actualizando @azure/mcp: $_" 'WARN'
    }

} else {
    Write-Log "Fase omitida (-ConfigOnly)" 'WARN'
}

# ============================================================
# FASE 2 — Actualizar mcp-config.json
# ============================================================
Write-Host "`n--- Fase 2: Actualizar mcp-config.json ---" -ForegroundColor Magenta

# Backup del config actual
$backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $configPath $backupPath
Write-Log "Backup guardado: $backupPath" 'OK'

# Preservar credenciales existentes
$current = Get-Content $configPath -Raw | ConvertFrom-Json
$azureCreds  = $null; $hasAzureCreds  = $false
$vmwareCreds = $null; $hasVmwareCreds = $false

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

# Cargar template del repo y resolver placeholders
$template = Get-Content $repoConfig -Raw
$template  = $template.Replace('%USERNAME%', $resolvedUser)
Write-Log "Placeholder %%USERNAME%% resuelto como: $resolvedUser" 'OK'
$newConfig = $template | ConvertFrom-Json

# Restaurar credenciales
if ($azureCreds -and $hasAzureCreds) {
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_SUBSCRIPTION_ID = $azureCreds.AZURE_SUBSCRIPTION_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_TENANT_ID       = $azureCreds.AZURE_TENANT_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_CLIENT_ID       = $azureCreds.AZURE_CLIENT_ID
    $newConfig.mcpServers.'azure-mcp'.env.AZURE_CLIENT_SECRET   = $azureCreds.AZURE_CLIENT_SECRET
    Write-Log "Credenciales Azure restauradas" 'OK'
}

if ($vmwareCreds -and $hasVmwareCreds) {
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_HOST     = $vmwareCreds.VCENTER_HOST
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_USER     = $vmwareCreds.VCENTER_USER
    $newConfig.mcpServers.'vmware-vsphere-mcp'.env.VCENTER_PASSWORD = $vmwareCreds.VCENTER_PASSWORD
    Write-Log "Credenciales VMware restauradas" 'OK'
}

# Escribir ruta real de Python (detectada en el sistema)
$pythonExe = Find-PythonExe
if ($pythonExe) {
    $newConfig.mcpServers.'windows-admin-mcp'.command  = $pythonExe
    $newConfig.mcpServers.'vmware-vsphere-mcp'.command = $pythonExe
    Write-Log "Python detectado y escrito en config: $pythonExe" 'OK'
} else {
    Write-Log "Python no encontrado. Instala Miniconda3 o Python 3.11+ y vuelve a ejecutar." 'WARN'
}

# Actualizar ruta del proxy de PowerShell.MCP
if ($proxyPath -and (Test-Path $proxyPath)) {
    $newConfig.mcpServers.'powershell-mcp'.command = $proxyPath
    Write-Log "powershell-mcp proxy actualizado: $proxyPath" 'OK'
}

# Escribir config actualizado
$newConfig | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
Write-Log "mcp-config.json actualizado: $configPath" 'OK'

# ============================================================
# FASE 3 — Verificacion final
# ============================================================
Write-Host "`n--- Fase 3: Verificacion ---" -ForegroundColor Magenta

$final = Get-Content $configPath -Raw | ConvertFrom-Json
$final.mcpServers.PSObject.Properties | ForEach-Object {
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
Write-Log "Actualizacion completada." 'OK'

if (-not $pythonExe) {
    Write-Log "PENDIENTE: Instala Python/Miniconda3 y vuelve a ejecutar para activar windows-admin-mcp y vmware-vsphere-mcp" 'WARN'
    Write-Host "  winget install --id Anaconda.Miniconda3 --silent --accept-source-agreements --accept-package-agreements"
}

Write-Log "Para revertir: Copy-Item '$backupPath' '$configPath' -Force" 'INFO'
Write-Host ""
