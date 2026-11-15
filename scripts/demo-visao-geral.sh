#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Demo ao vivo do trecho "Visão Geral" (Fase 4 - ToggleMaster).
# Rode DURANTE a gravação. Cada etapa: título -> "$ comando" -> saída -> pausa.
# Somente comandos de LEITURA (get / state list). Nada é alterado no cluster.
#
# Rode antes: bash scripts/preflight-visao-geral.sh
#
# Uso:  bash scripts/demo-visao-geral.sh
# Opções (env): NO_CLEAR=1 (não limpa a tela entre etapas)
#               OBS_REGEX='...' (namespaces destacados como observabilidade)
# -----------------------------------------------------------------------------
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-tc3-prod-001}"
AWS_REGION="${AWS_REGION:-us-east-2}"
SVC_REGEX="^(auth-service|flag-service|targeting-service|evaluation-service|analytics-service)$"
OBS_REGEX="${OBS_REGEX:-monitoring|observability|prometheus|grafana|loki|promtail|otel|opentelemetry|datadog|newrelic|tempo|alertmanager}"

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [[ -t 1 ]]; then
  G=$'\033[32m'; Y=$'\033[33m'; M=$'\033[35m'; C=$'\033[36m'; R=$'\033[31m'; W=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; Y=""; M=""; C=""; R=""; W=""; D=""; N=""
fi

# ---------- pré-checagens silenciosas ----------
for t in aws kubectl helm terraform; do
  command -v "$t" >/dev/null 2>&1 || { printf "%sERRO:%s '%s' não encontrado no PATH. Instale antes da gravação.\n" "$R" "$N" "$t"; exit 1; }
done
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CTX" != *"$CLUSTER_NAME"* ]]; then
  printf "%sERRO:%s kubectl não aponta para %s (atual: '%s').\n" "$R" "$N" "$CLUSTER_NAME" "${CTX:-nenhum}"
  printf "Rode: aws eks update-kubeconfig --name %s --region %s\n" "$CLUSTER_NAME" "$AWS_REGION"
  exit 1
fi

TOTAL=5
STEP=0

pause() {
  printf "\n%s" "$D"
  read -r -p "[Enter para continuar] " _
  printf "%s" "$N"
}

title() {
  STEP=$((STEP+1))
  [[ -z "${NO_CLEAR:-}" ]] && clear
  printf "%s━━━ [%d/%d] %s ━━━%s\n" "$W$C" "$STEP" "$TOTAL" "$1" "$N"
  [[ -n "${2:-}" ]] && printf "%s%s%s\n" "$D" "$2" "$N"
  printf "\n"
}

# Mostra o comando exatamente como será executado e o executa
show_run() {
  printf "%s\$ %s%s\n" "$G$W" "$1" "$N"
  sleep 0.6
  bash -o pipefail -c "$1"
  printf "\n"
}

# ---------------------------------------------------------------------------
title "Nós do cluster EKS ($CLUSTER_NAME)" \
      "Managed node group criado pelo Terraform (módulo eks), AL2023, subnets privadas"
show_run "kubectl get nodes -o wide"
pause

# ---------------------------------------------------------------------------
title "Infraestrutura como Código - Terraform state (backend S3)" \
      "Recursos principais gerenciados pelo Terraform (resumo) + total"
show_run "terraform -chdir=terraform state list | grep -E 'aws_vpc\.|aws_eks_cluster|aws_eks_node_group|aws_eks_addon|kubernetes_storage_class|aws_db_instance|aws_elasticache_replication_group|aws_sqs_queue|aws_dynamodb_table|aws_ecr_repository|helm_release'"
show_run "terraform -chdir=terraform state list | wc -l"
pause

# ---------------------------------------------------------------------------
title "Namespaces" \
      "5 microsserviços + argocd + add-ons (kube-system, keda) + observabilidade"
show_run "kubectl get ns"
pause

# ---------------------------------------------------------------------------
title "Pods em todos os namespaces" \
      "Legenda: ${M}■ microsserviços ToggleMaster${N}${D}   ${Y}■ observabilidade${N}${D}   ${C}■ argocd${N}"
printf "%s\$ kubectl get pods -A%s\n" "$G$W" "$N"
sleep 0.6
# A cor é só destaque visual na saída; o comando executado é o mesmo exibido.
kubectl get pods -A | awk -v svc="$SVC_REGEX" -v obs="$OBS_REGEX" \
  -v m="$M" -v y="$Y" -v c="$C" -v w="$W" -v n="$N" '
  NR==1        { print w $0 n; next }
  $1 ~ svc     { print m $0 n; next }
  tolower($1) ~ "(" obs ")" { print y $0 n; next }
  $1=="argocd" { print c $0 n; next }
               { print }'
printf "\n"
pause

# ---------------------------------------------------------------------------
title "GitOps - Applications do ArgoCD (App of Apps)" \
      "root-app -> gitops/bootstrap/apps/ (5 serviços + kube-prometheus-stack, loki, otel-agent, otel-gateway, observability-config)"
show_run "kubectl -n argocd get applications"
printf "%sFim da demo de terminal. Próximo: UI do ArgoCD (https://localhost:8080).%s\n" "$W$G" "$N"
