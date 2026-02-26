# Bootstrap Guide — Do zero ao cluster rodando

## Pré-requisitos

```bash
terraform version   # >= 1.7
aws --version       # AWS CLI v2
kubectl version     # >= 1.29
helm version        # >= 3.14
argocd version      # >= 2.10
kubeseal --version  # >= 0.26
```

Configure suas credenciais AWS:

```bash
aws configure
# ou
export AWS_PROFILE=meu-perfil
```

---

## 1. Infraestrutura (Terraform)

```bash
cd terraform

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

O Terraform provisiona:
- VPC com subnets públicas (3 AZs)
- EKS 1.31 com add-ons essenciais (CoreDNS, kube-proxy, VPC-CNI, EBS-CSI)
- Karpenter IAM + SQS + EventBridge + controller (via Helm)
- ECR para as imagens da aplicação
- S3 para backup do CloudNativePG

Anote os outputs — você vai precisar deles:

```bash
terraform output karpenter_node_role_name   # → manifests/karpenter/ec2nodeclass.yaml
terraform output ecr_repository_url         # → .github/workflows/ci.yml (ECR_URL)
terraform output github_actions_role_arn    # → secret AWS_ROLE_ARN no repositório gin-tattoo
```

---

## 2. Atualizar EC2NodeClass com o nome da role

```bash
NODE_ROLE=$(terraform -chdir=terraform output -raw karpenter_node_role_name)
sed -i "s/projetin-cluster-karpenter-node/${NODE_ROLE}/" manifests/karpenter/ec2nodeclass.yaml
```

---

## 3. Instalar ArgoCD

```bash
kubectl create namespace argocd

helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "7.x" \
  --wait

# Senha inicial do admin
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Senha ArgoCD: ${ARGOCD_PASSWORD}"
```

---

## 4. Criar SealedSecrets antes de aplicar o root app

Instale o controller:

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version "2.x" \
  --wait
```

Crie e sele os secrets (substitua os valores reais):

```bash
# Banco de dados (namespace: database)
kubectl create secret generic tattoo-db-credentials \
  --namespace=database \
  --from-literal=username=tattoo_user \
  --from-literal=password='<senha-forte>' \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > manifests/database/sealed-secret.yaml

# App homolog
kubectl create secret generic tattoo-db-credentials \
  --namespace=homolog \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > manifests/gin-tattoo-homolog/sealed-secret.yaml

# App prod
kubectl create secret generic tattoo-db-credentials \
  --namespace=prod \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > manifests/gin-tattoo-prod/sealed-secret.yaml

git add manifests/ && git commit -m "chore: add sealed secrets" && git push
```

### Atualizar IRSA do Loki

Após `terraform apply`, preencha o ARN no values:

```bash
LOKI_ARN=$(terraform -chdir=terraform output -raw loki_role_arn)
sed -i "s|\${LOKI_ROLE_ARN}|${LOKI_ARN}|" manifests/loki/values.yaml
git add manifests/loki/values.yaml && git commit -m "chore: set Loki IRSA ARN" && git push
```

---

## 5. Aplicar o root app (único apply manual)

```bash
kubectl apply -f argocd/root-app.yaml
```

O ArgoCD sincroniza automaticamente (por ordem de sync-wave):

| Wave | O que sobe |
|------|-----------|
| `-2` | VPA, cert-manager |
| `-1` | observability, loki, traefik, cluster-issuers |
| `0`  | karpenter-nodeconfig, database, promtail, network-policies, homolog, prod |

Monitore:

```bash
# Port-forward para a UI do ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --username admin --password "${ARGOCD_PASSWORD}" --insecure

argocd app list
argocd app wait database --timeout 300
argocd app wait observability --timeout 300
```

---

## 6. Configurar GitHub Actions no repositório gin-tattoo

Adicione os seguintes secrets em **Settings → Secrets and variables → Actions** do repositório `sant125/gin-tattoo`:

| Secret | Valor |
|--------|-------|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_role_arn` |
| `SONAR_TOKEN`  | Token gerado no SonarCloud (projeto `sant125_gin-tattoo`) |
| `GH_TOKEN`     | Personal access token com permissão `repo` (para o manifest update) |
| `HOMOLOG_URL`  | URL pública do ingress de homolog (ex: `https://staging.example.com`) |

O workflow `.github/workflows/ci.yml` usa OIDC — nenhuma credencial AWS estática é necessária.

---

## 7. Verificar saúde

```bash
# Nós provisionados pelo Karpenter
kubectl get nodes

# Apps ArgoCD
argocd app list

# Pods da aplicação
kubectl get pods -n prod
kubectl get pods -n homolog

# HPA
kubectl get hpa -n prod

# CloudNativePG
kubectl get cluster -n database

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 3000:80 &
# Acesse http://localhost:3000 → dashboard "gin-tattoo API"
```

---

## 8. Configurar domínios

Após o ArgoCD sincronizar o Traefik, pegue o DNS do NLB:

```bash
kubectl get svc -n traefik traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

No seu provedor de DNS (Cloudflare, GoDaddy, etc.), crie registros CNAME apontando para esse hostname:

```
api.example.com         → CNAME → <nlb-hostname>
staging.example.com     → CNAME → <nlb-hostname>
grafana.example.com     → CNAME → <nlb-hostname>
```

Substitua `example.com` pelo domínio real em:
- `manifests/gin-tattoo-prod/ingress.yaml`
- `manifests/gin-tattoo-homolog/ingress.yaml`
- `manifests/observability/values.yaml` (grafana.ingress.hosts)
- `manifests/cert-manager/cluster-issuers.yaml` (email)

Após os CNAMEs propagarem, o cert-manager emite os certificados automaticamente via HTTP01. Acompanhe:

```bash
kubectl get certificate -A
kubectl describe certificaterequest -n prod
```

---

## Troubleshooting

| Sintoma | Causa | Solução |
|---------|-------|---------|
| Nós não sobem | EC2NodeClass com role errada | `terraform output karpenter_node_role_name` e atualizar o yaml |
| `SealedSecret` não descriptografa | Controller de namespace diferente | Recriar o secret no namespace correto |
| `ErrImagePull` | ECR URL com account ID placeholder | Atualizar image no manifest com a URL real |
| ArgoCD em `OutOfSync` nos CRDs | CRDs grandes precisam de SSA | `syncOptions: [ServerSideApply=true]` (já configurado em observability-app.yaml) |
| CloudNativePG não conecta ao S3 | IAM role dos nós sem permissão no bucket | Verificar a policy `AmazonEC2ContainerRegistryReadOnly` e S3 do node role |
| Loki não grava no S3 | IRSA ARN não atualizado no values.yaml | `terraform output loki_role_arn` e atualizar `manifests/loki/values.yaml` |
| GH Actions ECR push negado | OIDC trust policy com sub errado | Verificar se o `repo:sant125/gin-tattoo:*` na trust policy bate com o repositório que dispara o workflow |
