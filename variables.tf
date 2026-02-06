variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR block"
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the Spring app"
  type        = string
  default     = "springapp"
}

variable "spring_app_image_tag" {
  description = "Docker image tag for the Spring application"
  type        = string
  default     = "latest"
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance (Ubuntu 22.04). Leave empty to auto-detect."
  type        = string
  default     = ""
}
