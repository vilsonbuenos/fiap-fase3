#!/usr/bin/env bash
# Testes do runbook self-healing/scripts/selfheal.sh com um kubectl falso
# (não precisa de cluster). Roda no CI (.github/workflows/self-healing-ci.yaml)
# e localmente:  bash self-healing/tests/test-selfheal.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/self-healing/scripts/selfheal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# kubectl falso: respostas controladas por variáveis FAKE_*; registra as chamadas
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
case "$*" in
  *"config current-context"*) echo "fake-cluster" ;;
  *"restartedAt"*)            printf '%s' "${FAKE_RESTARTED_AT:-}" ;;
  *"rollout status"*)         [[ "${FAKE_ROLLOUT_FAIL:-}" == "true" ]] && exit 1; echo "successfully rolled out" ;;
  *"field-selector"*)         printf '%s' "pod-old pod-new" ;;
  *"jsonpath={.items[*].metadata.name}"*) printf '%s' "pod-old" ;;
  *"get --raw"*)              [[ "${FAKE_HEALTH_FAIL:-}" == "true" ]] && exit 1; echo '{"status":"ok"}' ;;
  *)                          echo "kubectl $*" ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
# health check sem esperar 5s entre tentativas
sleep() { :; }; export -f sleep

PASS=0; FAIL=0
run_case() { # nome exit_esperado result_esperado restart_esperado(yes/no) -- env...
  local name="$1" want_exit="$2" want_result="$3" want_restart="$4"; shift 5
  : > "$TMP/calls"; : > "$TMP/out"
  env FAKE_CALLS="$TMP/calls" RESULT_FILE="$TMP/out" "$@" bash "$SCRIPT" > "$TMP/log" 2>&1
  local got_exit=$? got_result restarted=no
  got_result="$(grep '^result=' "$TMP/out" | cut -d= -f2)"
  grep -q "rollout restart" "$TMP/calls" && restarted=yes
  if [[ "$got_exit" == "$want_exit" && "$got_result" == "$want_result" && "$restarted" == "$want_restart" ]]; then
    echo "PASS  $name"; PASS=$((PASS + 1))
  else
    echo "FAIL  $name (exit=$got_exit/$want_exit result=$got_result/$want_result restart=$restarted/$want_restart)"
    sed 's/^/      /' "$TMP/log"; FAIL=$((FAIL + 1))
  fi
}

ago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }

run_case "rejeita serviço fora da allowlist"       1 rejected  no  -- SERVICE=postgres
run_case "rejeita serviço vazio"                   1 rejected  no  -- SERVICE=
run_case "rejeita namespace inválido"              1 rejected  no  -- SERVICE=auth-service 'NAMESPACE=kube-system;id'
run_case "cura: restart + health OK"               0 healed    yes -- SERVICE=auth-service
run_case "cura nos 5 serviços (evaluation)"        0 healed    yes -- SERVICE=evaluation-service
run_case "cooldown: restart há 3 min -> escala"    1 escalated no  -- SERVICE=auth-service "FAKE_RESTARTED_AT=$(ago 3)"
run_case "cooldown com FORCE=true -> reinicia"     0 healed    yes -- SERVICE=auth-service "FAKE_RESTARTED_AT=$(ago 3)" FORCE=true
run_case "restart antigo (30 min) -> reinicia"     0 healed    yes -- SERVICE=auth-service "FAKE_RESTARTED_AT=$(ago 30)"
run_case "dry run não reinicia"                    0 dry-run   no  -- SERVICE=flag-service DRY_RUN=true
run_case "rollout travado -> failed"               1 failed    yes -- SERVICE=auth-service FAKE_ROLLOUT_FAIL=true
run_case "health check falhando -> failed"         1 failed    yes -- SERVICE=auth-service FAKE_HEALTH_FAIL=true

# O detalhe deve listar só o pod novo (o antigo ainda aparece Running enquanto termina)
: > "$TMP/out"; env FAKE_CALLS=/dev/null RESULT_FILE="$TMP/out" SERVICE=auth-service bash "$SCRIPT" >/dev/null 2>&1
if grep -q '^detail=.*pod-old -> pod-new$' "$TMP/out"; then echo "PASS  detalhe mostra pod antigo -> novo"; PASS=$((PASS + 1))
else echo "FAIL  detalhe: $(cat "$TMP/out")"; FAIL=$((FAIL + 1)); fi

echo; echo "Resultado: ${PASS} passaram, ${FAIL} falharam"
(( FAIL == 0 ))
