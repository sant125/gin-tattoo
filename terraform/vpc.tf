module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs            = var.availability_zones
  public_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i)]

  map_public_ip_on_launch = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags exigidas pelo EKS/Karpenter para descoberta de subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                             = "1"
    "kubernetes.io/cluster/${local.name_prefix}-cluster" = "owned"
  }

  tags = local.tags
}
