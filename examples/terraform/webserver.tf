# Example Terraform configuration for a web server
# Demonstrates HAR's parsing and transformation capabilities

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC for the web server
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "webserver-vpc"
    Environment = "production"
  }
}

# Public subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "webserver-public-subnet"
  }
}

# Security group for web traffic
resource "aws_security_group" "web" {
  name        = "webserver-sg"
  description = "Allow HTTP and HTTPS traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "webserver-sg"
  }
}

# EC2 instance for web server
resource "aws_instance" "web" {
  ami                    = "ami-0c55b159cbfafe1f0"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]

  tags = {
    Name        = "webserver"
    Environment = "production"
  }

  depends_on = [aws_security_group.web]
}

# S3 bucket for static assets
resource "aws_s3_bucket" "assets" {
  bucket = "webserver-static-assets-12345"

  tags = {
    Name        = "webserver-assets"
    Environment = "production"
  }
}

# IAM user for deployment
resource "aws_iam_user" "deploy" {
  name = "webserver-deploy"
  path = "/system/"

  tags = {
    Purpose = "Deployment automation"
  }
}
