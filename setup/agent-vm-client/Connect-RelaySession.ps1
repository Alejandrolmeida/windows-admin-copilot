# ============================================================
# Connect-RelaySession.ps1
# Abre una sesion WinRM remota a traves del tunel Agent-VM-Client.
# Ejecutar en TU PC (el cliente).
#
# Si el servicio AgentVMClient-<maquina> esta instalado y corriendo,
# lo usa directamente. Si no, arranca el proxy en modo temporal.
#
# Requisitos:
#   - El agente debe estar corriendo en el equipo remoto
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

# Auto-detectar nombre de maquina desde el nombre del fichero
$machineName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile) -replace '^client-', ''
$serviceName = "AgentVMClient-$machineName"

# -------------------------------------------------------
# 1. Comprobar si el servicio cliente esta corriendo
# -------------------------------------------------------
$proxyProcess  = $null
$serviceMode   = $false

$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Log "Servicio '$serviceName' activo. Usando conexion de servicio." 'OK'
    $serviceMode = $true
} elseif ($svc -and $svc.Status -ne 'Running') {
    Write-Log "Servicio '$serviceName' instalado pero detenido. Arrancar el servicio o instalar con Install-RelayClient.ps1." 'WARN'
    Write-Log "Intentando arrancar el servicio..."
    try {
        Start-Service -Name $serviceName
        Start-Sleep -Seconds 3
        $serviceMode = $true
        Write-Log "Servicio arrancado" 'OK'
    } catch {
        Write-Log "No se pudo arrancar el servicio. Usando proxy temporal." 'WARN'
    }
}

# -------------------------------------------------------
# 2. Si no hay servicio, descargar azbridge y arrancar proxy temporal
# -------------------------------------------------------
if (-not $serviceMode) {
    Write-Log "Servicio '$serviceName' no encontrado. Arrancando proxy temporal..."
    Write-Log "  (Para evitar esto, instala el servicio con Install-RelayClient.ps1)" 'WARN'

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

    $configContent = Get-Content $ConfigFile -Raw
    if ($configContent -notmatch 'BindPort') {
        Write-Log "El fichero config no parece tener LocalForward/BindPort. Verifica que sea un config de cliente." 'ERROR'
        exit 1
    }

    Write-Log "Arrancando proxy local en localhost:$LocalPort ..."
    $proxyProcess = Start-Process -FilePath $exePath `
        -ArgumentList "-f `"$ConfigFile`"" `
        -PassThru -WindowStyle Hidden

    Write-Log "Proxy PID: $($proxyProcess.Id)" 'OK'
}

# Dar tiempo a que el proxy establezca el tunel con Azure (solo en modo temporal)
$maxWait = 15
$connected = $false
if ($serviceMode) {
    # El servicio ya deberia tener el puerto abierto
    $listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
    $connected = [bool]$listener
    if (-not $connected) {
        Write-Log "El servicio esta corriendo pero el puerto $LocalPort no esta escuchando aun. Esperando..." 'WARN'
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 1
            $listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
            if ($listener) { $connected = $true; break }
            Write-Host "." -NoNewline
        }
        Write-Host ""
    }
} else {
    for ($i = 0; $i -lt $maxWait; $i++) {
        Start-Sleep -Seconds 1
        $listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
        if ($listener) { $connected = $true; break }
        Write-Host "." -NoNewline
    }
    Write-Host ""
}

if (-not $connected) {
    Write-Log "El proxy no abrio el puerto $LocalPort." 'ERROR'
    Write-Log "Verifica que el agente este corriendo en el equipo remoto (Install-RelayAgent.ps1)." 'WARN'
    Write-Log "Consulta estado de maquinas con: .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>" 'WARN'
    if ($proxyProcess) { Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue }
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
    # Solo cerrar el proxy si era temporal (no el servicio)
    if ($proxyProcess -and -not $proxyProcess.HasExited) {
        Write-Log "Cerrando proxy temporal (PID $($proxyProcess.Id))..."
        Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Log "Proxy temporal cerrado" 'OK'
    } elseif ($serviceMode) {
        Write-Log "Sesion cerrada. El servicio '$serviceName' sigue corriendo en background." 'OK'
    }
}
