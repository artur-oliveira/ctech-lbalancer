terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }

  # One Terraform workspace per environment (dev/stage/prod). The S3 backend
  # automatically nests non-default workspaces under "env:/<workspace>/<key>".
  #
  # No hardcoded profile: like terraform/github, this root relies on the standard
  # AWS credential chain so it works both from a workstation
  # (AWS_PROFILE=ctech terraform ...) and from short-lived OIDC credentials in
  # .github/workflows/lbalancer.yml.
  backend "s3" {
    bucket       = "prod-ctech-terraform-state"
    key          = "lbalancer/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "ctech-lbalancer"
    }
  }
}
