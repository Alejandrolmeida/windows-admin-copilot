# Agent-VM-Client

Solución de conectividad remota WinRM sin necesidad de abrir puertos entrantes en el equipo destino. Utiliza **Azure Relay Hybrid Connections** como proxy inverso: el agente en el destino hace una conexión saliente HTTPS (puerto 443) a Azure, y el cliente se conecta a través del mismo relay.

## Arquitectura

```
Tu PC (cliente)                   Azure Relay                   Equipo remoto (destino)
─────────────────                 ───────────────               ────────────────────────
AgentVMClient-<vm>  ──HTTPS 443─► relay-sre-agent-proxy ◄──── AgentVMTarget
(servicio Windows)                Hybrid Connection              (servicio Windows)
     │
     ▼
localhost:15985
     │
Enter-PSSession ──────────────────────────────────────────────► WinRM (5985)
```

**Flujo:**
1. El agente destino (`AgentVMTarget`) abre túnel saliente HTTPS a Azure Relay
2. El servicio cliente (`AgentVMClient-<vm>`) expone `localhost:15985` y lo tuneliza por Azure
3. `Connect-RelaySession.ps1` abre una PSSession a `localhost:15985`

## Scripts disponibles

| Script | Donde ejecutar | Descripcion |
|--------|---------------|-------------|
| `New-RelayNamespace.ps1` | Tu PC | Crea el namespace Azure Relay + Hybrid Connections + configs YAML |
| `Install-RelayAgent.ps1` | Equipo remoto (Admin) | Instala `AgentVMTarget` como servicio Windows con arranque automatico |
| `Remove-RelayAgent.ps1` | Equipo remoto (Admin) | Desinstala el agente del equipo remoto |
| `Install-RelayClient.ps1` | Tu PC (Admin) | Instala `AgentVMClient-<vm>` como servicio Windows con arranque automatico |
| `Remove-RelayClient.ps1` | Tu PC (Admin) | Desinstala el servicio cliente |
| `Connect-RelaySession.ps1` | Tu PC | Abre sesion WinRM remota (usa el servicio si esta instalado) |
| `Get-VMStatus.ps1` | Tu PC | Lista todas las maquinas registradas con estado conectado/desconectado |

## Instalacion paso a paso

### 1. Crear infraestructura Azure (una vez por cliente)

```powershell
# En tu PC, con az login activo
.\New-RelayNamespace.ps1 `
    -ResourceGroup "rg-sre-agent-proxy" `
    -Namespace     "relay-sre-agent-proxy" `
    -Machines      "srv01","srv02","srv03" `
    -OutputPath    "C:\relay-configs"
```

Genera por cada maquina:
- `target-srv01.yml` → copiar al equipo remoto
- `client-srv01.yml` → usar en tu PC

### 2. Instalar agente en el equipo remoto (via RDP, una sola vez)

```powershell
# En el equipo remoto, como Administrador
.\Install-RelayAgent.ps1 -ConfigFile "target-srv01.yml"
```

Instala el servicio `AgentVMTarget` con inicio automático. A partir de aquí, el equipo nunca más necesita RDP.

### 3. Instalar servicio cliente en tu PC (recomendado)

```powershell
# En tu PC, como Administrador
.\Install-RelayClient.ps1 -ConfigFile "C:\relay-configs\client-srv01.yml"
# Para una segunda maquina en puerto diferente:
.\Install-RelayClient.ps1 -ConfigFile "C:\relay-configs\client-srv02.yml" -LocalPort 15986
```

Instala `AgentVMClient-srv01` con inicio automático. El proxy siempre estará disponible tras reiniciar.

### 4. Conectarse

```powershell
# Sesion interactiva
.\Connect-RelaySession.ps1 -ConfigFile "client-srv01.yml" -Username "DOMINIO\admin"

# Ejecutar comando remoto
.\Connect-RelaySession.ps1 -ConfigFile "client-srv01.yml" -Username "admin" -Command "Get-Service"
```

### 5. Consultar estado de maquinas

```powershell
.\Get-VMStatus.ps1 -ResourceGroup "rg-sre-agent-proxy" -Namespace "relay-sre-agent-proxy"
```

Salida ejemplo:
```
Estado        Maquina  Listeners  HybridConn    Creado
------        -------  ---------  ----------    ------
[OK] Conectado    srv01        1  winrm-srv01   2026-04-09 08:00
[--] Desconectado srv02        0  winrm-srv02   2026-04-09 08:00
[OK] Conectado    srv03        1  winrm-srv03   2026-04-09 08:00

Resumen: 2 conectadas | 1 desconectadas | 3 total
```

## Desinstalacion

```powershell
# Desinstalar servicio cliente de una maquina
.\Remove-RelayClient.ps1 -MachineName "srv01"

# Desinstalar todos los servicios cliente
.\Remove-RelayClient.ps1 -All

# Desinstalar agente del equipo remoto
.\Remove-RelayAgent.ps1
```

## Servicios Windows creados

| Servicio | Donde | Descripcion |
|----------|-------|-------------|
| `AgentVMTarget` | Equipo remoto | Abre túnel saliente a Azure Relay |
| `AgentVMClient-<vm>` | Tu PC | Expone localhost:15985 → Azure Relay |

Ambos tienen `StartupType = Automatic` → sobreviven reinicios.

## Costes Azure Relay

| Escenario | Coste/mes |
|-----------|-----------|
| 1 maquina, 24/7 | ~$9.5 |
| 5 maquinas, 24/7 | ~$47.5 |
| 20 maquinas, 8h/dia laboral | ~$33.3 |

Basado en $0.013/hora por Hybrid Connection activa. El primer GB de datos al mes es gratuito.

## Seguridad

| Elemento | Configuración |
|----------|--------------|
| Token destino | SAS con permiso `Listen` únicamente (no puede enviar) |
| Token cliente | SAS con permiso `Send` únicamente (no puede escuchar) |
| Transporte | TLS 1.2+ end-to-end a través de Azure |
| Firewall destino | Solo salida a `*.servicebus.windows.net:443` — sin reglas entrantes |
| Rotación de tokens | `az relay hyco authorization-rule keys renew` |

## Requisitos

### Azure
- Suscripción Azure activa
- [Azure CLI](https://aka.ms/installazurecliwindows) instalado y `az login` ejecutado

### Equipo remoto (destino)
- Windows 10 / Server 2016 o superior
- PowerShell 5.0+
- Acceso saliente HTTPS (443) — sin cambios de firewall entrante
- Permisos de Administrador para la instalación inicial

### Tu PC (cliente)
- PowerShell 5.0+
- Acceso saliente HTTPS (443)
- Permisos de Administrador para instalar el servicio cliente (opcional)
