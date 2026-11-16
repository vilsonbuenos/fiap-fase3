#!/usr/bin/env bash
# Simula o webhook do Datadog chamando o GitHub (útil para testar o workflow
# antes de o monitor existir). Envia exatamente o formato que o Datadog envia.
#
#   bash self-healing/demo/trigger-manual.sh [serviço] [transição]
#   ex.: bash self-healing/demo/trigger-manual.sh auth-service Triggered
#
# Requer o GitHub CLI autenticado (gh auth login) com acesso ao repositório.
set -euo pipefail
SVC="${1:-auth-service}"
TRANSITION="${2:-Triggered}"
REPO="${REPO:-vilsonbuenos/fiap-fase4}"

gh api "repos/${REPO}/dispatches" \
  -f event_type=self-healing \
  -f "client_payload[scope]=env:prod,service:${SVC}" \
  -f "client_payload[transition]=${TRANSITION}" \
  -f "client_payload[alert_id]=teste-manual" \
  -f "client_payload[alert_title]=[Teste] ${SVC} - disparo manual" \
  -f "client_payload[link]=https://github.com/${REPO}/actions"

echo "Disparo enviado. Acompanhe: gh run watch -R ${REPO} \$(gh run list -R ${REPO} -w self-healing -L1 --json databaseId -q '.[0].databaseId')"
