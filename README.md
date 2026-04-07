# Windows Admin Copilot

Entorno preconfigurado de **GitHub Copilot CLI** especializado en:
- Administración de **Windows Server**
- ERPs legacy: **Microsoft Dynamics NAV / Navision** y **Dynamics AX / Axapta**
- Virtualización: **Hyper-V**, **VMware vSphere**, **VirtualBox**
- Infraestructura cloud: **Microsoft Azure**

## Inicio rápido

```powershell
# 1. Clonar este repositorio en el equipo de trabajo
git clone https://github.com/Alejandrolmeida/windows-admin-copilot.git
cd windows-admin-copilot

# 2. Ejecutar setup completo (como Administrador)
.\setup\3-setup-all.ps1

# 3. Editar credenciales de servidores remotos
notepad "$env:USERPROFILE\.copilot\mcp-config.json"

# 4. Lanzar Copilot CLI
copilot
```

## Estructura

```
windows-admin-copilot/
├── setup/
│   ├── 1-install-powershell7.ps1   # Instala PowerShell 7
│   ├── 2-install-copilot-cli.ps1   # Instala Copilot CLI + Node.js + Python
│   └── 3-setup-all.ps1             # Setup completo en un paso
├── .copilot/
│   ├── copilot-instructions.md     # Agente especializado en Windows/NAV/AX
│   └── mcp-config.json             # Configuración de todos los MCPs
├── mcp-servers/
│   ├── install-mcp-servers.ps1     # Clona e instala todos los MCPs
│   └── README.md                   # Documentación de los MCPs
└── docs/
    ├── navision-commands.md        # Referencia de comandos Dynamics NAV
    └── axapta-commands.md          # Referencia de comandos Dynamics AX
```

## Servidores MCP configurados

| MCP | Uso |
|-----|-----|
| `powershell-mcp` | PowerShell 7 local + 10,000+ módulos PSGallery |
| `win-cli-mcp` | PowerShell/CMD/SSH a servidores remotos |
| `windows-admin-mcp` | WinRM para administración remota Windows |
| `azure-mcp` | Gestión de infraestructura Azure (oficial Microsoft) |
| `vmware-vsphere-mcp` | VMs en vCenter/ESXi vía API |
| Hyper-V | Vía `powershell-mcp` con módulo Hyper-V nativo |
| VirtualBox | Vía `win-cli-mcp` con VBoxManage CLI |

## Requisitos

- Windows 10/11 o Windows Server 2016+
- PowerShell 7.x
- Node.js 18+
- Python 3.10+
- Git
- Cuenta GitHub con suscripción Copilot activa

## Configuración de credenciales remotas

Editar `~/.copilot/mcp-config.json` tras la instalación:

- **Servidores Windows remotos**: añadir hosts SSH en `win-cli-mcp/config.json`
- **Azure**: rellenar `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`
- **VMware**: rellenar `VCENTER_HOST`, `VCENTER_USER`, `VCENTER_PASSWORD`

Ver `mcp-servers/README.md` para instrucciones detalladas.

## Documentación de referencia

- [Comandos Dynamics NAV/Navision](docs/navision-commands.md)
- [Comandos Dynamics AX/Axapta](docs/axapta-commands.md)
- [Servidores MCP](mcp-servers/README.md)
