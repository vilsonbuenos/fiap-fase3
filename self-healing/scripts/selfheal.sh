#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runbook automatizado de Self-Healing do ToggleMaster.
#
# Executado pelo workflow .github/workflows/self-healing.yaml (disparado pelo
# webhook do Datadog), mas também roda à mão com um kubeconfig válido:
#
#   SERVICE=auth-service bash self-healing/scripts/selfheal.sh
#
# Passos (cada um vira uma seção no log e no resumo do GitHub Actions):
#   1. Valida o serviço contra uma allowlist (o payload do webhook não é confiável)
#   2. Diagnóstico ANTES: deployment, pods, eventos recentes
#   3. Anti-flapping: se já houve restart há menos de COOLDOWN_MINUTES, não
#      reinicia de novo e escala para humano (evita loop de restart)
#   4. Ação corretiva: kubectl rollout restart + rollout status
#   5. Verificação DEPOIS: pods novos e health check pelo proxy da API do K8s
#
# Variáveis:
#   SERVICE            (obrigatória) nome do deployment/serviço
#   NAMESPACE          (opcional)    padrão = SERVICE (convenção deste repo)
#   COOLDOWN_MINUTES   (opcional)    padrão = 10
#   FORCE              (opcional)    "true" ignora o cooldown
#   DRY_RUN            (opcional)    "true" só diagnostica, não reinicia
#   ROLLOUT_TIMEOUT    (opcional)    padrão = 180s
#   RESULT_FILE        (opcional)    arquivo onde gravar result=<...> (outputs do GHA)
#
# Códigos de saída: 0 = curado ou ignorado de propósito, 1 = falhou/precisa humano
# -----------------------------------------------------------------------------
set -euo pipefail

SERVICE="${SERVICE:-}"
NAMESPACE="${NAMESPACE:-$SERVICE}"
COOLDOWN_MINUTES="${COOLDOWN_MINUTES:-10}"
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
RESULT_FILE="${RESULT_FILE:-/dev/null}"

# Allowlist: serviço -> caminho do health check (o mesmo do readinessProbe)
declare -A HEALTH_PATH=(
  [auth-service]="/auth/health"
  [flag-service]="/health"
  [targeting-service]="/targeting/health"
  [evaluation-service]="/evaluation/health"
  [analytics-service]="/health"
)

ts()      { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()     { echo "[$(ts)] $*"; }
section() { echo; echo "::group::$*" 2>/dev/null || true; echo "===== $* ====="; }
endsec()  { echo "::endgroup::" 2>/dev/null || true; }
result()  { echo "result=$1" >> "$RESULT_FILE"; echo "detail=$2" >> "$RESULT_FILE"; log "RESULTADO: $1 - $2"; }

# --- 1. Validação -------------------------------------------------------------
if [[ -z "$SERVICE" || -z "${HEALTH_PATH[$SERVICE]+x}" ]]; then
  result "rejected" "serviço '${SERVICE}' fora da allowlist (${!HEALTH_PATH[*]})"
  exit 1
fi
if [[ ! "$NAMESPACE" =~ ^[a-z0-9-]+$ ]]; then
  result "rejected" "namespace inválido: '${NAMESPACE}'"
  exit 1
fi
DEPLOY="deployment/${SERVICE}"
log "Alvo: ${DEPLOY} no namespace ${NAMESPACE} (cooldown=${COOLDOWN_MINUTES}min, force=${FORCE}, dry_run=${DRY_RUN})"
log "Contexto kubectl: $(kubectl config current-context 2>/dev/null || echo '?')"

# --- 2. Diagnóstico ANTES -----------------------------------------------------
section "Diagnóstico ANTES da ação"
kubectl -n "$NAMESPACE" get "$DEPLOY" -o wide
echo
kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" -o wide
echo
log "Últimos eventos do namespace:"
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 || true
endsec

# --- 3. Anti-flapping ---------------------------------------------------------
section "Checagem de cooldown (anti-flapping)"
LAST_RESTART="$(kubectl -n "$NAMESPACE" get "$DEPLOY" \
  -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null || true)"
if [[ -n "$LAST_RESTART" ]]; then
  now_s=$(date -u +%s)
  last_s=$(date -u -d "$LAST_RESTART" +%s 2>/dev/null || echo 0)
  age_min=$(( (now_s - last_s) / 60 ))
  log "Último restart automatizado/manual: ${LAST_RESTART} (há ${age_min} min)"
  if (( age_min < COOLDOWN_MINUTES )) && [[ "$FORCE" != "true" ]]; then
    endsec
    result "escalated" "restart feito há ${age_min} min (< ${COOLDOWN_MINUTES}); reiniciar de novo não resolveu, precisa de humano"
    exit 1
  fi
else
  log "Nenhum restart anterior registrado no deployment."
fi
endsec

if [[ "$DRY_RUN" == "true" ]]; then
  result "dry-run" "diagnóstico feito, nenhuma ação executada"
  exit 0
fi

# --- 4. Ação corretiva --------------------------------------------------------
section "Ação corretiva: rollout restart"
OLD_PODS="$(kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" -o jsonpath='{.items[*].metadata.name}')"
log "Pods antes: ${OLD_PODS:-<nenhum>}"
log "Executando: kubectl -n ${NAMESPACE} rollout restart ${DEPLOY}"
kubectl -n "$NAMESPACE" rollout restart "$DEPLOY"
if ! kubectl -n "$NAMESPACE" rollout status "$DEPLOY" --timeout="$ROLLOUT_TIMEOUT"; then
  endsec
  kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" -o wide || true
  result "failed" "rollout não ficou pronto em ${ROLLOUT_TIMEOUT}"
  exit 1
fi
endsec

# --- 5. Verificação DEPOIS ----------------------------------------------------
section "Verificação DEPOIS da ação"
kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" -o wide
# Pods antigos ainda aparecem como Running enquanto terminam: mostra só os novos
NEW_PODS=""
for p in $(kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}'); do
  [[ " ${OLD_PODS} " == *" ${p} "* ]] || NEW_PODS="${NEW_PODS:+$NEW_PODS }${p}"
done
log "Pods depois (novos): ${NEW_PODS:-<nenhum ainda>}"

HEALTH_URL="/api/v1/namespaces/${NAMESPACE}/services/${SERVICE}:http/proxy${HEALTH_PATH[$SERVICE]}"
HEALTH_OK=false
for i in 1 2 3 4 5; do
  if BODY="$(kubectl get --raw "$HEALTH_URL" 2>&1)"; then
    log "Health check OK (${HEALTH_PATH[$SERVICE]}): ${BODY}"
    HEALTH_OK=true
    break
  fi
  log "Health check tentativa ${i}/5 falhou: ${BODY}"
  sleep 5
done
endsec

if [[ "$HEALTH_OK" != "true" ]]; then
  result "failed" "pods reiniciados mas o health check não respondeu"
  exit 1
fi
result "healed" "rollout restart concluído; pods ${OLD_PODS:-?} -> ${NEW_PODS:-?}"
