output "monitor_id" {
  value = datadog_monitor.http_5xx_rate.id
}

output "monitor_url" {
  value = "https://app.${var.datadog_site}/monitors/${datadog_monitor.http_5xx_rate.id}"
}

output "webhook_handle" {
  description = "Cole este handle na mensagem de qualquer outro monitor para ligar o self-healing nele"
  value       = local.webhook_handle
}
