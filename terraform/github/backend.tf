terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }

  # This root owns one global CI identity, not one identity per environment.
  # The standard AWS credential chain supports both AWS_PROFILE=ctech on a
  # workstation and short-lived OIDC credentials in automation.
  backend "s3" {
    bucket       = "prod-ctech-terraform-state"
    key          = "lbalancer/github/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ctech-lbalancer"
      ManagedBy = "terraform"
      Scope     = "global"
    }
  }
}
