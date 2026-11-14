# ---------------------------------------------------------------------------
# Discos persistentes (Fase 4): Prometheus e Loki usam PVC.
# Desde o EKS 1.30 o cluster não tem StorageClass default e o provisionamento
# de EBS depende do add-on aws-ebs-csi-driver.
# Fica na raiz porque precisa do node group pronto (module.eks) e da role
# IRSA (module.irsa, que por sua vez depende do OIDC do module.eks).
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.irsa.role_arns["ebs-csi-driver-role"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks]

  tags = local.tags
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
