# scalr-gitops-infrastructure

GitOps инфраструктура: Scalr-as-code (Terraform) + FluxCD (Kubernetes). Управление Scalr через Terraform CLI, GitOps через FluxCD + ESO + Workload Identity.

---

## Структура репозитория

```
scalr-gitops-infrastructure/
├── scalr-admin/                        # Terraform: GCP bootstrap + Scalr конфигурация
│   ├── versions.tf                     # GCS backend + providers (google, scalr)
│   ├── variables.tf                    # Несекретные переменные (project_id, hostnames, etc.)
│   ├── data.tf                         # Читает github-pat из GCP Secret Manager
│   ├── gcp.tf                          # GSA + Workload Identity для ESO и Scalr Agent
│   ├── scalr.tf                        # scalr_agent_pool, scalr_environment, scalr_vcs_provider
│   ├── workspaces.tf                   # scalr_workspace.admin (CLI, execution_mode=local)
│   └── outputs.tf                      # GSA emails
└── fluxcd/
    ├── flux-system/                    # Flux контроллеры + GitRepository + корневой Kustomization
    ├── clusters/dev/                   # infrastructure.yaml — 3 Kustomization с dependsOn
    └── infrastructure/
        ├── external-secrets/           # ESO HelmRelease (chart 2.3.0)
        ├── external-secrets-config/    # ClusterSecretStore → GCP SM через WI
        └── scalr-agent/               # Scalr Agent HelmRelease + ExternalSecret
```

---

## Архитектура и ключевые решения

### Почему WI (Workload Identity) в scalr-admin/, а не в отдельном VCS-workspace

WI нужна для старта ESO и Scalr Agent в кластере. Вынести её в VCS-workspace нельзя из-за circular dependency при бутстрапе:

```
VCS-workspace создаёт WI → нужен Scalr Agent для запуска
Scalr Agent стартует → нужна WI (ESO читает JWT через WI)
```

Поэтому WI создаётся один раз через CLI (`scalr-admin/`) до того как агент существует. После бутстрапа меняется редко — держать в CLI нормально.

### Почему scalr-admin/ управляется только через CLI

`scalr-admin/` создаёт Scalr ресурсы (environment, agent pool, workspaces). Если прицепить его к Scalr VCS-workspace, получается циклическая зависимость: workspace управляет собой. Поэтому:

- `scalr-admin/` запускается **только через CLI** (`terraform apply` руками)
- `workspace.admin` создаётся в Scalr но `execution_mode = "local"` — Scalr не запускает runs сам
- Стейт хранится в **GCS**, не в Scalr — никакого конфликта состояний

### Почему SM контейнеры не в Terraform

Terraform не может создать Secret Manager контейнер и сразу же прочитать из него значение в одном `apply` — data source упадёт с ошибкой "No secret versions found" даже с `depends_on`. SM контейнеры создаются **один раз вручную через gcloud**, значения заливаются отдельно. В Terraform только `data` sources — читают, не создают.

### Где хранятся секреты

| Секрет | GCP Secret Manager | Кто читает |
|--------|-------------------|------------|
| `scalr-api-token` | `scalr-api-token` | `export SCALR_TOKEN=$(gcloud ...)` перед terraform |
| `github-pat` | `github-pat` | `data.tf` → `scalr_vcs_provider` + ESO → FluxCD |
| `scalr-agent-pool-token` | `scalr-agent-pool-token` | ESO → K8s Secret → Scalr Agent pod |

Секреты **не попадают в Terraform state**, **не хранятся в git**, **не передаются как переменные**.

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
  └─ Kustomization/flux-system → path: ./fluxcd/clusters/dev
       ├─ infrastructure-external-secrets
       │    └─ ESO HelmRelease (namespace + SA с WI аннотацией)
       ├─ infrastructure-external-secrets-config  [dependsOn: external-secrets]
       │    └─ ClusterSecretStore gcp-sm (auth: Workload Identity)
       └─ infrastructure-scalr-agent              [dependsOn: external-secrets-config]
            └─ ExternalSecret + Scalr Agent HelmRelease
```

Разделение `external-secrets` и `external-secrets-config` — ClusterSecretStore должен применяться строго после установки CRD из ESO HelmRelease.

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

**Scalr Account ID:**
Виден в URL: `.../accounts/acc-xxxxxxxxxx/...`

**GitHub PAT:**
GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic) → scope: `repo` → скопировать `ghp_...`

**Agent Pool JWT** — получить после Шага 4 (нужен уже созданный pool).

---

### Шаг 2: Адаптировать репозиторий под свой аккаунт

| Файл | Переменная | Текущее значение |
|------|-----------|-----------------|
| `scalr-admin/variables.tf` | `gcp_project_id` | `beneflo-gcp-project-dev` |
| `scalr-admin/variables.tf` | `gcp_region` | `europe-north2` |
| `scalr-admin/variables.tf` | `scalr_hostname` | `kitezh.scalr.io` |
| `scalr-admin/variables.tf` | `scalr_account_id` | `acc-v0p7ctljql63n2eg4` |
| `scalr-admin/variables.tf` | `github_username` | `exitfound` |
| `scalr-admin/versions.tf` | GCS bucket | `terraform_state_dev_beneflo` |
| `fluxcd/flux-system/gitrepository.yaml` | repo URL | `exitfound/scalr-gitops-infrastructure` |
| `fluxcd/infrastructure/*/serviceaccount.yaml` | GSA emails | `*@beneflo-gcp-project-dev.iam.gserviceaccount.com` |
| `fluxcd/infrastructure/external-secrets-config/clustersecretstore.yaml` | `projectID` | `beneflo-gcp-project-dev` |
| `fluxcd/infrastructure/scalr-agent/helmrelease.yaml` | `agent.url` | `https://kitezh.scalr.io` |

> GSA email-ы станут известны после `terraform apply` на Шаге 4. Обновить после него.

---

### Шаг 3: Создать SM контейнеры и залить секреты

SM контейнеры создаются вручную — не через Terraform (см. раздел "Ключевые решения").

```bash
PROJECT=beneflo-gcp-project-dev

# Создать контейнеры
gcloud secrets create github-pat             --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token        --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token --replication-policy=automatic --project=$PROJECT

# Залить значения
printf %s "ghp_..."  | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ..."   | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
# scalr-agent-pool-token — заполнить после Шага 4
```

---

### Шаг 4: Terraform apply (создать GCP + Scalr ресурсы)

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)

cd scalr-admin/
terraform init
terraform plan
terraform apply
```

Создаётся:
- GSA `scalr-agent-gsa` + `roles/storage.admin` + WI binding → для Scalr Agent
- GSA `eso-gsa` + `roles/secretmanager.secretAccessor` + WI binding → для ESO
- Scalr environment `dev`
- Scalr agent pool `scalr-gitops-agent`
- Scalr VCS provider GitHub (токен из SM)
- Scalr workspace `admin` (CLI, `execution_mode = "local"`)

#### Обновить GSA email-ы в FluxCD манифестах

```bash
terraform output
# Скопировать eso_gsa_email и scalr_agent_gsa_email
```

Вставить в:
- `fluxcd/infrastructure/external-secrets/serviceaccount.yaml` → аннотация `iam.gke.io/gcp-service-account`
- `fluxcd/infrastructure/scalr-agent/serviceaccount.yaml` → аннотация `iam.gke.io/gcp-service-account`

```bash
git add fluxcd/
git commit -m "fix: update GSA emails from terraform output"
git push
```

---

### Шаг 5: Получить Agent Pool JWT и залить в SM

```
Scalr UI → Account Settings → Agent Pools → scalr-gitops-agent → Tokens → Add Token
→ скопировать eyJ...
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

Если пусто — включить:
```bash
gcloud container clusters update <CLUSTER> --zone=<ZONE> \
  --workload-pool=$PROJECT.svc.id.goog
gcloud container node-pools update <NODE_POOL> --cluster=<CLUSTER> --zone=<ZONE> \
  --workload-metadata=GKE_METADATA
```

---

### Шаг 7: Установить FluxCD

```bash
# Установить контроллеры
kubectl apply -f fluxcd/flux-system/gotk-components.yaml

# Секрет для доступа к GitHub
kubectl create secret generic flux-system \
  --namespace=flux-system \
  --from-literal=username=<GITHUB_USERNAME> \
  --from-literal=password="$(gcloud secrets versions access latest --secret=github-pat --project=$PROJECT)"

# Подключить репозиторий
kubectl apply -f fluxcd/flux-system/gitrepository.yaml
kubectl apply -f fluxcd/flux-system/kustomization.yaml

# Форсировать первый sync
flux reconcile source git flux-system --force
flux reconcile kustomization flux-system --force
```

FluxCD разворачивает цепочку автоматически: ESO → ClusterSecretStore → Scalr Agent.

---

### Шаг 8: Проверка

```bash
# FluxCD — все Kustomization Ready
flux get kustomization

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

Для изменений в Scalr конфигурации (`scalr-admin/`):

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=beneflo-gcp-project-dev)
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
# Проверить WI binding:
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Должен быть: serviceAccount:<PROJECT>.svc.id.goog[external-secrets/external-secrets]
```

### Scalr Agent не подключается

```bash
# Проверить что JWT в K8s Secret
kubectl get secret scalr-agent-token -n scalr-agent -o jsonpath='{.data.token}' | base64 -d | head -c 20
# Должен показать: eyJ...

# Логи агента
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=30
```

### Agent Pool Token истёк или пересоздан

```bash
# Scalr UI → Agent Pools → Add Token → скопировать новый JWT
printf %s "eyJ_НОВЫЙ" | gcloud secrets versions add scalr-agent-pool-token --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут
```

### Scalr workspace пересоздаёт GCP ресурсы

Причина: Scalr VCS-workspace запускает terraform с собственным state (free tier) и не видит существующие ресурсы. Решение: `scalr-admin/` управляется **только через CLI**, ни один Scalr workspace не смотрит на эту директорию.
