#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Gera tráfego no ALB para popular o dashboard do Grafana, o Loki e o APM.
# Cada chamada ao evaluation-service atravessa flag/targeting/auth (cache miss),
# Redis e SQS -> analytics -> DynamoDB.
#
# Uso (Git Bash):  bash scripts/generate-traffic.sh [minutos]   (padrão: 5)
# -----------------------------------------------------------------------------
set -euo pipefail

MINUTES="${1:-5}"
FLAG="${FLAG_NAME:-enable-new-dashboard}"
ALB="${ALB:-$(kubectl get ingress -n evaluation-service evaluation-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')}"
[[ -n "$ALB" ]] || { echo "ERRO: ALB não encontrado (ingress do evaluation-service sem hostname)"; exit 1; }

echo "Enviando tráfego para http://${ALB} por ${MINUTES} min (Ctrl+C para parar)"
end=$((SECONDS + MINUTES * 60))
n=0
while (( SECONDS < end )); do
  for i in $(seq 1 10); do
    curl -s -o /dev/null "http://${ALB}/evaluation/evaluate?user_id=user-$((RANDOM % 500))&flag_name=${FLAG}" &
  done
  # flag inexistente: caminho de "não encontrado" (result=false)
  curl -s -o /dev/null "http://${ALB}/evaluation/evaluate?user_id=user-x&flag_name=flag-que-nao-existe" &
  wait
  n=$((n + 11))
  (( n % 220 == 0 )) && echo "  ${n} requisições"
  sleep 1
done
echo "Total: ${n} requisições"
