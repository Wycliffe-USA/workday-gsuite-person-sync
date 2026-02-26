# Workday-GSuite Person Sync – Lambda (Terraform)

Deploy the Workday-GSuite sync as an **AWS Lambda function** using a **Docker container image**. Sensitive data (Workday password, PSGSuite Configuration.psd1) is stored in **SSM Parameter Store** (SecureString) and fetched at runtime. **GitHub Actions** builds the image and pushes it to ECR.

## Architecture

- **Lambda** – Container image (PowerShell + PSGSuite + sync scripts)
- **ECR** – Container image repository
- **SSM Parameter Store** – `workdayRptPwd` and full `Configuration.psd1` content (SecureString)
- **EventBridge** – Optional scheduled runs (set `schedule_cron`)

## Bootstrap order (first-time setup)

The Lambda function requires an existing container image in ECR. Use this order:

1. **Create ECR repository only**:
   ```bash
   cd terraform
   terraform init
   terraform apply --target=aws_ecr_repository.sync --target=aws_ecr_lifecycle_policy.sync
   ```

2. **Create GitHub Actions IAM user and get credentials**:
   ```bash
   terraform apply --target=aws_iam_user.github_actions --target=aws_iam_user_policy.github_actions_ecr --target=aws_iam_access_key.github_actions
   terraform output github_actions_aws_access_key_id
   terraform output -raw github_actions_aws_secret_access_key  # Add to GitHub as AWS_SECRET_ACCESS_KEY
   ```
   Add both values as GitHub repo secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).

3. **Build and push the image** – Run the GitHub Actions workflow manually (Actions → Build and Push to ECR → Run workflow), or push to `main`/`master` after configuring secrets.

4. **Complete Terraform apply**:
   ```bash
   terraform apply
   ```

5. **Set real SSM values** in AWS Console (Parameter Store):
   - Update `/workday-gsuite-person-sync/workday-rpt-pwd` with the real Workday password
   - Update `/workday-gsuite-person-sync/psgsuite-config` with the full contents of your `config/Configuration.psd1` file

## GitHub Actions setup

Terraform creates a dedicated IAM user (`<app>-github-actions`) with ECR push access. Add the outputs as **repository secrets** (Settings → Secrets and variables → Actions):

- `AWS_ACCESS_KEY_ID` – from `terraform output github_actions_aws_access_key_id`
- `AWS_SECRET_ACCESS_KEY` – from `terraform output -raw github_actions_aws_secret_access_key` (sensitive)

Optional **repository variables**:

- `AWS_REGION` (default: `us-east-1`)
- `ECR_REPOSITORY_NAME` (default: `workday-gsuite-person-sync-prod`, must match Terraform `app_name` + `app_env`)

## Terraform variables

| Variable | Description | Default |
|----------|-------------|--------|
| `workday_rpt_usr` | Workday report API user | `ISU_gSuite_Sync_USA` |
| `workday_rpt_uri` | Workday report JSON endpoint URL | (see variables.tf) |
| `failsafe_record_change_limit` | Max record changes per run | `5` |
| `workday_rpt_pwd_param_name` | SSM parameter name for password | `/workday-gsuite-person-sync/workday-rpt-pwd` |
| `workday_rpt_pwd_initial_value` | Initial SSM value (change in Console) | `PLACEHOLDER_CHANGE_ME` |
| `psgsuite_config_param_name` | SSM parameter for Configuration.psd1 content | `/workday-gsuite-person-sync/psgsuite-config` |
| `psgsuite_config_initial_value` | Initial SSM value (change in Console) | Placeholder |
| `lambda_image_tag` | Docker image tag | `latest` |
| `lambda_timeout_seconds` | Lambda timeout (max 900) | `900` |
| `lambda_memory_mb` | Lambda memory (MB) | `1024` |
| `schedule_cron` | EventBridge cron (e.g. `cron(0 12 * * ? *)`) | `""` (disabled) |

## Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Outputs

- `lambda_function_name` – Invoke this to run the sync manually
- `lambda_function_arn` – ARN of the function
- `ecr_repository_url` – ECR URL (used by GitHub Actions)
- `workday_rpt_pwd_param_name` – SSM parameter for password
- `psgsuite_config_param_name` – SSM parameter for PSGSuite config
- `github_actions_aws_access_key_id` – Use as GitHub secret `AWS_ACCESS_KEY_ID`
- `github_actions_aws_secret_access_key` – Use as GitHub secret `AWS_SECRET_ACCESS_KEY` (sensitive)

## Manual run

```bash
aws lambda invoke --function-name <lambda_function_name> --log-type Tail response.json
cat response.json
```
