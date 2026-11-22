# One destroy attempt for Project 4 (Claude may edit this between attempts).
param([int]$Attempt = 1, [string]$CidrVar = "-var=admin_cidr=127.0.0.1/32")
$root = Split-Path -Parent $PSScriptRoot
$fl = Join-Path $root ".autopilot"; $od = Join-Path $root "out"; $fp = Join-Path $fl "final-push"
$env:AWS_PROFILE = "portfolio-sandbox"; $env:AWS_REGION = "us-east-1"
# Pre-destroy control loop (attempt 1 only, up to 60 min): reapply / rescan until docs are ready.
for ($i=0; $i -lt 240 -and $Attempt -eq 1 -and -not (Test-Path $fp); $i++) {
  if (Test-Path "$fl\reapply") {
    Remove-Item "$fl\reapply" -Force; Set-Location (Join-Path $root "terraform")
    terraform apply -auto-approve -input=false -no-color $CidrVar 2>&1 | ForEach-Object { "$_" } | Out-File -Encoding utf8 "$od\reapply.txt"
    "reapply done (exit $LASTEXITCODE)" | Out-File -Append -Encoding utf8 "$fl\status.txt"
  }
  if (Test-Path "$fl\rescan") {
    Remove-Item "$fl\rescan" -Force
    aws lambda invoke --function-name finops-obs-scanner --cli-binary-format raw-in-base64-out --payload "{}" "$od\scan-result-2.json" 2>&1 | Out-Null
    "rescan done" | Out-File -Append -Encoding utf8 "$fl\status.txt"
  }
  Start-Sleep 15
}
if (Test-Path $fp) {
  Remove-Item $fp -Force; Set-Location $root
  $env:GCM_INTERACTIVE = "never"; $env:GIT_TERMINAL_PROMPT = "0"
  if (-not (Test-Path .git)) { git init -b main 2>&1 }
  git config user.name "naderenan"; git config user.email "naderenan@users.noreply.github.com"
  git add -A 2>&1; git commit -m "FinOps + observability: Prometheus/Grafana, FinOps scanner Lambda, budgets and alarms (Terraform)" 2>&1
  git branch -M main; git remote remove origin 2>$null; git remote add origin "https://github.com/naderenan/04-finops-observability.git"
  git push -u origin main 2>&1
  "FINAL_PUSH_EXIT=$LASTEXITCODE"
}
Set-Location (Join-Path $root "terraform")
terraform destroy -auto-approve -input=false -no-color $CidrVar 2>&1
"TF_EXIT=$LASTEXITCODE"
if ($Attempt -ge 3) {
  "--- force cleanup with AWS CLI ---"
  foreach ($i in (aws ec2 describe-instances --filters "Name=tag:Project,Values=finops-obs" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text) -split "\s+") { if ($i) { aws ec2 terminate-instances --instance-ids $i 2>&1 } }
  foreach ($a in (aws ec2 describe-addresses --filters "Name=tag:Project,Values=finops-obs" --query "Addresses[].AllocationId" --output text) -split "\s+") { if ($a) { aws ec2 release-address --allocation-id $a 2>&1 } }
  foreach ($v in (aws ec2 describe-volumes --filters "Name=tag:Project,Values=finops-obs" "Name=status,Values=available" --query "Volumes[].VolumeId" --output text) -split "\s+") { if ($v) { aws ec2 delete-volume --volume-id $v 2>&1 } }
  aws lambda delete-function --function-name finops-obs-scanner 2>&1
  $acct = aws sts get-caller-identity --query Account --output text; aws budgets delete-budget --account-id $acct --budget-name finops-obs-monthly 2>&1
}
