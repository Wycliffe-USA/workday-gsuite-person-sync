locals {
  name = "${var.app_name}-${var.app_env}"

  tags = {
    app_name            = var.app_name
    app_env             = var.app_env
    terraform_managed   = "true"
    terraform_workspace = terraform.workspace
  }
}
