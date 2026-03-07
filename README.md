# gin-tattoo

Infraestrutura para o [gin-tattoo](https://github.com/sant125/gin-tattoo) — REST API em Go rodando em EKS com GitOps, observabilidade completa e TLS automático.

Reproduzível do zero: `terraform apply` + `kubectl apply -f argocd/root-app.yaml` e o ArgoCD reconcilia todo o estado do cluster.

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
| Infra | Terraform — VPC, EKS 1.32, Karpenter (Spot + On-demand), ECR, S3 |
| CI/CD | GitHub Actions (OIDC → ECR, SonarCloud, OWASP ZAP) → ArgoCD |
| Banco | CloudNativePG — 3 instâncias HA, backup S3 |
| Observabilidade | kube-prometheus-stack + Loki + Promtail |
| Secrets | Bitnami SealedSecrets |
| Ingress / TLS | Traefik + NLB + cert-manager (Let's Encrypt) |
| DNS | Cloudflare (proxy gratuito) — domínio apex direto no NLB |
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

## Decisões de design

**Karpenter em vez de Cluster Autoscaler**
O Karpenter provisiona nós diretamente via API do EC2, sem precisar de node groups pré-definidos por tipo de instância. O NodePool `spot` cobre workloads stateless (API) e o `on-demand` cobre os stateful (banco). As políticas de disruption consolidam nós subutilizados automaticamente. Para um setup com foco em FinOps, essa é a abordagem cloud-native atual. Em produção com SLAs mais rígidos, o caminho natural seria combinar instâncias reservadas para a baseline com o Karpenter gerenciando o burst.

**CloudNativePG em vez de RDS**
O CloudNativePG roda dentro do cluster com 3 instâncias HA (1 primary, 2 replicas) e expõe métricas completas do PostgreSQL para o Prometheus nativamente — sem exporter externo. Isso permite que o mesmo stack de observabilidade cubra aplicação e banco em um único lugar, o que faz diferença para times com práticas de SRE. O trade-off é o overhead operacional, que é maior do que no RDS. Para times sem DBA ou SRE dedicado, o RDS Multi-AZ ainda é a escolha certa — o custo é justificado. Os pods do banco usam `nodeSelector: capacity-type: ondemand` e regras de pod anti-affinity para garantir que cada réplica fique em um nó diferente, preservando o isolamento por domínio de falha e a tolerância a partição esperada de um sistema CP.

**Traefik em vez de ingress-nginx**
O ingress-nginx acumulou CVEs críticas nos últimos ciclos e sua trajetória de manutenção futura é incerta. O Traefik é ativamente mantido, expõe seu próprio endpoint de métricas para o Prometheus sem exporter separado e integra nativamente com cert-manager para os desafios do Let's Encrypt. Em relação ao AWS Load Balancer Controller: o LBC roteia tráfego via ALB/NLB com custos de ingestão de log por requisição que escalam com o volume. O Traefik mantém o tráfego intra-cluster até sair pelo NLB, sem overhead adicional de logging na AWS.

**Cloudflare em vez de Route53 para DNS**
O plano gratuito do Cloudflare faz proxy do tráfego pela edge deles, adicionando proteção DDoS e cache sem custo. O domínio apex aponta diretamente para o DNS name do NLB — o NLB já distribui entre todas as subnets da região, então a disponibilidade é tratada na camada AWS sem precisar de weighted routing ou health checks no nível de DNS.

**IRSA em vez de EKS Pod Identity**
O Pod Identity requer um DaemonSet de agente rodando no cluster antes que qualquer workload consiga assumir uma role IAM. Isso cria uma dependência de bootstrap: não dá pra instalar o agente sem um cluster funcionando, e os workloads não conseguem autenticar sem o agente. O IRSA usa o OIDC provider do cluster — sem agente in-cluster, a confiança é resolvida diretamente entre o IAM e o control plane do EKS.

**SonarCloud free vs SonarQube self-hosted vs plano pago**
O plano free do SonarCloud analisa apenas a branch principal. Branches de feature e homolog não são analisadas — o pipeline da branch `developer` pula o Sonar e vai direto pro build/deploy. Em produção isso é uma limitação real: code smells e vulnerabilidades introduzidos em feature branches só são detectados depois do merge na main.

Há três caminhos para resolver isso:

- **SonarCloud Team (~$10/mês por desenvolvedor)**: análise de todas as branches com PR decoration, sem infraestrutura pra operar. Faz sentido para times pequenos onde o custo operacional de manter outro serviço não compensa.
- **SonarQube Community (self-hosted, gratuito)**: roda dentro do cluster, análise ilimitada de branches. Requer ~4GB RAM e PostgreSQL dedicado — adiciona ~$60-80/mês de custo de infra (nó on-demand t3.large + storage). O overhead operacional (upgrades, backup, disponibilidade) cai pro time. Faz sentido se o time já tem capacidade SRE e quer controle total sobre os dados de análise.
- **Runner self-hosted + SonarCloud free**: o runner dentro do cluster tem acesso direto ao ECR via IRSA, elimina o `configure-aws-credentials` e reduz o tempo de build por cachear layers localmente. O Sonar ainda fica limitado à main, mas o custo do runner é absorvido pelo cluster existente — sem nó adicional se houver capacidade disponível nos nós on-demand.

Para o contexto atual (portfolio, repo público), o SonarCloud free cobre o essencial: quality gate bloqueando deploys com CVEs críticos ou code smells graves na branch principal.

**Métricas HTTP no Traefik vs na aplicação**
O Traefik expõe automaticamente métricas de request por rota — latência, throughput e status codes (golden signals) — sem que a aplicação precise instrumentar nada. O ServiceMonitor do Traefik já faz o scrape e os dados aparecem no Prometheus. A aplicação expor um endpoint `/metrics` próprio faz sentido apenas para métricas de domínio que o proxy não conhece: número de agendamentos criados, conversão por artista, tempo de query no banco. Para um time avaliando onde investir esforço de instrumentação, cobrir os golden signals via Traefik primeiro e só depois adicionar métricas de negócio na app é a ordem natural.

**Sem Redis**
As réplicas do CloudNativePG cobrem o escalonamento de leitura. Para o workload atual não existe padrão de session state ou invalidação de cache que justifique adicionar outro componente stateful para operar.

## Lições aprendidas

Alguns pontos que levaram tempo real para resolver durante o bootstrap inicial:

- **Primeira análise SonarCloud já retornou issues reais**: na primeira execução do Quality Gate, o scanner identificou container rodando como root e `COPY . .` sem `.dockerignore` como riscos médios de segurança, além de secret expandido inline em bloco `run:`. Os três foram corrigidos no mesmo ciclo — user não-root no Dockerfile, `.dockerignore` cobrindo arquivos sensíveis e secret movido para variável de ambiente antes de ser referenciado no shell. Zero retrabalho depois da PR ser mergeada.

- **IRSA em addons gerenciados do EKS**: vincular uma role IAM customizada a um addon (ex: EBS CSI driver) exige configurar `service_account_role_arn` no addon e garantir que a trust policy da role referencie o OIDC provider do cluster. O módulo não faz isso automaticamente ao receber uma role customizada — a trust policy precisa bater exatamente ou o `AssumeRoleWithWebIdentity` falha silenciosamente.
- **Karpenter >= 1.2.0 para Kubernetes 1.32**: versões abaixo da 1.2 entram em panic no startup com uma verificação de compatibilidade contra a versão do API server. Nenhum aviso durante o `helm install` — só aparece quando o pod sobe.
- **`map_public_ip_on_launch` em subnets públicas**: instâncias EC2 de managed node groups em subnets públicas não recebem IP público por padrão a menos que isso esteja explicitamente configurado na subnet. Sem isso, o kubelet não consegue alcançar o endpoint público do EKS e o nó nunca entra no cluster.
- **Bootstrap do access entry do root**: o provider Helm do Terraform autentica no cluster durante a inicialização do provider, antes de qualquer recurso ser aplicado. Se o access entry IAM do caller ainda não existir, o provider falha com `cluster unreachable` mesmo com o cluster saudável. Criar o access entry como resource independente com `depends_on` explícito no `helm_release` resolve o problema de ordenação de forma permanente.
- **Port-forward no WSL**: o `kubectl port-forward` faz bind no loopback do WSL por padrão. Para acessar pelo browser do Windows, use `--address 0.0.0.0` e o IP do WSL via `hostname -I`.

## Roadmap

- **HA multi-região**: Route53 health checks + latency-based routing entre duas regiões, com os endpoints do NLB como targets. Replicação lógica do CloudNativePG como caminho de dados entre regiões.
- **Istio service mesh**: mTLS entre serviços, políticas de tráfego granulares e tracing distribuído — faz sentido conforme o número de serviços cresce.
- **VPC CNI prefix delegation**: aumenta a densidade de pods em instâncias menores sem trocar o tipo, relevante se o node group system `t3.small` virar gargalo.

## Bootstrap

Ver [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

```bash
terraform init && terraform apply
kubectl apply -f argocd/root-app.yaml
```

## Estrutura

```
.
├── terraform/           # VPC, EKS, Karpenter, ECR, S3, IAM (OIDC GH Actions, IRSA)
├── manifests/
│   ├── database/        # CloudNativePG cluster (3 instâncias)
│   ├── gin-tattoo-homolog/
│   ├── gin-tattoo-prod/
│   ├── loki/            # Loki monolithic (S3) + Promtail
│   ├── network-policies/
│   ├── karpenter/       # NodePool + EC2NodeClass
│   └── observability/   # kube-prometheus-stack, dashboards, alertas
├── argocd/              # App of Apps + Applications individuais
└── docs/
    ├── BOOTSTRAP.md
    └── diagrams/
```
