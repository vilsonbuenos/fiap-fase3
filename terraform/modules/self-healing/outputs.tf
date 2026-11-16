output "role_arn" {
  description = "Vai na variável SELF_HEALING_ROLE_ARN do repositório no GitHub"
  value       = aws_iam_role.self_healing.arn
}

output "kubernetes_group" {
  value = var.kubernetes_group
}
