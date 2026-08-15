terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # One Terraform workspace per environment (dev/stage/prod). The S3 backend
  # automatically nests non-default workspaces under "env:/<workspace>/<key>".
  backend "s3" {
    bucket       = "prod-ctech-terraform-state"
    key          = "lbalancer/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    profile      = "ctech"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "ctech"
}
