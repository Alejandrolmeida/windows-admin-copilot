# ============================================================
# 3-setup-all.ps1
# Ejecuta toda la instalacion en orden
# ============================================================
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path $MyInvocation.MyCommand.Path

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Windows Admin Copilot - Setup Completo" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# 1. PowerShell 7
Write-Host "[1/3] PowerShell 7..." -ForegroundColor Yellow
& "$root\1-install-powershell7.ps1"

# Refrescar PATH entre pasos
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# 2. Copilot CLI y dependencias
Write-Host "`n[2/3] Copilot CLI y dependencias..." -ForegroundColor Yellow
& "$root\2-install-copilot-cli.ps1"

$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# 3. Servidores MCP (instala, actualiza y configura — preserva credenciales si ya existen)
Write-Host "`n[3/3] Servidores MCP..." -ForegroundColor Yellow
& "$root\..\mcp-servers\install-mcp-servers.ps1"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Setup completado. Proximos pasos:" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "1. El mcp-config.json ya fue copiado a $env:USERPROFILE\.copilot\ con tu usuario configurado"
Write-Host "2. Edita $env:USERPROFILE\.copilot\mcp-config.json con tus credenciales de servidores remotos"
Write-Host "3. Ejecuta 'copilot' y usa /login para autenticarte"
Write-Host "4. Usa /mcp para verificar los servidores MCP activos"
Write-Host ""
Write-Host "Para futuras actualizaciones, vuelve a ejecutar:"
Write-Host "  git pull && .\mcp-servers\install-mcp-servers.ps1" -ForegroundColor Cyan

