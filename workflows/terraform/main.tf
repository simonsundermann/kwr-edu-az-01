terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  # Least-privilege: verhindert, dass Terraform versucht, Provider auf Subscription zu registrieren
  skip_provider_registration = true
}
#RG created in create-sp2 with role assignment already
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

#uncomment RG not created in create-sp2 with role assignment already
#resource "azurerm_resource_group" "rg" {
#  name     = var.resource_group_name
#  location = var.location
#}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "vm_subnet" {
  name                 = "${var.name_prefix}-vm-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.255.0/27"]
}

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.name_prefix}-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-SSH-From-BastionSubnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = azurerm_subnet.bastion_subnet.address_prefixes[0]
    destination_port_range     = "22"
    source_port_range          = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-VNC-From-BastionSubnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = azurerm_subnet.bastion_subnet.address_prefixes[0]
    destination_port_range     = "5901"
    source_port_range          = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.name_prefix}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Bootstrap admin password (nur für Provisioning; SSH Passwort wird per cloud-init deaktiviert)
resource "random_password" "admin" {
  length  = 32
  special = true
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "${var.name_prefix}-vm"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size

  network_interface_ids = [azurerm_network_interface.nic.id]

  admin_username = var.admin_username

  disable_password_authentication = false
  admin_password                  = random_password.admin.result

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  custom_data = filebase64("${path.module}/cloud-init.yaml")

  encryption_at_host_enabled = true
  secure_boot_enabled        = true
  vtpm_enabled               = true
}

# NVIDIA Driver Extension (Azure)
resource "azurerm_virtual_machine_extension" "nvidia_driver" {
  name                       = "${var.name_prefix}-nvidia-driver"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm.id
  publisher                  = "Microsoft.HpcCompute"
  type                       = "NvidiaGpuDriverLinux"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({ driverType = "CUDA" })
}

# Entra ID SSH Login Extension (AADSSHLoginForLinux)
resource "azurerm_virtual_machine_extension" "aad_ssh_login" {
  name                       = "${var.name_prefix}-aadsshlogin"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

# Bastion
resource "azurerm_public_ip" "bastion_pip" {
  name                = "${var.name_prefix}-bastion-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "${var.name_prefix}-bastion"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_pip.id
  }
}