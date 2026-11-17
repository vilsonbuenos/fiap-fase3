#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Terminal C do vídeo: injeta a falha no pod atual do auth-service (na hora que
# você quiser) e sai. O tráfego fica com o traffic.sh (terminal A).
#
#   bash self-healing/demo/inject-failure.sh            # 100% de 500 por 10 min
#   bash self-healing/demo/inject-failure.sh 5 0.5      # 50% de 500 por 5 min
#   bash self-healing/demo/inject-failure.sh off        # desliga a falha
#   bash self-healing/demo/inject-failure.sh status     # mostra o estado
#
# A falha fica só na memória do pod: o /auth/health continua 200, então o
# Kubernetes não percebe nada (falha silenciosa). Só o self-healing (rollout
# restart) resolve, porque o pod novo nasce sem a falha.
#
# Fluxo esperado depois de rodar:
#   1. traffic.sh passa de 401 para 500
#   2. Datadog: monitor dispara em 1-3 min -> PagerDuty + Discord + webhook
#   3. GitHub Actions: rollout restart -> pod novo
#   4. traffic.sh volta para 401 sozinho; monitor Recovered; incidente resolvido
# -----------------------------------------------------------------------------
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self-healing/demo/_common.sh
source "$DIR/_common.sh"

ARG="${1:-10}"
RATE="${2:-1.0}"
BASE="$(resolve_base_url)"
KEY="$(resolve_master_key)"
CHAOS="${BASE}/auth/admin/chaos"
AUTH=(-H "Authorization: Bearer ${KEY}")

case "$ARG" in
  off)
    curl -sS -X DELETE "${AUTH[@]}" "$CHAOS"; echo
    exit 0 ;;
  status)
    curl -sS "${AUTH[@]}" "$CHAOS"; echo
    exit 0 ;;
esac

[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "Uso: $0 [minutos] [taxa 0-1] | off | status"; exit 1; }

echo "== Injetando falha: ${RATE} de erro 500 por ${ARG} min =="
curl -sS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
  -d "{\"error_rate\": ${RATE}, \"duration_seconds\": $((ARG * 60))}" "$CHAOS"
echo; echo
echo "Health check (continua OK - falha silenciosa, o Kubernetes não reinicia o pod):"
curl -sS "${BASE}/auth/health"; echo; echo
echo "Agora acompanhe: terminal A (traffic.sh), Datadog, PagerDuty, Discord e GitHub Actions."
