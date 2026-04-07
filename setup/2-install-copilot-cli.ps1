# ============================================================
# 2-install-copilot-cli.ps1
# Instala GitHub Copilot CLI y sus dependencias
# ============================================================
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "=== Instalando dependencias para Copilot CLI ===" -ForegroundColor Cyan

# Node.js (requerido para servidores MCP npm)
if (-not (Get-Command node -EA SilentlyContinue)) {
    Write-Host "Instalando Node.js..." -ForegroundColor Yellow
    winget install --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements
}

# Git
if (-not (Get-Command git -EA SilentlyContinue)) {
    Write-Host "Instalando Git..." -ForegroundColor Yellow
    winget install --id Git.Git --silent --accept-source-agreements --accept-package-agreements
}

# Python (requerido para windows-admin-mcp)
if (-not (Get-Command python -EA SilentlyContinue)) {
    Write-Host "Instalando Python..." -ForegroundColor Yellow
    winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
}

# GitHub Copilot CLI
Write-Host "Instalando GitHub Copilot CLI..." -ForegroundColor Yellow
winget install --id GitHub.Copilot --silent --accept-source-agreements --accept-package-agreements

# Refrescar PATH
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

Write-Host "`n=== Verificacion ===" -ForegroundColor Cyan
Write-Host "Node.js:    $(node --version 2>&1)"
Write-Host "Git:        $(git --version 2>&1)"
Write-Host "Python:     $(python --version 2>&1)"
Write-Host "Copilot:    $(copilot --version 2>&1)"
Write-Host "`nEjecuta 'copilot' y usa /login para autenticarte con GitHub" -ForegroundColor Green
