# kwr-edu-az-01
Azure GPU workstation stack with private Windows RDP access via Azure Bastion.

## What This Deploys
- Azure resource group, VNet, VM subnet, and `AzureBastionSubnet`
- Linux GPU VM (Ubuntu 22.04)
- Entra ID SSH login extension and NVIDIA GPU driver extension
- Azure Bastion Standard with native client tunneling enabled
- NSG rules allowing inbound `22` and `3389` only from Bastion subnet
- Cloud-init bootstrap for hardening, AAD sudo mapping, xRDP, and UFW
- Manual post-install script for robotics stack at `/usr/local/bin/robotics-postinstall.sh`

## Prerequisites
- Azure subscription permissions to deploy resources
- Terraform 1.6+
- Azure CLI with Bastion extension:
  - `az extension add --name bastion`
- Windows Remote Desktop client (`mstsc`)

## Deploy
Use GitHub Actions (`.github/workflows/main.yml`) or local Terraform:

```powershell
cd workflows/terraform
terraform init
terraform apply
```

## Connection Commands
After provisioning, fetch generated outputs:

```powershell
cd workflows/terraform
terraform output -raw bastion_aad_ssh_cmd
terraform output -raw bastion_rdp_tunnel_cmd
terraform output -raw rdp_client_target
terraform output -raw admin_username
terraform output -raw admin_password
```

## Connect From Windows via Bastion + RDP
1. Start the Bastion RDP tunnel in PowerShell and keep it running:

```powershell
cd workflows/terraform
$tunnelCmd = terraform output -raw bastion_rdp_tunnel_cmd
Invoke-Expression $tunnelCmd
```

2. Open Remote Desktop and connect to:
   - `127.0.0.1:53389`
   - or `mstsc /v:127.0.0.1:53389`
3. Sign in with:
   - Username: value of `terraform output -raw admin_username`
   - Password: value of `terraform output -raw admin_password`

## SSH (AAD) Access
To run admin operations over SSH:

```powershell
cd workflows/terraform
$sshCmd = terraform output -raw bastion_aad_ssh_cmd
Invoke-Expression $sshCmd
```

When prompted, complete device login at `https://microsoft.com/devicelogin`.

## Manual Robotics Stack Install
Cloud-init no longer installs Docker/NVIDIA toolkit/CUDA/ROS/Gazebo automatically.
After first SSH login, run:

```bash
sudo /usr/local/bin/robotics-postinstall.sh
```

This script installs/configures:
- Docker
- NVIDIA Container Toolkit (`nvidia-ctk runtime configure --runtime=docker`)
- CUDA toolkit (optional, enabled by default)
- ROS 2 Humble (optional, enabled by default)
- Gazebo + ROS Gazebo packages (optional, enabled by default)
- Helper scripts:
  - `/usr/local/bin/gpu-check`
  - `/usr/local/bin/isaac-sim-run`

Log file:
- `/var/log/robotics-postinstall.log`

## Troubleshooting
- Tunnel error `Defined port is currently unavailable`:
  - Local port is occupied. Change `--port` in the tunnel command and use the same port in `mstsc`.
- RDP authentication fails:
  - Confirm `admin_username` and `admin_password` outputs from Terraform state.
- `sudo` denied after AAD SSH:
  - Reconnect and verify your account is in `aad_admins` and has Azure role `Virtual Machine Administrator Login`.
- Bootstrap issues:
  - Check `/var/log/bootstrap.log`.
