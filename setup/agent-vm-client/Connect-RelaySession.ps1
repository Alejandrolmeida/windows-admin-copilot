# ============================================================
# Connect-RelaySession.ps1
# Abre una sesion WinRM remota a traves del tunel Azure Relay.
# Ejecutar en el equipo SERVIDOR (admin machine).
#
# Lee el puerto del cliente desde server-registry.json
# (generado por New-RelayNamespace.ps1 + Add-RelayClient.ps1).
# El tunel lo mantiene la tarea RelayAdminServer (Install-RelayServer.ps1).
#
# Requisitos:
#   - Tarea 'RelayAdminServer' corriendo (Install-RelayServer.ps1)
#   - Cliente registrado con Add-RelayClient.ps1 + Register-RelayClient.ps1
#
# Uso:
#   .\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "DOMINIO\admin"
#   .\Connect-RelaySession.ps1 -MachineName "srv-contab" -Username "admin" -Command "Get-Service"
#   .\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "admin" -LocalPort 15987
#   .\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "prod3" -AuthMethod Basic     # cuenta local
#   .\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "DOMINIO\admin" -AuthMethod Negotiate
# Si AuthMethod="Auto" (defecto): Negotiate para DOMINIO\user o user@dominio, Basic para cuentas locales.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MachineName,
    [Parameter(Mandatory)][string]$Username,
    [int]   $LocalPort      = 0,
    [string]$ConfigPath     = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.config'),
    [string]$RegistryFile   = '',
    [string]$ServerTaskName = 'RelayAdminServer',
    [string]$Command,
    [string]$Password,
    [ValidateSet('Auto','Basic','Negotiate')][string]$AuthMethod = 'Auto',
    [switch]$NoSession
)

$ErrorActionPreference = 'Stop'

if (-not $RegistryFile) { $RegistryFile = Join-Path $ConfigPath 'server-registry.json' }
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
# 0. Verificar tarea RelayAdminServer
# -------------------------------------------------------
$task = Get-ScheduledTask -TaskName $ServerTaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Log "Tarea '$ServerTaskName' no encontrada. Instala el servidor con: .\Install-RelayServer.ps1" 'ERROR'
    exit 1
}
if ($task.State -ne 'Running') {
    Write-Log "Tarea '$ServerTaskName' no esta corriendo (estado: $($task.State)). Arrancando..." 'WARN'
    Start-ScheduledTask -TaskName $ServerTaskName
    Start-Sleep -Seconds 5
    $task = Get-ScheduledTask -TaskName $ServerTaskName
    if ($task.State -ne 'Running') {
        Write-Log "No se pudo arrancar '$ServerTaskName'." 'ERROR'
        exit 1
    }
}
Write-Log "Servidor Relay activo: $ServerTaskName" 'OK'

# -------------------------------------------------------
# 1. Obtener puerto del cliente desde server-registry.json
# -------------------------------------------------------
$machineLower = $MachineName.ToLower()

if ($LocalPort -eq 0) {
    if (-not (Test-Path $RegistryFile)) {
        Write-Log "server-registry.json no encontrado en '$RegistryFile'." 'ERROR'
        Write-Log "Usa -LocalPort <puerto> para especificarlo manualmente, o ejecuta New-RelayNamespace.ps1 primero." 'WARN'
        exit 1
    }
    $registry = Get-Content $RegistryFile -Raw | ConvertFrom-Json
    $client   = $registry.clients | Where-Object { $_.name -eq $machineLower }
    if (-not $client) {
        Write-Log "Maquina '$machineLower' no encontrada en server-registry.json." 'ERROR'
        Write-Log "Clientes registrados: $(($registry.clients | ForEach-Object { $_.name }) -join ', ')" 'WARN'
        Write-Log "Registra la maquina con: .\Add-RelayClient.ps1 -MachineName '$machineLower'" 'WARN'
        exit 1
    }
    $LocalPort = $client.bindPort
    Write-Log "Puerto asignado para '$machineLower': $LocalPort" 'OK'
    $localAddress = $client.localAddress
} else {
    Write-Log "Usando puerto manual: $LocalPort" 'WARN'
    $localAddress = ''
}

# Asegurar que el hostname del cliente esta en el archivo hosts
if ($localAddress) {
    $hostsFile    = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($hostsContent -notmatch [regex]::Escape($machineLower)) {
        Add-Content -Path $hostsFile -Value "`n$localAddress`t$machineLower" -Encoding ASCII
        Write-Log "Hosts: añadida entrada '$localAddress $machineLower'" 'OK'
    }
}

# -------------------------------------------------------
# 2. Verificar que el puerto esta escuchando
# -------------------------------------------------------
Write-Log "Verificando puerto ${machineLower}:${LocalPort}..."
$maxWait   = 15
$connected = $false
$targetHost = if ($localAddress) { $machineLower } else { 'localhost' }
for ($i = 0; $i -lt $maxWait; $i++) {
    try {
        $tcpTest = Test-NetConnection -ComputerName $targetHost -Port $LocalPort -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($tcpTest) { $connected = $true; break }
    } catch {}
    if ($i -eq 0) { Write-Host "Esperando tunel" -NoNewline }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""

if (-not $connected) {
    Write-Log "El puerto $LocalPort no esta escuchando en $targetHost." 'ERROR'
    Write-Log "Comprueba que el cliente '$machineLower' tiene Register-RelayClient.ps1 instalado y corriendo." 'WARN'
    Write-Log "Estado de todos los clientes: .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>" 'WARN'
    exit 1
}
Write-Log "Tunel activo: ${targetHost}:${LocalPort} -> Azure Relay -> $machineLower" 'OK'

# -------------------------------------------------------
# 3. Abrir sesion WinRM a traves del tunel
# -------------------------------------------------------
try {
    if ($Password) {
        $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential($Username, $secPwd)
    } else {
        $cred = Get-Credential -UserName $Username -Message "Credenciales para el equipo '$machineLower'"
    }

    # Determinar método de autenticación (Auto detecta dominio por \ o @)
    $resolvedAuth = if ($AuthMethod -ne 'Auto') {
        $AuthMethod
    } elseif ($Username -match '\\' -or $Username -match '@') {
        'Negotiate'
    } else {
        'Basic'
    }
    Write-Log "Metodo de autenticacion: $resolvedAuth (usuario: $Username)" 'OK'
    $sessOpt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

    if ($Command) {
        Write-Log "Ejecutando comando remoto en '$machineLower': $Command"
        $result = Invoke-Command -ComputerName $targetHost -Port $LocalPort `
            -Credential $cred `
            -Authentication $resolvedAuth `
            -SessionOption $sessOpt `
            -UseSSL:$false `
            -ScriptBlock ([ScriptBlock]::Create($Command))
        $result
    } elseif (-not $NoSession) {
        Write-Log "Abriendo sesion interactiva en '$machineLower' (${targetHost}:${LocalPort})..." 'OK'
        Write-Host "  Para salir escribe: exit`n" -ForegroundColor Yellow
        Enter-PSSession -ComputerName $targetHost -Port $LocalPort `
            -Credential $cred `
            -Authentication $resolvedAuth `
            -SessionOption $sessOpt
    }
} finally {
    Write-Log "Sesion cerrada. El servidor Relay sigue corriendo en background." 'OK'
}
