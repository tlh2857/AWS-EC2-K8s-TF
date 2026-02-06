terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------
# Data Sources
# -------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Auto-detect latest Ubuntu 22.04 AMI if not provided
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id     = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
  account_id = data.aws_caller_identity.current.account_id
  ecr_url    = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# -------------------------------------------------------
# VPC & Networking
# -------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "k8s-springapp-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k8s-springapp-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "k8s-springapp-public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "k8s-springapp-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -------------------------------------------------------
# Security Group
# -------------------------------------------------------

resource "aws_security_group" "k8s_sg" {
  name_prefix = "k8s-springapp-sg"
  vpc_id      = aws_vpc.main.id
  description = "Security group for K8s EC2 instance"

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH access"
  }

  # Kubernetes API Server
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "Kubernetes API Server"
  }

  # NodePort range
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kubernetes NodePort services"
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  # Spring App default port
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Spring Boot app"
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "k8s-springapp-sg"
  }
}

# -------------------------------------------------------
# IAM Role for EC2 (ECR Access)
# -------------------------------------------------------

resource "aws_iam_role" "ec2_k8s_role" {
  name = "ec2-k8s-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "ec2-k8s-ecr-role"
  }
}

resource "aws_iam_role_policy" "ecr_policy" {
  name = "ecr-access-policy"
  role = aws_iam_role.ec2_k8s_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:CreateRepository"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_k8s_profile" {
  name = "ec2-k8s-ecr-instance-profile"
  role = aws_iam_role.ec2_k8s_role.name
}

# -------------------------------------------------------
# ECR Repository
# -------------------------------------------------------

resource "aws_ecr_repository" "springapp" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "springapp-ecr"
  }
}

# -------------------------------------------------------
# EC2 Instance
# -------------------------------------------------------

resource "aws_instance" "k8s_node" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_k8s_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata.sh", {
    aws_region       = var.aws_region
    ecr_url          = local.ecr_url
    ecr_repo         = aws_ecr_repository.springapp.repository_url
    image_tag        = var.spring_app_image_tag
    account_id       = local.account_id
    ecr_repo_name    = var.ecr_repository_name
  })

  tags = {
    Name = "k8s-springapp-node"
  }

  # Give enough time for userdata to complete
  timeouts {
    create = "30m"
  }
}
