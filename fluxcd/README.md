# fluxcd

Terraform-managed FluxCD bootstrap и GitOps конфигурация для GKE кластеров. Устанавливает Flux контроллеры, проставляет Workload Identity аннотации автоматически из `scalr-admin` remote state и непрерывно синхронизирует ESO и Scalr Agent через GitOps — без ручного `kubectl` после первого `terraform apply`.

---

## Содержание

1. [Что делает](#что-делает)
2. [Файловая структура](#файловая-структура)
3. [Как это работает](#как-это-работает)
4. [Нюансы которые были решены](#нюансы-которые-были-решены)
5. [Почему Terraform управляет Flux bootstrap](#почему-terraform-управляет-flux-bootstrap)
6. [Почему github_repository_file ресурсы существуют](#почему-github_repository_file-ресурсы-существуют)
7. [Почему fluxcd-bootstrap нельзя запускать как Scalr workspace](#почему-fluxcd-bootstrap-нельзя-запускать-как-scalr-workspace)
8. [Почему state в GCS](#почему-state-в-gcs)
9. [Предварительные требования](#предварительные-требования)
10. [Шаг 1 — Применить scalr-admin](#шаг-1--применить-scalr-admin)
11. [Шаг 2 — Agent Pool JWT в Secret Manager](#шаг-2--agent-pool-jwt-в-secret-manager)
12. [Шаг 3 — Настроить envs/dev.tfvars](#шаг-3--настроить-envsdevtfvars)
13. [Шаг 4 — Аутентификация в GKE](#шаг-4--аутентификация-в-gke)
14. [Шаг 5 — terraform init](#шаг-5--terraform-init)
15. [Шаг 6 — terraform apply](#шаг-6--terraform-apply)
16. [Шаг 7 — Верификация](#шаг-7--верификация)
17. [Добавление нового агента](#добавление-нового-агента)
18. [Добавление нового компонента через GitOps](#добавление-нового-компонента-через-gitops)
19. [Устранение проблем](#устранение-проблем)

---

## Что делает

`fluxcd-bootstrap/` — Terraform root module для одноразового автоматического bootstrap FluxCD на GKE кластере. Один `terraform apply` делает по порядку:

1. Читает `agents` map из `scalr-admin` remote state — получает GSA email, K8s namespace и KSA для каждого агента.
2. Коммитит `serviceaccount.yaml` для каждого агента в правильную директорию с аннотацией Workload Identity.
3. Коммитит `serviceaccount.yaml` для ESO с его GSA email.
4. Коммитит параметризованный `clustersecretstore.yaml` с GCP project ID.
5. Устанавливает Flux контроллеры, создаёт `flux-system` namespace, GitHub auth secret, регистрирует `GitRepository` + root `Kustomization` на `fluxcd/clusters/<cluster_name>`.

После этого FluxCD берёт управление и синхронизирует без участия человека:

```
flux_bootstrap_git (Terraform, один раз на кластер)
  └─► root Kustomization → fluxcd/clusters/scalr
        └─► infrastructure.yaml
              ├─► infrastructure-external-secrets
              │     └─► ESO HelmRelease (Helm)
              ├─► infrastructure-external-secrets-config
              │     └─► ClusterSecretStore gcp-sm (GCP SM через WI)
              └─► infrastructure-scalr-agent-dev
                    ├─► ExternalSecret → scalr-agent-pool-token → K8s Secret
                    └─► Scalr Agent HelmRelease
```

---

## Файловая структура

```
fluxcd/
├── fluxcd-bootstrap/              # Terraform root module — запускается один раз на кластер
│   ├── versions.tf                # GCS backend + providers: flux ~>1.8, github ~>6.0,
│   │                              #   kubernetes ~>3.1, google ~>6.0
│   ├── variables.tf               # cluster_name, gke_cluster_name, flux_version, …
│   ├── main.tf                    # GKE creds, terraform_remote_state, flux_bootstrap_git
│   ├── github.tf                  # github_repository_file: SA аннотации + ClusterSecretStore
│   ├── outputs.tf                 # flux_version_installed, eso_gsa_email_applied,
│   │                              #   scalr_agent_gsa_emails_applied (map по агентам)
│   ├── envs/
│   │   └── scalr.tfvars           # Значения для scalr кластера (один файл на кластер)
│   └── templates/
│       ├── eso-serviceaccount.yaml.tpl            # gsa_email
│       ├── scalr-agent-serviceaccount.yaml.tpl    # gsa_email, namespace, ksa
│       ├── clustersecretstore.yaml.tpl             # gcp_project_id
│       ├── cluster-kustomization.yaml.tpl          # для новых кластеров
│       └── cluster-infrastructure.yaml.tpl         # для новых кластеров
├── clusters/
│   └── scalr/                     # Scalr infra-кластер (ESO + агенты). Не "dev" среда —
│       │                          #   это management-кластер для всей Scalr платформы.
│       ├── kustomization.yaml     # Kustomize entry: ссылается на infrastructure.yaml
│       └── infrastructure.yaml    # Flux Kustomization CRs с dependsOn цепочкой
└── infrastructure/
    ├── external-secrets/          # ESO: namespace, SA, HelmRepository, HelmRelease
    ├── external-secrets-config/   # ClusterSecretStore (GCP SM, WI auth)
    └── scalr-agent-dev/           # Scalr Agent: namespace, SA, ExternalSecret,
                                   #   HelmRepository, HelmRelease
```

**Что управляет Terraform vs что управляет Flux:**

| Ресурс | Управляется |
|---|---|
| Flux контроллеры | `flux_bootstrap_git` (Terraform) |
| GitRepository + root Kustomization CR | `flux_bootstrap_git` (Terraform) |
| `serviceaccount.yaml` GSA аннотации (per-agent) | `github_repository_file` for_each (Terraform) |
| `clustersecretstore.yaml` project ID | `github_repository_file` (Terraform) |
| ESO HelmRelease | Flux (GitOps) |
| ClusterSecretStore | Flux (GitOps) |
| ExternalSecret → K8s Secret | ESO (авто-обновление каждые 5 мин) |
| Scalr Agent HelmRelease | Flux (GitOps) |

---

## Как это работает

### Цепочка зависимостей Flux Kustomizations

```
infrastructure-external-secrets          (устанавливает ESO + CRDs)
  └─► infrastructure-external-secrets-config  (применяет ClusterSecretStore, нужны CRDs)
        └─► infrastructure-scalr-agent-dev     (ExternalSecret + агент, нужен ClusterSecretStore)
```

Порядок обязателен: `ClusterSecretStore` — это CRD которую устанавливает ESO. Если применить раньше ESO — Kubernetes API отклонит как неизвестный тип ресурса.

### Поток секрета к агенту

```
GCP Secret Manager: scalr-agent-pool-token
  └─► ESO (аутентификация через Workload Identity, без статических ключей)
        └─► K8s Secret: scalr-agent-token  (обновляется каждые 5 мин)
              └─► HelmRelease valuesFrom → agent.token
                    └─► Scalr Agent pod подключается к Scalr
```

### Workload Identity аннотации

Аннотация `iam.gke.io/gcp-service-account` на K8s ServiceAccount должна содержать точный email GSA который создал `scalr-admin`. `fluxcd-bootstrap` читает этот email из `scalr-admin` remote state и коммитит файлы в git до того как Flux выполняет первую синхронизацию.

### Связь scalr-admin → fluxcd-bootstrap

```hcl
# main.tf
data "terraform_remote_state" "scalr_admin" {
  backend = "gcs"
  config  = { bucket = var.state_bucket, prefix = var.scalr_admin_state_prefix }
}

# github.tf
locals {
  eso_gsa_email = data.terraform_remote_state.scalr_admin.outputs.eso_gsa_email
  agents        = data.terraform_remote_state.scalr_admin.outputs.agents
  # agents map: { "dev" = { scalr_agent_gsa_email, namespace, ksa, ... } }
}
```

Из `agents` map через `for_each` создаётся `serviceaccount.yaml` для каждого агента:
```hcl
resource "github_repository_file" "scalr_agent_serviceaccount" {
  for_each = local.agents

  file    = "fluxcd/infrastructure/scalr-agent-${each.key}/serviceaccount.yaml"
  content = templatefile("templates/scalr-agent-serviceaccount.yaml.tpl", {
    gsa_email = each.value.scalr_agent_gsa_email
    namespace = each.value.namespace
    ksa       = each.value.ksa
  })
}
```

---

## Нюансы которые были решены

### 1. GSA email копипаста → автоматическая инъекция

**Было:** GSA email нужно было вручную копировать из `terraform output` scalr-admin и вставлять в `serviceaccount.yaml` файлы. Ошибка копирования = агент не может аутентифицироваться в GCP (молчаливый fail WI).

**Стало:** `fluxcd-bootstrap` читает email напрямую из GCS state scalr-admin через `terraform_remote_state`. Ручная работа исключена.

### 2. Flat output → agents map с for_each

**Было:** `outputs.scalr_agent_gsa_email` — плоский output, жёстко привязанный к dev агенту. При добавлении prod-агента fluxcd-bootstrap не знал бы про новый email.

**Стало:** `outputs.agents` — map с ключом по имени агента. `github_repository_file` использует `for_each` по этому map. Добавление нового агента в scalr-admin автоматически создаёт его `serviceaccount.yaml` при следующем `terraform apply` в fluxcd-bootstrap.

### 3. Директория scalr-agent → scalr-agent-{name}

**Было:** `fluxcd/infrastructure/scalr-agent/` — единственная директория без указания для какого агента.

**Стало:** `fluxcd/infrastructure/scalr-agent-dev/` — явный суффикс. При добавлении prod-агента создаётся `scalr-agent-prod/`. Каждый агент изолирован в своей директории со своим namespace, ExternalSecret и HelmRelease.

### 4. Template параметризован по namespace и KSA

**Было:** `scalr-agent-serviceaccount.yaml.tpl` — только `${gsa_email}`, namespace и KSA хардкодены.

**Стало:** template принимает `gsa_email`, `namespace`, `ksa` — все три берутся из `agents` map scalr-admin. Это важно для cross-project агентов у которых может быть другой namespace.

---

## Почему Terraform управляет Flux bootstrap

Ручной bootstrap требует 6+ команд `kubectl` и `flux`, создания GitHub auth secret вручную и копирования GSA emails из Terraform outputs в YAML файлы. Это невоспроизводимо идентично для второго кластера.

`flux_bootstrap_git` (из Terraform провайдера `fluxcd/flux`) заменяет всё это одним resource declaration. При `terraform apply` устанавливает контроллеры, создаёт namespace и git credential secret, регистрирует GitRepository и root Kustomization, коммитит Flux system манифесты. Идемпотентен: если установленная версия совпадает с `var.flux_version` — ничего не меняет.

---

## Почему github_repository_file ресурсы существуют

Workload Identity аннотация на ServiceAccount должна содержать точный GSA email который создал `scalr-admin`. Хардкодить это значение в YAML означало бы ручное обновление при каждом изменении project ID или добавлении нового environment.

`github_repository_file` читает GSA emails из `scalr-admin` remote state и коммитит правильные ServiceAccount манифесты в git **до** того как `flux_bootstrap_git` выполняется (принудительно через `depends_on`). К моменту первой Flux синхронизации правильные аннотации уже в git.

---

## Почему fluxcd-bootstrap нельзя запускать как Scalr workspace

`fluxcd-bootstrap` разворачивает Scalr Agent. Scalr Agent должен работать до того как любой Scalr VCS workspace может выполняться. Circular dependency: workspace не может развернуть агент который нужен для запуска этого workspace.

`fluxcd-bootstrap` всегда запускается вручную через CLI, один раз на кластер.

---

## Почему state в GCS

Каждый кластер получает свой GCS state prefix:

```
gs://terraform_state_dev_beneflo/
├── scalr-admin/
└── fluxcd-bootstrap/
    ├── dev/
    └── prod/   ← будущий
```

State изолирован по prefix, файлы не конфликтуют. Prefix задаётся через `-backend-config` при `terraform init`, не хардкодится в `versions.tf` — один модуль обслуживает все кластеры.

---

## Предварительные требования

- `scalr-admin/` применён (создаёт GSA + WI bindings, emails попадают в GCS state)
- GKE кластер с включённым Workload Identity (`--workload-pool=PROJECT.svc.id.goog`)
- GCP Secret Manager секреты существуют и заполнены:
  - `github-pat` — GitHub PAT с scope `repo`
  - `scalr-agent-pool-token` — Agent Pool JWT
- Инструменты:
  - `terraform` >= 1.5
  - `gcloud` CLI аутентифицирован
  - `kubectl` + `flux` CLI (для верификации)

---

## Шаг 1 — Применить scalr-admin

`fluxcd-bootstrap` читает `scalr-admin` remote state для получения GSA email адресов. Если `scalr-admin` не применён — `terraform plan` упадёт с ошибкой `"No state file found"`.

```bash
cd scalr-admin/
terraform output eso_gsa_email
terraform output agents
```

Оба должны вернуть непустые значения.

---

## Шаг 2 — Agent Pool JWT в Secret Manager

JWT создаётся в Scalr UI после того как agent pool существует (scalr-admin его создаёт):

```
Scalr UI → Account Settings → Agent Pools → scalr-gitops-infrastructure-agent
         → Tokens → Add Token → скопировать eyJ…
```

```bash
PROJECT=your-gcp-project-id

printf %s "eyJ_AGENT_JWT" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- \
  --project=$PROJECT
```

> **Почему `printf %s`?** `echo` добавляет перенос строки. Лишний символ в JWT вызывает молчаливые ошибки аутентификации агента.

---

## Шаг 3 — Настроить envs/scalr.tfvars

```hcl
cluster_name     = "scalr"
gke_cluster_name = "your-gke-cluster-name"
gke_location     = "europe-north2"
gcp_project_id   = "your-gcp-project-id"
github_org       = "your-github-username"
github_repo      = "scalr-gitops-infrastructure"
github_branch    = "main"
flux_version     = "2.8.5"
state_bucket     = "your-state-bucket-name"
```

`flux_version` должен совпадать с версией в кластере (если Flux уже установлен). Несовпадение = обновление/откат контроллеров при apply.

---

## Шаг 4 — Аутентификация в GKE

```bash
gcloud container clusters get-credentials YOUR_CLUSTER_NAME \
  --zone YOUR_ZONE \
  --project YOUR_PROJECT
```

Flux Terraform провайдер использует access token из gcloud application-default credentials. `kubeconfig` файл не читается — провайдер получает endpoint и CA cert из GKE data source.

---

## Шаг 5 — terraform init

```bash
terraform -chdir=fluxcd/fluxcd-bootstrap init \
  -backend-config="prefix=fluxcd-bootstrap/dev"
```

Аргумент `-backend-config="prefix=..."` изолирует state этого кластера в GCS. При добавлении второго кластера использовать уникальный prefix: `fluxcd-bootstrap/prod`.

---

## Шаг 6 — terraform apply

```bash
terraform -chdir=fluxcd/fluxcd-bootstrap apply \
  -var-file=envs/scalr.tfvars
```

Terraform показывает план с ресурсами:

| Ресурс | Что делает |
|---|---|
| `github_repository_file.eso_serviceaccount` | Коммитит ESO ServiceAccount с GSA email |
| `github_repository_file.scalr_agent_serviceaccount["dev"]` | Коммитит Scalr Agent ServiceAccount с GSA email, namespace, KSA |
| `github_repository_file.clustersecretstore` | Коммитит ClusterSecretStore с project ID |
| `flux_bootstrap_git.this` | Устанавливает Flux, создаёт GitRepository + root Kustomization |

`github_repository_file` ресурсы всегда завершаются до `flux_bootstrap_git` (`depends_on`). К первой Flux синхронизации правильные аннотации уже в git.

Outputs после успешного apply:
```
eso_gsa_email_applied          = "eso-gsa@PROJECT.iam.gserviceaccount.com"
flux_bootstrap_path            = "fluxcd/clusters/scalr"
flux_version_installed         = "v2.8.5"
scalr_agent_gsa_emails_applied = { "dev" = "scalr-agent-gsa@PROJECT.iam.gserviceaccount.com" }
```

---

## Шаг 7 — Верификация

Flux синхронизирует с интервалом 10 минут. Подождать ~2 минуты после apply:

```bash
# Все Kustomizations должны быть Ready
flux get kustomization -A

# Оба HelmRelease должны быть Ready
flux get helmrelease -A

# Flux контроллеры
kubectl get pods -n flux-system

# ESO pods (3: operator, cert-controller, webhook)
kubectl get pods -n external-secrets

# ClusterSecretStore — должен быть Valid
kubectl get clustersecretstore gcp-sm

# ExternalSecret — должен быть Ready
kubectl get externalsecret scalr-agent-token -n scalr-agent

# Scalr Agent pod
kubectl get pods -n scalr-agent

# Логи агента — ищем "Connected to Scalr"
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=30
```

---

## Добавление нового агента

При добавлении нового агента в scalr-admin и `terraform apply` там:

1. `scalr-admin/outputs.agents` map получает новый ключ (например `"prod"`) с `scalr_agent_gsa_email`, `namespace`, `ksa`.

2. В fluxcd-bootstrap запустить `terraform apply`:
   ```bash
   terraform -chdir=fluxcd/fluxcd-bootstrap apply -var-file=envs/scalr.tfvars
   ```
   Terraform автоматически создаст `github_repository_file.scalr_agent_serviceaccount["prod"]` с файлом `fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml`.

3. Вручную создать `fluxcd/infrastructure/scalr-agent-prod/` манифесты (копипаста `scalr-agent-dev/` с заменой namespace и имени SM секрета).

4. Добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml` (шаблон есть в комментарии файла).

5. Push в `main`. Flux подхватит новый Kustomization на следующем цикле.

---

## Добавление нового компонента через GitOps

**1. Создать директорию:**
```
fluxcd/infrastructure/my-app/
├── namespace.yaml
├── helmrepository.yaml
├── helmrelease.yaml
└── kustomization.yaml
```

**2. Добавить Kustomization CR в `fluxcd/clusters/scalr/infrastructure.yaml`:**
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

**3. Push в `main`.** Flux синхронизирует в течение интервала (максимум 10 минут).

---

## Устранение проблем

### Kustomization застрял в `False / Not Ready`

```bash
flux get kustomization -A
kubectl describe kustomization infrastructure-external-secrets -n flux-system
```

Частые причины:
- CRD ещё не установлена: `infrastructure-external-secrets-config` падает до того как ESO Ready. Ждать завершения ESO HelmRelease, Flux повторит автоматически.
- Ошибка git sync: `flux get source git flux-system`.

### HelmRelease не устанавливается

```bash
flux get helmrelease -A
kubectl describe helmrelease external-secrets -n external-secrets
```

Если HelmRepository недоступен — проверить network policies и egress из кластера.

### ESO не синхронизирует секрет

```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
```

Проверить WI binding (должен содержать infra project, не целевой):
```bash
gcloud iam service-accounts get-iam-policy eso-gsa@PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

Проверить аннотацию на ServiceAccount ESO:
```bash
kubectl get sa external-secrets -n external-secrets -o jsonpath='{.metadata.annotations}'
```

### Scalr Agent не подключается

```bash
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=50
```

Если в логах ошибки токена — `scalr-agent-pool-token` в SM невалиден. Push нового JWT:
```bash
printf %s "eyJ_NEW" | gcloud secrets versions add scalr-agent-pool-token --data-file=- --project=$PROJECT
```
ESO обновит K8s Secret автоматически в течение 5 минут, агент переподключится без рестарта.

### `terraform apply` fails: `No state file found`

`scalr-admin` не был применён или неправильный GCS prefix. Применить scalr-admin и проверить:
```bash
cd scalr-admin/
terraform output eso_gsa_email
```

### `flux_bootstrap_git` таймаут

Провайдер ждёт пока Flux станет healthy. Таймаут обычно означает что кластер не достигает `ghcr.io` (Flux container registry). Проверить egress network policies и firewall rules.

### Re-apply на уже бутстрапленном кластере

Безопасно. `flux_bootstrap_git` идемпотентен. Если версия совпадает с `flux_version` — контроллеры не трогаются. `github_repository_file` определяет равенство содержимого и пропускает коммиты если файлы не изменились.
