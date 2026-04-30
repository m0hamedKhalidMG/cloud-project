# -----------------------------------------------------------------------------
# CISC 886 – VPC & Networking
# File: main.tf
# All resources are prefixed with the Queen's netID variable (default: q1abc)
# Replace the default value with your actual netID before running.
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5"
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "netid" {
  description = "20596365"
  type        = string
  default     = "20596365"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

# We lock SSH access to a single trusted IP so the EC2 instance is not
# reachable from the public internet on port 22.
variable "my_ip_cidr" {
  description = "Your public IP in CIDR notation, e.g. 203.0.113.5/32"
  type        = string
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# VPC
# CIDR 10.0.0.0/16 gives us 65 536 addresses.  We only need a handful, but
# a /16 is the AWS default and gives room to add subnets later without
# re-addressing.  The project forbids use of the default VPC, so we create
# our own so we have full control over routing and security.
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true   # Required so EC2 gets a public DNS name
  enable_dns_support   = true

  tags = {
    Name = "${var.netid}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Public Subnet
# 10.0.1.0/24 — 256 addresses, more than enough for one EC2 instance.
# We place the EC2 host here so it can receive inbound traffic via the IGW.
# Using a dedicated public subnet (rather than the whole VPC) means we could
# later add a private subnet for databases or EMR workers without exposing them.
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true   # EC2 instances get a public IP automatically

  tags = {
    Name = "${var.netid}-subnet-public"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# Required for any traffic to leave or enter the VPC from the internet.
# Without this, even a public-subnet instance is unreachable.
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.netid}-igw"
  }
}

# -----------------------------------------------------------------------------
# Route Table
# The default VPC route table only has a local route (10.0.0.0/16 → local).
# We add a catch-all route (0.0.0.0/0) pointing to the IGW so instances in
# the public subnet can reach the internet for package installation and so
# users can reach OpenWebUI from their browsers.
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.netid}-rtb-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security Group
# Principle of least privilege: open only the ports the application needs.
#
#   Port 22  (SSH)    — inbound from your IP only.  Needed for remote setup.
#                       Restricting to /32 prevents brute-force from the internet.
#   Port 11434 (Ollama API) — inbound from your IP only during development;
#                       change to 0.0.0.0/0 only if the grader needs direct API
#                       access.  Ollama has no auth by default, so keep it tight.
#   Port 3000 (OpenWebUI)   — inbound from anywhere (0.0.0.0/0) so the grader
#                       can open the chat interface in a browser without a VPN.
#   Egress: all traffic — outbound is unrestricted so the instance can pull
#                       packages, model files, and Docker images.
# -----------------------------------------------------------------------------

resource "aws_security_group" "ec2" {
  name        = "${var.netid}-sg"
  description = "CISC 886 project security group"
  vpc_id      = aws_vpc.main.id

  # SSH — restricted to your IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "SSH from developer machine only"
  }

  # Ollama REST API — restricted to your IP during dev
  ingress {
    from_port   = 11434
    to_port     = 11434
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "Ollama API for curl demo"
  }

  # OpenWebUI — open to the world so graders can visit the interface
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "OpenWebUI browser interface"
  }

  # Allow all outbound so the instance can download packages and models
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted outbound"
  }

  tags = {
    Name = "${var.netid}-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# g4dn.xlarge has 1× NVIDIA T4 GPU (16 GB VRAM), 4 vCPUs, 16 GB RAM.
# This is the recommended instance from the resource guide for sub-10B models.
# AMI: Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) —
# comes with CUDA pre-installed, saving ~30 min of driver setup.
# -----------------------------------------------------------------------------

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.netid}-key"
  public_key = file("~/.ssh/20596365-key.pem")   # Replace with your public key path
}

resource "aws_instance" "chat" {
  ami                    = data.aws_ami.dlami.id
  instance_type          = "t3.xlarge"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.deployer.key_name

  root_block_device {
    volume_size = 100   # GB — enough for model weights + OS
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.netid}-ec2"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.chat.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.chat.public_dns
}

output "openwebui_url" {
  description = "URL to reach OpenWebUI"
  value       = "http://${aws_instance.chat.public_ip}:3000"
}
