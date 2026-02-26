# aws-devops

Infraestrutura para o [gin-tattoo](https://github.com/sant125/gin-tattoo) — REST API em Go rodando em EKS com GitOps, observabilidade completa e TLS automático.

## Arquitetura

<a href="docs/diagrams/architecture.svg">
  <img src="docs/diagrams/architecture.svg" alt="Arquitetura" width="100%">
</a>

## Pipeline

<a href="docs/diagrams/pipeline.svg">
  <img src="docs/diagrams/pipeline.svg" alt="Pipeline CI/CD" width="100%">
</a>

## Stack

| Camada | Tecnologia |
|--------|-----------|
| App | Go 1.22 + Gin, `/metrics` (Golden Signals), `/health`, Swagger |
| Infra | Terraform — VPC, EKS 1.31, Karpenter (Spot + OD), ECR, S3 |
| CI/CD | GitHub Actions (OIDC → ECR, SonarCloud, OWASP ZAP) → ArgoCD |
| Banco | CloudNativePG — 3 instâncias HA, backup S3 |
| Observability | kube-prometheus-stack + Loki + Promtail |
| Secrets | Bitnami SealedSecrets |
| TLS / Ingress | Traefik + NLB + cert-manager (Let's Encrypt) |
| Segurança | Network Policies, govulncheck, Trivy, OWASP ZAP, SonarCloud |

## Custo estimado (us-east-1)

| Recurso | $/mês |
|---------|-------|
| EKS control plane | $73 |
| Nós on-demand (2× t3.medium) | ~$60 |
| Nós Spot (2× t3.medium) | ~$15 |
| CloudNativePG storage (3× 20Gi gp3) | ~$5 |
| S3 + ECR | ~$3 |
| **Total** | **~$156/mês** |

Sem NAT Gateway (subnets públicas) — economia de ~$130/mês por AZ. Sem RDS — ~$90/mês a menos vs db.t3.medium Multi-AZ.

## Bootstrap

Ver [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

```bash
terraform -chdir=terraform init && terraform -chdir=terraform apply
kubectl apply -f argocd/root-app.yaml
```

## Estrutura

```
.
├── terraform/           # VPC, EKS, Karpenter, ECR, S3, IAM (OIDC GH Actions, Loki IRSA)
├── manifests/
│   ├── database/        # CloudNativePG cluster (3 instâncias)
│   ├── gin-tattoo-homolog/
│   ├── gin-tattoo-prod/
│   ├── loki/            # Loki monolithic (S3) + Promtail
│   ├── network-policies/
│   ├── karpenter/       # NodePool + EC2NodeClass
│   └── observability/   # kube-prometheus-stack, dashboard, alertas
├── argocd/              # root app + Applications individuais
└── docs/
    ├── BOOTSTRAP.md
    └── diagrams/
```
