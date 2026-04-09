# 🖥️ Windows Admin Copilot

<div align="center">

![Windows](https://img.shields.io/badge/Windows_Server-2016%2F2019%2F2022%2F2025-0078D4?style=for-the-badge&logo=windows&logoColor=white)
![Azure](https://img.shields.io/badge/Azure_Hybrid-Arc%20%7C%20VPN%20%7C%20Backup-0078D4?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Hyper-V](https://img.shields.io/badge/Virtualization-Hyper--V%20%7C%20VMware-7FBA00?style=for-the-badge&logo=vmware&logoColor=white)
![Dynamics](https://img.shields.io/badge/ERP-Navision%20%7C%20Axapta-002050?style=for-the-badge&logo=microsoftdynamics365&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-7.x-5391FE?style=for-the-badge&logo=powershell&logoColor=white)

**Entorno preconfigurado de GitHub Copilot con agente de IA especializado en infraestructura Windows empresarial, virtualización, ERP Microsoft Dynamics y nube híbrida Azure.**

</div>

---

## ¿Qué es Windows Admin Copilot?

Windows Admin Copilot es un entorno de **GitHub Copilot** preconfigurado con:

- Un **agente de IA especializado** (`Windows_Infra_Pro`) con conocimiento profundo de Windows Server, redes, virtualización, ERP Microsoft y Azure híbrido
- **Servidores MCP** (Model Context Protocol) para ejecutar comandos PowerShell locales, administración remota vía WinRM/SSH, gestión de Azure y VMware
- **Playbooks integrados** con comandos listos para usar en cada dominio técnico
- **Metodología evidence-first**: el agente diagnostica antes de actuar, solicita aprobación para operaciones destructivas y documenta todo

### ¿Para quién es esto?

| Perfil | Caso de uso |
|--------|-------------|
| **Administrador de sistemas** | Troubleshooting de Windows Server, AD, DNS, rendimiento |
| **Ingeniero de infraestructura** | Gestión de Hyper-V, VMware, migraciones, backup/DR |
| **Consultor ERP** | Diagnóstico y administración de Navision, Business Central, AX, F&O |
| **Arquitecto cloud** | Diseño y operación de nube híbrida con Azure Arc, VPN, AAD Connect |
| **SRE / DevOps** | Automatización PowerShell, runbooks, monitorización con Azure Monitor |

---

## El Agente: `Windows_Infra_Pro`

El agente vive en `.github/agents/Windows_Infra_Pro.agent.md` y está disponible en **GitHub Copilot Chat** dentro de VS Code (modo agente).

### Áreas de expertise

```
Windows & Windows Server
   Active Directory, AD CS, AD FS, Azure AD Connect
   DNS, DHCP, IIS, DFS, WSUS, RDS, NPS, Print Server
   Storage Spaces Direct, ReFS, SMB 3.x, iSCSI
   Seguridad: BitLocker, LAPS, Credential Guard, JEA, PAW
   Troubleshooting: SysInternals, WinDbg, Event Viewer

Networking
   TCP/IP, BGP, OSPF, VLANs, QoS, IPv4/IPv6
   Microsoft: DNS split-brain, DHCP failover, DirectAccess, RRAS, VPN
   Hardware: Cisco, HPE/Aruba, Fortinet, Palo Alto, pfSense
   Azure: Virtual WAN, ExpressRoute, VPN Gateway, NSG, Private Link
   Diagnóstico: Wireshark, netsh trace, PRTG, Zabbix

Virtualización
   Hyper-V: Live Migration, Failover Cluster, CSV, Replica
   VMware: ESXi, vCenter, vSAN, NSX-T, DRS/HA/FT (PowerCLI)
   Azure Stack HCI: S2D, SDN, Arc integration
   Backup/DR: Veeam, Azure Site Recovery, DPM

Microsoft Dynamics NAV / Business Central
   NAV 2009-2018: NST, C/AL, finsql.exe, licencias .flf
   Business Central: on-prem / cloud / hybrid, AL, Extensions
   Admin: Service Tier, Database Conversion, Upgrade Toolkit
   Integración: Power Platform, Azure AD SSO, OData/REST APIs

Microsoft Dynamics AX / Finance & Operations
   AX 2009 / AX 2012 R3: AOS, MorphX, X++, Batch Server
   D365 F&O: LCS, RSAT, DMF, BYOD, Azure DevOps
   SQL tuning para AX: índices, estadísticas, bloqueos, tempdb
   Integración: AIF, Logic Apps, Data Factory, Dual-Write

Nube Híbrida Azure
   Azure Arc: servidores, Kubernetes, Data Services
   Conectividad: ExpressRoute, S2S VPN, Virtual WAN
   Identity: AAD Connect (sync/cloud), PHS, PTA, Seamless SSO
   Backup: MARS Agent, MABS, Azure Site Recovery
   Monitorización: Azure Monitor Agent, Log Analytics, Sentinel
```

### Cómo trabaja el agente

1. **Contexto mínimo** — solicita los datos del entorno antes de diagnosticar
2. **Diagnóstico no invasivo** — comandos de solo lectura primero
3. **Hipótesis priorizadas** — lista causas por probabilidad con evidencia
4. **Solicitud de aprobación** — para operaciones destructivas presenta análisis de riesgo y espera confirmación explícita
5. **Solución + validación** — proporciona comandos de remediación y checklist post-cambio

---

## Requisitos

| Componente | Versión mínima |
|------------|---------------|
| Windows | 10/11 o Server 2016+ |
| PowerShell | 7.x (el setup lo instala) |
| Node.js | 18+ (el setup lo instala) |
| Python | 3.10+ |
| Git | 2.x |
| GitHub Copilot | Plan individual, Business o Enterprise |
| VS Code | 1.99+ (para agent mode) |

---

## Instalación

### Opción A — Setup completo automático (recomendado)

Abre PowerShell **como Administrador** y ejecuta:

```powershell
# 1. Clonar el repositorio
git clone https://github.com/Alejandrolmeida/windows-admin-copilot.git
cd windows-admin-copilot

# 2. Setup completo en un paso (instala PS7, Node, Python, MCPs)
.\setup\3-setup-all.ps1
```

El script `3-setup-all.ps1` realiza automáticamente:
- Instala PowerShell 7 (via winget)
- Instala Node.js 18 LTS y Python 3.11 (si no están presentes)
- Instala y configura todos los servidores MCP
- Copia la configuración MCP a `~/.copilot/mcp-config.json`

### Opción B — Instalación paso a paso

```powershell
# Paso 1: Instalar PowerShell 7
.\setup\1-install-powershell7.ps1

# Paso 2: Instalar Copilot CLI, Node.js y Python
.\setup\2-install-copilot-cli.ps1

# Paso 3: Instalar servidores MCP
.\mcp-servers\install-mcp-servers.ps1
```

### Actualización desde versión anterior

Si ya tienes el entorno instalado y quieres actualizar todo (servidores MCP + configuración):

```powershell
# 1. Actualizar el repositorio
cd windows-admin-copilot
git pull

# 2. Ejecutar el script de actualización completo
#    Actualiza repos, dependencias y config — preserva tus credenciales
.\setup\update-mcp-config.ps1
```

El script `update-mcp-config.ps1` realiza en orden:

| Fase | Acción |
|------|--------|
| **0** | Actualiza el módulo `PowerShell.MCP` desde PSGallery |
| **1** | `git pull` + reinstala dependencias de cada servidor MCP |
| **2** | Actualiza `mcp-config.json` con rutas reales (Python, proxy) y **preserva** credenciales |
| **3** | Verifica que todos los ejecutables existan |

Parámetros opcionales:
- `-ConfigOnly` — solo actualiza el config (omite fases 0 y 1)
- `-Force` — sobreescribe sin pedir confirmación

### Configurar credenciales

Tras la instalación, edita el fichero de configuración MCP:

```powershell
notepad "$env:USERPROFILE\.copilot\mcp-config.json"
```

Rellena los valores de Azure:

```jsonc
"azure-mcp": {
  "env": {
    "AZURE_SUBSCRIPTION_ID": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "AZURE_TENANT_ID":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "AZURE_CLIENT_ID":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "AZURE_CLIENT_SECRET":   "tu-secret-aqui"
  }
}
```

Rellena los valores de VMware:

```jsonc
"vmware-vsphere-mcp": {
  "env": {
    "VCENTER_HOST":     "vcenter.tudominio.local",
    "VCENTER_USER":     "administrator@vsphere.local",
    "VCENTER_PASSWORD": "tu-password-aqui"
  }
}
```

Para servidores Windows remotos vía SSH:

```powershell
notepad "C:\mcp-servers\win-cli-mcp-server\config.json"
```

### Usar el agente en VS Code

1. Abre VS Code en la carpeta del repositorio clonado
2. Abre **GitHub Copilot Chat** (`Ctrl+Shift+I`)
3. Selecciona el modo **Agente** en el selector de modo
4. Selecciona `Windows_Infra_Pro` en la lista de agentes
5. ¡Empieza a conversar!

> El agente aparece en VS Code porque está en `.github/agents/`. Requiere VS Code 1.99+ y Copilot con agent mode habilitado.

---

## Estructura del repositorio

```
windows-admin-copilot/
│
├── .github/
│   └── agents/
│       └── Windows_Infra_Pro.agent.md      <- Agente principal (VS Code agent mode)
│
├── .copilot/
│   ├── copilot-instructions.md             <- Instrucciones Copilot Chat estándar
│   └── mcp-config.json                     <- Configuración de servidores MCP
│
├── setup/
│   ├── 1-install-powershell7.ps1           <- Instala PowerShell 7 vía winget
│   ├── 2-install-copilot-cli.ps1           <- Instala Node.js, Python, Copilot CLI
│   ├── 3-setup-all.ps1                     <- Setup completo en un paso
│   ├── update-mcp-config.ps1               <- Actualiza config MCP preservando credenciales
│   ├── configure-winrm-target.ps1          <- Habilita WinRM en equipo destino
│   ├── configure-winrm-client.ps1          <- Configura WinRM en cliente (TrustedHosts)
│   ├── cleanup-winrm-client.ps1            <- Revierte configuración WinRM cliente
│   └── agent-vm-client/                    <- Solución de conectividad remota sin VPN
│       ├── README.md
│       ├── New-RelayNamespace.ps1/.bat     <- Crea infraestructura Azure Relay
│       ├── Install-RelayAgent.ps1/.bat     <- Instala agente en equipo remoto
│       ├── Remove-RelayAgent.ps1/.bat      <- Desinstala agente del equipo remoto
│       ├── Install-RelayClient.ps1/.bat    <- Instala servicio cliente local
│       ├── Remove-RelayClient.ps1/.bat     <- Desinstala servicio cliente
│       ├── Connect-RelaySession.ps1/.bat   <- Abre sesión WinRM remota
│       └── Get-VMStatus.ps1/.bat           <- Consulta estado de máquinas
│
├── mcp-servers/
│   ├── install-mcp-servers.ps1             <- Instala todos los servidores MCP
│   └── README.md
│
├── docs/
│   ├── navision-commands.md                <- Comandos PowerShell para NAV/Business Central
│   └── axapta-commands.md                  <- Comandos para AX 2012 y D365 F&O
│
└── README.md
```

---

## Conectividad remota: Agent-VM-Client

Para administrar máquinas remotas donde **no es posible abrir puertos entrantes** (solo RDP disponible), el proyecto incluye la solución **Agent-VM-Client** basada en Azure Relay Hybrid Connections.

```
Tu PC                        Azure Relay                   Equipo remoto
─────────────────            ───────────────               ──────────────
AgentVMClient-<vm>  ─HTTPS►  relay-sre-agent-proxy  ◄────  AgentVMTarget
(servicio Windows)           Hybrid Connection              (servicio Windows)
       │
       ▼
 localhost:15985
       │
Enter-PSSession ─────────────────────────────────────────► WinRM :5985
```

**Características:**
- El equipo destino solo necesita **salida HTTPS (443)** — sin cambios de firewall entrante
- Una única conexión RDP inicial para instalar el agente; después todo vía PowerShell
- Ambos lados corren como **Windows Service con arranque automático**
- Consulta de estado de máquinas conectadas/desconectadas en tiempo real

➡️ Ver [setup/agent-vm-client/README.md](setup/agent-vm-client/README.md) para la guía completa.

---

## Servidores MCP configurados

| MCP | Descripción | Casos de uso |
|-----|-------------|--------------|
| `powershell-mcp` | PowerShell 7 local + 10.000+ módulos PSGallery | Hyper-V, AD, scripts de automatización |
| `win-cli-mcp` | PowerShell / CMD / SSH a servidores remotos | Administración multi-servidor |
| `windows-admin-mcp` | WinRM: diagnóstico, servicios, Event Logs | Troubleshooting remoto Windows |
| `azure-mcp` | API oficial Microsoft Azure | VMs, Storage, SQL, Networking, Policy |
| `vmware-vsphere-mcp` | vCenter REST API | VMs, Snapshots, Datastores, Hosts ESXi |
| Hyper-V (integrado) | Módulo nativo Windows vía `powershell-mcp` | Gestión completa de VMs locales |
| VirtualBox (integrado) | `VBoxManage` CLI vía `win-cli-mcp` | VMs VirtualBox headless |

---

## Ejemplos de uso (Kick-Starter)

### Windows Server — Diagnóstico de rendimiento

```
@Windows_Infra_Pro El servidor SRV-APP-01 está lento desde esta mañana.
Windows Server 2019, tiene IIS y SQL Server Express. Los usuarios se quejan
de lentitud en la aplicación web. ¿Cómo lo diagnostico?
```

El agente responderá con comandos PowerShell listos para ejecutar (CPU, RAM, disco, procesos top), análisis de Event Log, hipótesis priorizadas y plan de mitigación paso a paso.

---

### Networking — Conectividad intermitente con Azure

```
@Windows_Infra_Pro Tenemos un problema de conectividad intermitente entre
la sede central y la sucursal. Usamos VPN Site-to-Site con Azure VPN Gateway
y un Fortigate en la oficina. Las conexiones a los servidores SQL en Azure
fallan cada 30-40 minutos. ¿Qué puede estar pasando?
```

---

### Hyper-V — Auditoría de snapshots

```
@Windows_Infra_Pro Necesito auditar todos los snapshots de las VMs en el
clúster Hyper-V. Quiero saber cuáles tienen más de 7 días, cuánto espacio
ocupan y ordenarlos por tamaño para limpiarlos.
```

El agente ejecutará via `powershell-mcp`:
```powershell
Get-VM | Get-Snapshot | Where-Object { $_.Created -lt (Get-Date).AddDays(-7) } |
  Select-Object VM, Name, Created, @{N='SizeGB';E={[math]::Round($_.SizeGB,2)}} |
  Sort-Object SizeGB -Descending | Format-Table -AutoSize
```

---

### Business Central — NST no arranca

```
@Windows_Infra_Pro El servicio de Business Central on-premises no arranca
tras una actualización de Windows Server. Versión BC 21, SQL Server 2019
en el mismo servidor. En el Event Log aparece error de timeout en el arranque.
¿Qué hago?
```

El agente diagnosticará: logs del NST, permisos de cuenta de servicio, dependencias (SQL Server, puertos 7045-7049) y conflictos tras Windows Update.

---

### Dynamics AX 2012 — Performance degradada

```
@Windows_Infra_Pro El AX 2012 R3 está muy lento en el módulo de contabilidad.
El AOS tiene 4 vCPUs y 16GB RAM en VMware. SQL Server está en servidor dedicado.
Los usuarios reportan timeouts al lanzar informes de Management Reporter.
¿Cómo identifico el cuello de botella?
```

---

### Azure Híbrido — Inventario Arc y backup

```
@Windows_Infra_Pro Dame un inventario de todos los servidores on-premises
conectados via Azure Arc. Incluye: nombre, OS, estado de conexión, extensiones
instaladas y si tienen Azure Backup configurado.
```

---

### Active Directory — Auditoría de seguridad

```
@Windows_Infra_Pro Necesito una auditoría de seguridad básica del AD.
Quiero identificar: cuentas sin password expiry, usuarios inactivos >90 días,
cuentas Domain Admin y GPOs sin enlazar. Dominio contoso.local con 3 DCs
en Windows Server 2022.
```

---

### Migración — NAV 2015 a Business Central

```
@Windows_Infra_Pro Tenemos un cliente con Microsoft Dynamics NAV 2015
(SQL Server 2014, ~80GB) y queremos migrar a Business Central 2024 on-premises.
¿Cuál es el path de actualización recomendado, qué riesgos hay con las
personalizaciones en C/AL, y cuánto tiempo estimado debería planificar?
```

---

## Política de seguridad del agente

El agente implementa un **protocolo de aprobación explícita** para operaciones que puedan causar interrupción de servicio:

### Permitido sin aprobación (solo lectura)
- `Get-*`, `Test-*`, `Resolve-*` en PowerShell
- Consultas SELECT en SQL Server (DMVs)
- `az * list`, `az * show` en Azure CLI
- Lectura de Event Logs, configuraciones, estado de servicios

### Requiere aprobación explícita
Antes de ejecutar `Stop-Service`, `Remove-VM`, `az vm stop`, modificaciones en AD o SQL, el agente presenta:

```
SOLICITUD DE APROBACION

Operacion: Stop-Service "MicrosoftDynamicsNavServer$BC"
Justificacion: [motivo detallado]
Usuarios afectados: Todos los usuarios de Business Central
Downtime estimado: 2-5 minutos
Plan de rollback: Start-Service "MicrosoftDynamicsNavServer$BC"

¿APRUEBAS esta operacion? (SI / NO / MODIFICAR)
```

---

## Documentación de referencia

- [setup/agent-vm-client/README.md](setup/agent-vm-client/README.md) — Conectividad remota sin VPN con Azure Relay
- [docs/navision-commands.md](docs/navision-commands.md) — Comandos PowerShell para Dynamics NAV/Business Central
- [docs/axapta-commands.md](docs/axapta-commands.md) — Comandos para AX 2012 y D365 F&O
- [mcp-servers/README.md](mcp-servers/README.md) — Configuración detallada de cada servidor MCP
- [Microsoft Learn — Windows Server](https://learn.microsoft.com/windows-server/)
- [Microsoft Learn — Business Central](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/)
- [Microsoft Learn — Azure Arc](https://learn.microsoft.com/azure/azure-arc/)
- [Azure Relay Hybrid Connections](https://learn.microsoft.com/azure/azure-relay/relay-hybrid-connections-protocol)

---

## Contribuir

1. Haz fork del repositorio
2. Edita `.github/agents/Windows_Infra_Pro.agent.md`
3. Añade tu playbook siguiendo la estructura existente
4. Abre un Pull Request con descripción del área cubierta

---

Creado para administradores de infraestructura Windows que merecen una IA que hable su idioma.
