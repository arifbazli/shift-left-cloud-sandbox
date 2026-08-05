# =============================================================================
# modules/compute/main.tf
# =============================================================================
# Resources: EC2 instance, Lambda function, ECS cluster + task, EKS cluster.
# All minimal viable config, single AZ (us-east-1a).
# NOTE: EKS apply requires floci Pro or a compatible image; tfsec scans fine.
# =============================================================================

# -----------------------------------------------------------------------------
# EC2 Instance
# SEC_INTENT: IMDSv2 enforced (hop limit = 1 prevents SSRF via IMDS). Detailed
# CloudWatch monitoring enabled. Root volume encrypted. SSM-managed (no SSH
# key pair) is the recommended access method — we set the profile here.
# AMI "ami-00000000" is a floci placeholder; real deploy uses a data source.
# -----------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = "ami-00000000" # floci placeholder; real deploy: data "aws_ami"
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.app_instance_profile

  monitoring = true # SEC_INTENT: CloudWatch detailed monitoring (AVD-AWS-0028)

  metadata_options {
    http_tokens                 = "required" # SEC_INTENT: IMDSv2 only (AVD-AWS-0028, AVD-AWS-0033)
    http_put_response_hop_limit = 1          # SEC_INTENT: no SSRF via IMDS
    http_endpoint               = "enabled"
  }

  root_block_device {
    encrypted   = true # SEC_INTENT: root volume encrypted at rest
    volume_type = "gp3"
  }

  tags = {
    Name        = "floci-app"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Lambda Function
# SEC_INTENT: function runs inside the VPC (private subnet) so it cannot reach
# the internet without NAT. X-Ray tracing gives end-to-end observability.
# Placeholder zip bundles a hello-world handler — the actual code is immaterial
# for shift-left scanning; tfsec checks config, not code.
# NOTE: Lambda apply requires floci to expose the Lambda service endpoint.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "floci-lambda-exec-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "main" {
  filename         = "${path.module}/lambda_placeholder.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_placeholder.zip")
  function_name    = "floci-hello-${var.environment}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"

  tracing_config {
    mode = "Active" # SEC_INTENT: X-Ray active tracing
  }

  vpc_config {
    # SEC_INTENT: Lambda in private subnet — no direct internet egress.
    subnet_ids         = [var.subnet_id]
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      ENV    = var.environment
      BUCKET = var.artifacts_bucket
    }
  }

  tags = {
    Name        = "floci-hello"
    Environment = var.environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc]
}

# -----------------------------------------------------------------------------
# ECS Cluster + Task Definition (Fargate)
# SEC_INTENT: Container Insights enabled for CloudWatch visibility. Fargate
# removes EC2 management surface. Task execution role limited to ECR pull and
# CloudWatch Logs write; no broad permissions.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_exec" {
  name               = "floci-ecs-exec-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_cluster" "main" {
  name = "floci-cluster-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled" # SEC_INTENT: Container Insights for anomaly detection
  }

  tags = {
    Name        = "floci-cluster"
    Environment = var.environment
  }
}

resource "aws_ecs_task_definition" "main" {
  family                   = "floci-app-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_exec.arn

  # SEC_INTENT: public ECR image so no credentials are needed in the sandbox.
  # Container only exposes port 80 inside the VPC; no public load balancer here.
  container_definitions = jsonencode([{
    name      = "floci-app"
    image     = "public.ecr.aws/nginx/nginx:latest"
    essential = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/floci-app"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name        = "floci-app-task"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# EKS Cluster
# SEC_INTENT: private API server endpoint (no public exposure). All control-plane
# log types sent to CloudWatch. The cluster role has the minimum AWS-managed
# policy (AmazonEKSClusterPolicy only).
# NOTE: EKS may partially apply against floci community; tfsec scans fine.
# AVD-AWS-0040 (endpoint_private_access) and AVD-AWS-0041 (public disabled) satisfied.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "floci-eks-cluster-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = "floci-eks-${var.environment}"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids              = [var.subnet_id]
    security_group_ids      = [var.security_group_id]
    endpoint_private_access = true  # SEC_INTENT: private endpoint only (AVD-AWS-0040)
    endpoint_public_access  = false # SEC_INTENT: no public API server (AVD-AWS-0041)
  }

  # SEC_INTENT: all control-plane audit logs forwarded to CloudWatch.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # SEC_INTENT: secrets encrypted with CMK so etcd-stored k8s secrets are
  # protected even if etcd storage is compromised (AVD-AWS-0039).
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.kms_key_arn
    }
  }

  tags = {
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}
