# Workday-GSuite Person Sync - Lambda (Container Image)
# Sensitive data: workdayRptPwd in SSM, Configuration.psd1 in Secrets Manager (64KB limit).
# GitHub Actions builds and pushes the Docker image to ECR.

locals {
  lambda_name = local.name
}

# -----------------------------------------------------------------------------
# ECR Repository for Lambda container image
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "sync" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "sync" {
  repository = aws_ecr_repository.sync.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 2 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 2
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# IAM User for GitHub Actions (ECR push only)
# -----------------------------------------------------------------------------
resource "aws_iam_user" "github_actions" {
  name = "${local.name}-github-actions"
}

resource "aws_iam_user_policy" "github_actions_ecr" {
  name = "ecr-push"
  user = aws_iam_user.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.sync.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "github_actions" {
  user = aws_iam_user.github_actions.name
}

# -----------------------------------------------------------------------------
# SSM Parameter Store - Sensitive values (placeholder; set real values manually in Console/CLI)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "workday_rpt_pwd" {
  name        = var.workday_rpt_pwd_param_name
  description = "Workday report API password for workday-gsuite-person-sync Lambda"
  type        = "SecureString"
  value       = var.workday_rpt_pwd_initial_value

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# Secrets Manager - PSGSuite config (exceeds SSM 8KB limit)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "psgsuite_config" {
  name        = var.psgsuite_config_secret_name
  description = "PSGSuite Configuration.psd1 content for workday-gsuite-person-sync Lambda"
}

resource "aws_secretsmanager_secret_version" "psgsuite_config" {
  secret_id     = aws_secretsmanager_secret.psgsuite_config.id
  secret_string = var.psgsuite_config_initial_value

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Lambda
# -----------------------------------------------------------------------------
resource "aws_iam_role" "lambda" {
  name = "${local.lambda_name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.lambda_name}-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_name}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [aws_ssm_parameter.workday_rpt_pwd.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.psgsuite_config.arn]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group with 14-day retention (valid values: 0,1,3,5,7,14,30,...)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days  = 14
}

# -----------------------------------------------------------------------------
# Lambda Function (Container Image)
# Handler fetches SSM params, writes config to /config/Configuration.psd1, runs sync.ps1
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "sync" {
  function_name = local.lambda_name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"

  depends_on = [aws_cloudwatch_log_group.lambda]
  image_uri     = "${aws_ecr_repository.sync.repository_url}:${var.lambda_image_tag}"
  timeout       = var.lambda_timeout_seconds
  memory_size   = var.lambda_memory_mb

  environment {
    variables = {
      WORKDAY_RPT_PWD_PARAM_NAME   = aws_ssm_parameter.workday_rpt_pwd.name
      PSGSUITE_CONFIG_SECRET_NAME = aws_secretsmanager_secret.psgsuite_config.name
      workdayRptUsr              = var.workday_rpt_usr
      workdayRptUri              = var.workday_rpt_uri
      failsafeRecordChangeLimit  = tostring(var.failsafe_record_change_limit)
    }
  }
}

# -----------------------------------------------------------------------------
# EventBridge Schedule
# -----------------------------------------------------------------------------
# Weekdays 12-23 UTC, every 15 minutes
resource "aws_cloudwatch_event_rule" "schedule_weekdays" {
  name                = "${local.lambda_name}-schedule"
  description         = "Trigger Workday-GSuite sync (weekday business hours)"
  schedule_expression = "cron(15,30,45 12-23 ? * MON-FRI *)"
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.schedule_weekdays.name
  target_id = "SyncLambdaWeekday"
  arn       = aws_lambda_function.sync.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowExecutionFromEventBridgeWeekday"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule_weekdays.arn
}

# Hourly, every day
resource "aws_cloudwatch_event_rule" "schedule_hourly" {
  name                = "${local.lambda_name}-schedule-hourly"
  description         = "Trigger Workday-GSuite sync (hourly)"
  schedule_expression = "cron(0 * * * ? *)"
}

resource "aws_cloudwatch_event_target" "lambda_hourly" {
  rule      = aws_cloudwatch_event_rule.schedule_hourly.name
  target_id = "SyncLambdaHourly"
  arn       = aws_lambda_function.sync.arn
}

resource "aws_lambda_permission" "events_hourly" {
  statement_id  = "AllowExecutionFromEventBridgeHourly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule_hourly.arn
}
