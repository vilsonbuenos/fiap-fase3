#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# "Prova real" do vídeo: injeta falha no auth-service e gera tráfego até o
# self-healing reiniciar o pod (o tráfego volta a dar 401/200 sozinho).
#
# Uso (Git Bash, kubeconfig apontando pro EKS):
#   bash self-healing/demo/inject-failure.sh [minutos]     (padrão: 10)
#
# O que acontece:
#   1. POST /auth/admin/chaos -> 100% das chamadas de negócio do pod atual = 500
#      (o /auth/health continua 200: o Kubernetes NÃO percebe nada)
#   2. Loop de requisições em /auth/validate mostrando o status de cada rodada
#   3. Datadog: taxa de 5xx > 5% -> monitor dispara -> webhook -> GitHub Actions
#   4. GitHub Actions: kubectl rollout restart -> pod novo, sem falha em memória
#   5. Aqui: os códigos voltam de 500 para 401 (chave inválida = comportamento normal)
# -----------------------------------------------------------------------------
set -euo pipefail

MINUTES="${1:-10}"
NS=auth-service
ALB="${ALB:-$(kubectl get ingress -n "$NS" auth-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')}"
[[ -n "$ALB" ]] || { echo "ERRO: ALB não encontrado (ingress do auth-service sem hostname)"; exit 1; }
BASE="http://${ALB}"

# MASTER_KEY sai do Secret sincronizado pelo Secrets Store CSI
MASTER_KEY="${MASTER_KEY:-$(kubectl get secret -n "$NS" auth-service-secrets -o jsonpath='{.data.MASTER_KEY}' | base64 -d)}"
[[ -n "$MASTER_KEY" ]] || { echo "ERRO: MASTER_KEY não encontrada"; exit 1; }

echo "== Pod atual =="
kubectl get pods -n "$NS" -l app=auth-service -o wide
echo
echo "== Injetando falha (100% de 500 por ${MINUTES} min) =="
curl -sS -X POST "${BASE}/auth/admin/chaos" \
  -H "Authorization: Bearer ${MASTER_KEY}" -H "Content-Type: application/json" \
  -d "{\"error_rate\": 1.0, \"duration_seconds\": $((MINUTES * 60))}"
echo; echo
echo "Health check (continua OK - falha silenciosa):"
curl -sS "${BASE}/auth/health"; echo; echo

echo "== Gerando tráfego em ${BASE}/auth/validate (Ctrl+C para parar) =="
echo "   Esperado: 500 até o self-healing agir; depois 401 (chave inválida = normal)"
end=$((SECONDS + MINUTES * 60))
while (( SECONDS < end )); do
  codes=()
  for i in $(seq 1 10); do
    codes+=("$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer demo-key-invalida' "${BASE}/auth/validate")")
  done
  n500=$(printf '%s\n' "${codes[@]}" | grep -c '^5' || true)
  printf '[%s] 10 req -> %2d x 5xx | %s\n' "$(date +%H:%M:%S)" "$n500" "$(printf '%s ' "${codes[@]}" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
  sleep 2
done
