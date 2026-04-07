# Comandos de referencia: Microsoft Dynamics NAV / Navision Legacy

## Gestión del servicio NST (NAV Service Tier)

```powershell
# Ver todas las instancias NAV instaladas
Get-NAVServerInstance

# Estado de una instancia
Get-NAVServerInstance -ServerInstance "DynamicsNAV"

# Iniciar / Detener / Reiniciar
Start-NAVServerInstance   -ServerInstance "DynamicsNAV"
Stop-NAVServerInstance    -ServerInstance "DynamicsNAV"
Restart-NAVServerInstance -ServerInstance "DynamicsNAV"

# Via servicios Windows (si no hay NAV Admin Shell)
Get-Service "MicrosoftDynamicsNavServer*"
Restart-Service "MicrosoftDynamicsNavServer`$DynamicsNAV" -Force
```

## Gestión de sesiones y usuarios

```powershell
# Ver sesiones activas
Get-NAVServerSession -ServerInstance "DynamicsNAV"

# Cerrar sesión específica
Remove-NAVServerSession -ServerInstance "DynamicsNAV" -SessionId 12

# Cerrar todas las sesiones (para mantenimiento)
Get-NAVServerSession -ServerInstance "DynamicsNAV" | Remove-NAVServerSession

# Ver usuarios en la base de datos
Invoke-Sqlcmd -Query "SELECT [User Security ID], [User Name], [Full Name], State FROM [CRONUS].[dbo].[User]" `
    -ServerInstance "SERVIDOR\NAVISION"
```

## Configuración del NST

```powershell
# Ver configuración actual
Get-NAVServerConfiguration -ServerInstance "DynamicsNAV"

# Cambiar parámetro (ejemplo: puerto)
Set-NAVServerConfiguration -ServerInstance "DynamicsNAV" -KeyName "ClientServicesPort" -KeyValue "7046"

# Fichero de configuración manual
notepad "C:\Program Files\Microsoft Dynamics NAV\*\Service\CustomSettings.config"
```

## Base de datos NAV en SQL Server

```powershell
# Listar bases de datos NAV
Invoke-Sqlcmd -Query "SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb')" `
    -ServerInstance "SERVIDOR\NAVISION"

# Comprobar tamaño de tablas grandes
Invoke-Sqlcmd -Query @"
SELECT TOP 20 t.name AS Tabla,
    SUM(a.total_pages) * 8 / 1024 AS TotalMB
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units a ON p.partition_id = a.container_id
GROUP BY t.name
ORDER BY TotalMB DESC
"@ -ServerInstance "SERVIDOR\NAVISION" -Database "CRONUS"

# Backup de base de datos NAV
Backup-SqlDatabase -ServerInstance "SERVIDOR\NAVISION" -Database "CRONUS" `
    -BackupFile "D:\Backups\CRONUS_$(Get-Date -Format 'yyyyMMdd_HHmm').bak"
```

## Exportar/Importar objetos (NAV clásico / finsql.exe)

```batch
# Exportar todos los objetos a fichero .fob
finsql.exe command=exportobjects,file=C:\Backup\objetos.fob,database=CRONUS,servername=SERVIDOR\NAVISION,logfile=C:\Logs\export.log

# Importar objetos desde .fob
finsql.exe command=importobjects,file=C:\Update\nuevos_objetos.fob,database=CRONUS,servername=SERVIDOR\NAVISION,logfile=C:\Logs\import.log
```

## Licencias

```powershell
# Ver licencia activa
Get-NAVServerConfiguration -ServerInstance "DynamicsNAV" | Where-Object { $_.Key -eq "LicenseFile" }

# Importar nueva licencia
Import-NAVServerLicense -ServerInstance "DynamicsNAV" -LicenseFile "C:\Licencias\nueva_licencia.flf"
Restart-NAVServerInstance -ServerInstance "DynamicsNAV"
```

## Logs y diagnóstico

```powershell
# Ver errores recientes del NST en Event Log
Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    ProviderName = 'MicrosoftDynamicsNavServer'
    Level     = 1,2   # Critical, Error
    StartTime = (Get-Date).AddHours(-4)
} | Select-Object TimeCreated, Message | Format-List

# Logs del NST en fichero
$logPath = "C:\ProgramData\Microsoft\Microsoft Dynamics NAV"
Get-ChildItem $logPath -Recurse -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
Get-Content (Get-ChildItem $logPath -Recurse -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 50
```

## Puertos de red NAV

| Puerto | Servicio |
|--------|---------|
| 7045   | NST Client Services (NAV 2013+) |
| 7046   | NST Client Services (clásico) |
| 7047   | SOAP Web Services |
| 7048   | OData Web Services |
| 7049   | NAV Management Port |
| 1433   | SQL Server |

```powershell
# Verificar que los puertos NAV están escuchando
Test-NetConnection -ComputerName "SERVIDOR" -Port 7046
netstat -an | Select-String "7046|7047|7048"
```
