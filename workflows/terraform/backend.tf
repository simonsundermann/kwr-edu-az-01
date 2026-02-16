terraform {
  backend "azurerm" {
    resource_group_name  = "rg-mgmt-tfstate"
    storage_account_name = "mgmttfstate"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
    use_oidc             = true
  }
  
}
