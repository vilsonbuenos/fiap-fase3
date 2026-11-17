variable "datadog_api_key" {
  type      = string
  sensitive = true
}

variable "datadog_app_key" {
  description = "Application key (Organization Settings > Application Keys)"
  type        = string
  sensitive   = true
}

variable "datadog_site" {
  description = "datadoghq.com, us3.datadoghq.com, us5.datadoghq.com, datadoghq.eu... (o mesmo DD_SITE do otel-gateway)"
  type        = string
  default     = "datadoghq.com"
}

variable "github_repository" {
  type    = string
  default = "vilsonbuenos/fiap-fase4"
}

variable "github_token" {
  description = "Fine-grained PAT só deste repositório com permissão 'Contents: Read and write' (exigida pelo repository_dispatch)"
  type        = string
  sensitive   = true
}

variable "env" {
  type    = string
  default = "prod"
}

variable "service_filter" {
  description = "Filtro de serviços do monitor. Ex.: 'service:auth-service' (só auth) ou '!service:otel-gateway' (todos)"
  type        = string
  default     = "service:auth-service"
}

variable "apm_operation_name" {
  description = <<-EOT
    Nome da operação dos spans de servidor no Datadog (APM > Service > auth-service,
    seletor de operação). Com o mapeamento novo do exporter OTel é
    "http.server.request"; no antigo é algo como
    "go.opentelemetry.io_contrib_instrumentation_net_http_otelhttp.server".
  EOT
  type        = string
  default     = "http.server.request"
}

variable "evaluation_window" {
  type    = string
  default = "last_5m"
}

variable "critical_threshold" {
  description = "Fração de 5xx que dispara o alerta e o self-healing (0.05 = 5%)"
  type        = number
  default     = 0.05
}

variable "warning_threshold" {
  type    = number
  default = 0.02
}

variable "extra_notification_handles" {
  description = "Handles extras do Datadog (PagerDuty/OpsGenie/Slack/Teams do grupo), ex.: '@pagerduty-ToggleMaster @slack-alertas'"
  type        = string
  default     = "@pagerduty-togglemaster @webhook-discord-togglemaster"
}
