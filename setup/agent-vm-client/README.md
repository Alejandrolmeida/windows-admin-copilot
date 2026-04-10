# Azure Relay — Administración Remota Windows sin VPN

Solución de conectividad remota WinRM **sin abrir puertos entrantes** en los equipos gestionados. Utiliza **Azure Relay Hybrid Connections** como proxy inverso: los clientes abren una conexión saliente HTTPS (puerto 443) a Azure, y el servidor de administración se conecta a través del mismo relay.

## 🚀 Quickstart (5 pasos)

> Requisito previo: `az login` ejecutado en el servidor de administración.

```powershell
# PASO 1 — Crear el namespace Azure Relay (una sola vez)
.\New-RelayNamespace.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -Location "westeurope"

# PASO 2 — Instalar el servidor en este equipo (una sola vez)
.\Install-RelayServer.ps1 -ConfigFile ".\server-relay.yml"

# PASO 3 — Registrar un cliente (repetir por cada equipo a gestionar)
.\Add-RelayClient.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -MachineName "pc-juan"
# → Genera client-pc-juan.yml → cópialo al equipo cliente

# PASO 4 — En el equipo cliente (como Administrador)
.\Register-RelayClient.ps1 -ConfigFile "client-pc-juan.yml"

# PASO 5 — Conectar desde el servidor
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "DOMINIO\admin"
```

---

## Arquitectura

```
SERVIDOR DE ADMINISTRACIÓN          AZURE RELAY                 EQUIPO CLIENTE (gestionado)
───────────────────────────         ───────────────             ───────────────────────────
Tarea: RelayAdminServer             Namespace (1 instancia)     Tarea: RelayClient
azbridge -f server-relay.yml
  LocalForward:
    BindAddress: pc-juan   ──Send──► HC: winrm-pc-juan  ◄──Listen── azbridge (CLI mode)
    BindPort:    15985                                               -T winrm-pc-juan:localhost:15985
    BindAddress: srv-contab ─Send──► HC: winrm-srv-contab ◄─Listen─ azbridge (CLI mode)
    BindPort:    15986
         │
         ▼
  hosts: 127.0.0.2 pc-juan
         127.0.0.3 srv-contab
         │
  Enter-PSSession -ComputerName pc-juan -Port 15985 ──────────────► WinRM (15985)
```

**Principios clave:**
- El servidor corre **UN SOLO proceso** azbridge con múltiples `LocalForward` (uno por cliente)
- Cada cliente tiene una **loopback IP única** (127.0.0.2, 127.0.0.3…) y entrada en `hosts`
- Los clientes usan una SAS key individual con permiso `Listen` por Hybrid Connection
- El servidor usa una SAS key a nivel de **namespace** con permiso `Send` (alcanza todas las HCs)
- Añadir un cliente **NO requiere reinstalar el servidor** → solo reiniciar su tarea programada

---

## Scripts disponibles

### Servidor de administración

| Script | Cuándo usarlo | Descripción |
|--------|---------------|-------------|
| `New-RelayNamespace.ps1` | **Una sola vez** | Crea/valida el namespace Azure Relay. Genera `server-relay.yml` + `server-registry.json`. |
| `Install-RelayServer.ps1` | **Una sola vez** | Instala azbridge como tarea `RelayAdminServer` (SYSTEM, inicio automático). |
| `Add-RelayClient.ps1` | **Una vez por cliente** | Crea HC en Azure, genera `client-<nombre>.yml`, actualiza config del servidor. |
| `Connect-RelaySession.ps1` | **Cada vez que conectas** | Abre sesión WinRM interactiva o ejecuta comandos remotos. |
| `Get-RelayStatus.ps1` | **Diagnóstico rápido** | Muestra estado del servidor y túneles activos desde el registro local. |
| `Get-VMStatus.ps1` | **Visibilidad Azure** | Consulta listeners en Azure vía API (requiere `az login`). |
| `Remove-RelayServer.ps1` | Desinstalación | Elimina la tarea y limpia la instalación local (no toca Azure). |

### Equipo cliente (gestionado)

| Script | Cuándo usarlo | Descripción |
|--------|---------------|-------------|
| `Register-RelayClient.ps1` | **Una vez por cliente** | Instala azbridge como tarea `RelayClient` (SYSTEM, inicio automático). Configura WinRM automáticamente. |
| `Remove-RelayClient.ps1` | Desinstalación | Elimina la tarea y limpia la instalación del cliente. |

---

## Flujo detallado

### Paso 1 — Crear el namespace (una sola vez)

```powershell
.\New-RelayNamespace.ps1 `
    -ResourceGroup "rg-relay" `
    -Namespace     "relay-empresa" `
    -Location      "westeurope"
```

Genera en el directorio de trabajo:
- `server-relay.yml` — config azbridge del servidor (SAS namespace-level + LocalForwards)
- `server-registry.json` — registro JSON de clientes con puertos y loopback IPs asignados

### Paso 2 — Instalar el servidor (una sola vez)

```powershell
# Como Administrador
.\Install-RelayServer.ps1 -ConfigFile ".\server-relay.yml"
```

Crea la tarea programada `RelayAdminServer` (SYSTEM, inicio automático, sin restricción de batería).
Un wrapper `start-relay.ps1` captura los logs en `C:\RelayAdminServer\relay.log`.

### Paso 3 — Registrar un nuevo cliente

```powershell
.\Add-RelayClient.ps1 `
    -ResourceGroup "rg-relay" `
    -Namespace     "relay-empresa" `
    -MachineName   "pc-juan"
```

Esto automáticamente:
1. Crea la Hybrid Connection `winrm-pc-juan` en Azure Relay
2. Genera `client-pc-juan.yml` con la SAS key Listen individual
3. Asigna una loopback IP única (127.0.0.2, 127.0.0.3…) y puerto (15985, 15986…)
4. Actualiza `server-relay.yml` y `server-registry.json`
5. Reinicia la tarea `RelayAdminServer` para aplicar el nuevo LocalForward

### Paso 4 — Instalar el agente en el equipo cliente

Copia `client-pc-juan.yml` al equipo cliente (USB, share de red, az vm run-command…) y ejecuta:

```powershell
# En el equipo cliente, como Administrador
.\Register-RelayClient.ps1 -ConfigFile "client-pc-juan.yml"
```

El script:
- Descarga e instala `azbridge.exe` si no está presente (~50 MB, GitHub releases)
- Reconfigura WinRM en el puerto definido en el YAML (`HostPort`)
- Crea la regla de firewall para el puerto WinRM
- Registra la tarea `RelayClient` (SYSTEM, inicio automático)
- Arranca el agente inmediatamente

A partir de aquí, el cliente se conecta al Relay automáticamente en cada reinicio.

### Paso 5 — Conectar

```powershell
# Sesión interactiva (pide credenciales por pantalla)
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "DOMINIO\admin"

# Ejecutar un comando remoto
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "admin" -Command "Get-Service"

# Sin prompt de contraseña (para scripts o CI/CD)
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "admin" -Password "contraseña" `
    -Command "hostname; Get-Date"

# Solo verificar el túnel sin abrir sesión
.\Connect-RelaySession.ps1 -MachineName "pc-juan" -Username "admin" -NoSession
```

---

## Ver estado de los clientes

### `Get-RelayStatus.ps1` — diagnóstico rápido local

Lee el registro local (`server-registry.json`) y comprueba la conectividad TCP de cada túnel. No requiere `az login`.

```powershell
# Desde el directorio de trabajo del servidor
.\Get-RelayStatus.ps1

# Con ruta personalizada al registry
.\Get-RelayStatus.ps1 -RegistryFile "C:\RelaySetup\server-registry.json"

# Añade columna de listeners en Azure (requiere az login)
.\Get-RelayStatus.ps1 -RegistryFile "C:\RelaySetup\server-registry.json" -ShowListeners
```

Salida:
```
══════════════════════════════════════════════════════
   Azure Relay — Estado de clientes registrados
══════════════════════════════════════════════════════
   2026-04-10 07:23:45

  Namespace   : relay-empresa
  Endpoint    : sb://relay-empresa.servicebus.windows.net:443
  Generado    : 2026-04-10 06:04:30
  Servidor    : ✅ Tarea 'RelayAdminServer' — Running
  Clientes    : 2 registrados

VM / Cliente  Hybrid Connection  Loopback IP  Puerto  Listeners  Tunel TCP    Estado      Registrado
------------  -----------------  -----------  ------  ---------  ---------    ------      ----------
pc-juan       winrm-pc-juan      127.0.0.2     15985          1  ✅ Activo    CONECTADO   2026-04-08
srv-contab    winrm-srv-contab   127.0.0.3     15986          0  ❌ Caido     DESCONECT.  2026-04-09

──────────────────────────────────────────────────────
  Resumen: 1 conectados  |  1 desconectados  |  2 total
```

### `Get-VMStatus.ps1` — visibilidad Azure (vía API)

Consulta directamente la API de Azure Relay para ver el `listenerCount` de cada Hybrid Connection. Requiere `az login`.

```powershell
.\Get-VMStatus.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa"

# Incluir todas las HCs (no solo las winrm-*)
.\Get-VMStatus.ps1 -ResourceGroup "rg-relay" -Namespace "relay-empresa" -ShowAll
```

---

## Archivos generados (fuera del repositorio)

> ⚠️ Estos archivos contienen **claves SAS** y **nunca deben subirse al repositorio**.

| Archivo | Ubicación recomendada | Descripción |
|---------|----------------------|-------------|
| `server-relay.yml` | Servidor (ej. `C:\RelaySetup\`) | Config azbridge del servidor. Gestionado automáticamente por los scripts. |
| `server-registry.json` | Servidor (ej. `C:\RelaySetup\`) | Registro JSON de todos los clientes: nombre, HC, puerto, loopback IP. |
| `client-<nombre>.yml` | Servidor → copiar al cliente | Config azbridge del cliente. SAS Listen individual por HC. |

---

## Tareas programadas creadas

| Tarea | Equipo | Usuario | Inicio | Descripción |
|-------|--------|---------|--------|-------------|
| `RelayAdminServer` | Servidor de administración | SYSTEM | Automático al arrancar | azbridge con todos los LocalForwards. Log en `C:\RelayAdminServer\relay.log`. |
| `RelayClient` | Cada equipo cliente | SYSTEM | Automático al arrancar | azbridge modo CLI, expone WinRM al Relay. |

---

## Desinstalación

```powershell
# En el servidor de administración
.\Remove-RelayServer.ps1

# En el equipo cliente
.\Remove-RelayClient.ps1
```

Para eliminar también la infraestructura de Azure:
```powershell
az relay namespace delete --resource-group "rg-relay" --name "relay-empresa"
# O eliminar el resource group completo:
az group delete --name "rg-relay" --yes
```

---

## Costes Azure Relay

| Escenario | Coste/mes (estimado) |
|-----------|----------------------|
| 1 cliente, 24/7 | ~$10 |
| 5 clientes, 24/7 | ~$15 |
| 20 clientes, 8h/día laboral | ~$35 |

- Namespace: ~$0.10/hora
- Por Hybrid Connection activa: ~$0.013/hora
- El primer GB de datos al mes es gratuito; después ~$0.10/GB

---

## Seguridad

| Elemento | Configuración |
|----------|--------------|
| SAS servidor | Permiso `Send` a nivel namespace (alcanza todas las HCs con una sola key) |
| SAS cliente | Permiso `Listen` individual por Hybrid Connection (compromiso mínimo) |
| Transporte | TLS 1.2+ end-to-end a través de Azure Service Bus |
| Firewall cliente | Solo salida a `*.servicebus.windows.net:443` — sin reglas entrantes |
| Archivos con keys | `server-relay.yml`, `client-*.yml` — nunca en el repositorio |
| Rotación de tokens | `az relay namespace authorization-rule keys renew --resource-group <rg> --namespace-name <ns> --name <rule>` |

---

## Requisitos

### Azure
- Suscripción Azure activa
- [Azure CLI](https://aka.ms/installazurecliwindows) instalado y `az login` ejecutado
- Permisos `Contributor` sobre el resource group

### Servidor de administración
- Windows 10/11 / Server 2016+ con PowerShell 5.0+
- Acceso saliente HTTPS (443) a `*.servicebus.windows.net`
- Permisos de Administrador local

### Equipos cliente (gestionados)
- Windows 10/11 / Server 2016+ con PowerShell 5.0+
- Acceso saliente HTTPS (443) a `*.servicebus.windows.net` — sin cambios de firewall entrante
- Permisos de Administrador para la instalación inicial
- WinRM no necesita estar preconfigurado — `Register-RelayClient.ps1` lo configura automáticamente

