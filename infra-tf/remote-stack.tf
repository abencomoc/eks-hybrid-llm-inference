###############################################################
# Remote VPC simulating on-prem network
###############################################################

module "remote_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${local.name}-remote-vpc"
  cidr = var.remote_node_cidr

  azs            = local.azs
  public_subnets = [for k, v in local.azs : cidrsubnet(var.remote_node_cidr, 8, k)]

  enable_nat_gateway = false
  create_igw         = true

  tags = local.tags
}

###############################################################
# Security Group for remote nodes
###############################################################

resource "aws_security_group" "remote_node_sg" {
  name        = "${local.name}-remote-node-sg"
  description = "Security group for hybrid remote nodes"
  vpc_id      = module.remote_vpc.vpc_id

  ingress {
    description = "Allow all traffic from self"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description = "Allow all traffic from cluster VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.cluster_vpc_cidr]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow Open WebUI NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.model_ui_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

###############################################################
# EC2 Instances simulating hybrid nodes
###############################################################

data "aws_ami" "node_ami" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = [var.hybrid_node_ami]
  }
}

resource "aws_launch_template" "hybrid_node" {
  name_prefix = "${local.name}-hybrid-node-"
  image_id    = data.aws_ami.node_ami.id
  key_name    = var.key_pair_name

  user_data = base64encode(templatefile("${path.module}/scripts/userdata.sh", {
    kubernetes_version  = var.kubernetes_version
    cluster_name        = module.eks.cluster_name
    region              = local.region
    ssm_activation_code = aws_ssm_activation.hybrid_nodes.activation_code
    ssm_activation_id   = aws_ssm_activation.hybrid_nodes.id
  }))
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.hybrid_node_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.remote_node_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-hybrid-node" })
  }

  tags = local.tags
}

resource "aws_autoscaling_group" "hybrid_node" {
  name                = "${local.name}-hybrid-node-asg"
  desired_capacity    = var.hybrid_node_count
  min_size            = 0
  max_size            = var.hybrid_node_count
  vpc_zone_identifier = module.remote_vpc.public_subnets

  mixed_instances_policy {
    instances_distribution {
      on_demand_allocation_strategy = "lowest-price"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.hybrid_node.id
        version            = "$Latest"
      }

      override {
        instance_type = "g5.2xlarge"
      }
      override {
        instance_type = "g6.2xlarge"
      }
      override {
        instance_type = "g6e.2xlarge"
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-hybrid-node"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################
# VPC Peering between cluster VPC and remote VPC
###############################################################

resource "aws_vpc_peering_connection" "cluster_to_remote" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = module.remote_vpc.vpc_id
  auto_accept = true

  tags = merge(local.tags, {
    Name = "${local.name}-cluster-to-remote-peering"
  })
}

# Routes: cluster public subnets -> remote nodes
resource "aws_route" "cluster_public_to_remote" {
  route_table_id            = module.vpc.public_route_table_ids[0]
  destination_cidr_block    = var.remote_node_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_remote.id
}

# Routes: cluster private subnets -> remote nodes
resource "aws_route" "cluster_private_to_remote" {
  route_table_id            = module.vpc.private_route_table_ids[0]
  destination_cidr_block    = var.remote_node_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_remote.id
}

# Routes: cluster private subnets -> remote pods (needed for kubectl logs/exec)
resource "aws_route" "cluster_private_to_pod_cidr" {
  route_table_id            = module.vpc.private_route_table_ids[0]
  destination_cidr_block    = var.remote_pod_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_remote.id
}

# Routes: cluster public subnets -> remote pods
resource "aws_route" "cluster_public_to_pod_cidr" {
  route_table_id            = module.vpc.public_route_table_ids[0]
  destination_cidr_block    = var.remote_pod_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_remote.id
}

# Routes: remote public subnets -> cluster VPC
resource "aws_route" "remote_to_cluster" {
  count                     = length(module.remote_vpc.public_route_table_ids)
  route_table_id            = module.remote_vpc.public_route_table_ids[count.index]
  destination_cidr_block    = local.cluster_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_remote.id
}

###############################################################
# SSM Hybrid Activation for hybrid nodes
###############################################################

resource "aws_ssm_activation" "hybrid_nodes" {
  name               = "${local.name}-hybrid-ssm-activation"
  iam_role           = aws_iam_role.hybrid_node.name
  registration_limit = var.ssm_registration_limit
  expiration_date    = timeadd(timestamp(), "720h") # 30 days

  tags = local.tags

  lifecycle {
    ignore_changes = [expiration_date]
  }
}

###############################################################
# Outputs
###############################################################

output "remote_vpc_id" {
  value = module.remote_vpc.vpc_id
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.cluster_to_remote.id
}

output "ssm_activation_id" {
  value = aws_ssm_activation.hybrid_nodes.id
}

output "ssm_activation_code" {
  value     = aws_ssm_activation.hybrid_nodes.activation_code
  sensitive = false
}

output "nodeconfig_cmd" {
  description = "Copy and run this command on each hybrid node to create nodeConfig.yaml"
  value       = <<-EOT
cat <<EOF > nodeConfig.yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${module.eks.cluster_name}
    region: ${local.region}
  hybrid:
    ssm:
      activationCode: ${aws_ssm_activation.hybrid_nodes.activation_code}
      activationId: ${aws_ssm_activation.hybrid_nodes.id}
EOF
  EOT
}

output "hybrid_node_asg_name" {
  value = aws_autoscaling_group.hybrid_node.name
}

output "list_hybrid_nodes_cmd" {
  value = "aws ec2 describe-instances --filters 'Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.hybrid_node.name}' 'Name=instance-state-name,Values=running' --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]' --output table --region ${local.region}"
}
