#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Passo único depois do primeiro sync do ArgoCD (pods dos 5 serviços Running):
#   1. cria as tabelas nos 3 RDS (db/init.sql), de dentro do cluster
#   2. gera a SERVICE_API_KEY do evaluation-service no auth-service e grava no
#      Secrets Manager (evaluation-service/SERVICE_API_KEY)
#   3. reinicia o evaluation-service para ler a chave nova
#   4. cria uma flag de exemplo com regra de 50% (para a demo)
#
# Os RDS são privados: o psql roda num pod temporário no namespace do serviço,
# usando o Secret que o CSI driver já sincronizou para o próprio serviço.
# Nenhum segredo é impresso.
#
# Uso (na raiz do repo, Git Bash):  bash scripts/bootstrap-app-data.sh
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
FLAG="${FLAG_NAME:-enable-new-dashboard}"

for t in aws kubectl curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "FALTANDO: $t"; exit 1; }
done

run_sql() {
  local ns="$1" secret="$2" file="$3"
  echo "== ${file} -> ${ns}"
  kubectl -n "$ns" wait --for=condition=available "deploy/${ns}" --timeout=300s >/dev/null
  kubectl -n "$ns" run "psql-init-${RANDOM}" --rm -i --restart=Never --quiet \
    --image=postgres:17-alpine \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"psql\",\"image\":\"postgres:17-alpine\",\"stdin\":true,\"command\":[\"psql\"],\"args\":[\"\$(DATABASE_URL)\",\"-v\",\"ON_ERROR_STOP=1\",\"-q\",\"-f\",\"-\"],\"env\":[{\"name\":\"DATABASE_URL\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"${secret}\",\"key\":\"DATABASE_URL\"}}}]}]}}" \
    < "$file"
}

run_sql auth-service auth-service-secrets auth-service/db/init.sql
run_sql flag-service flag-service-secrets flag-service/db/init.sql
run_sql targeting-service targeting-service-secrets targeting-service/db/init.sql

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

forward() {
  kubectl -n "$1" port-forward "svc/$1" "$2:80" >/dev/null 2>&1 &
  PIDS+=("$!")
}
forward auth-service 18001
forward flag-service 18002
forward targeting-service 18003
sleep 4

echo "== Gerando SERVICE_API_KEY no auth-service"
MASTER_KEY="$(aws secretsmanager get-secret-value --secret-id auth-service/MASTER_KEY --region "$REGION" --query SecretString --output text | tr -d '\r')"
RESP="$(curl -sf -X POST http://127.0.0.1:18001/auth/admin/keys \
  -H "Authorization: Bearer ${MASTER_KEY}" -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}')"
KEY="$(printf '%s' "$RESP" | sed -E 's/.*"key":"([^"]+)".*/\1/')"
unset MASTER_KEY RESP
[[ "$KEY" == tm_key_* ]] || { echo "ERRO: não consegui gerar a chave no auth-service"; exit 1; }

aws secretsmanager put-secret-value --secret-id evaluation-service/SERVICE_API_KEY \
  --secret-string "$KEY" --region "$REGION" >/dev/null
echo "   gravada em evaluation-service/SERVICE_API_KEY"

echo "== Criando a flag '${FLAG}' (50% dos usuários)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18002/flags \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${FLAG}\",\"description\":\"Demo Fase 4\",\"is_enabled\":true}")"
echo "   flag-service: HTTP ${code} (201 criada, 409 já existia)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18003/targeting/rules \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d "{\"flag_name\":\"${FLAG}\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}")"
echo "   targeting-service: HTTP ${code} (201 criada, 409 já existia)"
unset KEY

echo "== Reiniciando o evaluation-service para ler a chave nova"
# O CSI driver sincroniza o Secret a cada ~2 min (rotação); o restart garante
# que a variável de ambiente já sobe com o valor novo.
sleep 120
kubectl -n evaluation-service rollout restart deploy/evaluation-service
kubectl -n evaluation-service rollout status deploy/evaluation-service --timeout=180s

echo
echo "Pronto. Teste:"
echo "  ALB=\$(kubectl get ingress -n evaluation-service evaluation-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "  curl \"http://\$ALB/evaluation/evaluate?user_id=user-123&flag_name=${FLAG}\""
