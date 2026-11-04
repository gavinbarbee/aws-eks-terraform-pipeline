module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "vpc-gavinbarbee-eks"
  cidr = "10.0.0.0/16"

  # Pinned by zone ID because zone names map to different physical zones
  # per account; both IDs support EKS control planes
  azs             = ["use1-az1", "use1-az2"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # One NAT gateway keeps lab cost down; production uses one per AZ
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Tags Kubernetes uses to find subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
