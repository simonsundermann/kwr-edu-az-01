output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "bastion_name" {
  value = azurerm_bastion_host.bastion.name
}

output "vm_resource_id" {
  value = azurerm_linux_virtual_machine.vm.id
}

# Bootstrap password NICHT ausgeben (sensitiv)
output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

# Windows/Bastion default: local port 55901 avoids common local VNC collisions on 5901.
output "bastion_vnc_tunnel_cmd" {
  value = "az network bastion tunnel --name ${azurerm_bastion_host.bastion.name} --resource-group ${azurerm_resource_group.rg.name} --target-resource-id ${azurerm_linux_virtual_machine.vm.id} --resource-port 5901 --port 55901"
}

# VNC clients should connect with host::port syntax (double colon means TCP port).
output "vnc_client_target" {
  value = "localhost::55901"
}

output "bastion_aad_ssh_cmd" {
  value = "az network bastion ssh --name ${azurerm_bastion_host.bastion.name} --resource-group ${azurerm_resource_group.rg.name} --target-resource-id ${azurerm_linux_virtual_machine.vm.id} --auth-type AAD"
}
