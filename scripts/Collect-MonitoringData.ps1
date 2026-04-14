# ============================================================
# Collect-MonitoringData.ps1
# Descarga los archivos JSON de monitorización SQL desde los
# servidores remotos via WinRM/Azure Relay y los guarda en
# docs/data/ (gitignored) para su análisis local.
#
# Requiere:
#   - Tarea 'RelayAdminServer' corriendo (tunel activo)
#   - .config/credentials.json  (gitignored)
#   - .config/server-registry.json (gitignored)
#
# Uso:
#   .\scripts\Collect-MonitoringData.ps1               # Descargar datos activos (checkpoint)
#   .\scripts\Collect-MonitoringData.ps1 -Cycle cycle2 # Descargar output final del ciclo 2
#   .\scripts\Collect-MonitoringData.ps1 -ListTasks    # Ver tareas programadas en servidores
# ============================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.config'),
    [string]$OutputDir  = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\data'),
    [ValidateSet('checkpoint', 'cycle1', 'cycle2', 'weekend')]
    [string]$Cycle      = 'checkpoint',
    [switch]$ListTasks             # Solo listar tareas programadas, no descargar datos
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

# Mapa de ciclo a nombre de archivo en el servidor
$cycleFileMap = @{
    'checkpoint' = $null                                    # Buscara el checkpoint activo
    'cycle1'     = 'sql_workload_monitor.json'             # Output sin -OutputFile (ciclo original)
    'cycle2'     = 'sql_workload_monitor_cycle2.json'
    'weekend'    = 'sql_workload_monitor_weekend.json'
}

# -------------------------------------------------------
# 0. Leer configuracion
# -------------------------------------------------------
$credFile = Join-Path $ConfigPath 'credentials.json'
if (-not (Test-Path $credFile)) {
    Write-Log "credentials.json no encontrado en '$ConfigPath'." 'ERROR'
    exit 1
}
$credentials = Get-Content $credFile -Raw | ConvertFrom-Json
$remoteBase  = 'C:\SQLBenchmark\offline-benchmark'

# Crear directorio de salida local si no existe
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Log "Directorio creado: $OutputDir" 'OK'
}

# -------------------------------------------------------
# 1. Procesar cada servidor
# -------------------------------------------------------
$summary = @()

foreach ($server in $credentials.servers) {
    $serverName = $server.name
    Write-Log "=== Servidor: $serverName ($($server.localAddress):$($server.localPort)) ===" 'INFO'

    # Verificar tunel
    $tcpOk = Test-NetConnection -ComputerName $server.localAddress -Port $server.localPort `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $tcpOk) {
        Write-Log "Tunel caido para $serverName. Saltando." 'ERROR'
        $summary += [PSCustomObject]@{ Server=$serverName; Status='SKIPPED - tunel caido'; File='—' }
        continue
    }

    $secPwd = ConvertTo-SecureString $server.auth.password -AsPlainText -Force
    $cred   = New-Object PSCredential($server.auth.username, $secPwd)
    $sOpts  = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
    $connectHost = if ($server.connectionHostname) { $server.connectionHostname } else { $server.localAddress }

    try {
        $session = New-PSSession -ComputerName $connectHost -Port $server.localPort `
            -Authentication Basic -Credential $cred -SessionOption $sOpts

        if ($ListTasks) {
            # Modo: listar tareas de monitorización en el servidor remoto
            $tasks = Invoke-Command -Session $session -ScriptBlock {
                @('SQLMonitor-Cycle2', 'SQLMonitor-Weekend') | ForEach-Object {
                    $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
                    if ($t) {
                        $info = Get-ScheduledTaskInfo -TaskName $_ -ErrorAction SilentlyContinue
                        [PSCustomObject]@{
                            TaskName    = $t.TaskName
                            State       = $t.State
                            LastRun     = $info.LastRunTime
                            NextRun     = $info.NextRunTime
                            LastResult  = $info.LastTaskResult
                        }
                    } else {
                        [PSCustomObject]@{ TaskName=$_; State='Not registered'; LastRun='—'; NextRun='—'; LastResult='—' }
                    }
                }
            }
            Write-Host ""
            Write-Host "  Tareas en $serverName :" -ForegroundColor White
            $tasks | Format-Table -AutoSize
            Remove-PSSession $session
            continue
        }

        # Modo: descargar datos
        $remoteFiles = Invoke-Command -Session $session -ScriptBlock {
            param($baseDir, $targetFile)

            # Si se especifica un archivo concreto, buscarlo
            if ($targetFile) {
                $path = Join-Path $baseDir $targetFile
                if (Test-Path $path) {
                    return @([PSCustomObject]@{
                        Name     = $targetFile
                        Path     = $path
                        SizeKB   = [math]::Round((Get-Item $path).Length / 1KB, 1)
                        Modified = (Get-Item $path).LastWriteTime
                    })
                } else {
                    return @()
                }
            }

            # Sin archivo especifico: buscar checkpoints activos
            Get-ChildItem -Path $baseDir -Filter '*checkpoint*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object Name, FullName, @{N='Path';E={$_.FullName}},
                    @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}},
                    @{N='Modified';E={$_.LastWriteTime}}
        } -ArgumentList $remoteBase, $cycleFileMap[$Cycle]

        if (-not $remoteFiles -or @($remoteFiles).Count -eq 0) {
            Write-Log "No se encontraron archivos JSON para ciclo='$Cycle' en $serverName" 'WARN'
            $summary += [PSCustomObject]@{ Server=$serverName; Status='NO DATA'; File='—' }
            Remove-PSSession $session
            continue
        }

        foreach ($rf in @($remoteFiles)) {
            Write-Log "Descargando: $($rf.Name) ($($rf.SizeKB) KB, mod: $($rf.Modified))" 'INFO'

            # Leer el JSON como texto
            $jsonContent = Invoke-Command -Session $session -ScriptBlock {
                param($path) Get-Content $path -Raw -Encoding UTF8
            } -ArgumentList $rf.Path

            # Guardar localmente con prefijo del servidor
            $localName = "${serverName}_$($rf.Name)"
            $localPath = Join-Path $OutputDir $localName
            $jsonContent | Set-Content -Path $localPath -Encoding UTF8

            Write-Log "Guardado: $localPath ($([math]::Round((Get-Item $localPath).Length/1KB,1)) KB)" 'OK'
            $summary += [PSCustomObject]@{
                Server = $serverName
                Status = 'OK'
                File   = $localPath
            }
        }

        Remove-PSSession $session

    } catch {
        Write-Log "Error en $serverName : $_" 'ERROR'
        $summary += [PSCustomObject]@{ Server=$serverName; Status="ERROR: $_"; File='—' }
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

# -------------------------------------------------------
# 2. Resumen
# -------------------------------------------------------
if (-not $ListTasks) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "   Resumen — Datos descargados" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
    $summary | Format-Table -AutoSize

    $ok = @($summary | Where-Object { $_.Status -eq 'OK' })
    if ($ok.Count -gt 0) {
        Write-Log "$($ok.Count) archivo(s) descargados en '$OutputDir'" 'OK'
        Write-Host ""
        Write-Host "  Siguiente paso — generar el informe Word:" -ForegroundColor White
        Write-Host "  python docs\gen_migration_report.py" -ForegroundColor Cyan
    }
}
