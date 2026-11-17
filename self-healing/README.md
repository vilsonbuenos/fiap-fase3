# Self-Healing — ToggleMaster (Fase 4)

Quando o Datadog detecta que um microsserviço está devolvendo erros 5xx acima
do limite, um **GitHub Action disparado via webhook** reinicia o deployment no
EKS sem intervenção humana, verifica se ele voltou e registra o resultado.

```
 auth-service (OTel SDK) ──OTLP──▶ otel-gateway ──▶ Datadog APM
                                                     │  trace.http.server.request.{hits,errors}
                                                     ▼
                                  Monitor "[ToggleMaster] auth-service - 5xx > 5%"
                                                     │  @webhook-selfheal-github  + @pagerduty-togglemaster + @webhook-discord-togglemaster
                                                     ▼
                      POST api.github.com/repos/<repo>/dispatches  {event_type: self-healing}
                                                     │
                                                     ▼
                 .github/workflows/self-healing.yaml  (GitHub Actions)
                   1. valida o payload (allowlist, só "Triggered")
                   2. AssumeRoleWithWebIdentity (OIDC, sem chave AWS)
                   3. aws eks update-kubeconfig
                   4. self-healing/scripts/selfheal.sh
                        diagnóstico ▸ cooldown ▸ rollout restart ▸ rollout status ▸ health check
                   5. resumo no Actions + evento no Datadog + mensagem no ChatOps
                                                     │
                                                     ▼
                       EKS: pod antigo Terminating ▸ pod novo Running ▸ 5xx some ▸ monitor Recovered
```

## Arquivos

| Arquivo | O que faz |
|---|---|
| [`.github/workflows/self-healing.yaml`](../.github/workflows/self-healing.yaml) | Workflow disparado por `repository_dispatch` (Datadog) ou manualmente |
| [`self-healing/scripts/selfheal.sh`](scripts/selfheal.sh) | O runbook: diagnóstico, anti-flapping, `rollout restart`, verificação |
| [`terraform/modules/self-healing/`](../terraform/modules/self-healing/) | OIDC provider do GitHub, IAM role e EKS access entry (grupo K8s) |
| [`gitops/self-healing/rbac.yaml`](../gitops/self-healing/rbac.yaml) | RBAC mínimo do grupo, aplicado pelo ArgoCD |
| [`self-healing/datadog/`](datadog/) | Terraform do monitor 5xx e do webhook para o GitHub |
| [`auth-service/chaos.go`](../auth-service/chaos.go) | Injeção de falha para a demo (`/auth/admin/chaos`) |
| [`self-healing/demo/`](demo/) | Scripts do vídeo: tráfego contínuo, injeção manual da falha, pods ao vivo, disparo manual |
| [`self-healing/tests/test-selfheal.sh`](tests/test-selfheal.sh) | Testes do runbook com `kubectl` falso (sem cluster) |
| [`.github/workflows/self-healing-ci.yaml`](../.github/workflows/self-healing-ci.yaml) | CI: testes, shellcheck, actionlint, Terraform validate, build/teste Go, kustomize |

## Decisões de projeto

- **GitHub Action via webhook** (e não Lambda nem um operador no cluster): toda a
  automação fica versionada no mesmo repositório, cada execução deixa um log
  auditável na aba *Actions* e não há infraestrutura nova para manter.
- **Sem credenciais de longa duração**: o job assume a role por OIDC, e a
  *trust policy* aceita só este repositório na branch `main`.
- **Menor privilégio**: a role não é cluster-admin. Ela entra no grupo
  `togglemaster:self-healing`, que só pode fazer `patch` em deployments
  (o `rollout restart`), ler pods/eventos e fazer o health check, e só nos 5
  namespaces dos microsserviços.
- **Payload tratado como não confiável**: o workflow só aceita serviços da
  allowlist, só age nas transições `Triggered`/`Re-Triggered` e nunca
  interpola o payload direto no shell.
- **Anti-flapping / alert fatigue**: se o deployment já foi reiniciado há
  menos de 10 min e o alerta continua, o runbook **não** reinicia de novo.
  Ele marca a execução como `escalated` (job vermelho) para um humano assumir,
  em vez de entrar num loop de restarts. Também há um `concurrency` por serviço.
- **Convive com o ArgoCD**: o `rollout restart` só adiciona a annotation
  `kubectl.kubernetes.io/restartedAt` no template do pod, que não está no Git;
  o ArgoCD não a considera drift e não desfaz a ação.
- **Fecha o ciclo**: o resultado volta para o Datadog como evento (aparece na
  timeline do monitor) e para o canal de ChatOps.

## Setup (uma vez)

### 1. Infra AWS (Terraform principal)

O módulo já está ligado em `terraform/main.tf`:

```bash
cd terraform
terraform apply -var-file="manual.tfvars"
terraform output self_healing_role_arn
```

> Se a conta já tiver o OIDC provider `token.actions.githubusercontent.com`
> (erro `EntityAlreadyExists`), rode com `-var create_github_oidc_provider=false`.

### 2. RBAC no cluster (GitOps)

`gitops/bootstrap/apps/self-healing.yaml` é uma Application nova da root-app:
depois do push, o ArgoCD cria o ClusterRole e os RoleBindings. Para conferir:

```bash
kubectl get rolebinding -A -l app.kubernetes.io/part-of=self-healing
```

### 3. GitHub (Settings ▸ Secrets and variables ▸ Actions)

| Tipo | Nome | Valor |
|---|---|---|
| Variable | `SELF_HEALING_ROLE_ARN` | output `self_healing_role_arn` |
| Variable | `DD_SITE` | ex.: `datadoghq.com` (o mesmo do otel-gateway) |
| Secret (opcional) | `DD_API_KEY` | para registrar o resultado como evento no Datadog |
| Secret (opcional) | `CHATOPS_WEBHOOK_URL` | URL do webhook do canal do Discord (mensagem com o resultado do restart) |

`AWS_REGION` (`us-east-2`) e `EKS_CLUSTER_NAME` (`eks-tc3-prod-001`) já têm
padrão no workflow.

Crie também um **fine-grained personal access token** para o Datadog chamar o
GitHub: *Repository access* = só este repositório, *Permissions ▸ Contents* =
**Read and write** (é o que o endpoint `repository_dispatch` exige).

### 4. Datadog (monitor + webhook)

```bash
cd self-healing/datadog
cp terraform.tfvars.example terraform.tfvars   # API key, APP key, token do GitHub
terraform init
terraform apply
```

Antes, confira o nome da operação dos spans em *APM ▸ Services ▸ auth-service*
(seletor de operação no topo). Se não for `http.server.request`, ajuste
`apm_operation_name`.

Para ligar o self-healing num monitor que já existe (por exemplo, o do colega
que integrou o PagerDuty), basta colocar `@webhook-selfheal-github` na
mensagem dele, dentro de `{{#is_alert}}...{{/is_alert}}`, e o monitor tem que
ser agrupado `by {service}`.

### 4.1 Incidente (PagerDuty) e ChatOps (Discord)

O monitor também abre um incidente e avisa no chat. No recovery, o incidente
é resolvido sozinho.

| Onde | O quê |
|---|---|
| PagerDuty | Serviço `togglemaster` com a integração **Datadog** (gera a *Integration Key*) |
| Datadog ▸ Integrations ▸ PagerDuty | Conectar a conta e adicionar o serviço `togglemaster` com a key → handle `@pagerduty-togglemaster` |
| Discord | Canal ▸ Integrações ▸ Webhooks ▸ Novo webhook (copiar a URL) |
| Datadog ▸ Integrations ▸ Webhooks | `discord-togglemaster`, URL do Discord, payload `{"content": "**$EVENT_TITLE**\nValor: $ALERT_METRIC (transição: $ALERT_TRANSITION)\n$LINK"}` (curto de propósito: com `$TEXT_ONLY_MSG` passa do limite de 2000 caracteres do Discord) → handle `@webhook-discord-togglemaster` |
| GitHub | `gh secret set CHATOPS_WEBHOOK_URL -R vilsonbuenos/fiap-fase4` (mesma URL; o workflow avisa o resultado do restart) |

Os handles já estão no default de `extra_notification_handles`.

### 5. Nova imagem do auth-service

`chaos.go` precisa entrar na imagem: rode o pipeline/`scripts/build-push.sh`
do auth-service e faça o bump da tag (o deployment já tem `CHAOS_ENABLED=true`).

### 6. Teste sem o Datadog

Aba *Actions ▸ self-healing ▸ Run workflow* (marque `dry_run` primeiro), ou:

```bash
bash self-healing/demo/trigger-manual.sh auth-service Triggered
```

## Roteiro da demonstração (vídeo)

Pré-requisitos na máquina: Git Bash, `aws login` feito (conta 574644334976)
e, para o terminal B, o `kubectl`:

```bash
winget install -e --id Kubernetes.kubectl
aws eks update-kubeconfig --region us-east-2 --name eks-tc3-prod-001
```

Antes de gravar, confira que o monitor está **OK** e que o último restart
foi há mais de 10 min (senão o workflow termina como `escalated`).

Deixe abertos três terminais (Git Bash, na raiz do repositório) e o navegador
com Datadog (Monitors), PagerDuty (Incidents), Discord (canal de alertas) e
GitHub Actions.

| Terminal | Comando | Papel |
|---|---|---|
| A | `bash self-healing/demo/traffic.sh` | Tráfego contínuo até Ctrl+C. Verde = 401 (normal), vermelho = 500 |
| B | `bash self-healing/demo/watch-pods.sh auth-service` | Pods ao vivo: mostra a troca do pod |
| C | `bash self-healing/demo/inject-failure.sh` | **Você dispara** a falha na hora certa |

1. **Início:** A e B rodando há alguns segundos, tudo verde (`401`), um pod
   `Running`. Mostre o monitor em **OK**.
2. **Terminal C:** `bash self-healing/demo/inject-failure.sh` (100% de 500 por
   10 min). Ele mostra que o `/auth/health` continua `200`: o Kubernetes não
   percebe a falha.
3. **Terminal A:** as linhas ficam vermelhas (`5/5 5xx`) com o aviso
   `>>> serviço começou a devolver 5xx`.
4. **Datadog ▸ APM ▸ auth-service:** a taxa de erro sobe; abra um trace com
   erro (log `CHAOS: falha injetada`).
5. **Datadog ▸ Monitors** (1 a 3 min): o monitor vai para **ALERT**. Ao mesmo
   tempo:
   - **PagerDuty:** o incidente é aberto;
   - **Discord:** chega a mensagem do alerta;
   - **GitHub Actions:** a execução `Self-healing auto (Datadog: Triggered)`
     aparece sozinha.
6. **GitHub Actions:** abra o log de *Executar runbook*: diagnóstico ▸ cooldown
   ▸ `rollout restart` ▸ `successfully rolled out` ▸ health check OK ▸
   `RESULTADO: healed`. O Discord recebe a mensagem do resultado.
7. **Terminal B:** o pod antigo vai para `Terminating` e o novo fica `Running`.
8. **Terminal A:** volta a ficar verde (`401`) sozinho, com o aviso
   `>>> serviço voltou ao normal`. O pod novo nasce sem a falha injetada.
9. **Uns 5 min depois:** o monitor volta para **OK** (Recovered), o Discord
   recebe a recuperação e o incidente do PagerDuty é **resolvido sozinho**.
10. Extra (alert fatigue): injete de novo antes de 10 min. O workflow **não**
    reinicia e termina como `escalated`, pedindo um humano.

Para desligar a falha manualmente: `bash self-healing/demo/inject-failure.sh off`
(e `... status` para ver o estado).

## Evidências para o relatório

- **Print do log/execução do self-healing**: página da execução no GitHub
  Actions (o *Summary* tem a tabela do alerta + resultado `healed`) e o log
  expandido do passo *Executar runbook*.
- Print do terminal B com o pod `Terminating` → novo pod `Running`.
- Print do monitor do Datadog em ALERT → OK com o evento do self-healing.

## Solução de problemas

| Sintoma | Causa provável |
|---|---|
| Datadog: webhook com `404` | token sem acesso ao repositório ou nome do repositório errado |
| Datadog: webhook com `403`/`422` | token sem `Contents: Read and write` |
| Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | workflow rodando fora da `main` ou `github_repository` errado no Terraform |
| Actions: `deployments.apps ... is forbidden` | Application `self-healing` do ArgoCD ainda não sincronizou (RBAC) |
| Actions: `the server has asked for the client to provide credentials` | access entry não criado (rode o `terraform apply`) |
| Monitor nunca dispara | `apm_operation_name` diferente do real ou sem tráfego no serviço |
| Workflow não aparece após o webhook | o arquivo do workflow precisa estar na branch padrão (`main`) |
