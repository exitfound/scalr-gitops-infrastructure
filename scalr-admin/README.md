# scalr-admin

Terraform-конфигурация для bootstrap Scalr-as-code поверх GCP. Управляет GCP-сервисными аккаунтами, Workload Identity биндингами и Scalr-ресурсами (environment, agent pools, VCS provider, workspaces). Запускается **только через CLI** — никогда через Scalr VCS workspace.

---

## Содержание

1. [Архитектура](#архитектура)
2. [Файловая структура](#файловая-структура)
3. [Нюансы которые были решены](#нюансы-которые-были-решены)
4. [Почему CLI-only](#почему-cli-only)
5. [Почему WI живёт здесь](#почему-wi-живёт-здесь)
6. [Почему SM контейнеры создаются вручную](#почему-sm-контейнеры-создаются-вручную)
7. [Почему SCALR_TOKEN нельзя читать из SM](#почему-scalr_token-нельзя-читать-из-sm)
8. [Почему state в GCS](#почему-state-в-gcs)
9. [Предварительные требования](#предварительные-требования)
10. [Шаг 1 — Сбор токенов](#шаг-1--сбор-токенов)
11. [Шаг 2 — Адаптация конфигурации](#шаг-2--адаптация-конфигурации)
12. [Шаг 3 — GCS bucket для state](#шаг-3--gcs-bucket-для-state)
13. [Шаг 4 — SM контейнеры и секреты](#шаг-4--sm-контейнеры-и-секреты)
14. [Шаг 5 — terraform apply](#шаг-5--terraform-apply)
15. [Шаг 6 — Agent Pool JWT](#шаг-6--agent-pool-jwt)
16. [Добавление нового агента](#добавление-нового-агента)
17. [Добавление нового workspace](#добавление-нового-workspace)
18. [Устранение проблем](#устранение-проблем)

---

## Архитектура

Используется **Option A: один infra-кластер, все агенты в нём**.

```
GKE кластер (infra project: beneflo-gcp-project-dev)
  │
  ├── ESO pod
  │     └── KSA: external-secrets
  │           └── WI → eso-gsa@beneflo-gcp-project-dev
  │                     └── читает JWT всех агентов из SM
  │
  └── Scalr Agent pod "dev"
        └── KSA: scalr-agent (namespace: scalr-agent)
              └── WI → scalr-agent-gsa@beneflo-gcp-project-dev
                        ├── storage.objectAdmin → GCS state bucket
                        └── управляет ресурсами в gcp_project_id
```

**Ключевые свойства:**
- ESO — один shared экземпляр. Читает JWT токены всех агентов из GCP Secret Manager.
- Каждый Scalr Agent — отдельный pod, своя GSA в целевом GCP проекте, свой Scalr agent pool.
- Новый агент для нового GCP проекта = один новый `module "agent_*"` блок + `terraform apply`.
- `infra_project_id` всегда указывает на проект кластера, независимо от того в каком проекте GSA агента.

---

## Файловая структура

```
scalr-admin/
├── modules/
│   ├── eso/                  # ESO GSA + WI binding (shared, один на кластер)
│   ├── scalr-agent/          # Per-agent: GSA + WI binding + GCS IAM + SM IAM + agent pool
│   ├── scalr-environment/    # scalr_environment resource
│   ├── scalr-vcs-provider/   # scalr_vcs_provider resource
│   └── scalr-workspace/      # scalr_workspace + scalr_variable resources
├── versions.tf          # GCS backend, required_providers, provider configs
├── variables.tf         # gcp_project_id, gcp_region, eso_namespace, eso_ksa
├── terraform.tfvars     # gcp_project_id + gcp_region (всё остальное хардкодено в вызовах)
├── data.tf              # Читает github-pat из GCP Secret Manager
├── gcp.tf               # Вызов module "eso"
├── agents.tf            # Явные module "agent_*" блоки
├── environment.tf       # module "env_dev"
├── vcs.tf               # module "vcs_github"
├── workspaces.tf        # module "ws_admin" (CLI, execution_mode=local)
└── outputs.tf           # agents map + eso_gsa_email + Scalr resource IDs
```

**Принципы организации:**
- `terraform.tfvars` — только `gcp_project_id` и `gcp_region`. Все остальные значения (Scalr account ID, имена агентов, bucket) захардкожены прямо в вызовах модулей где используются.
- `gcp.tf` — только вызов `module "eso"`. Ресурсы агентов полностью инкапсулированы в `modules/scalr-agent/`.
- `agents.tf` — явные `module "agent_*"` блоки вместо `for_each` по map. Добавление агента = копирование блока.
- Все модули используют `versions.tf` (не `provider.tf`) для объявления `required_providers`.

---

## Нюансы которые были решены

### 1. Баг: WI binding использовал неправильный проект

**Проблема.** Workload Identity binding имеет формат:
```
member = "serviceAccount:<CLUSTER_PROJECT>.svc.id.goog[<namespace>/<ksa>]"
```

Критично: `<CLUSTER_PROJECT>` — это проект **GKE кластера**, а не проект где живёт GSA. Исходный код использовал `var.gcp_project_id` (целевой проект агента), что работало случайно пока infra-проект и целевой проект совпадали. При добавлении агента для другого проекта binding был бы невалидным.

**Решение.** В `modules/scalr-agent/` добавлена отдельная переменная `infra_project_id`:
```hcl
# modules/scalr-agent/main.tf
resource "google_service_account_iam_member" "scalr_agent_wi" {
  member = "serviceAccount:${var.infra_project_id}.svc.id.goog[${var.scalr_agent_namespace}/${var.scalr_agent_ksa}]"
  # infra_project_id = проект кластера (всегда)
  # gcp_project_id   = проект где GSA (может быть другим)
}
```

В `agents.tf` передаётся явно:
```hcl
module "agent_dev" {
  gcp_project_id   = "beneflo-gcp-project-dev"  # целевой проект
  infra_project_id = var.gcp_project_id          # проект кластера (из tfvars)
}
```

### 2. Баг: SM IAM binding брал проект по умолчанию из неправильной переменной

**Проблема.** SM секрет с JWT агента живёт в infra-проекте (где ESO). Исходный дефолт для `sm_project_id` брал `var.gcp_project_id` (целевой проект агента). При разных проектах IAM binding создавался бы в неправильном месте.

**Решение.** Дефолт изменён на `infra_project_id`:
```hcl
# modules/scalr-agent/main.tf
locals {
  sm_project_id = var.sm_project_id != null ? var.sm_project_id : var.infra_project_id
}
```

### 3. ESO GSA вынесен в модуль

Ресурсы ESO перемещены из плоского `gcp.tf` в `modules/eso/` по аналогии с `modules/scalr-agent/`. Это симметрично: ESO — shared singleton, агент — per-project. Оба теперь инкапсулированы.

```hcl
# gcp.tf
module "eso" {
  source    = "./modules/eso"
  project   = var.gcp_project_id
  namespace = var.eso_namespace
  ksa       = var.eso_ksa
}
```

### 4. outputs.tf — agents map вместо flat outputs

`fluxcd-bootstrap` читает из remote state. Раньше был плоский `scalr_agent_gsa_email` привязанный к dev. Сейчас — `agents` map с ключом по имени агента, содержащий `gsa_email`, `namespace`, `ksa`. `fluxcd-bootstrap` использует `for_each` по этому map и автоматически создаёт serviceaccount.yaml для каждого агента.

---

## Почему CLI-only

`scalr-admin` создаёт Scalr ресурсы от которых зависят другие workspaces: environment, agent pool, VCS provider. Если прицепить `scalr-admin` к Scalr VCS workspace — circular dependency:

```
scalr_workspace управляет scalr-admin/
  → scalr-admin/ создаёт scalr_environment
    → scalr_workspace нужен scalr_environment чтобы существовать
```

Workspace не может управлять ресурсами от которых сам зависит. `scalr-admin` всегда запускается через `terraform apply` с CLI. Admin workspace (`module.ws_admin`) создаётся в Scalr с `execution_mode = "local"` — Scalr видит его в UI но никогда не запускает автоматически.

---

## Почему WI живёт здесь

WI binding для агента и ESO — bootstrap инфраструктура. Должна существовать до того как агент подключится и до того как ESO начнёт читать секреты. Вынести в VCS workspace нельзя:

```
VCS workspace создаёт WI → нужен Scalr Agent для запуска
Scalr Agent стартует → нужна WI (ESO читает JWT через WI)
```

Разрыв цикла: WI создаётся вне Scalr через CLI. После bootstrap меняется редко.

---

## Почему SM контейнеры создаются вручную

Terraform не может в одном `apply` создать SM контейнер и сразу читать из него значение. `data "google_secret_manager_secret_version"` упадёт с `"No secret versions found"` даже с `depends_on` — контейнер только что создан, версий нет.

SM контейнеры (`github-pat`, `scalr-api-token`, `scalr-agent-pool-token`) создаются **один раз через gcloud**. Terraform содержит только `data` sources которые читают существующие значения.

---

## Почему SCALR_TOKEN нельзя читать из SM

Scalr provider требует токен при инициализации. Инициализация происходит **до** вычисления любых `data` source или `resource` блоков. Передать токен через data source невозможно — он вычисляется слишком поздно.

Единственный поддерживаемый способ — environment variable:
```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token \
  --project=YOUR_PROJECT)
terraform apply
```

Токен не попадает в state, не виден в plan output, не хранится на диске.

`github-pat` **можно** читать из SM через `data.tf` — он используется ресурсом `scalr_vcs_provider`, а не конфигурацией provider. Ресурсы вычисляются после инициализации провайдеров.

---

## Почему state в GCS

`scalr-admin` создаёт Scalr ресурсы (environment, workspace) от которых зависит Scalr remote backend. Если state жил бы в Scalr и Scalr стал недоступен — нет способа запустить `terraform apply` чтобы починить проблему (инструмент который управляет Scalr был бы сломан).

GCS bucket создаётся вручную один раз до первого `terraform init` и никогда не управляется Terraform.

---

## Предварительные требования

- GCP проект с GKE кластером и включённым Workload Identity
- `gcloud auth login && gcloud auth application-default login`
- `kubectl` настроен на кластер
- `terraform` >= 1.5
- Scalr аккаунт (free tier достаточно)

---

## Шаг 1 — Сбор токенов

**Scalr API Token:**
```
Scalr UI → Account Settings → API Tokens → Create Token → скопировать eyJ...
```

**GitHub Personal Access Token:**
```
GitHub → Settings → Developer settings → Personal access tokens (classic)
→ Generate → scope: repo → скопировать ghp_...
```

**Agent Pool JWT** — получается после Шага 5 (pool должен существовать).

---

## Шаг 2 — Адаптация конфигурации

`terraform.tfvars` содержит только две строки:
```hcl
gcp_project_id = "your-gcp-project-id"
gcp_region     = "europe-north2"
```

Для адаптации под свой аккаунт обновить хардкоды в:

| Файл | Что менять |
|---|---|
| `versions.tf` | GCS bucket name, `provider "scalr" { hostname }` |
| `agents.tf` | `gcp_project_id`, `scalr_agent_gsa_name`, `state_bucket`, `agent_pool_name` |
| `environment.tf` | `account_id` |
| `vcs.tf` | `name` (github username), `account_id` |

---

## Шаг 3 — GCS bucket для state

```bash
PROJECT=your-gcp-project-id
BUCKET=your-state-bucket-name

gcloud storage buckets create gs://$BUCKET \
  --project=$PROJECT \
  --location=europe-north1 \
  --uniform-bucket-level-access

gcloud storage buckets update gs://$BUCKET --versioning
```

---

## Шаг 4 — SM контейнеры и секреты

```bash
PROJECT=your-gcp-project-id

gcloud secrets create github-pat              --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token         --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token  --replication-policy=automatic --project=$PROJECT

printf %s "ghp_YOUR_PAT"   | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ_SCALR_TOKEN" | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
```

`scalr-agent-pool-token` — заполнить после Шага 6.

> **Почему `printf %s` а не `echo`?** `echo` добавляет перенос строки. Лишний символ в токене вызывает молчаливые ошибки аутентификации.

---

## Шаг 5 — terraform apply

```bash
PROJECT=your-gcp-project-id

export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token \
  --project=$PROJECT)

cd scalr-admin/
terraform init
terraform plan
terraform apply
```

После apply проверить outputs:
```bash
terraform output
```

Пример outputs:
```
agents = {
  "dev" = {
    "agent_pool_id"         = "apool-..."
    "agent_pool_name"       = "scalr-gitops-infrastructure-agent"
    "ksa"                   = "scalr-agent"
    "namespace"             = "scalr-agent"
    "scalr_agent_gsa_email" = "scalr-agent-gsa@PROJECT.iam.gserviceaccount.com"
  }
}
eso_gsa_email         = "eso-gsa@PROJECT.iam.gserviceaccount.com"
scalr_environment_id  = "env-..."
scalr_agent_pool_ids  = { "dev" = "apool-..." }
scalr_vcs_provider_id = "vcs-..."
```

---

## Шаг 6 — Agent Pool JWT

```
Scalr UI → Account Settings → Agent Pools → scalr-gitops-infrastructure-agent → Tokens → Add Token
```

```bash
printf %s "eyJ_AGENT_JWT" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- \
  --project=$PROJECT
```

JWT читается ESO через Workload Identity и доставляется как K8s Secret в pod агента. Terraform к этому значению не прикасается.

---

## Добавление нового агента

Для агента в новом GCP проекте (prod):

**1. Добавить SM контейнер для JWT:**
```bash
gcloud secrets create scalr-agent-pool-token-prod --replication-policy=automatic --project=$INFRA_PROJECT
```

**2. Добавить блок в `agents.tf`:**
```hcl
module "agent_prod" {
  source = "./modules/scalr-agent"

  name                         = "prod"
  gcp_project_id               = "your-gcp-project-prod"   # целевой проект
  infra_project_id             = var.gcp_project_id         # проект кластера — не меняется
  scalr_agent_gsa_name         = "scalr-agent-gsa"
  state_bucket                 = "terraform_state_prod"
  agent_pool_name              = "scalr-gitops-infrastructure-agent-prod"
  agent_pool_vcs_enabled       = false
  agent_pool_token_secret_name = "scalr-agent-pool-token-prod"
  eso_gsa_email                = module.eso.gsa_email
}
```

**3. Добавить в `outputs.tf`** блок `prod` в `output "agents"` и в `output "scalr_agent_pool_ids"`.

**4. terraform apply в scalr-admin.**

**5. Получить JWT из Scalr UI и залить в SM:**
```
Scalr UI → Agent Pools → scalr-gitops-infrastructure-agent-prod → Tokens → Add Token
```
```bash
printf %s "eyJ..." | gcloud secrets versions add scalr-agent-pool-token-prod --data-file=- --project=$INFRA_PROJECT
```

**6. terraform apply в fluxcd-bootstrap** — автоматически создаст `fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml` с правильным GSA email.

**7. Создать FluxCD манифесты** `fluxcd/infrastructure/scalr-agent-prod/` (копипаста `scalr-agent-dev/` с заменой namespace и secret name).

**8. Добавить Kustomization** в `fluxcd/clusters/dev/infrastructure.yaml` (шаблон есть в комментарии).

---

## Добавление нового workspace

```hcl
# workspaces.tf
module "ws_gcp_infra" {
  source              = "./modules/scalr-workspace"
  name                = "gcp-infrastructure"
  environment_id      = module.env_dev.environment_id
  execution_mode      = "remote"
  terraform_version   = "1.5.7"
  auto_apply          = false
  agent_pool_id       = module.agent_dev.agent_pool_id
  vcs_provider_id     = module.vcs_github.vcs_provider_id
  vcs_repo_identifier = "your-github-username/your-repo"
  vcs_branch          = "main"
  working_directory   = "terraform/"
  trigger_prefixes    = ["terraform/"]
}
```

Workspace с GCS state backend (вместо Scalr remote state):
```hcl
# В репозитории workspace, versions.tf:
terraform {
  backend "gcs" {
    bucket = "terraform_state_dev_beneflo"
    prefix = "gcp-infrastructure"
  }
}
```
Агент аутентифицируется в GCS через Workload Identity — дополнительной конфигурации не нужно.

---

## Устранение проблем

### State lock завис
```bash
terraform force-unlock LOCK_ID
```

### `No secret versions found` при terraform plan
SM контейнер существует но пустой. Залить значение:
```bash
printf %s "VALUE" | gcloud secrets versions add SECRET_NAME --data-file=- --project=$PROJECT
```

### `Provider configuration references a value that cannot be determined`
Попытка передать SCALR_TOKEN через переменную в provider блок. Использовать env variable:
```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)
```

### ESO не синхронизирует секрет
```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
# Проверить WI binding (infra project, не целевой):
gcloud iam service-accounts get-iam-policy eso-gsa@$INFRA_PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:INFRA_PROJECT.svc.id.goog[external-secrets/external-secrets]
```

### Agent Pool Token истёк
```bash
# Scalr UI → Agent Pools → Add Token → скопировать новый JWT
printf %s "eyJ_NEW" | gcloud secrets versions add scalr-agent-pool-token --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут
```

### WI binding невалидный после добавления агента в другой проект
Убедиться что `infra_project_id` в `agents.tf` указывает на проект **кластера**, а не на `gcp_project_id` агента. Это разные значения при cross-project setup.
