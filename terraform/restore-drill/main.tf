# Temporary EKS cluster for the restore drill. See
# docs/runbooks/eks-restore-drill.md. It exists for hours, then gets destroyed.
#
# State is separate from offsite-backups, so `terraform destroy` here cannot
# reach the backup bucket. The bucket is only ever read, by name.
#
# Costs are kept down on purpose: public subnets instead of a NAT gateway, and
# a free S3 gateway endpoint so restore traffic stays in the region.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket comes from -backend-config=bucket=<bootstrap output>.
  backend "s3" {
    key          = "restore-drill/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "homelab"
      Purpose   = "restore-drill"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name       = "restore-drill"
  bucket_arn = "arn:aws:s3:::rubiconetic-offsite-backups-${data.aws_caller_identity.current.account_id}"
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "drill" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "drill" {
  vpc_id = aws_vpc.drill.id
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.drill.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(aws_vpc.drill.cidr_block, 8, count.index)
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.drill.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.drill.id
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.drill.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "drill" {
  name     = local.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Fixed so clusters/drill can hard-code the backupstore's ClusterIP.
  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
  }

  # STANDARD stops this cluster sliding into extended support, which bills
  # $0.60 an hour instead of $0.10.
  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids          = aws_subnet.public[*].id
    public_access_cidrs = [var.home_ip_cidr]

    # The allowlist above would otherwise block the nodes' own public IPs.
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.drill.name
  addon_name   = "eks-pod-identity-agent"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "node" {
  name_prefix = "${local.name}-"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_gb
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # Longhorn needs both on every node, and Amazon Linux 2023 is not confirmed
  # to ship them. Instances don't inherit default_tags, so the teardown check
  # relies on the tag_specifications below.
  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    dnf install -y iscsi-initiator-utils nfs-utils
    systemctl enable --now iscsid
    modprobe iscsi_tcp

    --BOUNDARY--
  EOT
  )

  dynamic "tag_specifications" {
    for_each = ["instance", "volume"]

    content {
      resource_type = tag_specifications.value
      tags          = { Purpose = "restore-drill" }
    }
  }
}

resource "aws_eks_node_group" "drill" {
  cluster_name    = aws_eks_cluster.drill.name
  node_group_name = local.name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = [var.instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

data "aws_iam_policy_document" "restore_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "restore" {
  name               = "${local.name}-restore"
  assume_role_policy = data.aws_iam_policy_document.restore_assume.json
}

# Read-only, unlike the production restic key. Restic runs with --no-lock
# because it cannot write a lock file with this role.
data "aws_iam_policy_document" "restore" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "ReadObjects"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "restore" {
  name   = "restic-read-only"
  role   = aws_iam_role.restore.id
  policy = data.aws_iam_policy_document.restore.json
}

resource "aws_eks_pod_identity_association" "restore" {
  cluster_name    = aws_eks_cluster.drill.name
  namespace       = "default"
  service_account = "drill-restic"
  role_arn        = aws_iam_role.restore.arn

  depends_on = [aws_eks_addon.pod_identity]
}
