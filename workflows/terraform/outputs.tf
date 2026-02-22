output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "bastion_name" {
  value = azurerm_bastion_host.bastion.name
}

output "vm_resource_id" {
  value = azurerm_linux_virtual_machine.vm.id
}

output "admin_username" {
  value = var.admin_username
}

# Bootstrap password NICHT ausgeben (sensitiv)
output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

# Windows/Bastion default: local port 53389 avoids collisions with existing local RDP services.
output "bastion_rdp_tunnel_cmd" {
  value = "az network bastion tunnel --name ${azurerm_bastion_host.bastion.name} --resource-group ${azurerm_resource_group.rg.name} --target-resource-id ${azurerm_linux_virtual_machine.vm.id} --resource-port 3389 --port 53389"
}

output "rdp_client_target" {
  value = "127.0.0.1:53389"
}

output "bastion_aad_ssh_cmd" {
  value = "az network bastion ssh --name ${azurerm_bastion_host.bastion.name} --resource-group ${azurerm_resource_group.rg.name} --target-resource-id ${azurerm_linux_virtual_machine.vm.id} --auth-type AAD"
}
