module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    # Node group dedicado para workloads de sistema (Karpenter controller, addons).
    # Taint CriticalAddonsOnly impede que pods de aplicação agendem aqui.
    system = {
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      labels = {
        role = "system"
      }
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  enable_irsa = true

  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  tags = local.tags
}

# ─── ACCESS ENTRY ─────────────────────────────────────────────────────────────
# Resource separado (não via access_entries do módulo) para garantir que o
# access entry do caller exista antes do Helm provider tentar autenticar.
resource "aws_eks_access_entry" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"

  depends_on = [module.eks]
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ─── SECURITY GROUP RULES ─────────────────────────────────────────────────────
# Karpenter provisiona nós com o cluster primary SG (eks-cluster-sg-*).
# O managed node group usa um SG separado (projetin-cluster-node-*).
# Sem essas regras, tráfego cross-node (DNS UDP 53, etc.) é bloqueado.
resource "aws_security_group_rule" "cluster_to_node_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = module.eks.cluster_primary_security_group_id
  security_group_id        = module.eks.node_security_group_id
  description              = "Allow all traffic from cluster primary SG (Karpenter nodes) to node SG"
}

resource "aws_security_group_rule" "node_to_cluster_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = module.eks.node_security_group_id
  security_group_id        = module.eks.cluster_primary_security_group_id
  description              = "Allow all traffic from node SG to cluster primary SG (Karpenter nodes)"
}

# ─── STORAGE CLASS ────────────────────────────────────────────────────────────
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
