terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.34, < 6.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9"
    }
  }
}

provider "aws" {
  region = local.region
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name    = var.project_name
  region  = var.aws_region

  cluster_version = var.kubernetes_version

  cluster_vpc_cidr = var.cluster_vpc_cidr
  azs              = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project    = local.name
    GithubRepo = "github.com/aws-samples/eks-hybrid-examples"
  }
}

###############################################################
# Cluster VPC
###############################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${local.name}-cluster-vpc"
  cidr = local.cluster_vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.cluster_vpc_cidr, 2, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.cluster_vpc_cidr, 2, k + 2)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}

###############################################################
# EKS Cluster with Auto Mode
###############################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = "${local.name}-eks-cluster"
  cluster_version = local.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  node_security_group_additional_rules = {}

  # Enable EKS Auto Mode
  cluster_compute_config = {
    enabled    = true
    node_pools = ["system", "general-purpose"]
  }

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 1
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [{
                  key      = "eks.amazonaws.com/compute-type"
                  operator = "In"
                  values   = ["hybrid"]
                }]
              }]
            }
          }
        }
      })
    }
    kube-proxy = {
      most_recent = true
    }
  }

  # Remote network config for hybrid nodes
  cluster_remote_network_config = {
    remote_node_networks = {
      cidrs = [var.remote_node_cidr]
    }
    remote_pod_networks = {
      cidrs = [var.remote_pod_cidr]
    }
  }

  # Access entry for hybrid node IAM role
  access_entries = {
    hybrid-node-role = {
      principal_arn = aws_iam_role.hybrid_node.arn
      type          = "HYBRID_LINUX"
    }
  }

  tags = local.tags
}

###############################################################
# Hybrid Node IAM Role (SSM)
###############################################################

resource "aws_iam_role" "hybrid_node" {
  name = "${local.name}-hybrid-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "hybrid_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.hybrid_node.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "hybrid_node" {
  name = "EKSHybridNodePolicy"
  role = aws_iam_role.hybrid_node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListAccessEntries"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:DeregisterManagedInstance", "ssm:DescribeInstanceInformation"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "eks-auth:AssumeRoleForPodIdentity"
        Resource = "*"
      },
    ]
  })
}

###############################################################
# Outputs
###############################################################

output "configure_kubectl" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_vpc_id" {
  value = module.vpc.vpc_id
}

output "cluster_vpc_cidr" {
  value = var.cluster_vpc_cidr
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "node_iam_role_arn" {
  value = module.eks.node_iam_role_arn
}

output "node_iam_role_name" {
  value = module.eks.node_iam_role_name
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "hybrid_node_role_arn" {
  value = aws_iam_role.hybrid_node.arn
}
