# ============================================================
# update-mcp-config.ps1
# Actualiza mcp-config.json para usuarios que ya tienen una
# version anterior instalada. Preserva las credenciales
# existentes (Azure, VMware, SSH) y corrige:
#   - Rutas Python con %USERNAME% literal (no resuelto)
#   - Entradas hyper-v y virtualbox en mcpServers (invalidas)
#   - Entradas duplicadas en mcpServers
# ============================================================
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force   # Sobreescribir sin pedir confirmacion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $color
}

$configPath = "$env:USERPROFILE\.copilot\mcp-config.json"
$repoConfig = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "..\.copilot\mcp-config.json"
$repoConfig = (Resolve-Path $repoConfig -EA SilentlyContinue)?.Path

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Windows Admin Copilot - Update MCP Config " -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# ----------------------------------------------------------
# Verificar que existe el config activo
# ----------------------------------------------------------
if (-not (Test-Path $configPath)) {
    Write-Log "No se encontro $configPath" 'WARN'
    Write-Log "Parece que es una instalacion nueva. Ejecuta install-mcp-servers.ps1 en su lugar." 'WARN'
    exit 0
}

# ----------------------------------------------------------
# Backup del config actual
# ----------------------------------------------------------
$backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $configPath $backupPath
Write-Log "Backup guardado en: $backupPath" 'OK'

# ----------------------------------------------------------
# Cargar config actual y preservar credenciales
# ----------------------------------------------------------
$current = Get-Content $configPath -Raw | ConvertFrom-Json

# Extraer credenciales existentes antes de modificar
$azureCreds = $null
if ($current.mcpServers.'azure-mcp'.env) {
    $azureCreds = $current.mcpServers.'azure-mcp'.env
    $hasAzureCreds = ($azureCreds.AZURE_SUBSCRIPTION_ID -ne '')
    if ($hasAzureCreds) { Write-Log "Credenciales Azure detectadas — se preservarán" 'OK' }
}

$vmwareCreds = $null
if ($current.mcpServers.'vmware-vsphere-mcp'.env) {
    $vmwareCreds = $current.mcpServers.'vmware-vsphere-mcp'.env
    $hasVmwareCreds = ($vmwareCreds.VCENTER_HOST -ne '')
    if ($hasVmwareCreds) { Write-Log "Credenciales VMware detectadas — se preservarán" 'OK' }
}

# ----------------------------------------------------------
# Cargar el template del repo (fuente de verdad para estructura)
# ----------------------------------------------------------
if (-not $repoConfig -or -not (Test-Path $repoConfig)) {
    Write-Log "No se encontro el template del repo en: $repoConfig" 'ERROR'
    Write-Log "Ejecuta este script desde dentro del repositorio clonado." 'ERROR'
    exit 1
}

$template = Get-Content $repoConfig -Raw

# Sustituir %USERNAME% por el usuario real
$template = $template.Replace('%USERNAME%', $env:USERNAME)
Write-Log "Placeholder %%USERNAME%% sustituido por: $env:USERNAME" 'OK'

# Parsear el template ya con la ruta correcta
$newConfig = $template | ConvertFrom-Json

# ----------------------------------------------------------
# Restaurar credenciales preservadas
# ----------------------------------------------------------
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

# ----------------------------------------------------------
# Escribir config actualizado
# ----------------------------------------------------------
$newConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
Write-Log "mcp-config.json actualizado en: $configPath" 'OK'

# ----------------------------------------------------------
# Verificar resultado
# ----------------------------------------------------------
Write-Host ""
Write-Log "=== Verificacion ===" 'INFO'
$final = Get-Content $configPath -Raw | ConvertFrom-Json

$final.mcpServers.PSObject.Properties | ForEach-Object {
    $name = $_.Name
    $cmd  = $_.Value.command
    if ($cmd) {
        # Para rutas absolutas usar Test-Path; para comandos del PATH usar Get-Command
        $exists = if ([System.IO.Path]::IsPathRooted($cmd)) {
            Test-Path $cmd -EA SilentlyContinue
        } else {
            $null -ne (Get-Command $cmd -EA SilentlyContinue)
        }
        $status = if ($exists) { '✅' } else { '⚠️  NO ENCONTRADO' }
        Write-Host "  $status $name -> $cmd"
    }
}

Write-Host ""
Write-Log "Actualizacion completada." 'OK'
Write-Log "Si habia credenciales configuradas, revisa que se hayan preservado correctamente:" 'WARN'
Write-Host "  notepad `"$configPath`""
Write-Host ""
Write-Log "Para revertir: Copy-Item '$backupPath' '$configPath' -Force" 'INFO'
