#!/usr/bin/env bash
# Funções compartilhadas pelos scripts da demo (source, não executar direto).
# Funcionam com só o AWS CLI logado (aws login); kubectl é opcional.

REGION="${AWS_REGION:-us-east-2}"
ALB_NAME_PREFIX="${ALB_NAME_PREFIX:-k8s-fiapfase2prod}"

# URL base do ALB do auth-service: $ALB > ingress (kubectl) > busca pelo nome do ALB (aws).
resolve_base_url() {
  local alb="${ALB:-}"
  if [[ -z "$alb" ]] && command -v kubectl >/dev/null 2>&1; then
    alb="$(kubectl get ingress -n auth-service auth-service \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi
  if [[ -z "$alb" ]]; then
    alb="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?starts_with(LoadBalancerName, '${ALB_NAME_PREFIX}')].DNSName | [0]" \
      --output text 2>/dev/null || true)"
    [[ "$alb" == "None" ]] && alb=""
  fi
  [[ -n "$alb" ]] || { echo "ERRO: não achei o ALB do auth-service. Rode 'aws login' ou exporte ALB=<hostname>." >&2; return 1; }
  echo "http://${alb}"
}

# MASTER_KEY do auth-service: $MASTER_KEY > Secrets Manager (aws) > Secret do cluster (kubectl).
resolve_master_key() {
  local key="${MASTER_KEY:-}"
  if [[ -z "$key" ]]; then
    key="$(aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id auth-service/MASTER_KEY --query SecretString --output text 2>/dev/null || true)"
  fi
  if [[ -z "$key" ]] && command -v kubectl >/dev/null 2>&1; then
    key="$(kubectl get secret -n auth-service auth-service-secrets \
      -o jsonpath='{.data.MASTER_KEY}' 2>/dev/null | base64 -d || true)"
  fi
  [[ -n "$key" ]] || { echo "ERRO: não consegui ler a MASTER_KEY (rode 'aws login')." >&2; return 1; }
  printf '%s' "$key"
}
