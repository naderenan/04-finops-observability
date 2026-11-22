variable "project_name" {
  type    = string
  default = "finops-obs"
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "aws_profile" {
  type    = string
  default = "portfolio-sandbox"
}
variable "admin_cidr" {
  description = "Only this CIDR (your IP /32) can open Grafana (3000) and Prometheus (9090)."
  type        = string
}
variable "alert_email" {
  description = "Receives budget alerts and FinOps findings (SNS asks you to confirm once)."
  type        = string
}
variable "monthly_budget_usd" {
  type    = number
  default = 10
}
variable "monitor_instance_type" {
  description = "t3.small is free-tier eligible (works on AWS Free-plan accounts)."
  type        = string
  default     = "t3.small"
}
variable "create_demo_waste" {
  description = "Create a small unattached gp2 volume and an idle Elastic IP so the scanner has real findings to report."
  type        = bool
  default     = true
}
variable "idle_cpu_threshold" {
  description = "Average CPU % (24 h) below which a running instance is a right-sizing candidate."
  type        = number
  default     = 10
}
