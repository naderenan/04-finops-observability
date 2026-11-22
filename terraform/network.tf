resource "aws_vpc" "this" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.50.0.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_default_security_group" "lockdown" {
  vpc_id = aws_vpc.this.id # no rules = deny all
}

resource "aws_security_group" "monitor" {
  name        = "${local.name}-monitor"
  description = "Grafana/Prometheus from the admin IP only. No SSH (SSM only)."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-monitor" }
}

resource "aws_vpc_security_group_ingress_rule" "grafana" {
  security_group_id = aws_security_group.monitor.id
  description       = "Grafana from admin IP"
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_ingress_rule" "prometheus" {
  security_group_id = aws_security_group.monitor.id
  description       = "Prometheus from admin IP"
  ip_protocol       = "tcp"
  from_port         = 9090
  to_port           = 9090
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_egress_rule" "out" {
  security_group_id = aws_security_group.monitor.id
  description       = "HTTPS/HTTP out (images, AWS APIs)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
