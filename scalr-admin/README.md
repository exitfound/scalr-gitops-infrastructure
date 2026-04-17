# scalr-admin

Terraform configuration for bootstrapping Scalr-as-code on top of GCP. Manages GCP service accounts, Workload Identity bindings, and Scalr resources (environment, agent pool, VCS provider, workspaces). Runs exclusively via CLI — never via a Scalr VCS workspace.

---

## Table of Contents

1. [What this does](#what-this-does)
2. [Why CLI-only — the circular dependency problem](#why-cli-only)
3. [Why Workload Identity lives here](#why-workload-identity-lives-here)
4. [Why Secret Manager containers are created manually](#why-secret-manager-containers-are-created-manually)
5. [Why SCALR_TOKEN cannot be read from Secret Manager by Terraform](#why-scalr_token-cannot-be-read-from-secret-manager)
6. [Why state is in GCS, not Scalr](#why-state-is-in-gcs)
7. [Prerequisites](#prerequisites)
8. [Step 1 — Collect tokens and IDs](#step-1--collect-tokens-and-ids)
9. [Step 2 — Adapt terraform.tfvars](#step-2--adapt-terraformtfvars)
10. [Step 3 — Create GCS bucket for state](#step-3--create-gcs-bucket-for-state)
11. [Step 4 — Create Secret Manager containers and push values](#step-4--create-secret-manager-containers-and-push-values)
12. [Step 5 — Run terraform apply](#step-5--run-terraform-apply)
13. [Step 6 — Get Agent Pool JWT and push to Secret Manager](#step-6--get-agent-pool-jwt-and-push-to-secret-manager)
14. [Step 7 — Update FluxCD manifests with GSA emails](#step-7--update-fluxcd-manifests-with-gsa-emails)
15. [Adding a new workspace](#adding-a-new-workspace)
16. [Troubleshooting](#troubleshooting)

---

## File structure

```
scalr-admin/
├── modules/
│   ├── scalr-agent-pool/     # scalr_agent_pool resource
│   ├── scalr-environment/    # scalr_environment resource
│   ├── scalr-vcs-provider/   # scalr_vcs_provider resource
│   └── scalr-workspace/      # scalr_workspace + scalr_variable resources
├── versions.tf          # GCS backend, required_providers, provider configs
├── variables.tf         # All input variables with descriptions
├── terraform.tfvars     # Instance-specific values (not secrets)
├── data.tf              # Reads github-pat from GCP Secret Manager
├── gcp.tf               # GSA resources + Workload Identity bindings
├── agent_pool.tf        # module.agent_pool call
├── environment.tf       # module.env_dev call
├── vcs.tf               # module.vcs_github call
├── workspaces.tf        # module.ws_admin (and future workspace calls)
└── outputs.tf           # GSA emails + Scalr resource IDs
```

**Why this split:**
- `versions.tf` — provider config belongs with backend config, they're both infrastructure plumbing
- `gcp.tf` — GCP resources stay flat (bootstrap, changes rarely); splitting by provider keeps the dependency flow obvious
- `modules/` — one module per Scalr resource type; each new workspace is a single `module` block in `workspaces.tf` without touching shared files
- `data.tf` — data sources read external state, separating them from resources makes the dependency flow obvious
- `variables.tf` — no defaults for instance-specific values (`gcp_project_id`, `scalr_hostname`, `scalr_account_id`, `github_username`); Terraform will fail fast if `terraform.tfvars` is missing instead of silently using stale defaults

---

## Why CLI-only

`scalr-admin` creates the Scalr resources that other workspaces depend on: the environment, agent pool, and VCS provider. If you attached `scalr-admin` to a Scalr VCS workspace, you would get a circular dependency:

```
scalr_workspace manages scalr-admin/
  → scalr-admin/ creates scalr_environment
    → scalr_workspace needs scalr_environment to exist
```

A workspace cannot manage the resources it itself depends on. Therefore `scalr-admin` is always run manually via `terraform apply` from a local machine. No automation, no VCS triggers.

The admin workspace (`module.ws_admin`) is created in Scalr with `execution_mode = "local"` so Scalr records it in the UI but never attempts to run it automatically.

---

## Why Workload Identity lives here

Workload Identity (WI) bindings for the Scalr Agent and ESO pods are bootstrap infrastructure — they must exist before the agent can connect and before ESO can read secrets. The natural place to put WI would be a dedicated Scalr VCS workspace, but that creates another circular dependency:

```
VCS workspace creates WI for Scalr Agent
  → Scalr Agent must already be running to execute the VCS workspace
    → Scalr Agent needs WI to start
```

Breaking this loop requires creating WI outside of Scalr's control, which means CLI. Since `scalr-admin` is already CLI-only, WI bindings live here. After bootstrap, WI changes are rare — this is not a problem in practice.

---

## Why Secret Manager containers are created manually

The three SM containers (`github-pat`, `scalr-api-token`, `scalr-agent-pool-token`) are created manually via `gcloud`, not managed by Terraform. The reason is a hard Terraform limitation:

Terraform cannot create a Secret Manager container (`google_secret_manager_secret`) and in the same `apply` read a value from it via a `data` source. Even with `depends_on`, the `data "google_secret_manager_secret_version"` block will fail with `"No secret versions found"` because the container was just created — it has no versions yet.

The only workarounds are:
1. Two-step apply with `-target` — creates ordering issues, easy to forget, fragile
2. Create containers manually once → push values → then Terraform only reads

Option 2 is used here. Containers are created once during bootstrap and never touched by Terraform. Terraform only contains `data` sources that read existing values.

---

## Why SCALR_TOKEN cannot be read from Secret Manager by Terraform

The `scalr` provider requires a token to initialize. Provider initialization happens before any `data` source or `resource` block is evaluated — it is the very first thing Terraform does. This means you cannot do:

```hcl
# This does NOT work
data "google_secret_manager_secret_version" "scalr_token" { ... }

provider "scalr" {
  token = data.google_secret_manager_secret_version.scalr_token.secret_data  # evaluated too late
}
```

Terraform will error: provider configuration references a value that cannot be determined before providers are configured.

The only supported approach is to pass the token via the `SCALR_TOKEN` environment variable, which the Scalr provider reads automatically:

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token \
  --project=YOUR_PROJECT)
terraform apply
```

This is not a workaround — it is the intended usage pattern documented by Scalr. The token is never written to disk, never enters Terraform state, and is not visible in plan output.

Note: the `github-pat` token _can_ be read from SM via `data.tf` because it is consumed by a `scalr_vcs_provider` resource, not by provider configuration itself. Resource evaluation happens after providers are initialized, so the data source resolves correctly.

---

## Why state is in GCS

`scalr-admin` uses GCS as its state backend for two reasons.

First, bootstrap isolation: `scalr-admin` creates the Scalr resources (environment, workspace) that a Scalr remote backend would depend on. If state lived in Scalr and Scalr became unavailable, there would be no way to run `terraform apply` to fix the problem — the tool that manages Scalr would itself be broken.

Second, recovery: if the Scalr account becomes unavailable for any reason, state in GCS remains fully accessible. You can always run `terraform apply` locally against GCS state to restore the Scalr configuration.

GCS backend keeps state outside of Scalr, in a bucket you fully control. The state lock is managed by GCS object versioning (no separate lock table needed). The GCS bucket is created manually once before the first `terraform init`.

### When the Scalr remote backend IS appropriate

Scalr's UI will show an "Upload configuration" dialog for every workspace with a `remote` backend snippet:

```hcl
terraform {
  backend "remote" {
    hostname     = "youraccount.scalr.io"
    organization = "env-xxxxxxxxxxxxxxxxx"
    workspaces {
      name = "workspace-name"
    }
  }
}
```

This is the correct pattern for any workspace that manages regular infrastructure — app services, Kubernetes configs, cloud networking, etc. Scalr stores the state, runs plan/apply on VCS push, and shows run history in the UI. That is the intended Scalr workflow.

The only configuration where this does not apply is `scalr-admin` itself, because it creates the Scalr resources (environment, workspace) that the remote backend would depend on. Using Scalr as the backend for the configuration that creates Scalr's own workspace is a self-referential loop with no valid bootstrap path.

---

## Prerequisites

- GCP project with GKE cluster and Workload Identity enabled
- `gcloud` CLI authenticated: `gcloud auth login && gcloud auth application-default login`
- `kubectl` configured to the target cluster
- `terraform` >= 1.5
- Scalr account (free tier is sufficient)

---

## Step 1 — Collect tokens and IDs

### Scalr API Token

```
Scalr UI → Account Settings → API Tokens → Create Token
```

Copy the `eyJ...` value. This is `scalr-api-token` — used only to authenticate Terraform during `apply`. Never stored in code.

### Scalr Account ID

Visible in the Scalr UI URL:
```
https://youraccount.scalr.io/accounts/acc-xxxxxxxxxxxxxxxxx/...
                                       ^^^^^^^^^^^^^^^^^^^^
```

### Scalr Hostname

The subdomain of your Scalr account: `youraccount.scalr.io`

### GitHub Personal Access Token

```
GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
→ Generate new token → scope: repo → copy ghp_...
```

This token is used by Scalr to clone repositories for VCS-connected workspaces.

### Agent Pool JWT

**This is obtained after Step 5** — the pool must exist before a token can be generated. Come back here after `terraform apply`.

---

## Step 2 — Adapt terraform.tfvars

Edit `terraform.tfvars` with your values:

```hcl
gcp_project_id   = "your-gcp-project-id"
scalr_hostname   = "youraccount.scalr.io"
scalr_account_id = "acc-xxxxxxxxxxxxxxxxx"
github_username  = "your-github-username"

github_secret_name                 = "github-pat"
scalr_api_token_secret_name        = "scalr-api-token"
scalr_agent_pool_token_secret_name = "scalr-agent-pool-token"
```

The last three values are the GCP Secret Manager secret names. Change them only if you use different names.

Also update the GCS backend bucket name in `versions.tf`:

```hcl
backend "gcs" {
  bucket = "your-state-bucket-name"
  prefix = "scalr-admin"
}
```

If your bucket name differs from the default (`terraform_state_dev_beneflo`), also add it to `terraform.tfvars`:

```hcl
state_bucket = "your-state-bucket-name"
```

---

## Step 3 — Create GCS bucket for state

```bash
PROJECT=your-gcp-project-id
BUCKET=your-state-bucket-name

gcloud storage buckets create gs://$BUCKET \
  --project=$PROJECT \
  --location=europe-north1 \
  --uniform-bucket-level-access
```

Enable versioning (required for state locking):

```bash
gcloud storage buckets update gs://$BUCKET --versioning
```

This bucket is never managed by Terraform — creating it is a one-time manual step.

---

## Step 4 — Create Secret Manager containers and push values

SM containers are created once manually. Terraform only reads from them, never creates them (see [Why Secret Manager containers are created manually](#why-secret-manager-containers-are-created-manually)).

```bash
PROJECT=your-gcp-project-id

# Create containers
gcloud secrets create github-pat              --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-api-token         --replication-policy=automatic --project=$PROJECT
gcloud secrets create scalr-agent-pool-token  --replication-policy=automatic --project=$PROJECT

# Push values
printf %s "ghp_YOUR_GITHUB_PAT"  | gcloud secrets versions add github-pat      --data-file=- --project=$PROJECT
printf %s "eyJ_YOUR_SCALR_TOKEN" | gcloud secrets versions add scalr-api-token --data-file=- --project=$PROJECT
```

**Do not push `scalr-agent-pool-token` yet** — the agent pool doesn't exist until after Step 5.

> **Why `printf %s` and not `echo`?** The `echo` command appends a newline to the value. A newline at the end of a token will cause authentication failures that are very hard to debug. `printf %s` writes the string exactly as-is.

---

## Step 5 — Run terraform apply

```bash
PROJECT=your-gcp-project-id

# Authenticate the Scalr provider (see Why SCALR_TOKEN cannot be read from SM)
export SCALR_TOKEN=$(gcloud secrets versions access latest \
  --secret=scalr-api-token \
  --project=$PROJECT)

cd scalr-admin/
terraform init
terraform plan
terraform apply
```

After apply, check outputs:

```bash
terraform output
```

You will see:
- `scalr_agent_gsa_email` — needed for Step 7
- `eso_gsa_email` — needed for Step 7
- `scalr_environment_id` — use as `environment_id` when adding new workspaces
- `scalr_agent_pool_id` — use as `agent_pool_id` when adding new workspaces
- `scalr_vcs_provider_id` — use as `vcs_provider_id` when adding new workspaces

> **Provider version note:** The `scalr_agent_pool` resource had `account_id` as a required attribute in provider versions before 3.12. In 3.12+ `account_id` is deprecated and will trigger a warning if present. This configuration uses provider `~> 3.15` where `account_id` is omitted from `scalr_agent_pool` intentionally.

---

## Step 6 — Get Agent Pool JWT and push to Secret Manager

```
Scalr UI → Account Settings → Agent Pools → scalr-gitops-infrastructure-agent → Tokens → Add Token
```

Copy the `eyJ...` token, then push it:

```bash
printf %s "eyJ_YOUR_AGENT_POOL_JWT" | gcloud secrets versions add scalr-agent-pool-token \
  --data-file=- \
  --project=$PROJECT
```

This token is read by External Secrets Operator (via Workload Identity) and delivered as a Kubernetes Secret to the Scalr Agent pod. Terraform never touches this value — ESO manages the full lifecycle from SM to K8s Secret.

---

## Step 7 — Update FluxCD manifests with GSA emails

After `terraform apply`, copy the GSA emails from `terraform output` and paste them into the FluxCD manifests:

**`fluxcd/infrastructure/scalr-agent/serviceaccount.yaml`:**
```yaml
annotations:
  iam.gke.io/gcp-service-account: scalr-agent-gsa@YOUR_PROJECT.iam.gserviceaccount.com
```

**`fluxcd/infrastructure/external-secrets/serviceaccount.yaml`:**
```yaml
annotations:
  iam.gke.io/gcp-service-account: eso-gsa@YOUR_PROJECT.iam.gserviceaccount.com
```

Commit and push. FluxCD will reconcile automatically.

---

## Adding a new workspace

Every new Terraform repository that should be managed by Scalr needs a workspace. Add it to `workspaces.tf` as a single module block:

```hcl
module "ws_gcp_infra" {
  source            = "./modules/scalr-workspace"
  name              = "gcp-infrastructure"
  environment_id    = module.env_dev.environment_id
  execution_mode    = "remote"
  terraform_version = "1.5.7"
  auto_apply        = false
  agent_pool_id     = module.agent_pool.agent_pool_id
  vcs_provider_id   = module.vcs_github.vcs_provider_id
  vcs_repo_identifier = "your-github-username/your-repo"
  vcs_branch        = "main"
  working_directory = "terraform/"          # omit if repo root
  trigger_prefixes  = ["terraform/"]        # omit if whole repo triggers runs
}
```

For a CLI-driven workspace (no VCS, runs triggered manually or via API):

```hcl
module "ws_admin" {
  source            = "./modules/scalr-workspace"
  name              = "scalr-admin-workspace"
  environment_id    = module.env_dev.environment_id
  execution_mode    = "local"
  terraform_version = "1.5.7"
  auto_apply        = false
}
```

After adding the block run `terraform apply` from CLI. The new workspace will appear in the Scalr UI under the `scalr-gcp-infrastructure-dev` environment.

**Using GCS for workspace state:** if you want plan/apply to run on the Scalr agent but state to live in GCS instead of Scalr, add a GCS backend to the workspace's own `versions.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "terraform_state_dev_beneflo"
    prefix = "gcp-infrastructure"   # unique per workspace
  }
}
```

The agent authenticates to GCS via Workload Identity — no extra configuration needed in Scalr.

---

## Troubleshooting

### State lock stuck

If a previous apply was interrupted, GCS may hold a stale lock:

```bash
terraform force-unlock LOCK_ID
```

The lock ID is shown in the error message. GCS locks are object-level — no external lock table to query.

### `No secret versions found` on terraform plan

The SM container exists but has no versions yet. Push the value first:

```bash
printf %s "VALUE" | gcloud secrets versions add SECRET_NAME --data-file=- --project=$PROJECT
```

This error is also the reason SM containers are not created by Terraform — if Terraform created the container and immediately tried to read from it in the same apply, it would fail with this error every time.

### `Error: Provider configuration references a value that cannot be determined`

You tried to pass the Scalr token via a variable or data source into the `scalr` provider block. This does not work — the Scalr provider initializes before any data sources are evaluated. Use the environment variable instead:

```bash
export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=$PROJECT)
```

### ESO not syncing secrets

```bash
kubectl describe clustersecretstore gcp-sm
kubectl describe externalsecret scalr-agent-token -n scalr-agent
```

Check the Workload Identity binding is in place:

```bash
gcloud iam service-accounts get-iam-policy eso-gsa@$PROJECT.iam.gserviceaccount.com
# Should include: serviceAccount:PROJECT.svc.id.goog[external-secrets/external-secrets]
```

### Workspace recreates existing GCP resources

Symptom: a Scalr VCS workspace runs `terraform apply` and tries to create resources that already exist in GCP.

Cause: the workspace is using Scalr's own state backend (free tier default) and has no knowledge of the existing state. Scalr's state is per-workspace and does not see what was applied from `scalr-admin/`.

Fix: `scalr-admin/` must never be attached to a Scalr VCS workspace. Run it only from CLI with the GCS backend. If a VCS workspace accidentally ran against `scalr-admin/`, the state in Scalr and GCS are now diverged — resolve by running `terraform apply` from CLI to reconcile against the GCS state.
