terraform {
}


resource "azurerm_subnet" "bastion_subnet" {
name = "AzureBastionSubnet"
resource_group_name = azurerm_resource_group.rg.name
virtual_network_name = azurerm_virtual_network.vnet.name
address_prefixes = ["10.0.255.0/27"]
}


resource "azurerm_network_security_group" "nsg" {
name = "gpu-nsg"
location = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name


security_rule {
name = "Allow-SSH-Bastion"
priority = 100
direction = "Inbound"
access = "Allow"
protocol = "Tcp"
source_address_prefix = "10.0.255.0/27"
destination_port_range = "22"
}


security_rule {
name = "Allow-VNC-Bastion"
priority = 110
direction = "Inbound"
access = "Allow"
protocol = "Tcp"
source_address_prefix = "10.0.255.0/27"
destination_port_range = "5901"
}
}


resource "azurerm_network_interface" "nic" {
name = "gpu-nic"
location = azurerm_resource_group.rg.location
resource_group_name = azurerm_resource_group.rg.name


ip_configuration {
name = "internal"
subnet_id = azurerm_subnet.vm_subnet.id
private_ip_address_allocation = "Dynamic"
}
}


resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
network_interface_id = azurerm_network_interface.nic.id
network_security_group_id = azurerm_network_security_group.nsg.id
}


resource "azurerm_linux_virtual_machine" "vm" {
name = "gpu-vm"
resource_group_name = azurerm_resource_group.rg.name
location = azurerm_resource_group.rg.location
size = var.vm_size
admin_username = var.admin_username
network_interface_ids = [azurerm_network_interface.nic.id]


admin_ssh_key {
username = var.admin_username
public_key = var.ssh_public_key
}


os_disk {
caching = "ReadWrite"
storage_account_type = "Premium_LRS"
}


source_image_reference {
publisher = "Canonical"
offer = "0001-com-ubuntu-server-jammy"
sku = "22_04-lts"
version = "latest"
}


custom_data = base64encode(file("${path.module}/cloud-init.yaml"))
}