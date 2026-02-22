# kwr-edu-az-01
Azure GPU workstation stack for ROS/Gazebo/Isaac Sim with private access via Azure Bastion.

## What This Deploys
- Azure resource group, VNet, VM subnet, and `AzureBastionSubnet`
- Linux GPU VM (Ubuntu 22.04), Entra ID SSH login extension, NVIDIA GPU driver extension
- Azure Bastion Standard with native client tunneling enabled
- NSG rules allowing inbound `22` and `5901` only from Bastion subnet
- Cloud-init bootstrap for desktop + VNC + Docker + NVIDIA container runtime + ROS 2/Gazebo helpers

## Prerequisites
- Azure subscription permissions to deploy resources
- Terraform 1.6+
- Azure CLI with Bastion extension (`az extension add --name bastion`)
- For Windows remote desktop access, TurboVNC Viewer (or another VNC client that supports `host::port` syntax)

## Deploy
Use either GitHub Actions (`.github/workflows/main.yml`) or local Terraform in `workflows/terraform`.

Example local flow:

```powershell
cd workflows/terraform
terraform init
terraform apply
```

## Post-Provision Setup (on VM)
After infra is provisioned, connect once via Bastion SSH (AAD) and finish VNC initialization.

1. Get generated connection commands:

```powershell
cd workflows/terraform
terraform output -raw bastion_aad_ssh_cmd
terraform output -raw bastion_vnc_tunnel_cmd
terraform output -raw vnc_client_target
```

2. Open SSH session with the `bastion_aad_ssh_cmd` output.
3. Complete AAD device login in browser if prompted (`https://microsoft.com/devicelogin`).
4. On the VM, run one-time VNC setup:

```bash
sudo vnc-passwd
sudo vnc-start
sudo vnc-status
```

Notes:
- Cloud-init installs TurboVNC when available, otherwise falls back to TigerVNC.
- VNC password is separate from SSH password auth.

## Connect From Windows via Bastion + VNC
1. In PowerShell on Windows, run the generated tunnel command and keep it running:

```powershell
cd workflows/terraform
$tunnelCmd = terraform output -raw bastion_vnc_tunnel_cmd
Invoke-Expression $tunnelCmd
```

2. In TurboVNC Viewer, connect to `localhost::55901` (or use `terraform output -raw vnc_client_target`).

Important:
- Use double-colon format (`host::port`) for explicit TCP port mode.
- Keep the tunnel terminal open while using VNC.

## Isaac Sim Components
Cloud-init installs/configures:
- Docker
- NVIDIA Container Toolkit (`nvidia-ctk runtime configure --runtime=docker`)
- Helper launcher script: `/usr/local/bin/isaac-sim-run`
- Default image reference: `nvcr.io/nvidia/isaac-sim:latest`

To run:

```bash
isaac-sim-run
```

You may need:

```bash
docker login nvcr.io
```

## Troubleshooting
- `Defined port is currently unavailable`:
  - Local port is busy; change `--port` and use matching `localhost::<port>` in VNC client.
- VNC client closes immediately:
  - Verify on VM: `sudo vnc-status`
  - Check listener: `sudo ss -lntp | grep 5901`
- No sudo rights after AAD login:
  - Ensure your identity is in AAD admin scope and reconnect.
- `vncpasswd`/`vncserver` missing:
  - Check bootstrap log: `/var/log/bootstrap.log`
