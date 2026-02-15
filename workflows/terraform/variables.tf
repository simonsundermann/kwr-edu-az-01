variable "location" {
  type    = string
  default = "germanywestcentral"
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
  default = "Standard_D4s_v5"
  #default = "Standard_NC4as_T4_v3"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}