"""FinOps scanner: finds common AWS waste, publishes CloudWatch metrics and an SNS summary.

Checks (region-wide, read-only):
  * unattached EBS volumes          -> delete or snapshot
  * gp2 volumes                     -> migrate to gp3 (~20% cheaper, same or better performance)
  * Elastic IPs not associated      -> release ($0.005/hr each)
  * running instances with low CPU  -> right-sizing candidates (CloudWatch, last 24 h)
  * On-Demand instances tagged SpotEligible=true -> Spot candidates
"""
import json
import os
from datetime import datetime, timedelta, timezone

import boto3

ec2 = boto3.client("ec2")
cw = boto3.client("cloudwatch")
sns = boto3.client("sns")

EBS_PRICE = {"gp2": 0.10, "gp3": 0.08, "io1": 0.125, "io2": 0.125, "st1": 0.045, "sc1": 0.015, "standard": 0.05}
EIP_MONTHLY = 0.005 * 730
IDLE_CPU = float(os.environ.get("IDLE_CPU_THRESHOLD", "10"))
SCANNER = os.environ.get("SCANNER_NAME", "finops-obs")


def paginate(method, key, **kw):
    for page in ec2.get_paginator(method).paginate(**kw):
        yield from page[key]


def avg_cpu(instance_id):
    end = datetime.now(timezone.utc)
    pts = cw.get_metric_statistics(
        Namespace="AWS/EC2", MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=end - timedelta(hours=24), EndTime=end, Period=3600, Statistics=["Average"],
    )["Datapoints"]
    return round(sum(p["Average"] for p in pts) / len(pts), 2) if pts else None


def handler(event, context):
    volumes = list(paginate("describe_volumes", "Volumes"))
    unattached = [v for v in volumes if v["State"] == "available"]
    gp2 = [v for v in volumes if v["VolumeType"] == "gp2"]
    eips = ec2.describe_addresses()["Addresses"]
    idle_eips = [a for a in eips if "AssociationId" not in a]

    running = [i for r in paginate("describe_instances", "Reservations",
                                   Filters=[{"Name": "instance-state-name", "Values": ["running"]}])
               for i in r["Instances"]]
    rightsize, spot = [], []
    for i in running:
        cpu = avg_cpu(i["InstanceId"])
        tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
        if cpu is not None and cpu < IDLE_CPU:
            rightsize.append({"id": i["InstanceId"], "type": i["InstanceType"], "avg_cpu_24h": cpu})
        if i.get("InstanceLifecycle") != "spot" and tags.get("SpotEligible") == "true":
            spot.append({"id": i["InstanceId"], "type": i["InstanceType"], "note": "On-Demand, tagged SpotEligible"})

    unattached_cost = sum(v["Size"] * EBS_PRICE.get(v["VolumeType"], 0.1) for v in unattached)
    gp3_savings = sum(v["Size"] * (EBS_PRICE["gp2"] - EBS_PRICE["gp3"]) for v in gp2)
    waste = round(unattached_cost + len(idle_eips) * EIP_MONTHLY, 2)

    findings = {
        "scanned_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unattached_ebs": [{"id": v["VolumeId"], "type": v["VolumeType"], "gib": v["Size"]} for v in unattached],
        "gp2_volumes": [{"id": v["VolumeId"], "gib": v["Size"]} for v in gp2],
        "idle_elastic_ips": [{"ip": a.get("PublicIp"), "allocation": a.get("AllocationId")} for a in idle_eips],
        "rightsize_candidates": rightsize,
        "spot_candidates": spot,
        "estimated_monthly_waste_usd": waste,
        "potential_gp3_savings_usd_month": round(gp3_savings, 2),
    }

    dims = [{"Name": "Scanner", "Value": SCANNER}]
    metrics = {
        "UnattachedEBSVolumes": (len(unattached), "Count"),
        "UnattachedEBSGiB": (sum(v["Size"] for v in unattached), "Gigabytes"),
        "Gp2Volumes": (len(gp2), "Count"),
        "IdleElasticIPs": (len(idle_eips), "Count"),
        "RightsizeCandidates": (len(rightsize), "Count"),
        "SpotCandidates": (len(spot), "Count"),
        "EstimatedMonthlyWasteUSD": (waste, "None"),
        "Gp3SavingsUSD": (round(gp3_savings, 2), "None"),
    }
    cw.put_metric_data(Namespace="FinOps", MetricData=[
        {"MetricName": k, "Dimensions": dims, "Value": float(v), "Unit": u} for k, (v, u) in metrics.items()
    ])

    if os.environ.get("TOPIC_ARN"):
        sns.publish(
            TopicArn=os.environ["TOPIC_ARN"],
            Subject=f"FinOps scan: ~${waste}/month of waste found",
            Message=json.dumps(findings, indent=2),
        )
    print(json.dumps(findings))
    return findings
