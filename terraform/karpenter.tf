module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name           = module.eks.cluster_name
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn

  enable_irsa         = true
  enable_pod_identity = false

  # Reutiliza a role de nó criada em iam.tf
  create_node_iam_role = false
  node_iam_role_arn    = aws_iam_role.karpenter_node.arn

  tags = local.tags
}

# Aguarda o node system estar Ready antes de instalar o Karpenter controller.
# Sem isso o pod do Karpenter fica Pending — não há nó que tolere CriticalAddonsOnly.
resource "time_sleep" "wait_for_system_node" {
  depends_on      = [module.eks.eks_managed_node_groups]
  create_duration = "180s"
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.3.0"

  values = [
    jsonencode({
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    })
  ]

  depends_on = [module.eks, time_sleep.wait_for_system_node, aws_eks_access_policy_association.admin]
}
