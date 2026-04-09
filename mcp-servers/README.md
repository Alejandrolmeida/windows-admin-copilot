# Servidores MCP incluidos

## Descripción de cada MCP

| MCP | Tecnología | Propósito |
|-----|-----------|-----------|
| `powershell-mcp` | PowerShell 7 + PSGallery | Ejecución de cmdlets, módulos de NAV/AX/Hyper-V |
| `win-cli-mcp` | Node.js | PowerShell, CMD, SSH a servidores remotos |
| `windows-admin-mcp` | Python + WinRM | Administración remota de servidores Windows |
| `azure-mcp` | Node.js (npx) | Gestión oficial de recursos Azure (Microsoft) |
| `vmware-vsphere-mcp` | Python | Gestión de VMs en vCenter/ESXi |
| `memory` | Node.js (npx) | Memoria persistente entre sesiones (grafo de conocimiento) |

## Hyper-V y VirtualBox

No requieren MCP dedicado:

- **Hyper-V** → usar `powershell-mcp` con el módulo `Hyper-V` nativo de Windows Server  
  `Get-VM`, `Start-VM`, `Stop-VM`, `Checkpoint-VM`, `New-VM`, etc.

- **VirtualBox** → usar `win-cli-mcp` con `VBoxManage` CLI  
  `VBoxManage list vms`, `VBoxManage startvm`, `VBoxManage snapshot`, etc.

## Instalación y actualización

El mismo script sirve para primera instalación, actualizaciones y reparaciones.
Ejecutar como Administrador:

```powershell
.\install-mcp-servers.ps1
```

Las credenciales existentes (Azure, VMware) se detectan y **preservan automáticamente**.

| Parámetro | Descripción |
|-----------|-------------|
| `-ConfigOnly` | Solo regenera `mcp-config.json` (omite git pull y reinstalación de servidores) |
| `-Force` | Sin confirmaciones interactivas |

## Configuración de credenciales

Editar `.copilot\mcp-config.json` y rellenar:

- **azure-mcp**: `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`
- **vmware-vsphere-mcp**: `VCENTER_HOST`, `VCENTER_USER`, `VCENTER_PASSWORD`
- **win-cli-mcp**: editar `config.json` con hosts SSH remotos

## Obtener credenciales Azure

```powershell
# Login en Azure CLI
az login

# Obtener Subscription ID
az account show --query id -o tsv

# Crear Service Principal para el MCP
az ad sp create-for-rbac --name "copilot-mcp" --role Contributor `
    --scopes /subscriptions/<SUBSCRIPTION_ID>
# Guarda el output: appId=CLIENT_ID, password=CLIENT_SECRET, tenant=TENANT_ID
```
