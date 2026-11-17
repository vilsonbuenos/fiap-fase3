# ---------------------------------------------------------------------------
# Datadog: monitor de taxa de erro 5xx + webhook que dispara o Self-Healing.
#
# Stack separada da infra AWS (terraform/) para que quem não tem as chaves do
# Datadog continue rodando o plan/apply principal normalmente.
#
#   cd self-healing/datadog
#   cp terraform.tfvars.example terraform.tfvars   # preencha as chaves
#   terraform init && terraform apply
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
  }
  # State local de propósito (só 2 recursos, fácil de recriar). Está no .gitignore.
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
  api_url = "https://api.${var.datadog_site}/"
}

locals {
  services = ["auth-service", "flag-service", "targeting-service", "evaluation-service", "analytics-service"]

  # Métricas de APM calculadas pelo datadog/connector do otel-gateway a partir
  # dos spans de servidor HTTP. Span de servidor com status 5xx = erro.
  hits   = "sum:trace.${var.apm_operation_name}.hits{env:${var.env},${var.service_filter}} by {service}.as_count()"
  errors = "sum:trace.${var.apm_operation_name}.errors{env:${var.env},${var.service_filter}} by {service}.as_count()"

  webhook_handle = "@webhook-${datadog_webhook.selfheal_github.name}"
}

# Webhook -> GitHub API (repository_dispatch). As variáveis $ALERT_* são
# preenchidas pelo Datadog no momento do disparo.
resource "datadog_webhook" "selfheal_github" {
  name      = "selfheal-github"
  url       = "https://api.github.com/repos/${var.github_repository}/dispatches"
  encode_as = "json"

  custom_headers = jsonencode({
    "Accept"               = "application/vnd.github+json"
    "Authorization"        = "Bearer ${var.github_token}"
    "X-GitHub-Api-Version" = "2022-11-28"
  })

  payload = jsonencode({
    event_type = "self-healing"
    client_payload = {
      scope       = "$ALERT_SCOPE"
      transition  = "$ALERT_TRANSITION"
      alert_id    = "$ALERT_ID"
      alert_title = "$ALERT_TITLE"
      link        = "$LINK"
      date        = "$DATE"
    }
  })
}

resource "datadog_monitor" "http_5xx_rate" {
  # Nome fixo: variáveis {{...}} só são renderizadas nas notificações, não na
  # lista de monitores. O serviço aparece no título do alerta ("Triggered on
  # {service:...}") e na mensagem.
  name = "[ToggleMaster] Self-healing - taxa de erro 5xx acima de ${var.critical_threshold * 100}%"
  type = "query alert"

  # Multi-alert: um grupo por serviço. O escopo do alerta (service:xxx) chega
  # no webhook e o workflow sabe qual deployment reiniciar.
  query = "sum(${var.evaluation_window}):${local.errors} / ${local.hits} > ${var.critical_threshold}"

  message = <<-EOT
    {{#is_alert}}
    🔥 **{{service.name}}** está com **{{value}}** de respostas 5xx (limite ${var.critical_threshold * 100}%) nos últimos ${var.evaluation_window}.

    **Self-healing acionado:** o GitHub Actions vai executar `kubectl rollout restart deployment/{{service.name}} -n {{service.name}}`.
    Acompanhe em https://github.com/${var.github_repository}/actions/workflows/self-healing.yaml

    Runbook: https://github.com/${var.github_repository}/blob/main/self-healing/README.md
    ${local.webhook_handle} ${var.extra_notification_handles}
    {{/is_alert}}

    {{#is_warning}}
    ⚠️ {{service.name}} com {{value}} de 5xx (aviso em ${var.warning_threshold * 100}%). Nenhuma ação automática ainda.
    ${var.extra_notification_handles}
    {{/is_warning}}

    {{#is_recovery}}
    ✅ {{service.name}} recuperado: taxa de 5xx em {{value}}.
    ${var.extra_notification_handles}
    {{/is_recovery}}
  EOT

  monitor_thresholds {
    critical          = var.critical_threshold
    warning           = var.warning_threshold
    critical_recovery = var.critical_threshold / 2
  }

  require_full_window = false
  notify_no_data      = false
  evaluation_delay    = 30
  # Re-notifica se continuar em alerta: o workflow aplica o cooldown e escala
  # para humano se um restart recente não resolveu.
  renotify_interval = 15
  renotify_statuses = ["alert"]

  tags = ["team:togglemaster", "env:${var.env}", "automation:self-healing"]
}
