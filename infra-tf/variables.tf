variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster and hybrid nodes"
  type        = string
  default     = "1.34"
}


variable "project_name" {
  description = "Name used as prefix for all resources"
  type        = string
  default     = "hybrid-llm"
}

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "cluster_vpc_cidr" {
  description = "CIDR block for the EKS cluster VPC"
  type        = string
  default     = "10.226.0.0/24"
}

variable "remote_node_cidr" {
  description = "CIDR block for the remote (on-prem) node network"
  type        = string
  default     = "172.17.0.0/16"
}

variable "remote_pod_cidr" {
  description = "CIDR block for the remote (on-prem) pod network"
  type        = string
  default     = "172.18.0.0/16"
}

variable "hybrid_node_ami" {
  description = "AMI name filter for hybrid nodes"
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "hybrid_node_volume_size" {
  description = "Root volume size in GB for hybrid nodes"
  type        = number
  default     = 100
}

variable "hybrid_node_count" {
  description = "Number of hybrid node EC2 instances to create"
  type        = number
  default     = 1
}

variable "ssm_registration_limit" {
  description = "Max number of hybrid nodes that can use the SSM activation"
  type        = number
  default     = 10
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access to hybrid nodes"
  type        = string
  default     = "key-us-west-2"
}

variable "model_ui_allowed_cidr" {
  description = "CIDR block allowed to access Open WebUI NodePort on hybrid nodes"
  type        = string
  default     = "71.104.70.16/32"
}
