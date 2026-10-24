resource "aws_kms_key" "eks_secrets" {
  policy                  = data.aws_iam_policy_document.kms_account.json
  description             = "${var.name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Private API endpoint only (07-security-controls.md §3).
  endpoint_public_access  = false
  endpoint_private_access = true

  enable_irsa = true

  encryption_config = {
    provider_key_arn = aws_kms_key.eks_secrets.arn
    resources        = ["secrets"]
  }
  create_kms_key = false

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  authentication_mode = "API"
  access_entries = {
    for i, arn in var.admin_role_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true" # VPC CNI network policy agent enforces NetworkPolicy
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa["ebs-csi"].arn
    }
  }

  eks_managed_node_groups = {
    # General platform workloads: Keycloak, Rekor, CT log, Trillian, TUF, Argo CD agents.
    platform = {
      ami_type       = "BOTTLEROCKET_ARM_64"
      instance_types = ["m7g.xlarge"]
      min_size       = 3
      max_size       = 9
      desired_size   = 3
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
    # Fulcio and the TSA only (they hold the CA and TSA signing roles).
    signing = {
      ami_type       = "BOTTLEROCKET_ARM_64"
      instance_types = ["m7g.large"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      labels         = { "sigstore.example-bank.com/pool" = "signing" }
      taints = {
        signing = {
          key    = "sigstore.example-bank.com/signing"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  tags = var.tags
}
