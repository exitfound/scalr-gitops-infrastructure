# gke

Terraform-конфигурация для создания GKE Autopilot кластера с сопутствующей сетевой инфраструктурой (VPC, Cloud NAT). Кластер служит management-кластером — в нём работают ESO, Scalr Agent и FluxCD контроллеры.

---

## Место в общей архитектуре

```
scalr-gitops-infrastructure/
  ├── gke/                   ← этот модуль: создаёт кластер и сеть
  ├── scalr-admin/           # создаёт GSA, WI bindings, Scalr ресурсы
  └── fluxcd/
      └── fluxcd-bootstrap/  # устанавливает Flux на кластер (читает outputs этого модуля)
```

**Порядок применения:**

```
1. gke/             → кластер и сеть существуют
2. scalr-admin/     → GSA, WI bindings, Scalr environment/pools (независим от кластера)
3. fluxcd-bootstrap → Flux устанавливается на кластер из шага 1
```

`gke` не зависит от `scalr-admin` и `fluxcd-bootstrap`. Может применяться параллельно с `scalr-admin`.

---

## Что создаётся

```
GCP Project
  ├── VPC: gke-network
  │     └── Subnet: gke-subnet (10.0.0.0/20)
  │           ├── Secondary range: gke-pods     (10.4.0.0/14)
  │           └── Secondary range: gke-services (10.8.0.0/20)
  ├── Cloud Router: gke-router
  ├── Cloud NAT: gke-nat
  └── GKE Autopilot cluster
        ├── Workload Identity: PROJECT.svc.id.goog
        ├── Private nodes (без публичных IP)
        └── Публичный control plane (master_authorized_networks)
```

После создания кластера `fluxcd-bootstrap` устанавливает в него:

```
GKE cluster
  ├── flux-system namespace      → Flux контроллеры (управляет git sync)
  ├── external-secrets namespace → ESO + WI → GCP Secret Manager
  └── scalr-agent namespace      → Scalr Agent + WI → GCS state bucket
```

---

## Файловая структура

```
gke/
├── versions.tf   # GCS backend + providers: google/google-beta >=7.17 <8
├── variables.tf  # все входные переменные с дефолтами
├── network.tf    # VPC (module network v18.0) + Cloud NAT (module cloud-router v9.0)
├── cluster.tf    # GKE Autopilot (module gke-autopilot-cluster v44.0)
└── outputs.tf    # cluster_name, endpoint, ca_cert, location, network, subnet, workload_pool
```

---

## Ключевые решения

### GKE Autopilot

Node pools управляются GCP автоматически. Не нужно настраивать machine type, autoscaling, taints. Подходит для небольшого набора workloads (Flux + ESO + Scalr Agent).

### Workload Identity

`workload_pool = "PROJECT.svc.id.goog"` — все поды аутентифицируются в GCP API без статических ключей. ESO использует WI для чтения JWT из Secret Manager, Scalr Agent — для доступа к GCS state bucket. WI bindings создаются в `scalr-admin/`.

### Приватные ноды + Cloud NAT

Ноды не имеют публичных IP. Исходящий трафик (скачивание Helm charts, образов, Scalr API) идёт через Cloud NAT с `AUTO_ONLY` аллокацией.

### Публичный control plane

`enable_private_endpoint = false` — API server доступен извне. Необходимо: `fluxcd-bootstrap` подключается к API через `kubectl`, Flux контроллеры сами обращаются к API. Доступ ограничивается через `master_authorized_networks`.

### STABLE release channel

Обновления раз в 6-8 недель с длинным циклом квалификации. Предпочтительно для management-кластера с критичной GitOps-инфраструктурой.

---

## Outputs

| Output | Описание | Используется в |
|--------|----------|----------------|
| `cluster_name` | Имя кластера | `fluxcd-bootstrap/envs/scalr.tfvars` |
| `cluster_endpoint` | Адрес API server (sensitive) | `fluxcd-bootstrap` → kubernetes provider |
| `cluster_endpoint_dns` | DNS endpoint кластера | справочно |
| `cluster_ca_certificate` | CA сертификат (sensitive) | `fluxcd-bootstrap` → kubernetes provider |
| `cluster_location` | Регион кластера | `fluxcd-bootstrap/envs/scalr.tfvars` |
| `project_id` | GCP project ID | справочно |
| `network_name` | Имя VPC | справочно |
| `subnet_name` | Имя subnet | справочно |
| `workload_pool` | WI pool `PROJECT.svc.id.goog` | справочно |

`fluxcd-bootstrap` не читает remote state этого модуля — значения передаются через `envs/scalr.tfvars` вручную после создания кластера.

---

## Применить gke

### Предварительные требования

- GCP проект создан, включены API: `container.googleapis.com`, `compute.googleapis.com`
- `gcloud auth application-default login`
- GCS bucket для Terraform state создан вручную (тот же bucket что у `scalr-admin` и `fluxcd-bootstrap`)

### terraform apply

```bash
cd gke/

terraform init

terraform apply \
  -var="gcp_project_id=your-gcp-project-id" \
  -var="cluster_name=your-cluster-name"
```

Или через tfvars файл:

```bash
cat > terraform.tfvars <<EOF
gcp_project_id = "your-gcp-project-id"
cluster_name   = "your-cluster-name"
EOF

terraform apply
```

Создание кластера занимает ~15 минут.

### Получить credentials для kubectl

```bash
gcloud container clusters get-credentials YOUR_CLUSTER_NAME \
  --region europe-north2 \
  --project YOUR_PROJECT_ID
```

### Верификация

```bash
# Кластер Ready
gcloud container clusters describe YOUR_CLUSTER_NAME \
  --region europe-north2 \
  --project YOUR_PROJECT_ID \
  --format="value(status)"
# Ожидаем: RUNNING

# Workload Identity включён
gcloud container clusters describe YOUR_CLUSTER_NAME \
  --region europe-north2 \
  --project YOUR_PROJECT_ID \
  --format="value(workloadIdentityConfig.workloadPool)"
# Ожидаем: YOUR_PROJECT_ID.svc.id.goog

# Ноды подключены
kubectl get nodes
```

### Что передать в fluxcd-bootstrap

После apply скопировать значения для `fluxcd/fluxcd-bootstrap/envs/scalr.tfvars`:

```bash
terraform output cluster_name
terraform output cluster_location
terraform output project_id
```

---

## Переменные

| Переменная | По умолчанию | Описание |
|-----------|-------------|----------|
| `gcp_project_id` | — | GCP project ID (обязателен) |
| `gcp_region` | `europe-north2` | Регион кластера и всех ресурсов |
| `cluster_name` | — | Имя GKE кластера (обязателен) |
| `network_name` | `gke-network` | Имя VPC |
| `subnet_name` | `gke-subnet` | Имя subnet |
| `subnet_cidr` | `10.0.0.0/20` | CIDR для нод (4096 IP) |
| `pods_range_name` | `gke-pods` | Имя secondary range для podов |
| `pods_cidr` | `10.4.0.0/14` | CIDR для podов (262k IP) |
| `services_range_name` | `gke-services` | Имя secondary range для services |
| `services_cidr` | `10.8.0.0/20` | CIDR для ClusterIP services |
| `master_cidr` | `172.16.0.0/28` | CIDR control plane (/28 требует GCP) |
| `master_authorized_networks` | `0.0.0.0/0` | Разрешённые IP для API server |
| `router_name` | `gke-router` | Имя Cloud Router |
| `nat_name` | `gke-nat` | Имя Cloud NAT |
| `maintenance_window_start` | `05:00` | Начало maintenance window (UTC) |
| `resource_labels` | `{}` | Labels на кластер |

> **Безопасность:** `master_authorized_networks` по умолчанию открыт для всех. В production ограничить конкретными CIDR (VPN, офис, Cloud Shell).

---

## Устранение проблем

### Кластер не создаётся: quota exceeded

```bash
gcloud compute project-info describe --project=YOUR_PROJECT_ID | grep -A5 quota
# Или в GCP Console → IAM & Admin → Quotas
```

Autopilot динамически выделяет ресурсы при первом деплое podов, но для старта кластера нужны квоты на CPU/memory в регионе.

### Ноды не появляются после деплоя podов

Autopilot создаёт ноды по требованию. Нормальное время — 2-5 минут после первого `kubectl apply`. Проверить:

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl describe pod POD_NAME -n NAMESPACE
```

### Cloud NAT не работает: поды не имеют доступа в интернет

```bash
gcloud compute routers get-nat-mapping-info gke-router \
  --region europe-north2 --project YOUR_PROJECT_ID
```

Убедиться что Cloud NAT создан и покрывает `ALL_SUBNETWORKS_ALL_IP_RANGES`.

### `terraform destroy` — ошибка deletion_protection

```bash
# 1. Снять защиту
# Установить deletion_protection = false в cluster.tf
terraform apply

# 2. Теперь удалять
terraform destroy
```

### Workload Identity не работает для ESO / Scalr Agent

Проверить что WI bindings созданы в `scalr-admin`:
```bash
gcloud iam service-accounts get-iam-policy eso-gsa@PROJECT.iam.gserviceaccount.com
# Должно быть: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

WI pool кластера должен совпадать с `infra_project_id` в `scalr-admin/agents.tf`. Если кластер в одном проекте, а GSA в другом — WI binding настраивается для проекта **кластера**.
