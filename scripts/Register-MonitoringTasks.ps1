# ============================================================
# Register-MonitoringTasks.ps1
# Crea Scheduled Tasks de monitorización SQL directamente en
# los servidores remotos via WinRM/Azure Relay.
#
# Las tareas se ejecutan en los PROPIOS SERVIDORES (produccion 24/7),
# por lo que no dependen del equipo del administrador.
#
# Requiere:
#   - Tarea 'RelayAdminServer' corriendo (tunel activo)
#   - .config/credentials.json  (gitignored — contiene passwords)
#   - .config/server-registry.json (gitignored — contiene IPs y puertos)
#
# Uso:
#   .\Register-MonitoringTasks.ps1
#   .\Register-MonitoringTasks.ps1 -Cycle2Time "19:00" -WeekendTime "22:00"
#   .\Register-MonitoringTasks.ps1 -WhatIf
# ============================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath     = (Join-Path (Split-Path $PSScriptRoot -Parent) '.config'),
    [string]$Cycle2Time     = '18:35',   # Hora en el servidor remoto (HH:mm)
    [string]$WeekendTime    = '22:00',   # Hora del viernes en el servidor remoto
    [int]   $Cycle2Duration = 2880,      # 48 horas en minutos
    [int]   $WeekendDuration= 2880,      # 48 horas en minutos
    [int]   $Interval       = 120,       # Segundos entre muestras
    [string]$MonitorScript  = 'C:\SQLBenchmark\offline-benchmark\scripts\Monitor-SQLWorkload.ps1',
    [string]$OutputBase     = 'C:\SQLBenchmark\offline-benchmark',
    [switch]$SkipWeekend             # Saltar la task de fin de semana
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
# 0. Leer configuracion (desde archivos gitignored)
# -------------------------------------------------------
$credFile     = Join-Path $ConfigPath 'credentials.json'
$registryFile = Join-Path $ConfigPath 'server-registry.json'

foreach ($f in @($credFile, $registryFile)) {
    if (-not (Test-Path $f)) {
        Write-Log "Fichero no encontrado: $f" 'ERROR'
        Write-Log "Ejecuta primero New-RelayNamespace.ps1 y Add-RelayClient.ps1 para inicializar la configuracion." 'WARN'
        exit 1
    }
}

$credentials = Get-Content $credFile     -Raw | ConvertFrom-Json
$registry    = Get-Content $registryFile -Raw | ConvertFrom-Json

Write-Log "Configuracion cargada. Namespace: $($registry.namespace)" 'OK'

# -------------------------------------------------------
# 1. Calcular fechas de los triggers
# -------------------------------------------------------
$now         = Get-Date
$cycle2At    = $now.Date.Add([TimeSpan]::Parse($Cycle2Time))
if ($cycle2At -le $now) { $cycle2At = $cycle2At.AddDays(1) }  # Si ya paso hoy, usar manana

# Calcular proximo viernes
$daysToFriday = ([int][DayOfWeek]::Friday - [int]$now.DayOfWeek + 7) % 7
if ($daysToFriday -eq 0) { $daysToFriday = 7 }
$weekendAt    = $now.Date.AddDays($daysToFriday).Add([TimeSpan]::Parse($WeekendTime))

Write-Log "Trigger Ciclo 2 : $($cycle2At.ToString('yyyy-MM-dd HH:mm'))"
Write-Log "Trigger Weekend : $($weekendAt.ToString('yyyy-MM-dd HH:mm')) (proximo viernes)"

# -------------------------------------------------------
# 2. Iterar sobre servidores y crear tasks
# -------------------------------------------------------
$results = @()

foreach ($server in $credentials.servers) {
    $serverName = $server.name
    Write-Log "=== Procesando servidor: $serverName ===" 'INFO'

    # Construir credencial WinRM
    $secPwd  = ConvertTo-SecureString $server.auth.password -AsPlainText -Force
    $cred    = New-Object PSCredential($server.auth.username, $secPwd)
    $sOpts   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

    # Parametros de conexion
    # Usar connectionHostname si existe (necesario para WinRM HTTP.sys host matching)
    $connectHost = if ($server.connectionHostname) { $server.connectionHostname } else { $server.localAddress }
    $connParams = @{
        ComputerName   = $connectHost
        Port           = $server.localPort
        Authentication = 'Basic'
        Credential     = $cred
        SessionOption  = $sOpts
        ErrorAction    = 'Stop'
    }

    # Verificar conectividad antes de abrir sesion (siempre contra localAddress:localPort)
    $tcpOk = Test-NetConnection -ComputerName $server.localAddress -Port $server.localPort `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $tcpOk) {
        Write-Log "Puerto $($server.localAddress):$($server.localPort) no responde. Comprueba el tunel Azure Relay." 'ERROR'
        $results += [PSCustomObject]@{ Server=$serverName; Task='ALL'; Status='SKIPPED - tunel caido' }
        continue
    }
    Write-Log "Tunel activo: $($server.localAddress):$($server.localPort)" 'OK'

    try {
        $session = New-PSSession @connParams
        Write-Log "Sesion WinRM abierta en $serverName" 'OK'

        # ---------------------------------------------------
        # Tarea Ciclo 2 (ambos servidores)
        # ---------------------------------------------------
        $outputCycle2 = "$OutputBase\sql_workload_monitor_cycle2.json"
        $argCycle2    = "-NonInteractive -File `"$MonitorScript`" -Duration $Cycle2Duration -Interval $Interval -OutputFile `"$outputCycle2`""

        if ($PSCmdlet.ShouldProcess("$serverName", "Crear tarea SQLMonitor-Cycle2 a las $($cycle2At.ToString('HH:mm'))")) {
            $taskResult = Invoke-Command -Session $session -ScriptBlock {
                param($taskName, $exePath, $taskArgs, $triggerAt, $execLimitH, $outputDir)

                # Asegurarse de que el directorio de salida existe
                if (-not (Test-Path $outputDir)) {
                    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                }

                $action   = New-ScheduledTaskAction -Execute $exePath -Argument $taskArgs
                $trigger  = New-ScheduledTaskTrigger -Once -At $triggerAt
                $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Hours $execLimitH) `
                    -StartWhenAvailable `
                    -MultipleInstances IgnoreNew

                # Registrar como SYSTEM para no necesitar password en la task
                Register-ScheduledTask `
                    -TaskName  $taskName `
                    -Action    $action `
                    -Trigger   $trigger `
                    -Settings  $settings `
                    -RunLevel  Highest `
                    -User      'SYSTEM' `
                    -Force | Out-Null

                $t = Get-ScheduledTask -TaskName $taskName
                [PSCustomObject]@{
                    TaskName = $t.TaskName
                    State    = $t.State
                    NextRun  = (Get-ScheduledTaskInfo -TaskName $taskName).NextRunTime
                }
            } -ArgumentList 'SQLMonitor-Cycle2', 'pwsh.exe', $argCycle2, $cycle2At, 52, $OutputBase

            Write-Log "Task 'SQLMonitor-Cycle2' creada en $serverName — Proximo run: $($taskResult.NextRun)" 'OK'
            $results += [PSCustomObject]@{
                Server  = $serverName
                Task    = 'SQLMonitor-Cycle2'
                Status  = "OK — $($taskResult.State)"
                NextRun = $taskResult.NextRun
            }
        }

        # ---------------------------------------------------
        # Tarea Weekend (solo srvplenoilfs — ProcesarCubosdomingo)
        # ---------------------------------------------------
        if (-not $SkipWeekend -and $serverName -eq 'srvplenoilfs') {
            $outputWeekend = "$OutputBase\sql_workload_monitor_weekend.json"
            $argWeekend    = "-NonInteractive -File `"$MonitorScript`" -Duration $WeekendDuration -Interval $Interval -OutputFile `"$outputWeekend`""

            if ($PSCmdlet.ShouldProcess("$serverName", "Crear tarea SQLMonitor-Weekend el $($weekendAt.ToString('yyyy-MM-dd HH:mm'))")) {
                $taskResultWe = Invoke-Command -Session $session -ScriptBlock {
                    param($taskName, $exePath, $taskArgs, $triggerAt, $execLimitH, $outputDir)

                    if (-not (Test-Path $outputDir)) {
                        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                    }

                    $action   = New-ScheduledTaskAction -Execute $exePath -Argument $taskArgs
                    $trigger  = New-ScheduledTaskTrigger -Once -At $triggerAt
                    $settings = New-ScheduledTaskSettingsSet `
                        -ExecutionTimeLimit (New-TimeSpan -Hours $execLimitH) `
                        -StartWhenAvailable `
                        -MultipleInstances IgnoreNew

                    Register-ScheduledTask `
                        -TaskName  $taskName `
                        -Action    $action `
                        -Trigger   $trigger `
                        -Settings  $settings `
                        -RunLevel  Highest `
                        -User      'SYSTEM' `
                        -Force | Out-Null

                    $t = Get-ScheduledTask -TaskName $taskName
                    [PSCustomObject]@{
                        TaskName = $t.TaskName
                        State    = $t.State
                        NextRun  = (Get-ScheduledTaskInfo -TaskName $taskName).NextRunTime
                    }
                } -ArgumentList 'SQLMonitor-Weekend', 'pwsh.exe', $argWeekend, $weekendAt, 52, $OutputBase

                Write-Log "Task 'SQLMonitor-Weekend' creada en $serverName — Proximo run: $($taskResultWe.NextRun)" 'OK'
                $results += [PSCustomObject]@{
                    Server  = $serverName
                    Task    = 'SQLMonitor-Weekend'
                    Status  = "OK — $($taskResultWe.State)"
                    NextRun = $taskResultWe.NextRun
                }
            }
        }

        Remove-PSSession $session
        Write-Log "Sesion cerrada: $serverName" 'OK'

    } catch {
        Write-Log "Error en $serverName : $_" 'ERROR'
        $results += [PSCustomObject]@{ Server=$serverName; Task='ALL'; Status="ERROR: $_"; NextRun=$null }
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

# -------------------------------------------------------
# 3. Resumen final
# -------------------------------------------------------
Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   Resumen — Scheduled Tasks registradas" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Status -like 'ERROR*' -or $_.Status -like 'SKIPPED*' })
if ($failed.Count -gt 0) {
    Write-Log "$($failed.Count) error(es) — revisa los mensajes anteriores." 'WARN'
} else {
    Write-Log "Todas las tasks registradas correctamente. El portátil puede apagarse." 'OK'
    Write-Host ""
    Write-Host "  IMPORTANTE: Las tasks corren en los servidores remotos (SYSTEM)." -ForegroundColor Green
    Write-Host "  Verificar con:" -ForegroundColor DarkGray
    Write-Host "  .\scripts\Collect-MonitoringData.ps1 -ListTasks" -ForegroundColor Cyan
}
