variable "app_name" {
  description = "The name of this application. Will be used for naming resources."
  type        = string
  default     = "workday-gsuite-person-sync"
}

variable "app_env" {
  description = "Environment for the application stack (dev, test, prod, etc.)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key_id" {
  description = "Access key ID for AWS VPC"
  type        = string
}

variable "aws_secret_access_key" {
  description = "Access key secret for AWS VPC"
  type        = string
}

# Workday sync configuration (passed to Lambda as environment variables)
variable "workday_rpt_usr" {
  description = "Workday report API user (e.g. ISU_gSuite_Sync_USA)"
  type        = string
  default     = "ISU_gSuite_Sync_USA"
}

variable "workday_rpt_uri" {
  description = "Workday report API URI (custom report JSON endpoint)"
  type        = string
  default     = "https://services1.myworkday.com/ccx/service/customreport2/wycliffe/ISU_gSuite_Sync_USA/CRX_-_Workday-gSuite-Sync?format=json"
}

variable "failsafe_record_change_limit" {
  description = "Maximum record changes per run before script exits (safety limit)"
  type        = number
  default     = 5
}

# SSM Parameter Store - sensitive values stored here, fetched at runtime by Lambda
variable "workday_rpt_pwd_param_name" {
  description = "SSM Parameter Store name for Workday report password (SecureString). Create with placeholder; set real value in Console/CLI."
  type        = string
  default     = "/workday-gsuite-person-sync/workday-rpt-pwd"
}

variable "workday_rpt_pwd_initial_value" {
  description = "Initial value for Workday password SSM parameter. Change the real password in AWS Console after first apply."
  type        = string
  default     = "PLACEHOLDER_CHANGE_ME"
  sensitive   = true
}

variable "psgsuite_config_param_name" {
  description = "SSM Parameter Store name for PSGSuite Configuration.psd1 content (SecureString). Create with placeholder; set real value in Console/CLI."
  type        = string
  default     = "/workday-gsuite-person-sync/psgsuite-config"
}

variable "psgsuite_config_initial_value" {
  description = "Initial value for PSGSuite config SSM parameter. Set real Configuration.psd1 content in Console after first apply."
  type        = string
  default     = "# Placeholder - set real Configuration.psd1 content in Console/CLI"
  sensitive   = true
}

# Lambda
variable "lambda_image_tag" {
  description = "Docker image tag to use for Lambda (e.g. latest, or git SHA from CI)"
  type        = string
  default     = "latest"
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout (max 900)"
  type        = number
  default     = 900
}

variable "lambda_memory_mb" {
  description = "Lambda memory in MB"
  type        = number
  default     = 1024
}

variable "schedule_cron" {
  description = "EventBridge schedule expression. Default: daily at 12:00pm UTC."
  type        = string
  default     = "cron(0 12 * * ? *)"
}
