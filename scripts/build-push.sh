#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build das imagens, push no ECR e atualização da tag no GitOps (kustomization).
# O ECR é IMMUTABLE: a tag é o SHA curto do commit atual. Faça commit do código
# antes de rodar, senão a imagem não corresponde ao que está no Git.
#
# Uso (na raiz do repo, Git Bash):
#   bash scripts/build-push.sh                       # os 5 serviços
#   bash scripts/build-push.sh evaluation-service    # só um
# Depois: git add gitops/apps && git commit -m "deploy <tag>" && git push
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
PREFIX="fiap-fase2"
ALL=(auth-service flag-service targeting-service evaluation-service analytics-service)
SERVICES=("$@")
[[ ${#SERVICES[@]} -eq 0 ]] && SERVICES=("${ALL[@]}")

for t in aws docker git; do
  command -v "$t" >/dev/null 2>&1 || { echo "FALTANDO: $t"; exit 1; }
done

if ! git diff --quiet HEAD -- "${SERVICES[@]}"; then
  echo "ATENÇÃO: há mudanças não commitadas no código dos serviços."
  echo "         A tag (SHA do commit) não vai corresponder ao código da imagem."
  read -r -p "Continuar mesmo assim? [s/N] " ok
  [[ "$ok" == "s" || "$ok" == "S" ]] || exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text | tr -d '\r')"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

echo "Registry: ${REGISTRY}  Tag: ${TAG}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for s in "${SERVICES[@]}"; do
  repo="${PREFIX}/${s}"
  image="${REGISTRY}/${repo}:${TAG}"
  if aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=${TAG}" --region "$REGION" >/dev/null 2>&1; then
    echo "== ${s}: ${TAG} já existe no ECR, pulando build"
  else
    echo "== ${s}: build + push"
    docker build --platform linux/amd64 -t "$image" "$s"
    docker push "$image"
  fi
  sed -i -E "s|^([[:space:]]*newTag:).*|\1 \"${TAG}\"|" "gitops/apps/${s}/kustomization.yaml"
done

echo
echo "Tags atualizadas em gitops/apps/*/kustomization.yaml. Para o ArgoCD aplicar:"
echo "  git add gitops/apps && git commit -m \"deploy ${TAG}\" && git push"
