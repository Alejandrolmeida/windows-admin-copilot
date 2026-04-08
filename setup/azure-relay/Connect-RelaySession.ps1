# ============================================================
# Connect-RelaySession.ps1
# Abre una sesion WinRM remota a traves del tunel Azure Relay.
# Ejecutar en TU PC (el cliente).
#
# Requisitos:
#   - El agente azbridge debe estar corriendo en el equipo remoto
#     (instalado con Install-RelayAgent.ps1)
#   - Fichero YAML de cliente generado por New-RelayNamespace.ps1
#   - Acceso a internet saliente HTTPS (443)
#
# Uso:
#   .\Connect-RelaySession.ps1 -ConfigFile "client-srv01.yml" -Username "DOMINIO\usuario"
#   .\Connect-RelaySession.ps1 -ConfigFile "client-srv01.yml" -Username "admin" -LocalPort 15986
#   .\Connect-RelaySession.ps1 -ConfigFile "client-srv01.yml" -Username "admin" -Command "Get-Service"
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$Username,
    [int]   $LocalPort   = 15985,
    [string]$InstallPath = "$env:LOCALAPPDATA\azbridge",
    [string]$Version     = '0.16.1',
    [string]$Command,
    [switch]$NoSession
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $color
}

# -------------------------------------------------------
# 0. Verificar config file
# -------------------------------------------------------
if (-not (Test-Path $ConfigFile)) {
    Write-Log "Fichero de configuracion no encontrado: $ConfigFile" 'ERROR'
    exit 1
}
$ConfigFile = (Resolve-Path $ConfigFile).Path

# -------------------------------------------------------
# 1. Descargar azbridge si no existe (en AppData, sin admin)
# -------------------------------------------------------
$exePath = Join-Path $InstallPath 'azbridge.exe'

if (-not (Test-Path $exePath)) {
    Write-Log "azbridge no encontrado en $InstallPath. Descargando..."
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

    $arch   = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $zipUrl = "https://github.com/Azure/azure-relay-bridge/releases/download/v$Version/azbridge.$Version.win-$arch.zip"
    $zipPath = Join-Path $env:TEMP "azbridge-$Version.zip"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
    Remove-Item $zipPath -Force
    Write-Log "azbridge.exe listo en $InstallPath" 'OK'
} else {
    Write-Log "azbridge.exe encontrado en $InstallPath" 'OK'
}

# -------------------------------------------------------
# 2. Arrancar proxy local en background
# -------------------------------------------------------

# Parchear el config para asegurarnos de que usa el LocalPort correcto
$configContent = Get-Content $ConfigFile -Raw
if ($configContent -notmatch 'BindPort') {
    Write-Log "El fichero config no parece tener LocalForward. Verifica que sea un config de cliente." 'ERROR'
    exit 1
}

Write-Log "Arrancando proxy local en localhost:$LocalPort ..."
$proxyProcess = Start-Process -FilePath $exePath `
    -ArgumentList "-f `"$ConfigFile`"" `
    -PassThru -WindowStyle Hidden

Write-Log "Proxy PID: $($proxyProcess.Id)" 'OK'

# Dar tiempo a que el proxy establezca el tunel con Azure
$maxWait = 15
$connected = $false
for ($i = 0; $i -lt $maxWait; $i++) {
    Start-Sleep -Seconds 1
    $listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
    if ($listener) {
        $connected = $true
        break
    }
    Write-Host "." -NoNewline
}
Write-Host ""

if (-not $connected) {
    Write-Log "El proxy no abrio el puerto $LocalPort tras ${maxWait}s." 'ERROR'
    Write-Log "Verifica que el agente este corriendo en el equipo remoto (Install-RelayAgent.ps1)." 'WARN'
    Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Log "Tunel establecido en localhost:$LocalPort" 'OK'

# -------------------------------------------------------
# 3. Abrir sesion WinRM a traves del tunel
# -------------------------------------------------------
try {
    $cred = Get-Credential -UserName $Username -Message "Credenciales para el equipo remoto"

    if ($Command) {
        Write-Log "Ejecutando comando remoto: $Command"
        $result = Invoke-Command -ComputerName localhost -Port $LocalPort `
            -Credential $cred `
            -Authentication Basic `
            -UseSSL:$false `
            -ScriptBlock ([ScriptBlock]::Create($Command))
        $result
    } elseif (-not $NoSession) {
        Write-Log "Abriendo sesion interactiva remota (Enter-PSSession)..." 'OK'
        Write-Host "  Para salir escribe: exit`n" -ForegroundColor Yellow
        Enter-PSSession -ComputerName localhost -Port $LocalPort `
            -Credential $cred `
            -Authentication Basic
    }
} finally {
    # -------------------------------------------------------
    # 4. Limpiar proxy al salir
    # -------------------------------------------------------
    Write-Log "Cerrando proxy local (PID $($proxyProcess.Id))..."
    Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
    Write-Log "Tunel cerrado" 'OK'
}
