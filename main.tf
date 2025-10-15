provider "aws" {
  region = "us-east-1"
}

# ------------------------------------------------------------
# SNS Topic for Email Notifications
# ------------------------------------------------------------
resource "aws_sns_topic" "lambda_results_topic" {
  name = "lambda_results_topic"
}

# Subscribe your email (check inbox for confirmation link)
resource "aws_sns_topic_subscription" "email_subscriber" {
  topic_arn = aws_sns_topic.lambda_results_topic.arn
  protocol  = "email"
  endpoint  = "jeremy.pumphrey@nih.gov"
}

# ------------------------------------------------------------
# Lambda IAM Role
# ------------------------------------------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow SNS publish for email Lambda
resource "aws_iam_role_policy" "lambda_sns_publish" {
  name = "lambda_sns_publish"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow",
      Action   = ["sns:Publish"],
      Resource = [aws_sns_topic.lambda_results_topic.arn]
    }]
  })
}

# ------------------------------------------------------------
# Package Lambdas
# ------------------------------------------------------------
locals {
  lambdas = {
    lambda1       = "lambda_one.py"
    lambda2       = "lambda_two.py"
    lambda3       = "lambda_three.py"
    email_results = "email_results.py"
  }
}

# Build each lambda into a zip file
resource "archive_file" "lambda_zips" {
  for_each    = local.lambdas
  type        = "zip"
  source_file = "${path.module}/lambdas/${each.value}"
  output_path = "${path.module}/build/${each.key}.zip"
}

# Ensure build folder exists (important on first run)
resource "null_resource" "ensure_build_folder" {
  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/build"
  }
}

resource "aws_lambda_function" "lambda_funcs" {
  for_each = local.lambdas

  function_name    = each.key
  handler          = "${replace(each.value, ".py", "")}.handler"
  runtime          = "python3.13"
  role             = aws_iam_role.lambda_exec_role.arn
  filename         = archive_file.lambda_zips[each.key].output_path
  source_code_hash = archive_file.lambda_zips[each.key].output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.lambda_results_topic.arn
    }
  }

  depends_on = [
    null_resource.ensure_build_folder,
    archive_file.lambda_zips
  ]
}


# ------------------------------------------------------------
# Step Function IAM Role
# ------------------------------------------------------------
resource "aws_iam_role" "sfn_role" {
  name = "stepfunction_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_invoke" {
  role = aws_iam_role.sfn_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow",
      Action   = ["lambda:InvokeFunction"],
      Resource = [for f in aws_lambda_function.lambda_funcs : f.arn]
    }]
  })
}

# ------------------------------------------------------------
# Step Function Definition
# ------------------------------------------------------------
resource "aws_sfn_state_machine" "lambda_flow" {
  name     = "ParallelLambdasStateMachine"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    Comment = "Parallel Lambdas with individual and final email notifications"
    StartAt = "RunAllInParallel"
    States = {
      RunAllInParallel = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "Lambda1"
            States = {
              Lambda1 = {
                Type       = "Task"
                Resource   = aws_lambda_function.lambda_funcs["lambda1"].arn
                ResultPath = "$.Lambda1Result"
                Next       = "EmailResults1"
              }
              EmailResults1 = {
                Type     = "Task"
                Resource = aws_lambda_function.lambda_funcs["email_results"].arn
                Parameters = {
                  "lambdaName" : "lambda1",
                  "result.$" : "$.Lambda1Result"
                }
                End = true
              }
            }
          },
          {
            StartAt = "Lambda2"
            States = {
              Lambda2 = {
                Type       = "Task"
                Resource   = aws_lambda_function.lambda_funcs["lambda2"].arn
                ResultPath = "$.Lambda2Result"
                Next       = "EmailResults2"
              }
              EmailResults2 = {
                Type     = "Task"
                Resource = aws_lambda_function.lambda_funcs["email_results"].arn
                Parameters = {
                  "lambdaName" : "lambda2",
                  "result.$" : "$.Lambda2Result"
                }
                End = true
              }
            }
          },
          {
            StartAt = "Lambda3"
            States = {
              Lambda3 = {
                Type       = "Task"
                Resource   = aws_lambda_function.lambda_funcs["lambda3"].arn
                ResultPath = "$.Lambda3Result"
                Next       = "EmailResults3"
              }
              EmailResults3 = {
                Type     = "Task"
                Resource = aws_lambda_function.lambda_funcs["email_results"].arn
                Parameters = {
                  "lambdaName" : "lambda3",
                  "result.$" : "$.Lambda3Result"
                }
                End = true
              }
            }
          }
        ]
        Next = "FinalEmailResults"
      }

      FinalEmailResults = {
        Type     = "Task"
        Resource = aws_lambda_function.lambda_funcs["email_results"].arn
        Parameters = {
          "lambdaName" : "summary",
          "message" : "All parallel branches have completed successfully."
        }
        End = true
      }
    }
  })
}


# ------------------------------------------------------------
# EventBridge Schedule (Monday 9 AM ET = 13:00 UTC)
# ------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "weekly_trigger" {
  name                = "weekly_stepfunction_trigger"
  schedule_expression = "cron(0 13 ? * MON *)"
}

resource "aws_iam_role" "eventbridge_invoke_role" {
  name = "eventbridge_invoke_sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_policy" {
  role = aws_iam_role.eventbridge_invoke_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow",
      Action   = ["states:StartExecution"],
      Resource = [aws_sfn_state_machine.lambda_flow.arn]
    }]
  })
}

resource "aws_cloudwatch_event_target" "trigger_target" {
  rule     = aws_cloudwatch_event_rule.weekly_trigger.name
  arn      = aws_sfn_state_machine.lambda_flow.arn
  role_arn = aws_iam_role.eventbridge_invoke_role.arn
}

# === Outputs ===

output "lambda_function_names" {
  description = "Names of all deployed Lambda functions"
  value       = [for k, f in aws_lambda_function.lambda_funcs : f.function_name]
}

output "lambda_function_arns" {
  description = "ARNs of all deployed Lambda functions"
  value       = [for k, f in aws_lambda_function.lambda_funcs : f.arn]
}

output "sns_topic_arn" {
  description = "SNS topic ARN for email notifications"
  value       = aws_sns_topic.lambda_results_topic.arn
}

output "sns_subscription_email" {
  description = "Email address subscribed to the SNS topic"
  value       = aws_sns_topic_subscription.email_subscriber.endpoint
}

output "step_function_arn" {
  description = "ARN of the deployed Step Functions state machine"
  value       = aws_sfn_state_machine.lambda_flow.arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule that triggers the state machine"
  value       = aws_cloudwatch_event_rule.weekly_trigger.name
}
