# scalr-gitops-infrastructure

GitOps-инфраструктура: Scalr-as-code (Terraform) + FluxCD (Kubernetes). Один GKE-кластер выступает management-кластером — в нём работают ESO и Scalr-агент. Scalr управляет внешними Terraform-проектами через VCS-workspaces; state каждого проекта хранится в GCS, не в Scalr.

---

## Архитектура

```
GKE cluster (management)
  ├── ESO pod
  │     └── KSA external-secrets → WI → eso-gsa@PROJECT
  │                                       └── читает JWT агентов из Secret Manager
  └── Scalr Agent pod
        └── KSA scalr-agent → WI → scalr-agent-gsa@PROJECT
                                     ├── storage.objectAdmin → GCS state bucket
                                     └── управляет ресурсами целевого GCP проекта
```

**Поток JWT токена к агенту:**
```
Scalr UI → Agent Pool → Add Token → eyJ...
  → Secret Manager (scalr-agent-pool-token)
    → ESO (через Workload Identity, без статических ключей)
      → K8s Secret scalr-agent-token
        → HelmRelease valuesFrom
          → Scalr Agent pod подключается к Scalr
```

**Цепочка Flux Kustomizations:**
```
GitRepository/flux-system (GitHub, main, interval 10m)
  └─ Kustomization/flux-system → fluxcd/clusters/scalr
       ├─ infrastructure-external-secrets          → ESO HelmRelease
       ├─ infrastructure-external-secrets-config   → ClusterSecretStore (dependsOn: ESO)
       └─ infrastructure-scalr-agent           → ExternalSecret + Agent HelmRelease (dependsOn: ESO config)
```

---

## Структура репозитория

```
scalr-gitops-infrastructure/
├── scalr-admin/                        # Terraform bootstrap: GCP + Scalr ресурсы (CLI-only)
│   ├── modules/
│   │   ├── eso/                        # ESO GSA + WI binding (shared, один на кластер)
│   │   ├── scalr-agent/               # Per-agent: GSA + WI + GCS IAM + SM IAM + agent pool
│   │   ├── scalr-environment/         # scalr_environment resource
│   │   ├── scalr-vcs-provider/        # scalr_vcs_provider resource
│   │   └── scalr-workspace/           # scalr_workspace + scalr_variable resources
│   ├── gcp.tf                         # module "eso"
│   ├── agents.tf                      # module "agent_*" блоки
│   ├── environment.tf                 # module "env_dev"
│   ├── vcs.tf                         # module "vcs_github"
│   ├── workspaces.tf                  # module "ws_admin" (CLI, local)
│   ├── outputs.tf                     # agents map + GSA emails + Scalr IDs
│   ├── versions.tf                    # GCS backend + providers
│   ├── variables.tf                   # gcp_project_id, gcp_region
│   └── terraform.tfvars               # gcp_project_id + gcp_region
└── fluxcd/
    ├── fluxcd-bootstrap/              # Terraform bootstrap: Flux на кластере (CLI-only)
    │   ├── main.tf                    # GKE creds + Flux bootstrap
    │   ├── outputs.tf                 # GSA emails для справки при ручном создании SA
    │   ├── variables.tf
    │   ├── versions.tf
    │   └── envs/scalr.tfvars          # параметры кластера
    ├── clusters/scalr/
    │   ├── kustomization.yaml         # Flux entry point
    │   └── infrastructure.yaml        # Flux Kustomization CRs (редактируется вручную)
    └── infrastructure/
        ├── external-secrets/          # ESO: namespace, SA, HelmRepository, HelmRelease
        ├── external-secrets-config/   # ClusterSecretStore → GCP SM (WI)
        └── scalr-agent/           # Scalr Agent: namespace, SA, ExternalSecret, HelmRelease
```

---

## Почему CLI-only для bootstrap (проблема курицы и яйца)

`scalr-admin` и `fluxcd-bootstrap` запускаются **только через CLI** — никогда через Scalr VCS-workspace. Причина в трёх взаимозависимых циклах:

```
[1] Scalr workspace нужен Scalr environment
    → environment создаётся в scalr-admin
    → scalr-admin нельзя запустить через Scalr workspace
    (workspace управляет ресурсом от которого сам зависит)

[2] Scalr VCS workspace нужен Scalr Agent для запуска
    → Agent разворачивается через fluxcd-bootstrap
    → fluxcd-bootstrap нельзя запустить через Scalr VCS workspace
    (нет агента чтобы запустить workspace который разворачивает агента)

[3] ESO читает JWT агента через WI
    → WI binding создаётся в scalr-admin
    → scalr-admin создаётся до того как агент существует
```

**Разрыв цикла:** два `terraform apply` через CLI один раз. После этого все изменения — через git push + Flux.

---

## Где хранятся секреты

| Секрет | Где | Кто читает |
|--------|-----|-----------|
| `scalr-api-token` | GCP Secret Manager | `export SCALR_TOKEN=$(gcloud ...)` перед terraform |
| `github-pat` | GCP Secret Manager | `data.tf` → `scalr_vcs_provider` + Flux git auth |
| `scalr-agent-pool-token` | GCP Secret Manager | ESO → K8s Secret → Scalr Agent pod |

Секреты **не попадают в git**. В GCS state попадает `github-pat` (через data source — ограничение Terraform). State bucket должен иметь tight IAM.

---

## Bootstrap: развернуть с нуля

### Предварительные требования

- GCP проект с GKE кластером и включённым Workload Identity
- `gcloud auth login && gcloud auth application-default login`
- `kubectl` настроен на кластер
- `terraform` >= 1.5

---

### Шаг 1 — Создать GCS bucket для Terraform state

```bash
PROJECT=your-gcp-project-id
BUCKET=your-state-bucket-name

gcloud storage buckets create gs://$BUCKET \
  --project=$PROJECT \
  --location=europe-north1 \
  --uniform-bucket-level-access

gcloud storage buckets update gs://$BUCKET --versioning
```

Bucket создаётся вручную один раз — Terraform не может создать собственный backend.

---

### Шаг 2 — Собрать токены

**Scalr API Token:**
```
Scalr UI → Account Settings → API Tokens → Create Token → скопировать eyJ...
```

**GitHub Personal Access Token:**
```
GitHub → Settings → Developer settings → Personal access tokens (classic)
→ Generate new token → scope: repo → скопировать ghp_...
```

**Agent Pool JWT** — получить после Шага 5 (pool создаётся в ходе terraform apply).

---

### Шаг 3 — Создать SM контейнеры и залить секреты

```bash
gcloud secrets create github-pat              --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token         --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token  --replication-policy=automatic --project=$PROJECT

printf %s "ghp_..."  | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ_..."  | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
```

> **Важно:** `printf %s` вместо `echo` — `echo` добавляет перенос строки, что вызывает молчаливые ошибки аутентификации.

`scalr-agent-pool-token` заполнить после Шага 5.

SM контейнеры создаются вручную — Terraform не может создать контейнер и сразу читать из него в одном apply.

---

### Шаг 4 — Адаптировать конфигурацию под свой аккаунт

| Файл | Что менять |
|------|-----------|
| `scalr-admin/terraform.tfvars` | `gcp_project_id`, `gcp_region` |
| `scalr-admin/versions.tf` | GCS bucket name, Scalr hostname в `provider "scalr"` |
| `scalr-admin/agents.tf` | `gcp_project_id`, `scalr_agent_gsa_name`, `state_bucket`, `agent_pool_name` |
| `scalr-admin/environment.tf` | `account_id` |
| `scalr-admin/vcs.tf` | `name` (github username), `account_id` |
| `fluxcd/fluxcd-bootstrap/envs/scalr.tfvars` | `gke_cluster_name`, `gcp_project_id`, `github_org`, `state_bucket` |

---

### Шаг 5 — terraform apply: scalr-admin

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)

cd scalr-admin/
terraform init
terraform apply
```

Создаётся:
- `eso-gsa` — GSA для ESO + WI binding
- `scalr-agent-gsa` — GSA для Scalr Agent + WI binding + GCS IAM + SM IAM accessor
- Scalr environment, agent pool, VCS provider GitHub, admin workspace (local execution)

Проверить outputs:

```bash
terraform output
```

Нужно запомнить значения из `agents.dev.scalr_agent_gsa_email` и `eso_gsa_email` — понадобятся в Шаге 7.

---

### Шаг 6 — Получить Agent Pool JWT и залить в SM

```
Scalr UI → Account Settings → Agent Pools → <agent_pool_name> → Tokens → Add Token → скопировать eyJ...
```

```bash
printf %s "eyJ_..." | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- --project=$PROJECT
```

---

### Шаг 7 — Создать serviceaccount.yaml с Workload Identity аннотацией

Вручную заполнить два файла, подставив GSA emails из `terraform output` (Шаг 5):

**`fluxcd/infrastructure/external-secrets/serviceaccount.yaml`:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets
  annotations:
    iam.gke.io/gcp-service-account: <eso_gsa_email из terraform output>
```

**`fluxcd/infrastructure/scalr-agent/serviceaccount.yaml`:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scalr-agent
  namespace: scalr-agent
  annotations:
    iam.gke.io/gcp-service-account: <agents.dev.scalr_agent_gsa_email из terraform output>
```

```bash
git add fluxcd/infrastructure/
git commit -m "chore: set WI annotations for ESO and scalr-agent"
git push
```

WI аннотация связывает K8s ServiceAccount с GCP GSA. Без неё pod не сможет аутентифицироваться в GCP через Workload Identity.

---

### Шаг 8 — terraform apply: fluxcd-bootstrap

```bash
gcloud container clusters get-credentials <CLUSTER_NAME> --zone <ZONE> --project=$PROJECT

terraform -chdir=fluxcd/fluxcd-bootstrap init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="prefix=fluxcd-bootstrap/scalr"

terraform -chdir=fluxcd/fluxcd-bootstrap apply -var-file=envs/scalr.tfvars
```

Terraform устанавливает Flux контроллеры в кластер, создаёт `GitRepository` + root `Kustomization` указывающую на `fluxcd/clusters/scalr`. После apply Flux начинает следить за репой.

> `fluxcd-bootstrap` нужно запускать только при первом деплое или при обновлении версии Flux. Не нужен при добавлении новых агентов или изменении манифестов.

---

### Шаг 9 — Дождаться автоматического деплоя

Flux синхронизирует репу с интервалом 10 минут. Порядок деплоя определён через `dependsOn`:

```
1. infrastructure-external-secrets      → ESO + CRDs устанавливаются через Helm
2. infrastructure-external-secrets-config → ClusterSecretStore (нужны CRDs из шага 1)
3. infrastructure-scalr-agent       → ExternalSecret + Scalr Agent (нужен ClusterSecretStore)
```

Проверка:

```bash
# Все Kustomizations Ready
flux get kustomization -A

# HelmReleases Ready
flux get helmrelease -A

# ClusterSecretStore Valid
kubectl get clustersecretstore gcp-sm

# ExternalSecret Synced
kubectl get externalsecret scalr-agent-token -n scalr-agent

# Scalr Agent Running и подключился
kubectl get pods -n scalr-agent
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=20
# Ожидаем: "Agent session established" + "Agent started"
```

---

## Регулярное использование

### Изменения в Scalr конфигурации (workspaces, environments)

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)
cd scalr-admin/
terraform plan
terraform apply
```

### Добавление нового Terraform workspace

В `scalr-admin/workspaces.tf`:

```hcl
module "ws_my_project" {
  source              = "./modules/scalr-workspace"
  name                = "my-project"
  environment_id      = module.env_dev.environment_id
  execution_mode      = "remote"
  terraform_version   = "1.5.7"
  auto_apply          = false
  agent_pool_id       = module.agent_main.agent_pool_id
  vcs_provider_id     = module.vcs_github.vcs_provider_id
  vcs_repo_identifier = "your-github-username/your-repo"
  vcs_branch          = "main"
  working_directory   = "terraform/"
  trigger_prefixes    = ["terraform/"]
}
```

```bash
terraform apply  # в scalr-admin/
```

Workspace появится в Scalr UI и будет запускать Terraform при push в repo.

### Добавление нового компонента через GitOps

Создать директорию `fluxcd/infrastructure/my-app/` с манифестами и добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-my-app
  namespace: flux-system
spec:
  interval: 10m
  path: ./fluxcd/infrastructure/my-app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure-external-secrets-config  # если использует ExternalSecret
```

```bash
git push  # Flux подхватит автоматически в течение 10 минут
```

### Добавление нового Scalr Agent (для нового GCP проекта)

**1. Создать SM контейнер для JWT нового агента:**
```bash
gcloud secrets create scalr-agent-pool-token-prod --replication-policy=automatic --project=$INFRA_PROJECT
```

**2. Добавить блок в `scalr-admin/agents.tf`:**
```hcl
module "agent_prod" {
  source = "./modules/scalr-agent"

  name                         = "prod"
  gcp_project_id               = "your-gcp-project-prod"   # целевой проект
  infra_project_id             = var.gcp_project_id         # проект кластера — не меняется
  scalr_agent_gsa_name         = "scalr-agent-gsa-prod"
  scalr_agent_namespace        = "scalr-agent-prod"
  scalr_agent_ksa              = "scalr-agent-prod"
  state_bucket                 = "terraform_state_prod"
  agent_pool_name              = "scalr-gitops-infrastructure-agent-prod"
  agent_pool_vcs_enabled       = false
  agent_pool_token_secret_name = "scalr-agent-pool-token-prod"
  eso_gsa_email                = module.eso.gsa_email
}
```

Добавить в `outputs.tf` блок `prod` в `output "agents"` и в `output "scalr_agent_pool_ids"`.

**3. `terraform apply` в scalr-admin.**

**4. Создать `serviceaccount.yaml` с WI аннотацией:**
```bash
terraform output scalr_agent_gsa_emails  # взять email для prod
```

Создать `fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml` с этим email.

**5. Получить JWT из Scalr UI и залить в SM:**
```
Scalr UI → Agent Pools → scalr-gitops-infrastructure-agent-prod → Tokens → Add Token
```
```bash
printf %s "eyJ..." | gcloud secrets versions add scalr-agent-pool-token-prod --data-file=- --project=$INFRA_PROJECT
```

**6. Создать FluxCD манифесты** `fluxcd/infrastructure/scalr-agent-prod/` (копия `scalr-agent/` с заменой namespace, KSA и SM secret name).

**7. Добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml`.**

**8. `git push`** — Flux задеплоит автоматически.

### Ротация Agent Pool JWT

JWT не истекает автоматически, но при необходимости замены:

```bash
# Scalr UI → Agent Pools → Add Token → скопировать новый eyJ...
printf %s "eyJ_NEW" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут, агент переподключится
```

---

## Устранение проблем

### Flux Kustomization застрял в False

```bash
flux get kustomization -A
kubectl describe kustomization infrastructure-external-secrets -n flux-system
```

Частая причина: `external-secrets-config` применяется до того как ESO установил CRDs. Нужно подождать — Flux повторит попытку автоматически благодаря `remediation.retries: -1` в HelmRelease.

### ESO не читает секрет из SM

```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
# Проверить WI binding (должен быть infra project, не целевой):
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

### Scalr Agent не подключается

```bash
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=30
```

Если ошибка токена — JWT в SM невалиден. Залить новый (см. Ротация JWT выше).

### Проверить WI на кластере

```bash
gcloud container clusters describe <CLUSTER> --zone=<ZONE> --project=$PROJECT \
  --format="value(workloadIdentityConfig.workloadPool)"
# Ожидаем: PROJECT.svc.id.goog
```

### State lock завис

```bash
cd scalr-admin/
terraform force-unlock <LOCK_ID>
```

### `No state file found` при terraform plan в fluxcd-bootstrap

`scalr-admin` не применён. Применить и проверить:
```bash
cd scalr-admin/ && terraform output eso_gsa_email
```
