# fluxcd

Terraform-managed FluxCD bootstrap и GitOps конфигурация для GKE кластера. `fluxcd-bootstrap` устанавливает Flux один раз через CLI; после этого все изменения в кластере идут только через git push — Flux синхронизирует автоматически.

---

## Что делает fluxcd-bootstrap

`fluxcd-bootstrap/` — Terraform root module для одноразового bootstrap FluxCD на GKE кластере. Один `terraform apply` делает:

1. Устанавливает Flux контроллеры в кластер.
2. Создаёт `flux-system` namespace, GitHub auth secret с PAT из Secret Manager.
3. Регистрирует `GitRepository` CR — указывает Flux на GitHub репу.
4. Регистрирует root `Kustomization` CR — точка входа `fluxcd/clusters/scalr`.
5. Коммитит `gotk-components.yaml` и `gotk-sync.yaml` в репу.

После этого Flux берёт управление:

```
flux_bootstrap_git (Terraform, один раз)
  └─► root Kustomization → fluxcd/clusters/scalr
        └─► infrastructure.yaml
              ├─► infrastructure-external-secrets        → ESO HelmRelease
              ├─► infrastructure-external-secrets-config → ClusterSecretStore (dependsOn: ESO)
              └─► infrastructure-scalr-agent             → ExternalSecret + Agent HelmRelease (dependsOn: ESO config)
```

> `fluxcd-bootstrap` запускается только при первом деплое или обновлении версии Flux. Добавление новых агентов или манифестов не требует повторного запуска.

---

## Файловая структура

```
fluxcd/
├── fluxcd-bootstrap/              # Terraform root module — запускается один раз на кластер
│   ├── versions.tf                # GCS backend + providers: flux ~>1.8, kubernetes ~>3.1, google ~>6.0
│   ├── variables.tf               # cluster_name, gke_cluster_name, flux_version, …
│   ├── main.tf                    # GKE creds, scalr-admin remote state, flux_bootstrap_git
│   ├── github.tf                  # комментарий (GitHub provider удалён)
│   ├── outputs.tf                 # flux_version_installed, eso_gsa_email, scalr_agent_gsa_emails
│   ├── envs/
│   │   └── scalr.tfvars           # параметры кластера
│   └── templates/
│       ├── eso-serviceaccount.yaml.tpl           # шаблон-справка для ручного создания SA
│       ├── scalr-agent-serviceaccount.yaml.tpl   # шаблон-справка для ручного создания SA
│       ├── clustersecretstore.yaml.tpl            # шаблон-справка
│       ├── cluster-kustomization.yaml.tpl         # шаблон для новых кластеров
│       └── cluster-infrastructure.yaml.tpl        # динамический шаблон (for loop по agents)
├── clusters/
│   └── scalr/
│       ├── kustomization.yaml     # Flux entry point → infrastructure.yaml
│       └── infrastructure.yaml    # Flux Kustomization CRs — редактируется вручную
└── infrastructure/
    ├── external-secrets/          # ESO: namespace, SA, HelmRepository, HelmRelease
    ├── external-secrets-config/   # ClusterSecretStore → GCP SM (WI auth)
    └── scalr-agent/               # Scalr Agent: namespace, SA, ExternalSecret, HelmRelease
```

**Что управляет Terraform vs Flux vs вручную:**

| Ресурс | Управляется |
|---|---|
| Flux контроллеры | `flux_bootstrap_git` (Terraform, один раз) |
| GitRepository + root Kustomization CR | `flux_bootstrap_git` (Terraform, один раз) |
| `serviceaccount.yaml` с WI аннотацией | **вручную** (GSA email берётся из `terraform output` scalr-admin) |
| `infrastructure.yaml` (Kustomization список) | **вручную** (git push) |
| ESO HelmRelease | Flux (GitOps) |
| ClusterSecretStore | Flux (GitOps) |
| ExternalSecret → K8s Secret | ESO (авто-обновление каждые 5 мин) |
| Scalr Agent HelmRelease | Flux (GitOps) |

---

## Как это работает

### Цепочка зависимостей Flux Kustomizations

```
infrastructure-external-secrets           (устанавливает ESO + CRDs)
  └─► infrastructure-external-secrets-config  (ClusterSecretStore, нужны CRDs из ESO)
        └─► infrastructure-scalr-agent         (ExternalSecret + агент, нужен ClusterSecretStore)
```

Порядок обязателен: `ClusterSecretStore` — CRD которую устанавливает ESO. Если применить раньше — Kubernetes API отклонит как неизвестный тип. Flux повторяет автоматически благодаря `remediation.retries: -1` в HelmRelease.

### Поток секрета к агенту

```
GCP Secret Manager: scalr-agent-pool-token
  └─► ESO (аутентификация через Workload Identity, без статических ключей)
        └─► K8s Secret: scalr-agent-token  (обновляется каждые 5 мин)
              └─► HelmRelease valuesFrom → agent.token
                    └─► Scalr Agent pod подключается к Scalr
```

### Почему serviceaccount.yaml создаётся вручную

WI аннотация содержит точный GSA email созданный в `scalr-admin`. После `terraform apply scalr-admin` email доступен через:

```bash
terraform output scalr_agent_gsa_emails
terraform output eso_gsa_email
```

Файл создаётся один раз при добавлении агента и меняется только при смене GSA.

### Связь scalr-admin → fluxcd-bootstrap

`fluxcd-bootstrap` читает `scalr-admin` remote state для отображения GSA emails в outputs:

```hcl
# outputs.tf
locals {
  eso_gsa_email = data.terraform_remote_state.scalr_admin.outputs.eso_gsa_email
  agents        = data.terraform_remote_state.scalr_admin.outputs.agents
}

output "scalr_agent_gsa_emails" {
  value = { for k, v in local.agents : k => v.scalr_agent_gsa_email }
}
```

---

## Почему Terraform управляет Flux bootstrap

Ручной bootstrap требует 6+ команд `kubectl` и `flux`, создания GitHub auth secret вручную. Это невоспроизводимо для второго кластера.

`flux_bootstrap_git` заменяет всё это одним resource declaration. Идемпотентен: если версия совпадает с `var.flux_version` — ничего не меняет.

---

## Почему fluxcd-bootstrap нельзя запускать как Scalr workspace

`fluxcd-bootstrap` разворачивает Scalr Agent. Circular dependency: workspace не может развернуть агент который нужен для запуска этого workspace. Запускается только через CLI, один раз на кластер.

---

## Почему state в GCS

State изолирован по prefix, один модуль обслуживает все кластеры:

```
gs://your-state-bucket/
├── scalr-admin/
└── fluxcd-bootstrap/
    ├── scalr/
    └── prod/   ← будущий
```

Prefix задаётся через `-backend-config` при `terraform init`.

---

## Применить fluxcd-bootstrap

### Предварительные требования

- `scalr-admin` применён, outputs непусты
- SM секреты заполнены: `github-pat`, `scalr-agent-pool-token`
- `serviceaccount.yaml` файлы созданы вручную и запушены в git
- `gcloud` аутентифицирован, `kubectl` настроен на кластер

### terraform init

```bash
terraform -chdir=fluxcd/fluxcd-bootstrap init \
  -backend-config="bucket=YOUR_BUCKET" \
  -backend-config="prefix=fluxcd-bootstrap/scalr"
```

### terraform apply

```bash
terraform -chdir=fluxcd/fluxcd-bootstrap apply -var-file=envs/scalr.tfvars
```

Outputs после успешного apply:
```
eso_gsa_email          = "eso-gsa@PROJECT.iam.gserviceaccount.com"
flux_bootstrap_path    = "fluxcd/clusters/scalr"
flux_version_installed = "v2.8.5"
scalr_agent_gsa_emails = { "main" = "scalr-agent-gsa@PROJECT.iam.gserviceaccount.com" }
```

### Верификация

```bash
# Все Kustomizations Ready
flux get kustomization -A

# HelmReleases Ready
flux get helmrelease -A

# ClusterSecretStore Valid
kubectl get clustersecretstore gcp-sm

# ExternalSecret Synced
kubectl get externalsecret scalr-agent-token -n scalr-agent

# Scalr Agent Running
kubectl get pods -n scalr-agent
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=20
# Ожидаем: "Agent session established" + "Agent started"
```

---

## Добавление нового агента

1. **scalr-admin:** добавить `module "agent_prod"` в `agents.tf`, обновить `outputs.tf`, `terraform apply`.

2. **Создать `serviceaccount.yaml` вручную:**
```bash
# Взять email из scalr-admin outputs
terraform -chdir=scalr-admin output scalr_agent_gsa_emails
```
```yaml
# fluxcd/infrastructure/scalr-agent-prod/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scalr-agent-prod
  namespace: scalr-agent-prod
  annotations:
    iam.gke.io/gcp-service-account: <email из outputs>
```

3. **Создать FluxCD манифесты** `fluxcd/infrastructure/scalr-agent-prod/` (копия `scalr-agent/` с заменой namespace, KSA, SM secret name).

4. **Добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml`:**
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-scalr-agent-prod
  namespace: flux-system
spec:
  interval: 10m
  path: ./fluxcd/infrastructure/scalr-agent-prod
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure-external-secrets-config
```

5. **`git push`** — Flux задеплоит автоматически.

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

**2. Добавить Kustomization в `fluxcd/clusters/scalr/infrastructure.yaml`:**
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

**3. `git push`** — Flux синхронизирует в течение 10 минут.

---

## Устранение проблем

### Kustomization застрял в False / Not Ready

```bash
flux get kustomization -A
kubectl describe kustomization infrastructure-external-secrets -n flux-system
```

Частые причины: CRD ещё не установлена (ESO не Ready), ошибка git sync. Flux повторяет автоматически.

### HelmRelease Failed

```bash
flux get helmrelease -A
kubectl describe helmrelease scalr-agent -n scalr-agent
```

Благодаря `remediation.retries: -1` Flux будет повторять install/upgrade автоматически после устранения причины.

### ESO не синхронизирует секрет

```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
# Проверить WI binding:
gcloud iam service-accounts get-iam-policy eso-gsa@PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
# Проверить аннотацию на SA:
kubectl get sa external-secrets -n external-secrets -o jsonpath='{.metadata.annotations}'
```

### Scalr Agent не подключается

```bash
kubectl logs -n scalr-agent -l app.kubernetes.io/name=agent-local --tail=50
```

Ошибка токена — JWT в SM невалиден:
```bash
printf %s "eyJ_NEW" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- --project=$PROJECT
# ESO обновит K8s Secret автоматически в течение 5 минут
```

### `No state file found` при terraform plan

`scalr-admin` не применён или неправильный GCS prefix:
```bash
terraform -chdir=scalr-admin output eso_gsa_email
```

### `flux_bootstrap_git` таймаут

Кластер не достигает `ghcr.io` (Flux container registry). Проверить egress network policies и firewall rules.

### Re-apply на уже бутстрапленном кластере

Безопасно. `flux_bootstrap_git` идемпотентен — если версия совпадает с `flux_version`, контроллеры не трогаются.
