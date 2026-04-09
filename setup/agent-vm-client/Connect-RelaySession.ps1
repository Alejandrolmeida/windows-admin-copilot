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
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MachineName,
    [Parameter(Mandatory)][string]$Username,
    [int]   $LocalPort      = 0,
    [string]$RegistryFile   = '.\server-registry.json',
    [string]$ServerTaskName = 'RelayAdminServer',
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
} else {
    Write-Log "Usando puerto manual: $LocalPort" 'WARN'
}

# -------------------------------------------------------
# 2. Verificar que el puerto esta escuchando
# -------------------------------------------------------
Write-Log "Verificando puerto localhost:$LocalPort..."
$maxWait   = 15
$connected = $false
for ($i = 0; $i -lt $maxWait; $i++) {
    $listener = netstat -an 2>$null | Select-String "127.0.0.1:$LocalPort.*LISTEN"
    if ($listener) { $connected = $true; break }
    if ($i -eq 0) { Write-Host "Esperando tunel" -NoNewline }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""

if (-not $connected) {
    Write-Log "El puerto $LocalPort no esta escuchando." 'ERROR'
    Write-Log "Comprueba que el cliente '$machineLower' tiene Register-RelayClient.ps1 instalado y corriendo." 'WARN'
    Write-Log "Estado de todos los clientes: .\Get-VMStatus.ps1 -ResourceGroup <rg> -Namespace <ns>" 'WARN'
    exit 1
}
Write-Log "Tunel activo en localhost:$LocalPort -> $machineLower" 'OK'

# -------------------------------------------------------
# 3. Abrir sesion WinRM a traves del tunel
# -------------------------------------------------------
try {
    $cred = Get-Credential -UserName $Username -Message "Credenciales para el equipo '$machineLower'"

    if ($Command) {
        Write-Log "Ejecutando comando remoto en '$machineLower': $Command"
        $result = Invoke-Command -ComputerName localhost -Port $LocalPort `
            -Credential $cred `
            -Authentication Basic `
            -UseSSL:$false `
            -ScriptBlock ([ScriptBlock]::Create($Command))
        $result
    } elseif (-not $NoSession) {
        Write-Log "Abriendo sesion interactiva en '$machineLower'..." 'OK'
        Write-Host "  Para salir escribe: exit`n" -ForegroundColor Yellow
        Enter-PSSession -ComputerName localhost -Port $LocalPort `
            -Credential $cred `
            -Authentication Basic
    }
} finally {
    Write-Log "Sesion cerrada. El servidor Relay sigue corriendo en background." 'OK'
}
