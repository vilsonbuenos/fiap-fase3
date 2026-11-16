# ---------------------------------------------------------------------------
# Self-Healing (Fase 4): identidade do GitHub Actions no EKS.
#
#   GitHub Actions --OIDC--> IAM role (sem chave de longa duração)
#                  --access entry--> grupo K8s "togglemaster:self-healing"
#                  --RBAC (gitops/self-healing)--> patch em deployments
#
# A role NÃO recebe AmazonEKSClusterAdminPolicy: o que ela pode fazer dentro do
# cluster é só o que o Role/RoleBinding em gitops/self-healing/ concede
# (rollout restart dos 5 microsserviços + leitura para diagnóstico).
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : (
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  )
  cluster_arn = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
}

# Só um provider OIDC do GitHub por conta AWS. Se a conta já tiver um (de outro
# projeto), use create_github_oidc_provider = false.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
  # A AWS valida o GitHub pela CA confiável e ignora o thumbprint, mas o
  # campo ainda é aceito/esperado por versões mais antigas do provider.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

# Só workflows deste repositório, rodando na branch padrão, assumem a role.
# repository_dispatch e workflow_dispatch rodam com ref = branch padrão.
resource "aws_iam_role" "self_healing" {
  name = "${var.cluster_name}-self-healing"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for b in var.allowed_branches : "repo:${var.github_repository}:ref:refs/heads/${b}"
          ]
        }
      }
    }]
  })

  max_session_duration = 3600
  tags                 = var.tags
}

# IAM: só o necessário para "aws eks update-kubeconfig".
resource "aws_iam_role_policy" "describe_cluster" {
  name = "eks-describe-cluster"
  role = aws_iam_role.self_healing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = local.cluster_arn
    }]
  })
}

# Kubernetes: a role entra no cluster como membro do grupo abaixo. O RBAC desse
# grupo vem do GitOps (gitops/self-healing/rbac.yaml).
resource "aws_eks_access_entry" "self_healing" {
  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.self_healing.arn
  kubernetes_groups = [var.kubernetes_group]
  type              = "STANDARD"

  tags = var.tags
}
