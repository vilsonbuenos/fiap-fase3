variable "cluster_name" {
  type = string
}

variable "github_repository" {
  description = "Repositório (owner/nome) cujos workflows podem assumir a role"
  type        = string
}

variable "allowed_branches" {
  description = "Branches de onde o workflow pode assumir a role"
  type        = list(string)
  default     = ["main"]
}

variable "create_github_oidc_provider" {
  description = "false se a conta AWS já tiver o OIDC provider token.actions.githubusercontent.com"
  type        = bool
  default     = true
}

variable "kubernetes_group" {
  description = "Grupo Kubernetes associado à role (precisa bater com o RoleBinding do GitOps)"
  type        = string
  default     = "togglemaster:self-healing"
}

variable "tags" {
  type    = map(string)
  default = {}
}
