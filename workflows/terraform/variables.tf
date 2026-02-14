variable "location" {
  type    = string
  default = "westeurope"
}

variable "resource_group_name" {
  type    = string
  default = "rg-gpu-robotics"
}

variable "name_prefix" {
  type    = string
  default = "gpu"
}

variable "vm_size" {
  type    = string
  default = "Standard_NC4as_T4_v3"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  type = string
}