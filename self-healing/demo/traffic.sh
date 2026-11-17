#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Terminal A do vídeo: tráfego contínuo no auth-service até Ctrl+C.
#
#   bash self-healing/demo/traffic.sh            (5 requisições, pausa de 1 s)
#   REQS=20 PAUSE=1 bash self-healing/demo/traffic.sh
#
# Cada linha mostra os códigos HTTP da rodada:
#   verde    = 401 (chave inválida de propósito = serviço saudável)
#   vermelho = 5xx (falha injetada, ou o serviço quebrado)
# Deixe rodando o vídeo todo: dá para ver o 401 virar 500 quando a falha é
# injetada e voltar para 401 sozinho quando o self-healing reinicia o pod.
# -----------------------------------------------------------------------------
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=self-healing/demo/_common.sh
source "$DIR/_common.sh"

REQS="${REQS:-5}"
PAUSE="${PAUSE:-1}"
BASE="$(resolve_base_url)" || exit 1

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
total=0; total5=0; state=""

echo "${BOLD}Tráfego em ${BASE}/auth/validate (${REQS} req a cada ${PAUSE}s) — Ctrl+C para parar${RESET}"
trap 'echo; echo "${BOLD}Total: ${total} requisições, ${total5} com 5xx${RESET}"; exit 0' INT TERM

while true; do
  n5=0; line=""
  for _ in $(seq 1 "$REQS"); do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
      -H 'Authorization: Bearer demo-key-invalida' "${BASE}/auth/validate" || true)"
    if [[ "$code" == 5* || "$code" == "000" ]]; then
      n5=$((n5 + 1)); line+="${RED}${code}${RESET} "
    else
      line+="${GREEN}${code}${RESET} "
    fi
  done
  total=$((total + REQS)); total5=$((total5 + n5))

  if (( n5 > 0 )); then now="falha"; else now="ok"; fi
  if [[ -n "$state" && "$now" != "$state" ]]; then
    if [[ "$now" == "falha" ]]; then
      echo "${RED}${BOLD}>>> $(date +%H:%M:%S) serviço começou a devolver 5xx${RESET}"
    else
      echo "${GREEN}${BOLD}>>> $(date +%H:%M:%S) serviço voltou ao normal (sem 5xx)${RESET}"
    fi
  fi
  state="$now"

  if (( n5 > 0 )); then tag="${RED}${n5}/${REQS} 5xx${RESET}"; else tag="${GREEN}OK${RESET}      "; fi
  printf '%s[%s]%s %b | %b\n' "$YELLOW" "$(date +%H:%M:%S)" "$RESET" "$tag" "$line"
  sleep "$PAUSE"
done
