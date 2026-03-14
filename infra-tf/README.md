# Terraform Infrastructure

This folder contains all Terraform code to deploy the demo infrastructure. A single `terraform apply` creates the full environment — EKS cluster, hybrid nodes, networking, and all required cluster components.

```
infra-tf/
├── cluster-stack.tf   — EKS cluster, VPC, hybrid node IAM role
├── remote-stack.tf    — Remote VPC, hybrid EC2 nodes, VPC peering, SSM activation
├── k8s-apply.tf       — Helm releases and Kubernetes manifests applied post-cluster
├── variables.tf       — Input variables and defaults
└── manifests/         — YAML templates for K8s resources (Cilium, GPU Operator, NodeClass, NodePool)
```

---

### cluster-stack.tf

```
# Cluster VPC
module.vpc
  ├── VPC (10.226.0.0/24)
  ├── Public Subnets  x2 (us-west-2a, us-west-2b)
  ├── Private Subnets x2 (us-west-2a, us-west-2b)
  ├── Internet Gateway
  └── NAT Gateway x1 (single)

# EKS Cluster
module.eks
  ├── EKS Cluster (Auto Mode, v1.34)
  │   ├── Node Pools: system, general-purpose
  │   ├── Addons: coredns, kube-proxy (pinned to hybrid nodes)
  │   ├── Hybrid Remote Node Network: 172.17.0.0/16
  │   ├── Hybrid Remote Pod Network:  172.18.0.0/16
  │   └── EKS Access Entry: hybrid-node-role (HYBRID_LINUX)
  └── IAM Roles (cluster role, node role — managed by EKS module)

# Hybrid Node IAM Role
aws_iam_role.hybrid_node
  ├── IAM Role (hybrid-llm-hybrid-node-role)
  ├── Trust Policy: ssm.amazonaws.com
  ├── AmazonSSMManagedInstanceCore
  ├── AmazonEC2ContainerRegistryPullOnly
  └── Inline Policy: EKSHybridNodePolicy
      ├── eks:DescribeCluster, eks:ListAccessEntries
      ├── ssm:DeregisterManagedInstance, ssm:DescribeInstanceInformation
      └── eks-auth:AssumeRoleForPodIdentity

# Outputs
configure_kubectl, cluster_name, cluster_vpc_id, cluster_vpc_cidr
cluster_endpoint, node_security_group_id, node_iam_role_arn
private_subnet_ids, hybrid_node_role_arn
```

---

### remote-stack.tf

```
# Remote VPC (simulates on-prem network)
module.remote_vpc
  ├── VPC (172.17.0.0/16)
  ├── Public Subnets x2 (us-west-2a, us-west-2b)
  └── Internet Gateway

# Security Group
aws_security_group.remote_node_sg
  ├── Ingress: all traffic from self
  ├── Ingress: all traffic from cluster VPC (10.226.0.0/24)
  ├── Ingress: SSH 22 (0.0.0.0/0)
  ├── Ingress: Open WebUI NodePort 30080 (var.model_ui_allowed_cidr)
  └── Egress:  all

# Hybrid Node EC2
aws_launch_template.hybrid_node
  ├── AMI: Ubuntu 24.04 (latest)
  ├── Volume: 100GB gp3
  ├── UserData: nodeadm install + EKS hybrid node registration via SSM
  └── Instance types (mixed): g5.2xlarge, g6.2xlarge, g6e.2xlarge

aws_autoscaling_group.hybrid_node
  ├── Desired/Max: var.hybrid_node_count (default: 1)
  ├── Min: 0
  └── Subnets: remote public subnets

# VPC Peering
aws_vpc_peering_connection.cluster_to_remote
  ├── aws_route.cluster_public_to_remote   (cluster public  → 172.17.0.0/16)
  ├── aws_route.cluster_private_to_remote  (cluster private → 172.17.0.0/16)
  ├── aws_route.cluster_private_to_pod_cidr (cluster private → 172.18.0.0/16)
  ├── aws_route.cluster_public_to_pod_cidr  (cluster public  → 172.18.0.0/16)
  └── aws_route.remote_to_cluster          (remote public   → 10.226.0.0/24)

# SSM Hybrid Activation
aws_ssm_activation.hybrid_nodes
  ├── IAM Role: hybrid_node
  ├── Registration Limit: var.ssm_registration_limit (default: 10)
  └── Expiry: 30 days

# Outputs
remote_vpc_id, peering_connection_id
ssm_activation_id, ssm_activation_code
hybrid_node_asg_name, nodeconfig_cmd, list_hybrid_nodes_cmd
```

---

### k8s-apply.tf

```
# Cilium CNI (Helm)
helm_release.cilium
  ├── Chart: cilium/cilium v1.15.6
  ├── Namespace: kube-system
  ├── Affinity: hybrid nodes only
  └── IPAM: cluster-pool (172.18.0.0/16)

# NVIDIA GPU Operator (Helm)
helm_release.gpu_operator
  ├── Chart: nvidia/gpu-operator
  ├── Namespace: gpu-operator
  ├── Affinity: hybrid nodes only
  ├── Driver:        enabled (580.126.16)
  ├── Toolkit:       enabled
  └── Device Plugin: enabled

# GPU NodeClass + NodePool (EKS Auto Mode)
kubectl_manifest.gpu_nodeclass
  ├── NodeClass: gpu-nodeclass
  ├── Subnets: cluster private subnets
  └── Security Groups: node_security_group_id, cluster_primary_security_group_id

kubectl_manifest.gpu_nodepool
  └── NodePool: gpu-nodepool (references gpu-nodeclass)

# ALB IngressClass
kubectl_manifest.alb_ingressclassparams
kubectl_manifest.alb_ingressclass
  └── IngressClass: alb (AWS Load Balancer Controller)
```

---

### variables.tf

| Variable | Default | Description |
|---|---|---|
| `kubernetes_version` | `1.34` | EKS and nodeadm version |
| `project_name` | `hybrid-llm` | Prefix for all resource names |
| `aws_region` | `us-west-2` | Deployment region |
| `cluster_vpc_cidr` | `10.226.0.0/24` | Cluster VPC CIDR |
| `remote_node_cidr` | `172.17.0.0/16` | Hybrid node network CIDR |
| `remote_pod_cidr` | `172.18.0.0/16` | Hybrid pod network CIDR |
| `hybrid_node_ami` | Ubuntu 24.04 | AMI filter for hybrid nodes |
| `hybrid_node_volume_size` | `100` | Root volume size (GB) |
| `hybrid_node_count` | `1` | Number of hybrid nodes |
| `ssm_registration_limit` | `10` | Max SSM hybrid node registrations |
| `key_pair_name` | `key-us-west-2` | EC2 key pair for SSH access |
| `model_ui_allowed_cidr` | — | CIDR allowed to access WebUI on port 30080 |
