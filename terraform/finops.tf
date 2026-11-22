################################################################################
# FinOps: scanner Lambda (daily), CloudWatch metrics + alarms, SNS, budget.
################################################################################
resource "aws_sns_topic" "finops" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.finops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "archive_file" "scanner" {
  type        = "zip"
  source_file = "${path.module}/lambda/finops_scanner.py"
  output_path = "${path.module}/build/finops_scanner.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scanner" {
  name               = "${local.name}-scanner"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "scanner_logs" {
  role       = aws_iam_role.scanner.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "scanner" {
  statement {
    sid       = "ReadOnlyInventory"
    actions   = ["ec2:DescribeVolumes", "ec2:DescribeAddresses", "ec2:DescribeInstances", "cloudwatch:GetMetricStatistics"]
    resources = ["*"]
  }
  statement {
    sid       = "PublishFinOpsMetricsOnly"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["FinOps"]
    }
  }
  statement {
    sid       = "NotifyFinOpsTopic"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.finops.arn]
  }
}

resource "aws_iam_role_policy" "scanner" {
  name   = "finops-scanner"
  role   = aws_iam_role.scanner.id
  policy = data.aws_iam_policy_document.scanner.json
}

resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/aws/lambda/${local.name}-scanner"
  retention_in_days = 7
}

resource "aws_lambda_function" "scanner" {
  function_name    = "${local.name}-scanner"
  role             = aws_iam_role.scanner.arn
  runtime          = "python3.12"
  handler          = "finops_scanner.handler"
  filename         = data.archive_file.scanner.output_path
  source_code_hash = data.archive_file.scanner.output_base64sha256
  timeout          = 60
  memory_size      = 256
  environment {
    variables = {
      TOPIC_ARN          = aws_sns_topic.finops.arn
      IDLE_CPU_THRESHOLD = tostring(var.idle_cpu_threshold)
      SCANNER_NAME       = local.name
    }
  }
  depends_on = [aws_cloudwatch_log_group.scanner]
}

# Daily schedule (EventBridge)
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${local.name}-daily-scan"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "daily" {
  rule = aws_cloudwatch_event_rule.daily.name
  arn  = aws_lambda_function.scanner.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scanner.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}

# Alarms on the scanner's metrics
resource "aws_cloudwatch_metric_alarm" "waste" {
  alarm_name          = "${local.name}-monthly-waste-over-1usd"
  alarm_description   = "FinOps scanner found more than $1/month of avoidable spend"
  namespace           = "FinOps"
  metric_name         = "EstimatedMonthlyWasteUSD"
  dimensions          = { Scanner = local.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.finops.arn]
}

resource "aws_cloudwatch_metric_alarm" "rightsize" {
  alarm_name          = "${local.name}-rightsize-candidate"
  alarm_description   = "Monitoring host averaged under ${var.idle_cpu_threshold}% CPU for 1 hour: consider a smaller instance or Spot"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.monitor.id }
  statistic           = "Average"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.idle_cpu_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.finops.arn]
}

# Budget with actual + forecast alerts
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Deliberate, tiny "waste" so the scanner has something real to find
resource "aws_ebs_volume" "demo_unattached" {
  count             = var.create_demo_waste ? 1 : 0
  availability_zone = local.az
  size              = 1
  type              = "gp2"
  encrypted         = true
  tags              = { Name = "${local.name}-demo-unattached-gp2", Purpose = "finops-demo-waste" }
}

resource "aws_eip" "demo_idle" {
  count  = var.create_demo_waste ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-demo-idle-eip", Purpose = "finops-demo-waste" }
}
