#!/usr/bin/env bash
# Segundo terminal do vídeo: mostra o pod sendo substituído quando o
# self-healing roda (Terminating -> ContainerCreating -> Running) e a
# annotation restartedAt gravada pelo rollout restart.
#
#   bash self-healing/demo/watch-pods.sh [serviço]     (padrão: auth-service)
set -euo pipefail
SVC="${1:-auth-service}"

echo "Último restart registrado no deployment:"
kubectl get deployment -n "$SVC" "$SVC" \
  -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}{"\n"}' || true
echo
echo "Observando pods de ${SVC} (Ctrl+C para sair)..."
kubectl get pods -n "$SVC" -l "app=${SVC}" -o wide --watch-only=false -w
