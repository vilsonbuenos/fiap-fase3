# Roteiro do vídeo: Visão Geral (Fase 4)

> **Objetivo do trecho (enunciado):** mostrar que o cluster EKS (IaC) e o ArgoCD
> (GitOps) continuam rodando com a nova stack de observabilidade.
> **Duração alvo:** cerca de 3 minutos. **Cluster:** `eks-tc3-prod-001` (us-east-2).
> **Repositório da demo:** `github.com/vilsonbuenos/fiap-fase4` (Terraform em `terraform/`,
> GitOps em `gitops/`).
>
> **Stack de observabilidade (namespace `observability`, toda via ArgoCD):**
> `kube-prometheus-stack` (Prometheus, Grafana e Alertmanager), `loki`, `otel-agent`
> (DaemonSet que coleta logs), `otel-gateway` (recebe OTLP e envia para Prometheus, Loki e
> **Datadog APM**) e `observability-config` (SecretProviderClasses e dashboard).

## Antes de gravar (cerca de 10 min antes)

1. `aws eks update-kubeconfig --name eks-tc3-prod-001 --region us-east-2`
2. `bash scripts/preflight-visao-geral.sh`: só grave se terminar em **PRONTO PARA GRAVAR**.
3. Em um terminal separado, deixe rodando:
   `kubectl -n argocd port-forward svc/argocd-server 8080:443`
4. Faça login na UI do ArgoCD (https://localhost:8080) com a senha que o preflight imprimiu.
5. Deixe abertas as abas: console AWS → EKS → `eks-tc3-prod-001`, a UI do ArgoCD e o
   GitHub na pasta `gitops/`.
6. Terminal: fonte grande (16–18pt), tema escuro, janela maximizada, `clear`.
7. Uns 5 min antes, rode `bash scripts/generate-traffic.sh 5`. Assim o `analytics-service`
   sai do zero (o KEDA escala pela fila SQS) e o Grafana e o Datadog já têm dados para os
   próximos trechos do vídeo.

## Sequência de telas e falas

### 1. Console AWS → EKS (cerca de 30 s)

**Tela:** EKS → Clusters → `eks-tc3-prod-001`. Mostre a aba *Overview* (status
**Active**, versão do Kubernetes), depois a aba *Compute* com o node group.

**Fala:**
> "Começando pela visão geral: este é o nosso cluster EKS, o `eks-tc3-prod-001`, em
> us-east-2. Ele foi provisionado inteiramente via Terraform: VPC, node group gerenciado,
> RDS, ElastiCache, SQS, DynamoDB e os add-ons do cluster. Para a Fase 4 a evolução também
> foi por código: subimos para três nós e adicionamos o driver EBS CSI com uma StorageClass
> gp3, que dá disco persistente ao Prometheus e ao Loki."

### 2. Terminal: `bash scripts/demo-visao-geral.sh` (cerca de 75 s)

| Etapa | O que aparece | Fala (curta) |
|---|---|---|
| 1/5 nodes | `kubectl get nodes -o wide` | "Os três nós do node group estão *Ready*, em subnets privadas, com AL2023." |
| 2/5 terraform | `terraform state list` resumido + total | "Aqui está a prova da IaC: o state remoto no S3 tem o cluster, o node group, o add-on EBS CSI, a StorageClass, os bancos, a fila e os Helm releases. Nada foi criado à mão." |
| 3/5 ns | `kubectl get ns` | "Cada microsserviço tem o próprio namespace, e a observabilidade fica no namespace `observability`, separada da aplicação." |
| 4/5 pods | `kubectl get pods -A` colorido | "Em roxo, os cinco serviços do ToggleMaster. Em amarelo, a nova stack: Prometheus, Grafana, Alertmanager, Loki e os coletores OpenTelemetry. O agent roda em cada nó e o gateway envia os traces para o Datadog APM. Tudo *Running*." |
| 5/5 argocd | `kubectl -n argocd get applications` | "Do lado GitOps, o ArgoCD gerencia dez Applications: os cinco serviços e as cinco da observabilidade, todas *Synced* e *Healthy*." |

### 3. UI do ArgoCD (cerca de 45 s)

**Tela:** lista de Applications (tudo verde). Clique na `root-app` e mostre a árvore
App of Apps. Depois abra uma app de serviço (ex.: `flag-service`) e a `kube-prometheus-stack`,
que mostra a árvore com Prometheus, Grafana e Alertmanager.

**Fala:**
> "Na interface do ArgoCD usamos o padrão *App of Apps*: a `root-app` aponta para a pasta
> `gitops/bootstrap/apps` e cria uma Application por componente. Todas estão sincronizadas
> com o Git e saudáveis. O sync é automático, com *prune* e *self-heal*: se alguém alterar
> algo direto no cluster, o ArgoCD desfaz e volta ao que está no repositório. A
> observabilidade entrou pelo mesmo fluxo: os charts oficiais com os *values* versionados
> no nosso repo, e *sync waves* garantindo que namespace e secrets venham antes dos pods."

### 4. GitHub: pasta `gitops/` (cerca de 30 s)

**Tela:** repo `vilsonbuenos/fiap-fase4` → `gitops/bootstrap/apps/` (os 10 YAMLs) →
`gitops/observability/values/` → `gitops/apps/flag-service/kustomization.yaml` → histórico
de commits mostrando os commits `deploy <tag>`.

**Fala:**
> "Esta é a fonte da verdade. Cada arquivo em `bootstrap/apps` vira uma Application, e as
> configurações da observabilidade ficam em `observability/values`. Um deploy é só um commit
> da nova tag de imagem no `kustomization.yaml`, e o ArgoCD aplica sozinho. Ou seja: infraestrutura em
> Terraform, entrega em GitOps, e agora observabilidade em cima dessa mesma base. Na
> sequência, o grupo mostra os detalhes de métricas, logs, traces e alertas."

## Prints para o relatório

- [ ] Console AWS: cluster `eks-tc3-prod-001` com status **Active** (aba Overview)
- [ ] Console AWS: node group com nós em *Ready* (aba Compute)
- [ ] Terminal: `kubectl get nodes -o wide`
- [ ] Terminal: resumo do `terraform state list` com o total de recursos
- [ ] Terminal: `kubectl get pods -A` com serviços e observabilidade destacados
- [ ] Terminal: `kubectl -n argocd get applications`, tudo Synced/Healthy
- [ ] UI do ArgoCD: lista de Applications **toda verde**
- [ ] UI do ArgoCD: árvore da `root-app` (App of Apps)
- [ ] UI do ArgoCD: a Application `kube-prometheus-stack` aberta (árvore de recursos)
- [ ] Terminal: `kubectl -n observability get pods,pvc` com as PVCs *Bound* em gp3
- [ ] GitHub: pasta `gitops/bootstrap/apps/` com as 10 Applications
- [ ] GitHub: histórico com os commits `deploy <tag>`
- [ ] Saída do `preflight-visao-geral.sh` terminando em **PRONTO PARA GRAVAR**

## Plano B

- **Port-forward caiu:** rode o comando de novo e dê F5 na UI.
- **App OutOfSync na hora:** clique em *Sync* na UI e explique (polling padrão de 3 min).
- **Pod em CrashLoop:** não esconda. Diga que o self-healing do Kubernetes/ArgoCD está
  atuando e siga em frente (o trecho de alertas e self-healing do grupo cobre isso).
