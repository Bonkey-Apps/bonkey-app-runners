# bonkey-puzzles free-tier self-hosted runner (`environments/bonkey-puzzles`)

A **second, self-contained** deployment of the GCE self-hosted runner stack — a
GCP **Always-Free** `e2-micro` (30 GB `pd-standard`) Managed Instance Group
**registered to `Bonkey-Apps/bonkey-puzzles`**. It exists so that repo's GitHub
Pages **deploy** job has a runner (org Actions billing is at $0, so
`ubuntu-latest` jobs queue forever).

This root instantiates the reusable module at
[`../../modules/runner-mig`](../../modules/runner-mig) and has its **own
Terraform state** (GCS backend prefix `gcp-runner-puzzles`). It never reads,
locks, or mutates the live **bonkey-puzzles-app** runner's state.

> **#293.** Configuration + docs only. Running `terraform apply` and verifying
> registration happen on the bonkey-puzzles side and are **gated on a
> bonkey-puzzles-scoped PAT** — out of scope for the PR that lands this.

---

## ⚠️ This runner is for the LIGHT Pages deploy only

`e2-micro` has **1 GB RAM**. Do **NOT** run heavy/Expo-web-export builds on it —
the OOM killer will take them down. Per the #274 flow, **bonkey-puzzles-app** builds
the Expo web export (on its billed `n2`-class runner) and opens a PR in
bonkey-puzzles; **bonkey-puzzles' own runner only runs the light Pages deploy**
(commit the built `dist/` to the Pages branch / push the artifact). That fits
`e2-micro` comfortably.

| Runs here (free-tier `e2-micro`) | Stays on bonkey-puzzles-app runner |
|----------------------------------|------------------------------|
| GitHub Pages **deploy** job      | Expo **web export** / build  |
| (light file copy / push)         | Android / heavy CI           |

---

## Free-tier parameter set (fixed in `main.tf`)

| Parameter | Value | Why |
|-----------|-------|-----|
| `github_repo` | `Bonkey-Apps/bonkey-puzzles` | Registration target |
| `machine_type` | `e2-micro` | Always Free machine type (1/account, us regions) |
| `boot_disk_size_gb` | `30` | Always Free standard-PD allowance |
| `boot_disk_type` | `pd-standard` | `pd-ssd` leaves free tier |
| `region` / `zone` | `us-central1` / `us-central1-a` | Always-Free region |
| `runner_mode` | `ephemeral` | On-demand only — no standing fleet |
| `runner_target_size` | `0` | Idle by default; provision on demand (see `scripts/runner-up.sh` or a deliberate resize) rather than an always-on runner |
| `runner_instance_name` | `gh-runner-puzzles` | Distinct from bonkey-puzzles-app `gh-runner` |
| `runner_labels` | `self-hosted, linux, x64, gce-free, bonkey-puzzles` | Routes the deploy job here |
| `network_tags` | `gh-runner-puzzles` | Own deny-ingress firewall target |

These are literals in `main.tf` and are intentionally **not** overridable via
tfvars, so the deployment cannot drift off the Always-Free tier.

---

## Required secret — a bonkey-puzzles-scoped PAT (human action)

> **The existing `GH_RUNNER_PAT` is scoped to `bonkey-puzzles-app` and will NOT
> register a runner against `bonkey-puzzles`.** Runner registration is
> repo-scoped (`POST /repos/Bonkey-Apps/bonkey-puzzles/actions/runners/registration-token`),
> so a **new** token scoped to `bonkey-puzzles` is mandatory.

Create a **fine-grained PAT**:

1. GitHub → Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → **Generate new token**.
2. **Resource owner**: `Bonkey-Apps`. **Repository access** → Only select
   repositories → **`bonkey-puzzles`**.
3. **Permissions → Repository permissions → Administration → Read and write.**
4. Copy the token.

Store it in **Secret Manager** (do not commit, do not paste into tfvars):

```bash
# One-time: create the secret
printf '%s' 'github_pat_...' | gcloud secrets create bonkey-puzzles-runner-pat \
  --data-file=- --project=YOUR_PROJECT_ID
# Rotate later: add a new version
printf '%s' 'github_pat_...' | gcloud secrets versions add bonkey-puzzles-runner-pat \
  --data-file=- --project=YOUR_PROJECT_ID
```

At apply time, export it into `TF_VAR_github_runner_pat`:

```bash
# If a stale gcloud access token is exported it can shadow your creds — clear it:
unset CLOUDSDK_AUTH_ACCESS_TOKEN
export TF_VAR_github_runner_pat="$(gcloud secrets versions access latest \
  --secret=bonkey-puzzles-runner-pat --project=YOUR_PROJECT_ID)"
```

The PAT is consumed once at VM boot to mint a short-lived registration token,
then cleared from memory. It lives only in GCE instance metadata (encrypted at
rest) — never on disk, never logged, never in git. It is also redacted from
Terraform plan/apply output and state (`sensitive`).

---

## Deploy (on the bonkey-puzzles side — gated on the PAT, out of scope for this PR)

```bash
cd gcp-runner/environments/bonkey-puzzles

# 1. Configure
cp terraform.tfvars.example terraform.tfvars   # set project_id (gitignored)
unset CLOUDSDK_AUTH_ACCESS_TOKEN
export TF_VAR_github_runner_pat="$(gcloud secrets versions access latest \
  --secret=bonkey-puzzles-runner-pat --project=YOUR_PROJECT_ID)"
export GOOGLE_CREDENTIALS="$(cat /path/to/sa-key.json)"   # provisioning SA

# 2. Init / plan / apply (uses its OWN state: GCS prefix gcp-runner-puzzles)
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

> Local-only validation (no GCP creds, no apply):
> `terraform init -backend=false && terraform validate`.

### Verify the runner registered

1. Browser: **GitHub → Bonkey-Apps/bonkey-puzzles → Settings → Actions →
   Runners.** You should see **`gce-gh-runner-puzzles-…`** with status
   **Idle / online** and labels `self-hosted, linux, x64, gce-free,
   bonkey-puzzles`.
2. Or via API (also emitted as the `verify_runner_command` output) with the
   bonkey-puzzles PAT:
   ```bash
   curl -H "Authorization: Bearer $TF_VAR_github_runner_pat" \
     https://api.github.com/repos/Bonkey-Apps/bonkey-puzzles/actions/runners
   ```
   Look for `"name": "gce-gh-runner-puzzles-…"`, `"status": "online"`.

Startup takes a few minutes (apt + runner download). If it doesn't appear, read
the serial console:
```bash
gcloud compute instances list --filter="name~gh-runner-puzzles" --project=YOUR_PROJECT_ID
gcloud compute instances get-serial-port-output <vm-name> \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

---

## Targeting this runner from the bonkey-puzzles Pages-deploy job

In the **bonkey-puzzles** repo's Pages-deploy workflow, set the deploy job's
`runs-on` to the exact label set:

```yaml
jobs:
  deploy-pages:
    runs-on: [self-hosted, linux, x64, gce-free, bonkey-puzzles]
    steps:
      - uses: actions/checkout@v5
      # ... download the web-export artifact built on bonkey-puzzles-app, then
      #     publish it to Pages. Keep this LIGHT — no Expo export here.
```

The `bonkey-puzzles` label distinguishes this runner from the bonkey-puzzles-app
`gce-free` runner, so a heavy bonkey-puzzles-app job can never land on the e2-micro.

---

## Teardown

```bash
cd gcp-runner/environments/bonkey-puzzles
terraform destroy
```

Persistent mode leaves an **offline** runner entry in bonkey-puzzles; GitHub
auto-prunes offline self-hosted runners after ~14 days, or remove it immediately
via Settings → Actions → Runners → **Remove**.

---

## State isolation guarantee

- Backend bucket `gs://bonkey-apps-tfstate`, prefix **`gcp-runner-puzzles`**.
- The bonkey-puzzles-app root uses prefix **`gcp-runner`**.
- Disjoint prefixes ⇒ disjoint state objects and locks. Applying or destroying
  this root **cannot** affect the live bonkey-puzzles-app runner. Never change this
  prefix to `gcp-runner` — that would alias the live state.
