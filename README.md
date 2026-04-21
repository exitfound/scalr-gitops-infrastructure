# scalr-gitops-infrastructure

GitOps-инфраструктура: Scalr-as-code (Terraform) + FluxCD (Kubernetes). GKE Autopilot кластер создаётся через Terraform и выступает management-кластером — в нём работают ESO и Scalr-агент. Scalr управляет внешними Terraform-проектами через VCS-workspaces; state каждого проекта хранится в GCS, не в Scalr.

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
GitRepository/flux-system (GitHub, main, interval 5m)
  └─ Kustomization/flux-system → fluxcd/clusters/scalr
       ├─ infrastructure-external-secrets          → ESO HelmRelease
       ├─ infrastructure-external-secrets-config   → ClusterSecretStore (dependsOn: ESO)
       └─ infrastructure-scalr-agent               → ExternalSecret + Agent HelmRelease (dependsOn: ESO config)
```

---

## Структура репозитория

```
scalr-gitops-infrastructure/
├── gke/                                # Terraform: GKE Autopilot кластер + VPC + Cloud NAT (CLI-only)
│   ├── versions.tf                     # GCS backend + providers: google/google-beta >=7.17 <8
│   ├── variables.tf                    # gcp_project_id, cluster_name, CIDRs, master_authorized_networks
│   ├── terraform.tfvars                # gcp_project_id, gcp_region, cluster_name
│   ├── network.tf                      # VPC (module network v18.0) + Cloud NAT (module cloud-router v9.0)
│   ├── cluster.tf                      # GKE Autopilot (module gke-autopilot-cluster v44.0)
│   └── outputs.tf                      # cluster_name, endpoint, ca_cert, location, network, workload_pool
├── scalr-admin/                        # Terraform bootstrap: GCP + Scalr ресурсы (CLI-only)
│   ├── modules/
│   │   ├── eso/                        # ESO GSA + WI binding (shared, один на кластер)
│   │   ├── scalr-agent/               # Per-agent: GSA + WI + GCS IAM + SM IAM + agent pool
│   │   ├── scalr-environment/         # scalr_environment resource
│   │   ├── scalr-vcs-provider/        # scalr_vcs_provider resource
│   │   └── scalr-workspace/           # scalr_workspace + scalr_variable resources
│   ├── gcp.tf                         # module "eso"
│   ├── agents.tf                      # module "agent_*" блоки
│   ├── environment.tf                 # module "env_main"
│   ├── vcs.tf                         # module "vcs_github"
│   ├── workspaces.tf                  # module "ws_admin" (CLI, local)
│   ├── outputs.tf                     # agents map + GSA emails + Scalr IDs
│   ├── versions.tf                    # GCS backend + providers
│   ├── variables.tf                   # gcp_project_id, gcp_region
│   └── terraform.tfvars               # gcp_project_id + gcp_region
└── fluxcd/
    ├── fluxcd-bootstrap/              # Terraform bootstrap: Flux на кластере (CLI-only)
    │   ├── main.tf                    # GKE creds + Flux bootstrap
    │   ├── outputs.tf                 # GSA emails для справки
    │   ├── variables.tf
    │   ├── versions.tf
    │   └── envs/scalr.tfvars          # параметры кластера и проекта
    ├── clusters/scalr/
    │   ├── kustomization.yaml         # Flux entry point
    │   ├── infrastructure.yaml        # Flux Kustomization CRs (интервалы, пути)
    │   └── flux-system/               # авто-генерируется flux_bootstrap_git при первом apply
    └── infrastructure/
        ├── external-secrets/          # ESO: namespace, SA, HelmRepository, HelmRelease
        │   └── serviceaccount.yaml    # WI аннотация — заполняется вручную после scalr-admin apply
        ├── external-secrets-config/   # ClusterSecretStore → GCP SM (WI)
        │   └── clustersecretstore.yaml # projectID — заполняется вручную
        └── scalr-agent/               # Scalr Agent: namespace, SA, ExternalSecret, HelmRelease
            └── serviceaccount.yaml    # WI аннотация — заполняется вручную после scalr-admin apply
```

---

## Почему CLI-only для bootstrap (проблема курицы и яйца)

`gke`, `scalr-admin` и `fluxcd-bootstrap` запускаются **только через CLI** — никогда через Scalr VCS-workspace. Причина в трёх взаимозависимых циклах:

```
[1] Scalr workspace нужен Scalr environment
    → environment создаётся в scalr-admin
    → scalr-admin нельзя запустить через Scalr workspace

[2] Scalr VCS workspace нужен Scalr Agent для запуска
    → Agent разворачивается через fluxcd-bootstrap
    → fluxcd-bootstrap нельзя запустить через Scalr VCS workspace

[3] ESO читает JWT агента через WI
    → WI binding создаётся в scalr-admin
    → scalr-admin создаётся до того как агент существует
```

**Разрыв цикла:** три `terraform apply` через CLI один раз. После этого все изменения — через git push + Flux.

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

- GCP проект создан, billing подключён
- `gcloud auth login && gcloud auth application-default login`
- `terraform` >= 1.3, `kubectl`, `flux` CLI установлены

---

### Шаг 1 — Включить API и создать GCS bucket

```bash
PROJECT=your-gcp-project-id
BUCKET=your-state-bucket-name
REGION=europe-north2

gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=$PROJECT

gcloud storage buckets create gs://$BUCKET \
  --project=$PROJECT \
  --location=$REGION \
  --uniform-bucket-level-access

gcloud storage buckets update gs://$BUCKET --versioning
```

Bucket создаётся вручную один раз — Terraform не может создать собственный backend. Один bucket используется всеми тремя модулями (`gke/`, `scalr-admin/`, `fluxcd-bootstrap/`) с разными prefix.

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

**Agent Pool JWT** — получить после Шага 6 (pool создаётся в ходе scalr-admin apply).

---

### Шаг 3 — Создать SM контейнеры и залить секреты

```bash
gcloud secrets create github-pat             --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token        --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token --replication-policy=automatic --project=$PROJECT

printf %s "ghp_..."  | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ_..."  | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
```

> **Важно:** `printf %s` вместо `echo` — `echo` добавляет перенос строки, что вызывает молчаливые ошибки аутентификации.

`scalr-agent-pool-token` заполнить после Шага 6.

SM контейнеры создаются вручную — Terraform не может создать контейнер и сразу читать из него в одном apply.

---

### Шаг 4 — Адаптировать конфигурацию под свой проект

Отредактировать следующие файлы:

| Файл | Что менять |
|------|-----------|
| `gke/versions.tf` | `bucket` — имя GCS bucket |
| `gke/terraform.tfvars` | `gcp_project_id`, `gcp_region`, `cluster_name` |
| `scalr-admin/versions.tf` | `bucket` — имя GCS bucket |
| `scalr-admin/terraform.tfvars` | `gcp_project_id`, `gcp_region` |
| `scalr-admin/agents.tf` | `gcp_project_id` (строка hardcoded, не var), `state_bucket`, `agent_pool_name` |
| `scalr-admin/environment.tf` | `account_id` — ID Scalr аккаунта |
| `scalr-admin/vcs.tf` | `name` (github username), `account_id` |
| `fluxcd/fluxcd-bootstrap/envs/scalr.tfvars` | `gcp_project_id`, `github_org`, `state_bucket` |
| `fluxcd/infrastructure/external-secrets-config/clustersecretstore.yaml` | `projectID` — GCP project ID |

> **Важно:** `clustersecretstore.yaml` содержит hardcoded `projectID` из которого ESO читает секреты. Если не обновить — ESO не сможет получить `scalr-agent-pool-token` и агент не запустится.

---

### Шаг 5 — terraform apply: gke + scalr-admin (можно параллельно)

`gke` и `scalr-admin` независимы друг от друга — можно запускать одновременно в разных терминалах.

**gke** (~15 минут):
```bash
cd gke/
terraform init
terraform apply
```

**scalr-admin:**
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

Сохранить outputs — понадобятся в Шаге 7:

```bash
terraform -chdir=scalr-admin output
```

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

### Шаг 7 — Заполнить serviceaccount.yaml с Workload Identity аннотациями

Взять GSA emails из `terraform output` (Шаг 5) и вставить в два файла:

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
    iam.gke.io/gcp-service-account: <agents.main.scalr_agent_gsa_email из terraform output>
```

WI аннотация связывает K8s ServiceAccount с GCP GSA. Без неё pod не сможет аутентифицироваться в GCP.

---

### Шаг 8 — Закоммитить все изменения и запушить

```bash
git add \
  gke/versions.tf \
  gke/terraform.tfvars \
  scalr-admin/versions.tf \
  scalr-admin/terraform.tfvars \
  scalr-admin/agents.tf \
  fluxcd/fluxcd-bootstrap/envs/scalr.tfvars \
  fluxcd/infrastructure/external-secrets/serviceaccount.yaml \
  fluxcd/infrastructure/external-secrets-config/clustersecretstore.yaml \
  fluxcd/infrastructure/scalr-agent/serviceaccount.yaml

git commit -m "chore: configure project settings and WI annotations"
git push
```

---

### Шаг 9 — Настроить kubectl на кластер

```bash
gcloud container clusters get-credentials <cluster_name> \
  --region $REGION \
  --project $PROJECT
```

---

### Шаг 10 — terraform apply: fluxcd-bootstrap

```bash
cd fluxcd/fluxcd-bootstrap/

terraform init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="prefix=fluxcd-bootstrap/scalr"

terraform apply -var-file=envs/scalr.tfvars
```

Terraform устанавливает Flux контроллеры в кластер, создаёт `GitRepository` + root `Kustomization` указывающую на `fluxcd/clusters/scalr`.

> **Важно:** `flux_bootstrap_git` автоматически коммитит `gotk-components.yaml` и `gotk-sync.yaml` прямо в GitHub. После apply нужно подтянуть эти коммиты перед следующим push:
> ```bash
> git pull --rebase
> ```

> `fluxcd-bootstrap` нужно запускать только при первом деплое или при обновлении версии Flux. Не нужен при добавлении новых агентов или изменении манифестов.

---

### Шаг 11 — Дождаться автоматического деплоя

Flux синхронизирует репу с интервалом 5 минут. Порядок деплоя определён через `dependsOn`:

```
1. infrastructure-external-secrets       → ESO + CRDs устанавливаются через Helm
2. infrastructure-external-secrets-config → ClusterSecretStore (нужны CRDs из шага 1)
3. infrastructure-scalr-agent            → ExternalSecret + Scalr Agent (нужен ClusterSecretStore)
```

> **Известный race condition:** при первом запуске `infrastructure-external-secrets-config` может упасть с ошибкой webhook ESO — pod ещё не успел поднять endpoints. Flux автоматически повторяет попытку каждые 30 секунд и через 1-2 минуты применит успешно. Ручного вмешательства не требуется.

Проверка:

```bash
# Все Kustomizations Ready
kubectl get kustomizations -A

# HelmReleases Ready
kubectl get helmreleases -A

# ClusterSecretStore Valid
kubectl get clustersecretstore gcp-sm

# ExternalSecret Synced
kubectl get externalsecret scalr-agent-token -n scalr-agent

# Scalr Agent Running
kubectl get pods -n scalr-agent
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=20
# Ожидаем: "Agent session established" + "Agent started"
```

Финальная проверка — **Scalr UI → Agent Pools → `<agent_pool_name>` → Agents** — агент должен появиться в статусе Online.

---

## Регулярное использование

### Изменения в GKE конфигурации

```bash
cd gke/
terraform plan
terraform apply
```

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
  environment_id      = module.env_main.environment_id
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
  interval: 5m
  path: ./fluxcd/infrastructure/my-app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure-external-secrets-config  # если использует ExternalSecret
```

```bash
git push  # Flux подхватит автоматически в течение 5 минут
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
  state_bucket                 = "terraform_state_prod"
  agent_pool_name              = "scalr-gitops-infrastructure-agent-prod"
  agent_pool_vcs_enabled       = false
  agent_pool_token_secret_name = "scalr-agent-pool-token-prod"
  eso_gsa_email                = module.eso.gsa_email
}
```

**3. `terraform apply` в scalr-admin.**

**4. Заполнить `serviceaccount.yaml` с WI аннотацией:**
```bash
terraform -chdir=scalr-admin output  # взять scalr_agent_gsa_email для prod
```

Создать `fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml` с этим email.

**5. Получить JWT из Scalr UI и залить в SM:**
```
Scalr UI → Agent Pools → scalr-gitops-infrastructure-agent-prod → Tokens → Add Token
```
```bash
printf %s "eyJ..." | gcloud secrets versions add scalr-agent-pool-token-prod \
  --data-file=- --project=$INFRA_PROJECT
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

### Форсировать синхронизацию Flux (не ждать 5 минут)

```bash
flux reconcile source git flux-system --namespace flux-system
flux reconcile kustomization infrastructure-external-secrets-config --namespace flux-system
flux reconcile kustomization infrastructure-scalr-agent --namespace flux-system
flux reconcile helmrelease scalr-agent -n scalr-agent
```

### Flux Kustomization застрял в False

```bash
kubectl get kustomizations -A
kubectl describe kustomization infrastructure-external-secrets-config -n flux-system
```

Частая причина: `external-secrets-config` применяется до того как ESO webhook поднял endpoints. Flux повторяет попытку каждые 30 секунд автоматически — ждать не более 2 минут.

### ESO не читает секрет из SM (PermissionDenied)

```bash
kubectl describe externalsecret scalr-agent-token -n scalr-agent
kubectl get clustersecretstore gcp-sm -o yaml | grep projectID
```

Проверить что `projectID` в `clustersecretstore.yaml` совпадает с проектом где лежат секреты. Если нет — обновить файл и сделать `git push`.

Проверить WI binding:
```bash
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

### HelmRelease scalr-agent завис с ошибкой "secret not found"

Значит ExternalSecret ещё не синхронизировался. Принудительно:
```bash
kubectl annotate externalsecret scalr-agent-token -n scalr-agent \
  force-sync=$(date +%s) --overwrite

# После появления секрета форсировать HelmRelease:
flux reconcile helmrelease scalr-agent -n scalr-agent
```

### Scalr Agent не подключается

```bash
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=30
```

Если ошибка токена — JWT в SM невалиден. Залить новый (см. Ротация JWT выше).

### Проверить Workload Identity на кластере

```bash
gcloud container clusters describe <CLUSTER> --region=$REGION --project=$PROJECT \
  --format="value(workloadIdentityConfig.workloadPool)"
# Ожидаем: PROJECT.svc.id.goog
```

### GKE кластер не удаляется

`deletion_protection = false` по умолчанию в текущей конфигурации. Если защита включена:
```bash
# Установить deletion_protection = false в gke/cluster.tf
cd gke/ && terraform apply
terraform destroy
```

### `No state file found` при terraform plan в fluxcd-bootstrap

`scalr-admin` не применён. Применить сначала:
```bash
cd scalr-admin/ && terraform apply
```

### State lock завис

```bash
cd scalr-admin/
terraform force-unlock <LOCK_ID>
```
