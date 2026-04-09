# Azure Relay - Administración Remota Windows

Solución de conectividad remota WinRM **sin abrir puertos entrantes** en los equipos gestionados. Utiliza **Azure Relay Hybrid Connections** como proxy inverso: los clientes abren una conexión saliente HTTPS (puerto 443) a Azure, y el servidor de administración se conecta a través del mismo relay.

## Arquitectura

```
SERVIDOR DE ADMINISTRACION             AZURE RELAY                EQUIPO CLIENTE (gestionado)
────────────────────────────           ────────────────           ───────────────────────────
RelayAdminServer                       Namespace (1 instancia)
azbridge -f server-relay.yml
  LocalForward:
    - RelayName: winrm-pc-juan  ──Send──► HC: winrm-pc-juan  ◄──Listen── RelayClient
      BindPort: 15985                                                      azbridge -f client-pc-juan.yml
    - RelayName: winrm-srv-contab ──Send─► HC: winrm-srv-contab             RemoteForward → WinRM:5985
      BindPort: 15986
         │
         ▼
  localhost:15985 / localhost:15986
         │
  Enter-PSSession ──────────────────────────────────────────────────────► WinRM (5985)
```

**Principios clave:**
- El servidor corre **UN SOLO proceso** azbridge con múltiples `LocalForward` (uno por cliente)
- Los clientes usan una SAS key individual con permiso `Listen` por Hybrid Connection
- El servidor usa una SAS key a nivel de **namespace** con permiso `Send` (alcanza todas las HCs)
- Añadir un cliente NO requiere reinstalar el servidor → solo reiniciar su tarea programada

## Scripts disponibles

### Servidor de administración (ejecutar en el equipo admin)

| Script | Descripción |
|--------|-------------|
| `New-RelayNamespace.ps1` | Crea/valida el namespace Azure Relay. Genera `server-relay.yml` + `server-registry.json`. **Una sola vez.** |
| `Install-RelayServer.ps1` | Instala azbridge como tarea `RelayAdminServer` (SYSTEM, inicio automático). **Una sola vez.** |
| `Add-RelayClient.ps1` | Registra un nuevo cliente: crea HC, genera `client-<nombre>.yml`, actualiza config del servidor. **Una vez por cliente.** |
| `Connect-RelaySession.ps1` | Abre sesión WinRM interactiva o ejecuta comandos en un cliente. |
| `Get-VMStatus.ps1` | Lista todos los clientes con estado conectado/desconectado. |
| `Remove-RelayServer.ps1` | Desinstala el servidor de administración (no toca Azure). |

### Equipo cliente (ejecutar en cada equipo gestionado)

| Script | Descripción |
|--------|-------------|
| `Register-RelayClient.ps1` | Instala azbridge como tarea `RelayClient` (SYSTEM, inicio automático). Recibe el YAML generado por `Add-RelayClient.ps1`. |
| `Remove-RelayClient.ps1` | Desinstala el agente del equipo cliente. |

## Flujo de instalación

### Paso 1 — Crear el namespace (una sola vez)

```powershell
# En el servidor de administración, con az login activo
.\New-RelayNamespace.ps1 `
    -ResourceGroup "rg-relay" `
    -Namespace     "relay-empresa" `
    -Location      "westeurope"
```

Genera en el directorio actual:
- `server-relay.yml` — config del servidor (SAS namespace-level + LocalForwards)
- `server-registry.json` — registro de clientes con metadatos de puertos

### Paso 2 — Instalar el servidor (una sola vez)

```powershell
# En el servidor de administración, como Administrador
.\Install-RelayServer.ps1 -ConfigFile "server-relay.yml"
```

Instala la tarea `RelayAdminServer` con inicio automático al arrancar Windows (SYSTEM).

### Paso 3 — Registrar cada cliente

```powershell
# En el servidor de administración (por cada nuevo equipo a gestionar)
.\Add-RelayClient.ps1 `
    -ResourceGroup "rg-relay" `
    -Namespace     "relay-empresa" `
    -MachineName   "pc-juan"
```

Esto:
1. Crea la Hybrid Connection `winrm-pc-juan` en Azure Relay
2. Genera `client-pc-juan.yml` con la SAS key Listen
3. Actualiza `server-relay.yml` con el nuevo `LocalForward` en puerto 15985 (o el siguiente disponible)
4. Reinicia la tarea `RelayAdminServer` si está instalada

### Paso 4 — Instalar el agente en el equipo cliente

```powershell
# Copia client-pc-juan.yml al equipo cliente (por USB, share, etc.)
# En el equipo cliente, como Administrador
.\Register-RelayClient.ps1 -ConfigFile "client-pc-juan.yml"
```

A partir de este momento, el equipo cliente se conecta a Azure Relay automáticamente al arrancar. No necesita ningún acceso entrante.

### Conectarse

```powershell
# Sesión interactiva
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "DOMINIO\admin"

# Ejecutar un comando remoto
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "admin" -Command "Get-Service"
```

### Ver estado de todos los clientes

```powershell
.\Get-VMStatus.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa"
```

Salida ejemplo:
```
========== ESTADO DE MAQUINAS REMOTAS ==========
  Namespace : relay-empresa
  Fecha     : 2026-06-01 09:30:00

Estado         Maquina      Listeners  HybridConn         Creado
------         -------      ---------  ----------         ------
[OK] Conectado pc-juan              1  winrm-pc-juan      2026-05-28 10:00
[OK] Conectado srv-contab           1  winrm-srv-contab   2026-05-29 14:00
[--] Desconect pc-maria             0  winrm-pc-maria     2026-05-30 09:00

  Resumen: 2 conectadas | 1 desconectadas | 3 total
```

## Archivos generados

| Archivo | Ubicación | Descripción |
|---------|-----------|-------------|
| `server-relay.yml` | Servidor | Config azbridge del servidor. Gestionado automáticamente. |
| `server-registry.json` | Servidor | Registro JSON de todos los clientes con nombre, HC, puerto asignado. |
| `client-<nombre>.yml` | Servidor (copiar a cliente) | Config azbridge del cliente individual. SAS Listen por HC. |

## Tareas programadas creadas

| Tarea | Equipo | Descripción |
|-------|--------|-------------|
| `RelayAdminServer` | Servidor de administración | Proceso azbridge con todos los LocalForwards. SYSTEM, inicio automático. |
| `RelayClient` | Cada equipo cliente | Proceso azbridge con RemoteForward → WinRM. SYSTEM, inicio automático. |

## Desinstalación

```powershell
# En el servidor de administración
.\Remove-RelayServer.ps1

# En el equipo cliente
.\Remove-RelayClient.ps1
```

## Costes Azure Relay

| Escenario | Coste/mes (estimado) |
|-----------|----------------------|
| 1 cliente, 24/7 | ~$10 |
| 5 clientes, 24/7 | ~$15 |
| 20 clientes, 8h/día laboral | ~$35 |

- Namespace: ~$0.10/hora
- Por Hybrid Connection activa: ~$0.013/hora
- El primer GB de datos al mes es gratuito

## Seguridad

| Elemento | Configuración |
|----------|--------------|
| SAS servidor | Permiso `Send` a nivel namespace (alcanza todas las HCs) |
| SAS cliente | Permiso `Listen` individual por Hybrid Connection |
| Transporte | TLS 1.2+ end-to-end a través de Azure |
| Firewall cliente | Solo salida a `*.servicebus.windows.net:443` — sin reglas entrantes |
| Rotación de tokens | `az relay namespace authorization-rule keys renew` |

## Requisitos

### Azure
- Suscripción Azure activa
- [Azure CLI](https://aka.ms/installazurecliwindows) instalado y `az login` ejecutado

### Servidor de administración
- Windows 10/11 / Server 2016+ con PowerShell 5.0+
- Acceso saliente HTTPS (443)
- Permisos de Administrador

### Equipos cliente (gestionados)
- Windows 10/11 / Server 2016+ con PowerShell 5.0+
- WinRM habilitado (el script lo configura automáticamente)
- Acceso saliente HTTPS (443) — sin cambios de firewall entrante
- Permisos de Administrador para la instalación inicial

