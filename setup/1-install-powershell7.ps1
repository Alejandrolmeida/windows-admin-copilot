# ============================================================
# 1-install-powershell7.ps1
# Instala PowerShell 7.x en Windows
# ============================================================
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "=== Instalando PowerShell 7 ===" -ForegroundColor Cyan

# Intentar via winget primero
if (Get-Command winget -EA SilentlyContinue) {
    winget install --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
} else {
    # Fallback: instalador oficial de Microsoft
    $url = "https://aka.ms/install-powershell.ps1"
    Invoke-Expression "& { $(Invoke-RestMethod $url) } -UseMSI -Quiet"
}

# Verificar instalacion
$pwsh = Get-Command pwsh -EA SilentlyContinue
if ($pwsh) {
    Write-Host "PowerShell $(&pwsh -NoProfile -Command '$PSVersionTable.PSVersion') instalado correctamente" -ForegroundColor Green
} else {
    Write-Warning "Reinicia la terminal y verifica con: pwsh --version"
}
