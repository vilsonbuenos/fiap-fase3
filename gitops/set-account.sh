#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Troca o Account ID AWS em todos os manifests de gitops/ (*.yaml): role-arn das
# ServiceAccounts, URI do ECR nas imagens (kustomization + deployment), URLs de
# SQS e os values da stack de observabilidade.
#
# O account "antigo" é detectado nos próprios manifests (URI do ECR), então o
# script funciona em qualquer troca de conta, quantas vezes for preciso.
#
# Uso (na raiz do repo):
#   bash gitops/set-account.sh 123456789012      # informando o account
#   bash gitops/set-account.sh                    # autodetecta via AWS CLI
# -----------------------------------------------------------------------------
set -euo pipefail

NEW="${1:-}"

if [[ -z "$NEW" ]] && command -v aws >/dev/null 2>&1; then
  NEW="$(aws sts get-caller-identity --query Account --output text 2>/dev/null | tr -d '\r' || true)"
fi

if [[ ! "$NEW" =~ ^[0-9]{12}$ ]]; then
  echo "ERRO: account ID inválido ('${NEW:-vazio}')."
  echo "Uso: bash gitops/set-account.sh <ACCOUNT_ID_12_DIGITOS>"
  echo "     (ou configure o AWS CLI para autodetectar via 'aws sts get-caller-identity')"
  exit 1
fi

OLD="$(grep -rhoE '[0-9]{12}\.dkr\.ecr\.' --include='*.yaml' gitops/apps 2>/dev/null | head -1 | cut -c1-12 || true)"

if [[ -z "$OLD" ]]; then
  echo "ERRO: não achei nenhuma URI de ECR em gitops/apps/*/*.yaml para detectar o account atual."
  exit 1
fi

if [[ "$NEW" == "$OLD" ]]; then
  echo "Os manifests já usam o account $NEW — nada a fazer."
  exit 0
fi

count=0
while IFS= read -r f; do
  sed -i "s/${OLD}/${NEW}/g" "$f"
  echo "  atualizado: $f"
  count=$((count+1))
done < <(grep -rl --include='*.yaml' "$OLD" gitops/ 2>/dev/null || true)

echo "Feito: $OLD -> $NEW em $count arquivo(s)."
echo "Valide com: kubectl kustomize gitops/apps/flag-service | grep -E 'image:|role-arn'"
