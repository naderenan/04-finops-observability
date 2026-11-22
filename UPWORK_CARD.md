# Upwork Portfolio Card: Project 4

## Title (<= 70 chars)
AWS FinOps & Observability: Prometheus, Grafana, Cost Waste Scanner

## Role
AWS DevOps / FinOps Engineer

## Project Description (<= 600 chars, filled in after the live run)
Terraform-built FinOps and observability stack on AWS. Prometheus, node-exporter and Grafana on a hardened EC2 host with SSM, IMDSv2 and admin-IP-only access. A scheduled Lambda finds cost waste: unattached EBS, gp2 volumes, idle Elastic IPs, low-CPU instances and Spot candidates. It publishes the findings to CloudWatch, a Grafana dashboard, alarms and SNS, backed by an AWS Budget. In the verified run it found $3.75/month of waste, and Prometheus fired a right-sizing alert at 1% CPU. Destroyed with a zero-cost audit.

## Skills (Upwork max 5)
- Grafana
- Prometheus
- Terraform
- AWS Lambda
- Amazon Web Services

## Project URL
https://github.com/naderenan/04-finops-observability

## Media to upload (in order)
1. architecture.png
2. screenshots/01-grafana-finops.png
3. screenshots/02-grafana-host.png
4. screenshots/03-scanner-findings.png
5. screenshots/04-prometheus-rightsize-alert.png
6. screenshots/05-alarms-budget-access.png
