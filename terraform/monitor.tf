################################################################################
# Monitoring host: Prometheus + Grafana + node-exporter (Docker Compose).
# No SSH key, no port 22 (SSM only). Grafana/Prometheus reachable from the admin
# IP only. Grafana reads CloudWatch with the instance role (no keys).
################################################################################
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "grafana_admin" {
  name  = "/${local.name}/grafana/admin-password"
  type  = "SecureString"
  value = random_password.grafana_admin.result
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitor" {
  name               = "${local.name}-monitor"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "monitor_ssm" {
  role       = aws_iam_role.monitor.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "monitor" {
  statement {
    sid       = "GrafanaCloudWatchReadOnly"
    actions   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "cloudwatch:DescribeAlarms", "cloudwatch:GetMetricStatistics", "ec2:DescribeRegions", "ec2:DescribeInstances", "tag:GetResources"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadGrafanaAdminPassword"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.grafana_admin.arn]
  }
}

resource "aws_iam_role_policy" "monitor" {
  name   = "grafana-cloudwatch-read"
  role   = aws_iam_role.monitor.id
  policy = data.aws_iam_policy_document.monitor.json
}

resource "aws_iam_instance_profile" "monitor" {
  name = "${local.name}-monitor"
  role = aws_iam_role.monitor.name
}

locals {
  monitoring_files = {
    "docker-compose.yml"                                     = "${path.module}/monitoring/docker-compose.yml"
    "prometheus.yml"                                         = "${path.module}/monitoring/prometheus.yml"
    "alert_rules.yml"                                        = "${path.module}/monitoring/alert_rules.yml"
    "grafana/provisioning/datasources/datasources.yml"       = "${path.module}/monitoring/grafana/provisioning/datasources/datasources.yml"
    "grafana/provisioning/dashboards/dashboards.yml"         = "${path.module}/monitoring/grafana/provisioning/dashboards/dashboards.yml"
    "grafana/dashboards/host-health.json"                    = "${path.module}/monitoring/grafana/dashboards/host-health.json"
    "grafana/dashboards/finops.json"                         = "${path.module}/monitoring/grafana/dashboards/finops.json"
  }
}

resource "aws_instance" "monitor" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.monitor_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.monitor.id]
  iam_instance_profile        = aws_iam_instance_profile.monitor.name
  associate_public_ip_address = true # dashboards reachable from admin IP only (SG)
  # no key_name: SSH is not used

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers need 2 hops to reach IMDSv2 for the instance role
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region      = var.region
    param_name  = aws_ssm_parameter.grafana_admin.name
    files_b64gz = { for k, f in local.monitoring_files : k => base64gzip(file(f)) }
  })

  tags = { Name = "${local.name}-monitor", SpotEligible = "true" }
}
