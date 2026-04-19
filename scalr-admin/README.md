# scalr-admin

Terraform-конфигурация для bootstrap Scalr-as-code поверх GCP. Управляет GCP-сервисными аккаунтами, Workload Identity биндингами и Scalr-ресурсами (environment, agent pools, VCS provider, workspaces). Запускается **только через CLI** — никогда через Scalr VCS workspace.

---

## Архитектура

```
GKE кластер (infra project: beneflo-gcp-project-dev)
  │
  ├── ESO pod
  │     └── KSA: external-secrets (namespace: external-secrets)
  │           └── WI → eso-gsa@beneflo-gcp-project-dev
  │                     └── читает JWT всех агентов из SM
  │
  └── Scalr Agent pod
        └── KSA: scalr-agent (namespace: scalr-agent)
              └── WI → scalr-agent-gsa@beneflo-gcp-project-dev
                        ├── storage.objectAdmin → GCS state bucket
                        └── управляет ресурсами в целевом GCP проекте
```

**Ключевые свойства:**
- ESO — один shared экземпляр. Читает JWT токены всех агентов из GCP Secret Manager.
- Каждый Scalr Agent — отдельный pod, своя GSA, свой namespace, свой Scalr agent pool.
- Новый агент = один новый `module "agent_*"` блок в `agents.tf` + `terraform apply`.
- `infra_project_id` всегда указывает на проект **кластера**, независимо от того в каком GCP проекте GSA агента.

---

## Файловая структура

```
scalr-admin/
├── modules/
│   ├── eso/                  # ESO GSA + WI binding (shared, один на кластер)
│   ├── scalr-agent/          # Per-agent: GSA + WI + GCS IAM + SM IAM + agent pool
│   ├── scalr-environment/    # scalr_environment resource
│   ├── scalr-vcs-provider/   # scalr_vcs_provider resource
│   └── scalr-workspace/      # scalr_workspace + scalr_variable resources
├── versions.tf               # GCS backend, required_providers, provider configs
├── variables.tf              # gcp_project_id, gcp_region, eso_namespace, eso_ksa
├── terraform.tfvars          # gcp_project_id + gcp_region
├── data.tf                   # Читает github-pat из GCP Secret Manager
├── gcp.tf                    # module "eso"
├── agents.tf                 # Явные module "agent_*" блоки
├── environment.tf            # module "env_dev"
├── vcs.tf                    # module "vcs_github"
├── workspaces.tf             # module "ws_admin" (execution_mode=local)
└── outputs.tf                # agents map + eso_gsa_email + Scalr resource IDs
```

**Принципы организации:**
- `terraform.tfvars` — только `gcp_project_id` и `gcp_region`. Все остальные значения (Scalr account ID, имена агентов, bucket) захардкожены в вызовах модулей.
- `gcp.tf` — только вызов `module "eso"`. Ресурсы агентов инкапсулированы в `modules/scalr-agent/`.
- `agents.tf` — явные `module "agent_*"` блоки. Добавление агента = копирование блока.
- Все модули используют `versions.tf` (не `provider.tf`) для `required_providers`.

---

## Почему CLI-only

`scalr-admin` создаёт Scalr ресурсы от которых зависят все workspaces: environment, agent pool, VCS provider. Circular dependency:

```
scalr_workspace управляет scalr-admin/
  → scalr-admin/ создаёт scalr_environment
    → scalr_workspace нужен scalr_environment чтобы существовать
```

`scalr-admin` всегда запускается через CLI. `module.ws_admin` создаётся в Scalr с `execution_mode = "local"` — Scalr видит его в UI но никогда не запускает автоматически.

---

## Почему WI живёт здесь

WI binding должен существовать **до** того как агент стартует (ESO читает JWT через WI). Вынести в VCS workspace нельзя — получается тот же circular dependency. WI создаётся один раз через CLI, меняется редко.

---

## Почему SM контейнеры создаются вручную

Terraform не может в одном `apply` создать SM контейнер и сразу читать из него. `data "google_secret_manager_secret_version"` падает если контейнер пуст. Контейнеры создаются через `gcloud`, Terraform содержит только `data` sources.

---

## Почему SCALR_TOKEN нельзя читать из SM

Scalr provider инициализируется **до** вычисления любых `data` source. Токен передаётся только через env variable:

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token --project=$PROJECT)
terraform apply
```

`github-pat` можно читать через `data.tf` — он используется ресурсом `scalr_vcs_provider`, а не конфигурацией provider.

---

## Почему state в GCS

`scalr-admin` создаёт Scalr ресурсы от которых зависит Scalr remote backend. Если state был бы в Scalr и Scalr стал недоступен — нет способа запустить `terraform apply` чтобы починить проблему. GCS bucket создаётся вручную один раз и никогда не управляется Terraform.

---

## Применить scalr-admin

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token --project=$PROJECT)

cd scalr-admin/
terraform init
terraform apply
```

Пример outputs:

```
agents = {
  "main" = {
    "agent_pool_id"         = "apool-..."
    "agent_pool_name"       = "scalr-gitops-infrastructure-agent"
    "ksa"                   = "scalr-agent"
    "namespace"             = "scalr-agent"
    "scalr_agent_gsa_email" = "scalr-agent-gsa@PROJECT.iam.gserviceaccount.com"
  }
}
eso_gsa_email         = "eso-gsa@PROJECT.iam.gserviceaccount.com"
scalr_environment_id  = "env-..."
scalr_agent_pool_ids  = { "main" = "apool-..." }
scalr_vcs_provider_id = "vcs-..."
```

`agents.main.scalr_agent_gsa_email` и `eso_gsa_email` нужны для ручного заполнения `serviceaccount.yaml` в fluxcd.

---

## Добавление нового агента

Для агента в новом GCP проекте:

**1. Создать SM контейнер для JWT:**
```bash
gcloud secrets create scalr-agent-pool-token-prod \
  --replication-policy=automatic --project=$INFRA_PROJECT
```

**2. Добавить блок в `agents.tf`:**
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

> Важно: `scalr_agent_namespace` и `scalr_agent_ksa` должны быть уникальны для каждого агента во избежание конфликта ServiceAccount.

**3. Добавить в `outputs.tf`** блок `prod` в `output "agents"` и `output "scalr_agent_pool_ids"`.

**4. `terraform apply`.**

**5. Взять GSA email из outputs:**
```bash
terraform output scalr_agent_gsa_emails
```

**6. Создать `serviceaccount.yaml` вручную:**
```yaml
# fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scalr-agent-prod
  namespace: scalr-agent-prod
  annotations:
    iam.gke.io/gcp-service-account: <scalr_agent_gsa_email из outputs>
```

**7. Получить JWT из Scalr UI и залить в SM:**
```
Scalr UI → Agent Pools → scalr-gitops-infrastructure-agent-prod → Tokens → Add Token
```
```bash
printf %s "eyJ..." | gcloud secrets versions add scalr-agent-pool-token-prod \
  --data-file=- --project=$INFRA_PROJECT
```

**8. Создать FluxCD манифесты** `fluxcd/infrastructure/scalr-agent-prod/` (копия `scalr-agent/` с заменой namespace, KSA, SM secret name).

**9. Добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml` и `git push`.**

---

## Добавление нового workspace

```hcl
# workspaces.tf
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

Workspace с GCS state backend:
```hcl
# В репозитории workspace, versions.tf:
terraform {
  backend "gcs" {
    bucket = "terraform_state_dev_beneflo"
    prefix = "my-project"
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
SM контейнер пустой. Залить значение:
```bash
printf %s "VALUE" | gcloud secrets versions add SECRET_NAME --data-file=- --project=$PROJECT
```

### `Provider configuration references a value that cannot be determined`
Попытка передать SCALR_TOKEN через переменную. Использовать env variable:
```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)
```

### ESO не синхронизирует секрет
```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
# WI binding должен использовать infra project, не целевой:
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

### WI binding невалидный при добавлении агента в другой проект
`infra_project_id` в `agents.tf` должен указывать на проект **кластера**, а не `gcp_project_id` агента.

### Agent Pool Token истёк
```bash
# Scalr UI → Agent Pools → Add Token → скопировать новый JWT
printf %s "eyJ_NEW" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут
```
