output "grafana_url" {
  value = "http://${aws_instance.monitor.public_ip}:3000"
}
output "prometheus_url" {
  value = "http://${aws_instance.monitor.public_ip}:9090"
}
output "monitor_instance_id" {
  value = aws_instance.monitor.id
}
output "scanner_function" {
  value = aws_lambda_function.scanner.function_name
}
output "grafana_admin_password_parameter" {
  description = "aws ssm get-parameter --with-decryption --name <this>"
  value       = aws_ssm_parameter.grafana_admin.name
}
