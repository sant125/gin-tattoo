# Bootstrap Guide — Do zero ao cluster rodando

## Pré-requisitos

```bash
terraform version   # >= 1.7
aws --version       # AWS CLI v2
kubectl version     # >= 1.29
helm version        # >= 3.14
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
- VPC com subnets públicas (3 AZs, IP público automático)
- EKS 1.32 com add-ons essenciais (CoreDNS, kube-proxy, VPC-CNI, EBS-CSI com IRSA)
- Managed node group `system` (t3.small, taint `CriticalAddonsOnly`) — hospeda Karpenter e addons
- Karpenter IAM + SQS + EventBridge + controller (via Helm, aguarda 3min o node system)
- Access entry do caller com `AmazonEKSClusterAdminPolicy`
- StorageClass `gp3` como padrão
- ECR, S3 (backup CNPG + Loki), IAM IRSA roles, OIDC GitHub Actions

Anote os outputs:

```bash
terraform output karpenter_node_role_name   # → manifests/karpenter/ec2nodeclass.yaml
terraform output ecr_repository_url         # → secret ECR_URL no repo gin-tattoo
terraform output github_actions_role_arn    # → secret AWS_ROLE_ARN no repo gin-tattoo
terraform output loki_role_arn              # → manifests/loki/values.yaml
```

---

## 2. Aplicar manifests do Karpenter

O Karpenter controller já está rodando (instalado pelo Terraform), mas precisa dos NodePools e EC2NodeClass para provisionar nós.

```bash
# Atualiza o nome da role no EC2NodeClass (gerado dinamicamente pelo Terraform)
NODE_ROLE=$(cd terraform && terraform output -raw karpenter_node_role_name)
sed -i "s/projetin-karpenter-node/${NODE_ROLE}/" manifests/karpenter/ec2nodeclass.yaml

kubectl apply -f manifests/karpenter/
```

Aguarda um nó app ser provisionado (sem taint — onde ArgoCD e demais workloads vão rodar):

```bash
kubectl get nodes -w
```

---

## 3. Instalar SealedSecrets

O SealedSecrets precisa existir antes do root-app para que os SealedSecret resources sejam descriptografados pelo ArgoCD.

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version "2.x" \
  --wait
```

Crie e sele os secrets (substitua os valores reais):

```bash
KUBESEAL="kubeseal --controller-name sealed-secrets --controller-namespace kube-system"

# Banco de dados (namespace: database)
kubectl create secret generic tattoo-db-credentials \
  --namespace=database \
  --from-literal=username=tattoo_user \
  --from-literal=password='<senha-forte>' \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | $KUBESEAL --format yaml > manifests/database/sealed-secret.yaml

# App homolog
kubectl create secret generic tattoo-db-credentials \
  --namespace=homolog \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | $KUBESEAL --format yaml > manifests/gin-tattoo-homolog/sealed-secret.yaml

# App prod
kubectl create secret generic tattoo-db-credentials \
  --namespace=prod \
  --from-literal=DATABASE_URL='postgres://tattoo_user:<senha>@tattoo-db-rw.database.svc:5432/tattoo?sslmode=disable' \
  --dry-run=client -o yaml \
  | $KUBESEAL --format yaml > manifests/gin-tattoo-prod/sealed-secret.yaml

git add manifests/ && git commit -m "chore: add sealed secrets" && git push
```

### Atualizar IRSA do Loki

```bash
LOKI_ARN=$(cd terraform && terraform output -raw loki_role_arn)
sed -i "s|\${LOKI_ROLE_ARN}|${LOKI_ARN}|" manifests/loki/values.yaml
git add manifests/loki/values.yaml && git commit -m "chore: set Loki IRSA ARN" && git push
```

---

## 4. Instalar ArgoCD

O ArgoCD precisa de nós app (sem taint) para agendar — por isso vem após o Karpenter provisionar.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "7.x" \
  --wait --timeout 10m

# Senha inicial do admin
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Senha ArgoCD: ${ARGOCD_PASSWORD}"
```

> PS.: se fizer port-forward no WSL, usa `--address 0.0.0.0` — o WSL tem IP separado do Windows.
> ```bash
> kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0
> ```

---

## 5. Aplicar o root app (único apply manual)

```bash
kubectl apply -f argocd/root-app.yaml
```

O ArgoCD sincroniza automaticamente por ordem de sync-wave:

| Wave | O que sobe |
|------|-----------|
| `-2` | VPA, cert-manager |
| `-1` | CNPG operator, observability, loki, traefik, cluster-issuers |
| `0`  | karpenter-nodeconfig, promtail, network-policies, homolog, prod |
| `2`  | database (aguarda CNPG operator + webhook prontos) |

Monitore:

```bash
kubectl get applications -n argocd
argocd app wait tattoo-database --timeout 300
argocd app wait observability --timeout 300
```

---

## 6. Configurar GitHub Actions no repositório gin-tattoo

Adicione os seguintes secrets em **Settings → Secrets and variables → Actions**:

| Secret | Valor |
|--------|-------|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_role_arn` |
| `SONAR_TOKEN`  | Token gerado no SonarCloud |
| `GH_TOKEN`     | Personal access token com permissão `repo` |
| `HOMOLOG_URL`  | URL pública do ingress de homolog |

O workflow usa OIDC — nenhuma credencial AWS estática é necessária.

---

## 7. Verificar saúde

```bash
# Nós (system + app provisionados pelo Karpenter)
kubectl get nodes

# Apps ArgoCD
kubectl get applications -n argocd

# Banco
kubectl get cluster -n database

# Pods da aplicação
kubectl get pods -n prod
kubectl get pods -n homolog

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 3000:80
# http://localhost:3000 → dashboard "gin-tattoo API"
```

---

## 8. Configurar domínios

Após o ArgoCD sincronizar o Traefik:

```bash
kubectl get svc -n traefik traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

No Cloudflare (ou outro DNS), aponte o domínio apex pro DNS name do NLB via CNAME. Substitua `example.com` pelo domínio real em:
- `manifests/gin-tattoo-prod/ingress.yaml`
- `manifests/gin-tattoo-homolog/ingress.yaml`
- `manifests/observability/values.yaml` (grafana.ingress.hosts)

---

## Troubleshooting

| Sintoma | Causa | Solução |
|---------|-------|---------|
| ArgoCD em Pending após install | Nó app ainda não provisionado | Aguardar Karpenter — verificar `kubectl get nodes` |
| Nós não sobem | EC2NodeClass com role errada | `terraform output karpenter_node_role_name` e atualizar o yaml |
| Nós demoram 10-15min pra entrar | `map_public_ip_on_launch` desativado | Já corrigido no Terraform |
| DNS timeout entre pods em nós diferentes | SGs distintos entre Karpenter nodes e managed node group | Já corrigido no Terraform com `aws_security_group_rule` cross-SG |
| `sealed-secrets-controller not found` | kubeseal procura o service name padrão | Use `--controller-name sealed-secrets --controller-namespace kube-system` |
| `ErrImagePull` | Imagem não publicada no ECR ainda | Rodar o pipeline CI no repo gin-tattoo |
| `tattoo-database` falha com `x509: certificate signed by unknown authority` | Webhook do CNPG ainda inicializando | Aguardar 1-2min e forçar sync: `kubectl patch application tattoo-database -n argocd --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'` |
| Loki não grava no S3 | IRSA ARN não atualizado no values.yaml | `terraform output loki_role_arn` e atualizar `manifests/loki/values.yaml` |
| `helm_release.karpenter` falha com `cluster unreachable` | Access entry do root não existe antes do Helm inicializar | Já corrigido no Terraform com `aws_eks_access_entry` como resource separado com `depends_on` |
| GH Actions ECR push negado | OIDC trust policy com sub errado | Verificar se o `repo:sant125/gin-tattoo:*` na trust policy bate com o repositório |
