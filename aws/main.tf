terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  shared_credentials_files = ["/home/mage/.aws/creds"]
  shared_config_files = ["/home/mage/.aws/config"]
}

provider "docker" {
  registry_auth {
      address = data.aws_ecr_authorization_token.token.proxy_endpoint
      username = data.aws_ecr_authorization_token.token.user_name
      password  = data.aws_ecr_authorization_token.token.password
    }
}

resource "aws_ecr_repository" "autodrive-repo" {
  name = "autodrive-repo"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "subnet2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

data "aws_ecr_authorization_token" "token" {}

#Node Server
resource "docker_image" "node_server" {
  name = "${aws_ecr_repository.autodrive-repo.repository_url}:server"
  build {
    context = "containers/node_server"
    tag = ["${aws_ecr_repository.autodrive-repo.repository_url}:server"]
  }
  platform = "linux/arm64"
}

resource "docker_registry_image" "node_server_registry" {
  name = docker_image.node_server.name
}

#API
resource "docker_image" "api" {
  name = "${aws_ecr_repository.autodrive-repo.repository_url}:api"
  build {
    context = "containers/api"
    tag = ["${aws_ecr_repository.autodrive-repo.repository_url}:api"]
  }
  platform = "linux/arm64"
}

resource "docker_registry_image" "api_registry" {
  name = docker_image.api.name
}

#Web
resource "docker_image" "web" {
  name = "${aws_ecr_repository.autodrive-repo.repository_url}:web"
  build {
    context = "containers/webapp"
    tag = ["${aws_ecr_repository.autodrive-repo.repository_url}:web"]
  }
  platform = "linux/arm64"
}

resource "docker_registry_image" "web_registry" {
  name = docker_image.web.name
}

#AutoDRIVE
resource "docker_image" "autodrive" {
  name = "${aws_ecr_repository.autodrive-repo.repository_url}:autodrive"
  build {
    context = "containers/autodrive"
    tag = ["${aws_ecr_repository.autodrive-repo.repository_url}:autodrive"]
  }
  platform = "linux/arm64"
}

resource "docker_registry_image" "autodrive_registry" {
  name = docker_image.autodrive.name
}

resource "aws_eks_cluster" "main" {
  name     = "gpu-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = [aws_subnet.subnet.id, aws_subnet.subnet2.id]
  }
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_node_group" "gpu_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "gpu-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.subnet.id, aws_subnet.subnet2.id]

  scaling_config {
    desired_size = 1
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["p3.2xlarge"]

  ami_type = "AL2_x86_64_GPU"

  #remote_access {
  #  ec2_ssh_key = "your-key-pair"
  #}
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry_read_only" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "autodrive-cluster"
  cluster_version = "1.21"
  vpc_id          = aws_vpc.main.id
  subnet_ids = [aws_subnet.subnet.id, aws_subnet.subnet2.id]
}

resource "kubernetes_config_map" "aws_auth" {
  depends_on = [module.eks]

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = jsonencode([{
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }])
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

resource "kubernetes_deployment" "autodrive" {
  metadata {
    name = "autodrive"
    labels = {
      app = "autodrive"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "autodrive"
      }
    }

    template {
      metadata {
        labels = {
          app = "autodrive"
        }
      }

      spec {
        container {
          name  = "autodrive"
          image = docker_image.autodrive.name

          port {
            container_port = 8000
          }

          env {
            name  = "DISPLAY"
            value = ":20"
          }

          env {
            name  = "XDG_RUNTIME_DIR"
            value = "/tmp/runtime-dir"
          }

          command = ["./entrypoint.sh"]
        }
      }
    }
  }
}

resource "kubernetes_service" "autodrive" {
  metadata {
    name = "autodrive"
  }

  spec {
    selector = {
      app = "autodrive"
    }

    port {
      protocol = "TCP"
      port     = 8000
      target_port = 8000
    }

    type = "ClusterIP"
  }
}