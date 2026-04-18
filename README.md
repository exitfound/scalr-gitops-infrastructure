# scalr-gitops-infrastructure

GitOps инфраструктура: Scalr-as-code (Terraform) + FluxCD (Kubernetes). Управление Scalr через Terraform CLI, GitOps через FluxCD + ESO + Workload Identity.

---

## Структура репозитория

```
scalr-gitops-infrastructure/
├── scalr-admin/                        # Terraform: GCP bootstrap + Scalr конфигурация
│   ├── versions.tf                     # GCS backend + providers (google, scalr)
│   ├── variables.tf                    # gcp_project_id, gcp_region, eso_namespace, eso_ksa
│   ├── terraform.tfvars                # Только gcp_project_id + gcp_region
│   ├── data.tf                         # Читает github-pat из GCP Secret Manager
│   ├── gcp.tf                          # ESO GSA + WI binding (shared)
│   ├── agents.tf                       # Явные module-блоки для каждого Scalr Agent
│   ├── environment.tf                  # Scalr environment
│   ├── vcs.tf                          # Scalr VCS provider (GitHub)
│   ├── workspaces.tf                   # scalr_workspace.admin (CLI, execution_mode=local)
│   ├── outputs.tf                      # agents map + GSA emails + Scalr resource IDs
│   └── modules/
│       ├── scalr-agent/                # Per-agent: GSA + WI + GCS IAM + SM IAM + agent pool
│       ├── scalr-environment/          # scalr_environment resource
│       ├── scalr-vcs-provider/         # scalr_vcs_provider resource
│       └── scalr-workspace/            # scalr_workspace + scalr_variable resources
└── fluxcd/
    ├── fluxcd-bootstrap/               # Terraform: bootstrap FluxCD на кластере (CLI, per-cluster)
    │   ├── envs/scalr.tfvars           # Значения для scalr кластера (cluster_name = "scalr")
    │   └── templates/                  # Шаблоны ServiceAccount + ClusterSecretStore
    ├── clusters/scalr/                 # Scalr infra-кластер. Не "dev" среда —
    │                                   #   management-кластер для всей Scalr платформы.
    │                                   #   infrastructure.yaml — Kustomization с dependsOn
    └── infrastructure/
        ├── external-secrets/           # ESO HelmRelease
        ├── external-secrets-config/    # ClusterSecretStore → GCP SM через WI
        └── scalr-agent-dev/            # Scalr Agent (dev): ExternalSecret + HelmRelease
```

---

## Архитектура

```
GKE cluster (один, shared)
  ├── ESO pod
  │     └── KSA → eso-gsa@PROJECT → читает JWT всех агентов из SM
  │
  └── Scalr Agent pod (dev)
        └── KSA → scalr-agent-gsa@PROJECT → управляет GCP ресурсами
                                           → читает/пишет Terraform state в GCS
```

**ESO — shared** (один на кластер). **Каждый Scalr Agent** — свой pod, своя GSA, своя WI binding, свой agent pool. Добавление агента для нового GCP проекта = один новый `module "agent_*"` блок в `agents.tf`.

---

## Ключевые решения

### Почему WI в scalr-admin/, а не в VCS-workspace

WI нужна для старта ESO и Scalr Agent. Вынести в VCS-workspace нельзя из-за circular dependency:

```
VCS-workspace создаёт WI → нужен Scalr Agent для запуска
Scalr Agent стартует → нужна WI (ESO читает JWT через WI)
```

WI создаётся один раз через CLI до того как агент существует. После бутстрапа меняется редко.

### Почему scalr-admin/ управляется только через CLI

`scalr-admin/` создаёт Scalr ресурсы (environment, agent pool, workspace). Если прицепить к Scalr VCS-workspace — циклическая зависимость. Поэтому:

- Запускается **только через CLI**
- `workspace.admin` создаётся в Scalr но `execution_mode = "local"`
- Стейт в **GCS**, не в Scalr

### Почему SM контейнеры не в Terraform

Terraform не может создать SM контейнер и сразу же прочитать из него значение в одном `apply`. SM контейнеры создаются **один раз вручную через gcloud**. В Terraform только `data` sources.

### Почему terraform.tfvars содержит только 2 строки

Все значения (Scalr account ID, hostname, GitHub username, agent pool names и т.д.) захардкожены прямо в вызовах модулей — там где используются. `terraform.tfvars` содержит только значения, нужные для Google provider: `gcp_project_id` и `gcp_region`.

### Где хранятся секреты

| Секрет | GCP Secret Manager | Кто читает |
|--------|-------------------|------------|
| `scalr-api-token` | `scalr-api-token` | `export SCALR_TOKEN=$(gcloud ...)` перед terraform |
| `github-pat` | `github-pat` | `data.tf` → `scalr_vcs_provider` |
| `scalr-agent-pool-token` | `scalr-agent-pool-token` | ESO → K8s Secret → Scalr Agent pod |

Секреты не попадают в Terraform state, не хранятся в git, не передаются как переменные.

### Поток JWT токена к агенту

```
Scalr UI → Add Token → eyJ...
    → gcloud secrets versions add scalr-agent-pool-token
        → GCP Secret Manager
            → ESO (Workload Identity, без ключей)
                → ExternalSecret → K8s Secret scalr-agent-token
                    → HelmRelease valuesFrom
                        → Scalr Agent pod подключается к Scalr
```

### Цепочка зависимостей FluxCD

```
GitRepository/flux-system (GitHub, main, interval 5m)
  └─ Kustomization/flux-system → path: ./fluxcd/clusters/scalr
       ├─ infrastructure-external-secrets
       │    └─ ESO HelmRelease
       ├─ infrastructure-external-secrets-config  [dependsOn: external-secrets]
       │    └─ ClusterSecretStore gcp-sm (Workload Identity)
       └─ infrastructure-scalr-agent-dev          [dependsOn: external-secrets-config]
            └─ ExternalSecret + Scalr Agent HelmRelease
```

---

## Bootstrap: развернуть с нуля

### Предварительные требования

- GCP проект с GKE и Workload Identity
- GCS бакет для Terraform state (создать вручную)
- `gcloud auth login && gcloud auth application-default login`
- `kubectl` настроен на кластер
- `terraform` >= 1.5
- Scalr аккаунт (free tier достаточно)

---

### Шаг 1: Получить токены

**Scalr API Token:**
Scalr UI → Account Settings → API Tokens → Create Token → скопировать `eyJ...`

**GitHub PAT:**
GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic) → scope: `repo` → скопировать `ghp_...`

**Agent Pool JWT** — получить после Шага 4 (нужен уже созданный pool).

---

### Шаг 2: Адаптировать под свой аккаунт

| Файл | Что менять |
|------|-----------|
| `scalr-admin/terraform.tfvars` | `gcp_project_id`, `gcp_region` |
| `scalr-admin/versions.tf` | GCS bucket name + Scalr hostname в `provider "scalr"` |
| `scalr-admin/agents.tf` | `gcp_project_id`, `scalr_agent_gsa_name`, `state_bucket`, `agent_pool_name` |
| `scalr-admin/environment.tf` | `account_id` |
| `scalr-admin/vcs.tf` | `name` (github username), `account_id` |
| `fluxcd/fluxcd-bootstrap/envs/scalr.tfvars` | `gke_cluster_name`, `gcp_project_id`, `github_org` |

> GSA email-ы в FluxCD манифестах заполняются автоматически через `terraform_remote_state` — ручное редактирование не нужно.

---

### Шаг 3: Создать SM контейнеры и залить секреты

```bash
PROJECT=your-gcp-project-id

gcloud secrets create github-pat             --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token        --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token --replication-policy=automatic --project=$PROJECT

printf %s "ghp_..."  | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ..."   | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
# scalr-agent-pool-token — заполнить после Шага 4
```

---

### Шаг 4: Terraform apply для scalr-admin

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)

cd scalr-admin/
terraform init
terraform plan
terraform apply
```

Создаётся:
- GSA `eso-gsa` + WI binding → для ESO
- GSA `scalr-agent-gsa` + WI binding + GCS IAM + SM accessor → для Scalr Agent (dev)
- Scalr environment, agent pool, VCS provider GitHub, admin workspace

Проверить outputs:

```bash
terraform output
```

---

### Шаг 5: Получить Agent Pool JWT и залить в SM

```
Scalr UI → Account Settings → Agent Pools → scalr-gitops-infrastructure-agent → Tokens → Add Token
```

```bash
printf %s "eyJ..." | gcloud secrets versions add scalr-agent-pool-token --data-file=- --project=$PROJECT
```

---

### Шаг 6: Проверить Workload Identity на кластере

```bash
gcloud container clusters describe <CLUSTER> --zone=<ZONE> --project=$PROJECT \
  --format="value(workloadIdentityConfig.workloadPool)"
# Ожидаем: <PROJECT>.svc.id.goog
```

---

### Шаг 7: Bootstrap FluxCD

```bash
cd fluxcd/fluxcd-bootstrap/

terraform init -backend-config="prefix=fluxcd-bootstrap/dev"
terraform apply -var-file=envs/scalr.tfvars
```

Terraform автоматически:
1. Читает GSA emails из `scalr-admin` remote state
2. Коммитит `serviceaccount.yaml` с правильными WI аннотациями в GitHub
3. Устанавливает FluxCD на кластер и регистрирует GitRepository

FluxCD после этого разворачивает цепочку сам: ESO → ClusterSecretStore → Scalr Agent.

---

### Шаг 8: Проверка

```bash
# FluxCD — все Kustomization Ready
flux get kustomization -A

# HelmReleases — ESO и scalr-agent Ready
flux get helmrelease -A

# ESO — ClusterSecretStore Valid, ExternalSecret Synced
kubectl get clustersecretstore
kubectl get externalsecret -n scalr-agent

# Scalr Agent — pod Running, подключился к Scalr
kubectl get pods -n scalr-agent
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=20
# Ожидаем: "connected" или "waiting for runs"
```

---

## Регулярное использование

Для изменений в Scalr конфигурации:

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)
cd scalr-admin/
terraform plan
terraform apply
```

Никаких VCS, никаких автоматических запусков — только явный CLI.

---

## Устранение проблем

### Залип state lock

```bash
cd scalr-admin/
terraform force-unlock <LOCK_ID>
```

### ESO не читает секрет из SM

```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Должен быть: serviceAccount:<PROJECT>.svc.id.goog[external-secrets/external-secrets]
```

### Scalr Agent не подключается

```bash
kubectl get secret scalr-agent-token -n scalr-agent -o jsonpath='{.data.token}' | base64 -d | head -c 20
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=30
```

### Agent Pool Token истёк

```bash
# Scalr UI → Agent Pools → Add Token → скопировать новый JWT
printf %s "eyJ_НОВЫЙ" | gcloud secrets versions add scalr-agent-pool-token --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут
```
