terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  # Bucket name is passed at init time with -backend-config
  backend "s3" {
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-eks-terraform-pipeline"
      Owner       = "gavinbarbee"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
