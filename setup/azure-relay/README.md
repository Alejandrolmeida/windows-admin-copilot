# Azure Relay Bridge — WinRM sin puertos entrantes

Solución para conectar WinRM a equipos remotos usando **Azure Relay Hybrid Connections** como proxy inverso. Solo requiere tráfico **saliente HTTPS (443)** en el equipo destino.

## Arquitectura

```
[Tu PC]                      [Azure Relay]               [Equipo remoto]
   |                              |                             |
   | ── HTTPS/WSS ──────────────► | ◄── HTTPS/WSS saliente ─── |
   |   Connect-RelaySession.ps1   |    Install-RelayAgent.ps1   |
   |                              |                             |
localhost:15985 ─── túnel ────────────────────── localhost:5985 (WinRM)
```

- El equipo remoto **no necesita puertos entrantes** — solo salida a internet por 443
- Solo necesitas RDP **una vez** para instalar el agente
- El agente arranca como Windows Service y sobrevive reinicios

## Scripts

| Script | Donde ejecutar | Descripción |
|---|---|---|
| `New-RelayNamespace.ps1` | Tu PC (con Az CLI) | Crea el namespace Azure + Hybrid Connections + configs YAML |
| `Install-RelayAgent.ps1` | Equipo remoto (Admin) | Descarga azbridge, instala como servicio |
| `Connect-RelaySession.ps1` | Tu PC | Abre túnel local + Enter-PSSession |
| `Remove-RelayAgent.ps1` | Equipo remoto (Admin) | Desinstala el agente |

## Flujo completo

### Paso 1 — Crear recursos Azure (una sola vez por cliente)

```powershell
# En tu PC, con Az CLI instalado y az login hecho
.\New-RelayNamespace.ps1 `
    -ResourceGroup "rg-relay-cliente01" `
    -Namespace     "relay-cliente01" `
    -Machines      "srv01", "srv02", "srv03" `
    -Location      "westeurope" `
    -OutputPath    "C:\relay-configs\cliente01" `
    -CreateResourceGroup
```

Genera por cada máquina:
- `target-srv01.yml` → copiar al equipo remoto
- `client-srv01.yml` → queda en tu PC

### Paso 2 — Instalar agente en el equipo remoto (una sola vez, via RDP)

```powershell
# Conéctate por RDP, copia target-srv01.yml y ejecuta como Administrador:
.\Install-RelayAgent.ps1 -ConfigFile "target-srv01.yml"
```

Después de esto **ya no necesitas RDP** para gestión rutinaria.

### Paso 3 — Conectar desde tu PC

```powershell
.\Connect-RelaySession.ps1 `
    -ConfigFile "C:\relay-configs\cliente01\client-srv01.yml" `
    -Username   "DOMINIO\usuario"
```

O para ejecutar un comando puntual sin sesión interactiva:

```powershell
.\Connect-RelaySession.ps1 `
    -ConfigFile "C:\relay-configs\cliente01\client-srv01.yml" `
    -Username   "DOMINIO\usuario" `
    -Command    "Get-Service | Where-Object Status -eq Running"
```

### Paso 4 — Desinstalar (opcional)

```powershell
# En el equipo remoto, como Administrador:
.\Remove-RelayAgent.ps1
```

## Requisitos

### Azure
- Suscripción Azure activa
- Azure CLI instalado: https://aka.ms/installazurecliwindows
- `az login` ejecutado

### Equipo remoto (destino)
- Windows 10 / Server 2016 o superior
- PowerShell 5.0+
- Acceso saliente HTTPS (443) — **sin cambios de firewall**
- Permisos de Administrador para instalación inicial

### Tu PC (cliente)
- PowerShell 5.0+
- Acceso saliente HTTPS (443)
- No requiere permisos de administrador

## Coste estimado (West Europe)

| Uso | 1 máquina | 10 máquinas | 20 máquinas |
|---|---|---|---|
| Servicio 24/7 | ~$9.50/mes | ~$95/mes | ~$190/mes |
| 8h/día, 20 días | ~$2/mes | ~$20/mes | ~$42/mes |

> Cada Hybrid Connection incluye 5 GB de datos/mes. Para gestión administrativa el consumo de datos es mínimo (< 1 GB/mes por máquina).

## Seguridad

- Autenticación mediante **SAS tokens** con permisos mínimos (Listen/Send separados)
- Tráfico cifrado **TLS** extremo a extremo
- Los tokens pueden regenerarse en Azure Portal si se comprometen
- Recomendado: rotar los SAS tokens periódicamente con `az relay hyco authorization-rule keys renew`
