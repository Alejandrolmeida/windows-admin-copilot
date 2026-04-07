# Comandos de referencia: Microsoft Dynamics AX / Axapta Legacy

## Gestión del AOS (Application Object Server)

```powershell
# Ver servicios AOS instalados
Get-Service "AOS*" | Select-Object Name, Status, DisplayName

# Iniciar / Detener / Reiniciar AOS
Start-Service   "AOS60`$01"
Stop-Service    "AOS60`$01" -Force
Restart-Service "AOS60`$01" -Force

# Ver estado detallado
Get-Service "AOS60`$01" | Format-List *

# Nombres comunes por versión:
# AX 2012:  AOS60$01  (o AOS60$<NombreInstancia>)
# AX 2009:  AOS50$01
# AX 4.0:   AOS40$01
# Axapta 3: AOS30$01
```

## Archivos de configuración AOS

```powershell
# Localizar fichero de configuración del servidor
$aosPath = "C:\Program Files\Microsoft Dynamics AX\60\Server"
Get-ChildItem $aosPath -Recurse -Filter "*.axc" | Select-Object FullName

# Ver configuración activa (ax.ini del servidor)
Get-Content "$aosPath\MicrosoftDynamicsAX\bin\ax.ini"

# Cambiar parámetro en ax.ini (ejemplo: puerto TCP del AOS)
# Puerto por defecto AX 2012: 2712
(Get-Content "$aosPath\MicrosoftDynamicsAX\bin\ax.ini") -replace "tcp=.*", "tcp=2712" |
    Set-Content "$aosPath\MicrosoftDynamicsAX\bin\ax.ini"
```

## Base de datos AX en SQL Server

```powershell
# Verificar que la base de datos AX responde
Invoke-Sqlcmd -Query "SELECT TOP 1 RECID FROM USERINFO" `
    -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX"

# Ver usuarios activos en AX (tabla SYSSESSIONS)
Invoke-Sqlcmd -Query @"
SELECT s.USERID, s.STATUS, s.CLIENTCOMPUTER, s.LOGINDATE, s.LOGINTIME
FROM SYSSESSIONS s
WHERE s.STATUS = 1
ORDER BY s.LOGINDATE DESC
"@ -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX"

# Ver conexiones activas al AOS desde SQL
Invoke-Sqlcmd -Query @"
SELECT session_id, login_name, host_name, program_name, status,
       cpu_time, memory_usage, total_elapsed_time/1000 AS elapsed_sec
FROM sys.dm_exec_sessions
WHERE program_name LIKE '%Dynamics AX%' OR program_name LIKE '%AOS%'
ORDER BY total_elapsed_time DESC
"@ -ServerInstance "SERVIDOR\AXAPTA"

# Backup base de datos AX
Backup-SqlDatabase -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX" `
    -BackupFile "D:\Backups\AX_$(Get-Date -Format 'yyyyMMdd_HHmm').bak"

# Rebuild de índices (mantenimiento semanal recomendado)
Invoke-Sqlcmd -Query @"
EXEC sp_MSforeachtable 'ALTER INDEX ALL ON ? REBUILD WITH (ONLINE=OFF)'
"@ -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX" -QueryTimeout 3600
```

## Batch jobs y servicios de fondo

```powershell
# Ver batch jobs activos en SQL
Invoke-Sqlcmd -Query @"
SELECT CAPTION, STATUS, SERVERID, STARTDATETIME, ENDDATETIME
FROM BATCHJOB
WHERE STATUS IN (1, 2)  -- Waiting=1, Executing=2
ORDER BY STARTDATETIME DESC
"@ -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX"

# Ver batch threads bloqueados
Invoke-Sqlcmd -Query @"
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time/1000 AS wait_sec,
       t.text AS sql_text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id > 0
"@ -ServerInstance "SERVIDOR\AXAPTA"
```

## Logs y diagnóstico AX

```powershell
# Logs del AOS (ficheros)
$logPath = "C:\Program Files\Microsoft Dynamics AX\60\Server\MicrosoftDynamicsAX\Log"
Get-ChildItem $logPath -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
Get-Content (Get-ChildItem $logPath -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 100

# Event Log AX
Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    ProviderName = 'Microsoft Dynamics AX*'
    Level     = 1,2
    StartTime = (Get-Date).AddHours(-4)
} -EA SilentlyContinue | Select-Object TimeCreated, Message | Format-List

# Verificar que el AOS responde en red
Test-NetConnection -ComputerName "SERVIDOR" -Port 2712  # AX 2012
Test-NetConnection -ComputerName "SERVIDOR" -Port 2712  # AX 2009 usa mismo puerto por defecto
```

## Puertos de red AX

| Puerto | Servicio |
|--------|---------|
| 2712   | AOS TCP (clientes AX) |
| 8101   | AOS .NET Business Connector |
| 80/443 | Enterprise Portal (IIS) |
| 1433   | SQL Server |

## Procedimiento de reinicio limpio (producción)

```powershell
# 1. Notificar usuarios conectados (ver arriba cómo obtenerlos)
# 2. Esperar o forzar cierre de sesiones en SQL
Invoke-Sqlcmd -Query "UPDATE SYSSESSIONS SET STATUS=0 WHERE STATUS=1" `
    -ServerInstance "SERVIDOR\AXAPTA" -Database "MicrosoftDynamicsAX"

# 3. Detener Batch Service primero (si existe separado)
Stop-Service "DynamicsAXBatch" -EA SilentlyContinue -Force

# 4. Detener AOS
Stop-Service "AOS60`$01" -Force

# 5. Limpiar caché AOS (opcional, para problemas de memoria)
Remove-Item "C:\Program Files\Microsoft Dynamics AX\60\Server\MicrosoftDynamicsAX\bin\XppIL\*" `
    -Recurse -Force -EA SilentlyContinue

# 6. Iniciar AOS
Start-Service "AOS60`$01"

# 7. Verificar arranque correcto (esperar 30s)
Start-Sleep 30
Get-Service "AOS60`$01"
Test-NetConnection -ComputerName "localhost" -Port 2712
```
