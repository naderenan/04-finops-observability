# Client Report: FinOps & Observability Stack

**Engagement type:** Cost optimisation + monitoring (IaC)  **Stack:** Terraform, Prometheus, Grafana, AWS Lambda, CloudWatch, SNS, AWS Budgets

## 1. Problem (typical starting point)
Small teams usually discover cloud waste when the bill arrives:
- **Orphaned resources** (unattached volumes, idle Elastic IPs) keep billing silently.
- **Over-provisioned instances** run at single-digit CPU for months.
- **No early warning:** budgets are missing or only alert after the money is spent.
- **Monitoring and cost live in different places**, so nobody connects "idle" with "expensive".

## 2. Solution
- **Prometheus + Grafana** for host metrics, with right-sizing and reliability alert rules, deployed and provisioned as code.
- A **FinOps scanner** (Lambda, daily) that finds unattached EBS, gp2 volumes that should be gp3, idle Elastic IPs, low-CPU instances and Spot candidates, then turns them into **dollar figures**.
- Findings become **CloudWatch metrics on a Grafana dashboard** next to the performance data, plus an **email alert**.
- **AWS Budgets** with actual (80 %) and forecast (100 %) alerts, so overspend is flagged before month end.

## 3. Security
- No SSH; access via SSM. Dashboards allow-listed to the admin IP.
- Scanner is read-only and may only write metrics to its own `FinOps` namespace.
- Grafana uses the instance role (no access keys); its admin password is an SSM SecureString.
- IMDSv2, encrypted disks, deny-all default security group.

## 4. Cost Impact
| | Before | After |
|---|---|---|
| Waste discovery | Monthly bill review | Daily, automatic, in dollars |
| Budget alerts | None / after the fact | 80 % actual + 100 % forecast |
| Right-sizing evidence | Guesswork | CPU/memory alert rules + 24 h CloudWatch averages |
| Run cost of this stack | — | ~$0.035/hr |

## Validation

The stack was deployed to a sandbox AWS account, checked, and destroyed the same day:

- The scanner found every planted waste item (unattached gp2 volume, idle Elastic IP, On-Demand instance marked Spot-eligible). It estimated $3.75/month of waste, published it to CloudWatch and sent an SNS email.
- The waste alarm moved to ALARM. The AWS Budget alerts at 80% actual and 100% forecast spend.
- Prometheus flagged the idle monitor host as a right-sizing candidate after 10 minutes at about 1% CPU. The CloudWatch-based check correctly waited, because it needs 24h of history. Using both gives fast detection plus confirmation before any resize.
- Grafana and Prometheus were reachable only from one admin IP. There is no SSH, IMDSv2 is enforced, and the Grafana admin password lives in SSM Parameter Store.
- Cost while running is about $0.035/hour. After teardown an audit confirmed zero billable resources remained.


*The "before" column describes common patterns, not a specific client. This is a portfolio build deployed to a sandbox account; the "waste" it finds in the demo was created on purpose.*
