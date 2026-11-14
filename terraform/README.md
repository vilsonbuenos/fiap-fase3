# Como rodar este Terraform

Passo a passo completo numa conta AWS nova (inclui pré-requisitos, bucket de
state, ArgoCD e observabilidade): [docs/fase4/01-setup-aws-do-zero.md](../docs/fase4/01-setup-aws-do-zero.md).

## 1. Pré-requisitos

- Terraform >= 1.10
- AWS CLI v2
- Acesso à conta AWS (o account id é detectado via `data.aws_caller_identity`)

## 2. Credenciais AWS

Use uma chave de acesso de um usuário IAM (o apply completo leva ~25 min):

```bash
aws configure --profile fiap-fase4      # Access Key, Secret, região us-east-2
aws sts get-caller-identity --profile fiap-fase4
```

Se você já tiver rodado `aws login` (SSO) nesta sessão, limpe variáveis
residuais — elas têm prioridade sobre `--profile`:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
```

## 3. Bucket do state e init

O backend S3 não tem bucket fixo (nome de bucket é global e muda por conta).
Crie o bucket uma vez (ver o guia) e informe no init:

```bash
cd terraform
terraform init -backend-config="bucket=<SEU_BUCKET_DE_STATE>"
```

## 4. Plan / Apply

```bash
terraform plan  -var="aws_profile=fiap-fase4"
terraform apply -var="aws_profile=fiap-fase4"
```

Ou crie um `terraform.tfvars` (ignorado pelo Git) com `aws_profile = "fiap-fase4"`.
O [manual.tfvars](manual.tfvars) é um exemplo e só é lido com `-var-file`.

Variáveis úteis:

| Variável | Padrão | Para quê |
|----------|--------|----------|
| `kubernetes_version` | `1.35` | precisa estar em standard support (`aws eks describe-cluster-versions`) |
| `node_desired_size` | `3` | 5 serviços + ArgoCD + stack de observabilidade |
| `eks_admin_principal_arns` | `[]` | ARNs IAM extras com admin no cluster (colegas, role do self-healing) |

## 5. Problemas já conhecidos

- **Node group falha com "AMI not supported"**: `c7i-flex.large` exige
  `ami_type = "AL2023_x86_64_STANDARD"` (já configurado em [modules/eks/main.tf](modules/eks/main.tf)).
- **Node group não sobe / `VcpuLimitExceeded`**: conta nova costuma ter cota baixa de
  vCPU on-demand. Veja a seção 2.8 do guia.
- **KEDA falha por webhook do ALB sem endpoints**: resolvido com `depends_on`
  do Helm release do KEDA no do ALB controller.
- **Apply falha no meio com "Failed to save state" / `errored.tfstate`**:
  normalmente credencial expirada. Recupere com:
  ```bash
  terraform state push errored.tfstate
  # se der "Error acquiring the state lock":
  terraform force-unlock -force <LockID-do-erro>
  ```
  Depois rode `terraform apply` de novo — é idempotente.

## 6. Destruir tudo

Antes, remova os recursos criados por controllers do cluster (ALB e discos
EBS), senão o destroy da VPC trava. O guia tem a sequência completa:

```bash
kubectl delete ingress --all -A
kubectl delete pvc --all -n observability
terraform destroy -var="aws_profile=fiap-fase4"
```
