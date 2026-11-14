# GitOps (ArgoCD) — ToggleMaster

Fonte da verdade dos 5 workloads e, desde a Fase 4, da stack de observabilidade
(Prometheus, Grafana, Loki e OpenTelemetry Collector). O ArgoCD
(`selfHeal: true`) reconcilia o cluster com o que está aqui no Git. O
Terraform não é dono destes manifests.

Passo a passo completo numa conta AWS nova: [docs/fase4/01-setup-aws-do-zero.md](../docs/fase4/01-setup-aws-do-zero.md).

## Estrutura

```
gitops/
  bootstrap/
    root-app.yaml                # App of Apps — aplica só este
    apps/                        # 1 Application por componente
      <service>.yaml             # 5 microsserviços (kustomize)
      observability-config.yaml  # namespace, SecretProviderClasses, dashboards
      kube-prometheus-stack.yaml # Helm: Prometheus + Grafana + Alertmanager
      loki.yaml                  # Helm: Loki monolítico
      otel-gateway.yaml          # Helm: OTel Collector (Deployment)
      otel-agent.yaml            # Helm: OTel Collector (DaemonSet)
  apps/
    <service>/                   # manifests + kustomization.yaml
  observability/
    values/                      # values dos charts Helm acima
    config/                      # kustomize: namespace, SPCs, dashboard JSON
```

As Applications de Helm usam *multi-source*: o chart vem do repositório
oficial e o arquivo de values vem deste repo (`$values/gitops/observability/values/...`).

## Repositório e Account ID

- `repoURL` das Applications: `https://github.com/vilsonbuenos/fiap-fase3.git`.
  Se o repositório for privado, cadastre a credencial no ArgoCD antes do sync.
- O Account ID aparece nas annotations de IRSA, nas URIs do ECR e nas URLs do
  SQS. Para trocar de conta, rode na raiz do repo (detecta o account atual nos
  próprios manifests):

```bash
bash gitops/set-account.sh                 # autodetecta via AWS CLI
bash gitops/set-account.sh 123456789012    # ou informando o account
```

## Bootstrap do ArgoCD

Com o kubeconfig apontando pro cluster certo (confira `kubectl config
current-context`):

```bash
bash gitops/install-argocd.sh
```

Ele instala o ArgoCD via Helm (versão pinada), aplica a root-app e imprime a
senha do admin e o comando de port-forward.

Para testar sem AWS (cluster kind local), use `bash gitops/test-local.sh`.

## Validar localmente antes de commitar

```bash
kubectl kustomize gitops/apps/<service>
kubectl kustomize gitops/observability/config
```

## Atualizar a versão de um serviço

`scripts/build-push.sh` faz build/push no ECR com a tag = SHA do commit e
reescreve o `newTag` em `gitops/apps/<service>/kustomization.yaml`. Depois é só
commit + push; o ArgoCD sincroniza (polling de até 3 min, ou **Sync** na UI).

O workflow reutilizável `.github/workflows/gitops-bump.yaml` faz a mesma troca
de tag a partir de um pipeline (`workflow_call` com `service` e `image_tag`).

O ECR é **IMMUTABLE**: a tag TEM que ser nova a cada build (SHA do commit).

## Notas

- **analytics-service**: sem ingress; inclui `scaledobject.yaml` +
  `keda-trigger-auth.yaml`. A Application tem `ignoreDifferences` para o KEDA não
  deixar o ScaledObject `OutOfSync` para sempre.
- **Observabilidade**: arquitetura e justificativa em
  [docs/fase4/02-arquitetura-otel.md](../docs/fase4/02-arquitetura-otel.md).
