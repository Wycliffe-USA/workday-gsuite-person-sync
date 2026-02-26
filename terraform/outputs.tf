output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.sync.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.sync.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Lambda container image (used by GitHub Actions)"
  value       = aws_ecr_repository.sync.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.sync.name
}

output "workday_rpt_pwd_param_name" {
  description = "SSM parameter name for Workday password (set real value in AWS Console)"
  value       = aws_ssm_parameter.workday_rpt_pwd.name
}

output "psgsuite_config_param_name" {
  description = "SSM parameter name for PSGSuite config (set real value in AWS Console)"
  value       = aws_ssm_parameter.psgsuite_config.name
}

# -----------------------------------------------------------------------------
# GitHub Actions credentials - add these as GitHub repo secrets (Settings → Secrets)
# -----------------------------------------------------------------------------
output "github_actions_aws_access_key_id" {
  description = "AWS Access Key ID for GitHub Actions. Add as repo secret AWS_ACCESS_KEY_ID."
  value       = aws_iam_access_key.github_actions.id
}

output "github_actions_aws_secret_access_key" {
  description = "AWS Secret Access Key for GitHub Actions. Add as repo secret AWS_SECRET_ACCESS_KEY."
  value       = aws_iam_access_key.github_actions.secret
  sensitive   = true
}
