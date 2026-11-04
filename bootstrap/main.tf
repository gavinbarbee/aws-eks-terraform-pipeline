terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-eks-terraform-pipeline"
      Owner     = "gavinbarbee"
      ManagedBy = "Terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# The repo has immutable subject claims enabled, so the OIDC sub
# includes owner and repo IDs (owner@id/repo@id), not just the name
variable "github_sub_prefix" {
  type    = string
  default = "repo:gavinbarbee@177060158/aws-eks-terraform-pipeline@1446122516"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Remote state bucket (S3 native locking, no DynamoDB table needed)
resource "aws_s3_bucket" "tfstate" {
  bucket        = "gavinbarbee-eks-tfstate-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# GitHub Actions OIDC federation (no stored AWS keys)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only workflows in this one repo can assume the role
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_sub_prefix}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "role-gavinbarbee-github-actions-eks"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# Lab scope: broad rights so Terraform can create VPC, EKS, IAM, and ECR.
# Production would scope this to the exact services and resources.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
