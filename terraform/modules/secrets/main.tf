resource "random_password" "auth_master_key" {
  length  = var.master_key_length
  special = false
}

# recovery_window_in_days = 0 em todos os secrets: sem isso, um destroy seguido
# de apply falha por 30 dias com "secret ... is scheduled for deletion".

# ---------------------------------------------------------------------------
# auth-service: DATABASE_URL e MASTER_KEY, um secret por chave conforme
# esperado pelo K8s/auth-service/secretproviderclass.yaml
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "auth_database_url" {
  name                    = "auth-service/DATABASE_URL"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "auth_database_url" {
  secret_id     = aws_secretsmanager_secret.auth_database_url.id
  secret_string = "postgres://${var.databases["auth"].master_username}:${var.databases["auth"].password}@${var.databases["auth"].address}:5432/${var.databases["auth"].db_name}"
}

resource "aws_secretsmanager_secret" "auth_master_key" {
  name                    = "auth-service/MASTER_KEY"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "auth_master_key" {
  secret_id     = aws_secretsmanager_secret.auth_master_key.id
  secret_string = random_password.auth_master_key.result
}

# ---------------------------------------------------------------------------
# flag-service / targeting-service: DATABASE_URL
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "flag_database_url" {
  name                    = "flag-service/DATABASE_URL"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "flag_database_url" {
  secret_id     = aws_secretsmanager_secret.flag_database_url.id
  secret_string = "postgres://${var.databases["flag"].master_username}:${var.databases["flag"].password}@${var.databases["flag"].address}:5432/${var.databases["flag"].db_name}"
}

resource "aws_secretsmanager_secret" "targeting_database_url" {
  name                    = "targeting-service/DATABASE_URL"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "targeting_database_url" {
  secret_id     = aws_secretsmanager_secret.targeting_database_url.id
  secret_string = "postgres://${var.databases["targeting"].master_username}:${var.databases["targeting"].password}@${var.databases["targeting"].address}:5432/${var.databases["targeting"].db_name}"
}

# ---------------------------------------------------------------------------
# evaluation-service: REDIS_URL e SERVICE_API_KEY
# SERVICE_API_KEY só pode ser gerada de verdade chamando a API do
# auth-service (POST /auth/admin/keys) após o deploy — aqui criamos um valor
# placeholder e marcamos para não ser revertido por applies futuros; atualize
# com scripts/bootstrap-app-data.sh (ou 'aws secretsmanager put-secret-value').
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "evaluation_redis_url" {
  name                    = "evaluation-service/REDIS_URL"
  recovery_window_in_days = 0
  tags                    = var.tags
}

# rediss:// (TLS): o ElastiCache tem transit_encryption_enabled + auth token,
# então conexão em texto puro é recusada.
resource "aws_secretsmanager_secret_version" "evaluation_redis_url" {
  secret_id     = aws_secretsmanager_secret.evaluation_redis_url.id
  secret_string = "rediss://:${var.redis_auth_token}@${var.redis_primary_endpoint}:6379"
}

resource "aws_secretsmanager_secret" "evaluation_service_api_key" {
  name                    = "evaluation-service/SERVICE_API_KEY"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "evaluation_service_api_key" {
  secret_id     = aws_secretsmanager_secret.evaluation_service_api_key.id
  secret_string = "REPLACE_ME_AFTER_CREATING_KEY_VIA_AUTH_SERVICE"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Observabilidade (Fase 4)
# DATADOG_API_KEY: placeholder; a chave real é gravada fora do Terraform
# (put-secret-value) para não ir para o state nem para o Git.
# GRAFANA_ADMIN: JSON {username, password}; o SecretProviderClass do Grafana
# extrai os dois campos com jmesPath.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "datadog_api_key" {
  name                    = "observability/DATADOG_API_KEY"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "datadog_api_key" {
  secret_id     = aws_secretsmanager_secret.datadog_api_key.id
  secret_string = "REPLACE_ME_WITH_DATADOG_API_KEY"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "observability/GRAFANA_ADMIN"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana_admin.result
  })
}
