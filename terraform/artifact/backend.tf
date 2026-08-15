terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "prod-ctech-terraform-state"
    key          = "lbalancer/artifact/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    profile      = "ctech"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "ctech"
}
