provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "portfolio"
      ManagedBy   = "terraform"
      Repository  = "04-finops-observability"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = var.project_name
  az   = data.aws_availability_zones.available.names[0]
}
