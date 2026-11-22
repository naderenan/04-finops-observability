# PROJECT 4 AUTOPILOT: deploy (Grafana/Prometheus locked to your IP) -> run the FinOps
# scanner -> capture evidence -> (Claude screenshots Grafana + writes docs) -> push ->
# destroy until clean. Waits for Claude's fixes on failure (.autopilot\retry).
# SAFETY: auto-destroy 3 h after start no matter what.
$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "portfolio-sandbox"; $env:AWS_REGION = "us-east-1"
$root  = Split-Path -Parent $PSScriptRoot
$flags = Join-Path $root ".autopilot"; $out = Join-Path $root "out"
New-Item -ItemType Directory -Force $flags, $out | Out-Null
$deadline = (Get-Date).AddHours(3)
function Status($s) { "$(Get-Date -Format s) $s" | Out-File -Append -Encoding utf8 (Join-Path $flags "status.txt"); Write-Host "`n>>> $s" -ForegroundColor Cyan }
function Run($file, [string]$title, [scriptblock]$sb) {
  $f = Join-Path $out $file
  "`n$ $title" | Out-File -Append -Encoding utf8 $f
  & $sb 2>&1 | ForEach-Object { $l = "$_"; $l | Out-File -Append -Encoding utf8 $f; $l } | Out-Host
}
function Flag($n) { $p = Join-Path $flags $n; if (Test-Path $p) { Remove-Item $p -Force; return $true }; return $false }
Set-Location (Join-Path $root "terraform")
$myip = (Invoke-RestMethod "https://checkip.amazonaws.com").Trim()
$cidr = "-var=admin_cidr=$myip/32"
Status "started (dashboards will be reachable only from $myip)"

$deployed = $false
while (-not $deployed -and (Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $flags "destroy"))) {
  Run "deploy.txt" "terraform init" { terraform init -input=false -no-color }
  Run "deploy.txt" "terraform validate" { terraform validate -no-color }
  Run "deploy.txt" "terraform apply" { terraform apply -auto-approve -input=false -no-color $cidr; "TF_EXIT=$LASTEXITCODE" }
  $c = Get-Content (Join-Path $out "deploy.txt") -Raw
  if ($c.Substring([Math]::Max(0,$c.Length-200)) -match "TF_EXIT=0") { $deployed = $true; Status "deployed" }
  else {
    Status "FAILED: terraform apply - waiting for Claude's fix (.autopilot\retry)"
    while (-not (Flag "retry") -and (Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $flags "destroy"))) { Start-Sleep 20 }
    Status "retrying"
  }
}

if ($deployed) {
  Run "tf-outputs.txt" "terraform output" { terraform output -no-color }
  $g = (terraform output -raw grafana_url); $p = (terraform output -raw prometheus_url); $fn = (terraform output -raw scanner_function)
  Status "waiting for Grafana + Prometheus to come up"
  for ($i=0; $i -lt 60; $i++) { try { $h = Invoke-RestMethod "$g/api/health" -TimeoutSec 5; if ($h.database -eq "ok") { break } } catch {}; Start-Sleep 15 }
  # Run the scanner now (it also runs daily on schedule)
  Run "01-scanner.txt" "aws lambda invoke $fn (FinOps scan)" { aws lambda invoke --function-name $fn --cli-binary-format raw-in-base64-out --payload "{}" "$out\scan-result.json" --query "{status:StatusCode,error:FunctionError}" --output yaml; Get-Content "$out\scan-result.json" }
  Start-Sleep 90
  Run "02-metrics.txt" "aws cloudwatch get-metric-data (namespace FinOps)" {
    $q = @("EstimatedMonthlyWasteUSD","UnattachedEBSVolumes","IdleElasticIPs","Gp2Volumes","RightsizeCandidates","SpotCandidates","Gp3SavingsUSD") | ForEach-Object -Begin {$n=0} -Process { $n++; @{Id="m$n";Label=$_;MetricStat=@{Metric=@{Namespace="FinOps";MetricName=$_;Dimensions=@(@{Name="Scanner";Value="finops-obs"})};Period=60;Stat="Maximum"}} }
    $q | ConvertTo-Json -Depth 8 | Out-File -Encoding ascii "$out\q.json"
    $end = (Get-Date).ToUniversalTime(); $st = $end.AddMinutes(-30)
    aws cloudwatch get-metric-data --metric-data-queries "file://$out\q.json" --start-time $st.ToString("s") --end-time $end.ToString("s") --query "MetricDataResults[].{metric:Label,latest:Values[0]}" --output table
  }
  Run "02-metrics.txt" "aws cloudwatch describe-alarms (FinOps)" { aws cloudwatch describe-alarms --alarm-name-prefix finops-obs --query "MetricAlarms[].{alarm:AlarmName,state:StateValue,threshold:Threshold,metric:MetricName}" --output table }
  Run "03-prometheus.txt" "curl $p/api/v1/targets (scrape health)" { (Invoke-RestMethod "$p/api/v1/targets").data.activeTargets | ForEach-Object { "{0,-14} {1,-6} {2}" -f $_.labels.job, $_.health, $_.scrapeUrl } }
  Run "03-prometheus.txt" "curl $p/api/v1/rules (alert rules)" { (Invoke-RestMethod "$p/api/v1/rules").data.groups | ForEach-Object { $grp = $_.name; $_.rules | ForEach-Object { "{0,-20} {1,-28} {2}" -f $grp, $_.name, $_.state } } }
  Run "04-budget.txt" "aws budgets describe-budget" { $acct = aws sts get-caller-identity --query Account --output text; aws budgets describe-budget --account-id $acct --budget-name finops-obs-monthly --query "Budget.{name:BudgetName,limit:BudgetLimit.Amount,unit:BudgetLimit.Unit,period:TimeUnit,actualSpend:CalculatedSpend.ActualSpend.Amount,forecast:CalculatedSpend.ForecastedSpend.Amount}" --output yaml; aws budgets describe-notifications-for-budget --account-id $acct --budget-name finops-obs-monthly --query "Notifications[].{type:NotificationType,threshold:Threshold,unit:ThresholdType}" --output table }
  Run "04-budget.txt" "monitor host hardening" { aws ec2 describe-instances --instance-ids (terraform output -raw monitor_instance_id) --query "Reservations[].Instances[].{type:InstanceType,keyPair:KeyName,imds:MetadataOptions.HttpTokens,hopLimit:MetadataOptions.HttpPutResponseHopLimit}" --output table; aws ec2 describe-security-group-rules --filters "Name=tag:Project,Values=finops-obs" --query "SecurityGroupRules[?IsEgress==``false``].{port:FromPort,source:CidrIpv4,desc:Description}" --output table }
  Status "captured - Grafana ready for screenshots at $g"
}

while (-not (Test-Path (Join-Path $flags "destroy")) -and (Get-Date) -lt $deadline) { Start-Sleep 20 }
Status "destroying"
$dEnd = (Get-Date).AddHours(10); $attempt = 0
while ((Get-Date) -lt $dEnd) {
  $attempt++
  Run "destroy.txt" "destroy attempt $attempt" { & (Join-Path $PSScriptRoot "destroy-step.ps1") -Attempt $attempt -CidrVar $cidr }
  $ec2 = aws ec2 describe-instances --filters "Name=tag:Project,Values=finops-obs" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text 2>$null
  $eip = aws ec2 describe-addresses --filters "Name=tag:Project,Values=finops-obs" --query "Addresses[].AllocationId" --output text 2>$null
  $vol = aws ec2 describe-volumes --filters "Name=tag:Project,Values=finops-obs" --query "Volumes[].VolumeId" --output text 2>$null
  $lam = aws lambda list-functions --query "Functions[?FunctionName=='finops-obs-scanner'].FunctionName" --output text 2>$null
  $vpc = aws ec2 describe-vpcs --filters "Name=tag:Project,Values=finops-obs" --query "Vpcs[].VpcId" --output text 2>$null
  $acct = aws sts get-caller-identity --query Account --output text
  $bud = aws budgets describe-budgets --account-id $acct --query "Budgets[?BudgetName=='finops-obs-monthly'].BudgetName" --output text 2>$null
  Run "destroy.txt" "audit" { "EC2: [$ec2]  EIP: [$eip]  EBS: [$vol]  Lambda: [$lam]  VPC: [$vpc]  Budget: [$bud]" }
  if (-not $ec2 -and -not $eip -and -not $vol -and -not $lam -and -not $vpc -and -not $bud) { Status "CLEAN: Destroyed & Clean"; break }
  Start-Sleep 120
}
Status "finished"
Write-Host "`nAUTOPILOT FINISHED." -ForegroundColor Green
