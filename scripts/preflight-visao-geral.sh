#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Preflight do trecho "Visão Geral" do vídeo (Fase 4 - ToggleMaster).
#
# Valida, SOMENTE LENDO o cluster/estado (nenhum apply/delete/install), se está
# tudo pronto para gravar:
#   - ferramentas (aws, kubectl, helm, terraform)
#   - kubectl apontando para o EKS eks-tc3-prod-001
#   - nós Ready, pods saudáveis, PVCs Bound
#   - Applications do ArgoCD Synced + Healthy
#   - stack de observabilidade presente no cluster
#   - terraform state acessível (prova de IaC)
# Ao final imprime a senha do admin do ArgoCD e o comando de port-forward.
#
# Uso:  bash scripts/preflight-visao-geral.sh
# Variáveis opcionais:
#   CLUSTER_NAME (padrão eks-tc3-prod-001)   AWS_REGION (padrão us-east-2)
#   EXPECTED_ACCOUNT (padrão: lido do ECR em gitops/apps/*/kustomization.yaml)
#   OBS_NS (padrão observability)            OBS_REGEX (regex dos namespaces/apps
#   de observabilidade)                      TF_STATE_BUCKET (bucket do backend S3)
# -----------------------------------------------------------------------------
set -uo pipefail

# Vai para a raiz do repo (o script fica em scripts/)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CLUSTER_NAME="${CLUSTER_NAME:-eks-tc3-prod-001}"
AWS_REGION="${AWS_REGION:-us-east-2}"
# A conta "oficial" é a que está nas imagens do ECR dos manifests GitOps
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-$(grep -ohE '[0-9]{12}\.dkr\.ecr' gitops/apps/*/kustomization.yaml 2>/dev/null | head -1 | cut -c1-12)}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
OBS_NS="${OBS_NS:-observability}"
OBS_REGEX="${OBS_REGEX:-monitoring|observability|prometheus|grafana|loki|promtail|otel|opentelemetry|datadog|newrelic|tempo|alertmanager}"
KREQ="--request-timeout=15s"

# ---------- saída colorida (desliga se não for terminal) ----------
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; C=$'\033[36m'; W=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; W=""; N=""
fi

FAILS=()   # itens bloqueantes
WARNS=()   # itens que não bloqueiam, mas merecem atenção

section() { printf "\n%s== %s ==%s\n" "$W$B" "$1" "$N"; }
ok()      { printf "  %s[OK]%s    %s\n" "$G" "$N" "$1"; }
warn()    { printf "  %s[AVISO]%s %s\n" "$Y" "$N" "$1"; WARNS+=("$1"); }
fail()    { printf "  %s[FALHA]%s %s\n" "$R" "$N" "$1"; FAILS+=("$1"); }
info()    { printf "          %s\n" "$1"; }

printf "%s\nPreflight - Visão Geral (EKS + ArgoCD + observabilidade)%s\n" "$W$C" "$N"
printf "Cluster esperado: %s (%s)\n" "$CLUSTER_NAME" "$AWS_REGION"

# ---------------------------------------------------------------------------
section "1. Ferramentas"
missing=0
for t in aws kubectl helm terraform; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t encontrado ($(command -v "$t"))"
  else
    fail "$t não encontrado no PATH - instale antes de continuar"
    missing=1
  fi
done
if [[ $missing -eq 1 ]]; then
  printf "\n%sFaltam ferramentas obrigatórias. Instale e rode de novo.%s\n" "$R$W" "$N"
  exit 1
fi

# ---------------------------------------------------------------------------
section "2. Credenciais AWS"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT" || "$ACCOUNT" == "None" ]]; then
  fail "AWS CLI sem credenciais válidas (aws sts get-caller-identity falhou)"
  info "Configure: aws configure / aws sso login / export AWS_PROFILE=<perfil>"
else
  if [[ -z "$EXPECTED_ACCOUNT" ]]; then
    ok "Conta AWS: $ACCOUNT (não consegui ler a conta esperada dos manifests)"
  elif [[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]]; then
    ok "Conta AWS: $ACCOUNT (mesma dos manifests gitops/)"
  else
    fail "Conta AWS atual ($ACCOUNT) difere da usada nas imagens/roles de gitops/ ($EXPECTED_ACCOUNT)"
    info "Logue na conta certa (export AWS_PROFILE=...) ou, se o ambiente mudou: bash gitops/set-account.sh $ACCOUNT"
  fi
fi

# ---------------------------------------------------------------------------
section "3. Contexto do kubectl"
CTX="$(kubectl config current-context 2>/dev/null || true)"
UPDATE_CMD="aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"
CLUSTER_OK=0
if [[ -z "$CTX" ]]; then
  fail "Nenhum contexto kubectl ativo"
  info "Rode: $UPDATE_CMD"
elif [[ "$CTX" != *"$CLUSTER_NAME"* ]]; then
  fail "Contexto atual é '$CTX', não o $CLUSTER_NAME"
  info "Rode: $UPDATE_CMD"
else
  ok "Contexto: $CTX"
  if kubectl $KREQ get --raw=/readyz >/dev/null 2>&1 || kubectl $KREQ version >/dev/null 2>&1; then
    ok "API server do cluster respondendo"
    CLUSTER_OK=1
  else
    fail "API server não respondeu (cluster parado? credencial expirada? sem acesso no aws-auth/access entries?)"
    info "Teste: kubectl get nodes   |   Renove: $UPDATE_CMD"
  fi
fi

if [[ $CLUSTER_OK -eq 1 ]]; then
  # -------------------------------------------------------------------------
  section "4. Nós"
  NODES="$(kubectl $KREQ get nodes --no-headers \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type' 2>/dev/null)"
  if [[ -z "$NODES" ]]; then
    fail "Nenhum nó no cluster (node group com desired=0?)"
  else
    total=$(printf "%s\n" "$NODES" | wc -l | tr -d ' ')
    notready=$(printf "%s\n" "$NODES" | awk '$2!="True"')
    if [[ -z "$notready" ]]; then
      ok "$total nó(s) Ready"
    else
      fail "Nó(s) fora de Ready:"
      printf "%s\n" "$notready" | sed 's/^/            /'
    fi
    printf "%s\n" "$NODES" | awk '{printf "          - %s (%s)\n", $1, $3}'
    if [[ $total -lt 3 ]]; then
      warn "Só $total nó(s). Com Prometheus/Grafana/Loki/agente APM, 2x c7i-flex.large (4 GiB) fica apertado - veja pods Pending"
    fi
  fi

  # -------------------------------------------------------------------------
  section "5. Pods (todos os namespaces)"
  # Colunas: NAMESPACE NAME READY STATUS RESTARTS AGE
  PODS="$(kubectl $KREQ get pods -A --no-headers 2>/dev/null)"
  BAD="$(printf "%s\n" "$PODS" | awk 'NF>=4 {
      split($3, r, "/");
      if ($4 == "Completed" || $4 == "Succeeded") next;
      if ($4 == "Running" && r[1] == r[2]) next;
      printf "%-22s %-55s %-6s %s\n", $1, $2, $3, $4 }')"
  ptotal=$(printf "%s\n" "$PODS" | grep -c . || true)
  if [[ -z "$BAD" ]]; then
    ok "$ptotal pod(s), todos Running/Completed e prontos"
  else
    nbad=$(printf "%s\n" "$BAD" | wc -l | tr -d ' ')
    fail "$nbad pod(s) com problema (de $ptotal):"
    printf "%s\n" "$BAD" | sed 's/^/            /'
    info "Diagnóstico: kubectl -n <ns> describe pod <pod>  |  kubectl -n <ns> logs <pod>"
  fi

  # Serviços do ToggleMaster
  for s in auth-service flag-service targeting-service evaluation-service analytics-service; do
    n=$(printf "%s\n" "$PODS" | awk -v ns="$s" '$1==ns && $4=="Running"' | wc -l | tr -d ' ')
    if [[ "$n" -ge 1 ]]; then
      ok "$s: $n pod(s) Running"
    elif [[ "$s" == "analytics-service" ]]; then
      warn "analytics-service com 0 pods (KEDA minReplicaCount=0 com fila SQS vazia é esperado). Para o vídeo: bash scripts/generate-traffic.sh 5 (se existir) ou explique o scale-to-zero"
    else
      fail "$s sem pods Running"
    fi
  done

  # -------------------------------------------------------------------------
  section "6. Armazenamento (PVCs da stack de observabilidade)"
  DEFAULT_SC="$(kubectl $KREQ get storageclass --no-headers 2>/dev/null | awk '/\(default\)/{print $1}')"
  if [[ -n "$DEFAULT_SC" ]]; then
    ok "StorageClass padrão: $DEFAULT_SC"
  else
    warn "Nenhuma StorageClass marcada como (default) - PVCs sem storageClassName ficarão Pending"
  fi
  if kubectl $KREQ -n kube-system get deploy ebs-csi-controller >/dev/null 2>&1; then
    ok "EBS CSI driver instalado (ebs-csi-controller)"
  else
    warn "EBS CSI driver não encontrado - no EKS 1.23+ volumes EBS (gp2/gp3) não são provisionados sem ele"
  fi
  PVC_BAD="$(kubectl $KREQ get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"{printf "%-22s %-45s %s\n",$1,$2,$3}')"
  if [[ -z "$PVC_BAD" ]]; then
    ok "Nenhuma PVC pendente"
  else
    fail "PVC(s) não Bound:"
    printf "%s\n" "$PVC_BAD" | sed 's/^/            /'
  fi

  # -------------------------------------------------------------------------
  section "7. ArgoCD"
  ARGO_OK=0
  if ! kubectl $KREQ get ns "$ARGOCD_NS" >/dev/null 2>&1; then
    fail "Namespace $ARGOCD_NS não existe - instale com: bash gitops/install-argocd.sh"
  elif ! kubectl $KREQ get crd applications.argoproj.io >/dev/null 2>&1; then
    fail "CRD applications.argoproj.io ausente - ArgoCD incompleto"
  else
    ARGO_OK=1
    APPS="$(kubectl $KREQ -n "$ARGOCD_NS" get applications --no-headers \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null)"
    if [[ -z "$APPS" ]]; then
      fail "Nenhuma Application no ArgoCD - aplique: kubectl apply -f gitops/bootstrap/root-app.yaml"
    else
      atotal=$(printf "%s\n" "$APPS" | wc -l | tr -d ' ')
      ABAD="$(printf "%s\n" "$APPS" | awk '$2!="Synced" || $3!="Healthy" {printf "%-28s sync=%-10s health=%s\n",$1,$2,$3}')"
      if [[ -z "$ABAD" ]]; then
        ok "$atotal Application(s), todas Synced + Healthy"
      else
        fail "Application(s) fora de Synced/Healthy:"
        printf "%s\n" "$ABAD" | sed 's/^/            /'
        info "Na UI: abra a app > 'App Diff' / eventos. Ou: kubectl -n $ARGOCD_NS describe application <nome>"
      fi
      printf "%s\n" "$APPS" | awk '{printf "          - %-28s %-10s %s\n",$1,$2,$3}'
    fi
  fi

  # -------------------------------------------------------------------------
  section "8. Stack de observabilidade (Fase 4)"
  OBS_NS="$(kubectl $KREQ get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -Ei "$OBS_REGEX" || true)"
  OBS_APPS=""
  [[ $ARGO_OK -eq 1 ]] && OBS_APPS="$(kubectl $KREQ -n "$ARGOCD_NS" get applications --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -Ei "$OBS_REGEX" || true)"
  if [[ -z "$OBS_NS" && -z "$OBS_APPS" ]]; then
    fail "Nenhum namespace/Application de observabilidade (Prometheus, Grafana, Loki, OTel, APM) encontrado"
    info "O enunciado pede o cluster rodando 'com a nova stack' - alinhe com o time de observabilidade"
  else
    [[ -n "$OBS_NS" ]]   && ok "Namespaces: $(echo $OBS_NS | tr ' ' ',')"
    [[ -n "$OBS_APPS" ]] && ok "Applications no ArgoCD: $(echo $OBS_APPS | tr ' ' ',')"
    [[ -z "$OBS_APPS" ]] && warn "Stack de observabilidade existe no cluster mas NÃO está no ArgoCD (instalada à mão/helm?) - não aparece como GitOps"
    for comp in "prometheus" "grafana" "alertmanager" "loki" "otel|opentelemetry"; do
      if printf "%s\n" "$PODS" | awk '{print $2}' | grep -Eqi "$comp"; then
        ok "Componente com pods: $comp"
      else
        warn "Nenhum pod encontrado para: $comp"
      fi
    done
    # APM: agente próprio (Datadog/New Relic) OU exportação via OTel gateway (secret datadog-api-key)
    if printf "%s\n" "$PODS" | awk '{print $2}' | grep -Eqi "datadog|newrelic"; then
      ok "APM: agente Datadog/New Relic com pods"
    elif kubectl $KREQ -n "$OBS_NS" get secret datadog-api-key >/dev/null 2>&1; then
      ok "APM: Datadog via OTel gateway (secret $OBS_NS/datadog-api-key sincronizado do Secrets Manager)"
    else
      warn "APM: nem agente Datadog/New Relic nem secret $OBS_NS/datadog-api-key - traces podem não chegar ao APM"
      info "Confira o secret observability/DATADOG_API_KEY no Secrets Manager e os logs: kubectl -n $OBS_NS logs deploy/otel-gateway-opentelemetry-collector"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "9. Terraform (prova de IaC)"
if [[ ! -d terraform/.terraform ]]; then
  fail "terraform/ não inicializado neste clone"
  info "Rode (só baixa providers e conecta no backend S3, não altera infra):"
  if grep -qE '^[[:space:]]*bucket[[:space:]]*=' terraform/versions.tf 2>/dev/null; then
    info "  terraform -chdir=terraform init"
  else
    info "  terraform -chdir=terraform init -backend-config=\"bucket=${TF_STATE_BUCKET:-<BUCKET_DO_STATE>}\""
    info "  (o bucket não está no versions.tf - peça o nome a quem cuida da infra)"
  fi
else
  STATE="$(terraform -chdir=terraform state list 2>/dev/null)"
  if [[ -z "$STATE" ]]; then
    fail "terraform state list vazio ou sem acesso ao backend s3-tc3-backend-iac"
    info "Verifique credenciais AWS/perfil com acesso ao bucket"
  else
    ok "State remoto acessível: $(printf "%s\n" "$STATE" | wc -l | tr -d ' ') recursos"
    printf "%s\n" "$STATE" | grep -q 'aws_eks_cluster' && ok "aws_eks_cluster presente no state" || fail "aws_eks_cluster não está no state"
    if grep -q 'aws_eks_addon' terraform/*.tf 2>/dev/null && ! printf "%s\n" "$STATE" | grep -q 'aws_eks_addon.ebs_csi'; then
      warn "EBS CSI (aws_eks_addon.ebs_csi) está no código mas não no state - a parte de storage da Fase 4 ainda não foi aplicada"
    fi
    if printf "%s\n" "$STATE" | grep -q '^module\.k8s_manifests'; then
      warn "module.k8s_manifests ainda está no state - um 'terraform apply' DESTRUIRIA os workloads do ArgoCD"
      info "Quem cuida da infra deve rodar: terraform -chdir=terraform state rm 'module.k8s_manifests'"
    fi
  fi
fi

if git ls-files --error-unmatch terraform.tfstate >/dev/null 2>&1; then
  warn "terraform.tfstate versionado na raiz do repo (vazio, mas confunde no vídeo/GitHub) - remover com git rm --cached"
fi

# ---------------------------------------------------------------------------
section "10. Acesso à UI do ArgoCD"
if [[ $CLUSTER_OK -eq 1 ]]; then
  PW="$(kubectl $KREQ -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
  printf "  Usuário: %sadmin%s\n" "$W" "$N"
  if [[ -n "$PW" ]]; then
    printf "  Senha:   %s%s%s\n" "$W" "$PW" "$N"
  else
    warn "Secret argocd-initial-admin-secret não encontrado (removido após troca de senha?) - use a senha definida pelo grupo"
  fi
  printf "  Port-forward (deixe rodando em outro terminal):\n"
  printf "    %skubectl -n %s port-forward svc/argocd-server 8080:443%s\n" "$C" "$ARGOCD_NS" "$N"
  printf "    -> https://localhost:8080  (aceite o certificado autoassinado)\n"

  # Grafana (útil para o trecho seguinte do vídeo)
  GSVC="$(kubectl $KREQ -n "$OBS_NS" get svc --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -E 'grafana$' | head -1)"
  if [[ -n "$GSVC" ]]; then
    GPW="$(kubectl $KREQ -n "$OBS_NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
    printf "\n  Grafana: %skubectl -n %s port-forward svc/%s 3000:80%s -> http://localhost:3000\n" "$C" "$OBS_NS" "$GSVC" "$N"
    [[ -n "$GPW" ]] && printf "  Grafana admin / %s%s%s\n" "$W" "$GPW" "$N"
  fi
else
  info "(pulado: sem acesso ao cluster)"
fi

# ---------------------------------------------------------------------------
printf "\n%s===========================================================%s\n" "$W" "$N"
if [[ ${#FAILS[@]} -eq 0 ]]; then
  printf "%s  PRONTO PARA GRAVAR%s\n" "$G$W" "$N"
  if [[ ${#WARNS[@]} -gt 0 ]]; then
    printf "%s  (%d aviso(s) - revise acima, não bloqueiam)%s\n" "$Y" "${#WARNS[@]}" "$N"
  fi
  printf "%s===========================================================%s\n" "$W" "$N"
  exit 0
else
  printf "%s  NÃO PRONTO - corrigir antes de gravar:%s\n" "$R$W" "$N"
  for f in "${FAILS[@]}"; do printf "   %s-%s %s\n" "$R" "$N" "$f"; done
  if [[ ${#WARNS[@]} -gt 0 ]]; then
    printf "%s  Avisos:%s\n" "$Y$W" "$N"
    for w in "${WARNS[@]}"; do printf "   %s-%s %s\n" "$Y" "$N" "$w"; done
  fi
  printf "%s===========================================================%s\n" "$W" "$N"
  exit 1
fi
