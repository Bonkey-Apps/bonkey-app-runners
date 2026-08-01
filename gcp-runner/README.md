# GCE Self-Hosted GitHub Actions Runner — Terraform

Provisions a GitHub Actions self-hosted runner on Google Compute Engine.
Default configuration stays within GCP's **Always Free tier**. At VM boot the
startup script mints a registration token from a fine-grained PAT, registers the
runner, and installs it as an auto-restarting systemd service.

> This is **#141 / sub-issue #142** of the GCE runner epic.

## Runner modes (`runner_mode`)

Controlled by the `runner_mode` variable (default `persistent`):

| Mode | Behavior | Use when |
|------|----------|----------|
| **`persistent`** (default) | Registers and **stays available** across jobs. Installed as a systemd service that auto-restarts on crash and survives reboot. No `--ephemeral`, no self-deletion. `terraform apply` yields an Idle/online runner out of the box. | You want a standing runner that picks up jobs as they queue. |
| **`ephemeral`** | One-shot. Registers with `--ephemeral`, runs exactly one job, then the VM self-deletes (watchdog with a hard max-lifetime catches hung jobs). | On-demand JIT runs; no idle VM left around. |

In both modes the runner registers with a stable name `gce-<instance_name>`
and `--replace`, so re-applying replaces the same entry instead of failing on a
stale registration.

---

## Secrets you must create

Before running `terraform apply` the human operator must provision the
following. **None of these values should be committed to the repository.**

### 1. `GCP_PROJECT_ID`

- **What:** Your GCP project ID (a string like `my-project-12345`).
- **Where to put it:**
  - Terraform variable: set `project_id` in `terraform.tfvars` **or** via
    `export TF_VAR_project_id=my-project-12345`.
  - GitHub Actions secret (for a future workflow that calls Terraform):
    `GCP_PROJECT_ID`.

### 2. `GCP_SA_KEY` — Service-account JSON key

- **What:** The JSON key file for a GCP service account that can manage Compute
  Engine resources.
- **IAM roles required on the GCP project** (grant these before `terraform apply`):

  | Role | Why needed |
  |------|-----------|
  | `roles/compute.instanceAdmin.v1` | Create / start / stop / delete GCE instances and disks |
  | `roles/iam.serviceAccountAdmin` | Create the runner SA (only needed if `service_account_email` is left empty) |
  | `roles/iam.serviceAccountUser` | Allow the runner SA to act as itself for self-deletion |

  A tighter custom role is possible; the above is the minimal predefined set.

- **How to create the key:**

  ```bash
  # 1. Create (or identify) a service account
  gcloud iam service-accounts create terraform-runner \
    --display-name="Terraform GCE runner provisioner" \
    --project=YOUR_PROJECT_ID

  # 2. Grant roles
  SA="terraform-runner@YOUR_PROJECT_ID.iam.gserviceaccount.com"
  for role in roles/compute.instanceAdmin.v1 roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser; do
    gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
      --member="serviceAccount:$SA" --role="$role"
  done

  # 3. Create and download a JSON key
  gcloud iam service-accounts keys create sa-key.json --iam-account="$SA"
  ```

- **Where to put it:**
  - Local Terraform runs: set `export GOOGLE_CREDENTIALS="$(cat sa-key.json)"`.
  - GitHub Actions secret: `GCP_SA_KEY` = entire contents of `sa-key.json`
    (the JSON blob, not the file path). In the workflow, write it to a temp
    file and set `GOOGLE_CREDENTIALS`.

### 3. `GH_RUNNER_PAT` — GitHub fine-grained PAT

- **What:** A fine-grained Personal Access Token that the startup script uses
  at boot to mint a one-time JIT registration token. By default the runners
  register at the **org** level, so it calls
  `POST /orgs/{org}/actions/runners/registration-token` (one fleet serves every
  repo in `Bonkey-Apps`). If you set `github_org = ""` to register against a
  single repo instead, it calls
  `POST /repos/{owner}/{repo}/actions/runners/registration-token`.

- **Required permissions (fine-grained PAT):**

  | Registration scope | Permission | Level |
  |--------------------|------------|-------|
  | Org (default, `github_org` set) | Organization → **Self-hosted runners** | Read and write |
  | Repo (`github_org = ""`)        | Repository → **Administration**        | Read and write |

  The token is consumed at boot to mint an ephemeral registration token and is
  then cleared from memory. It is stored only in GCE instance metadata
  (encrypted at rest by GCP) and is never written to disk or logged.

- **How to create (org-level, default):**
  1. GitHub → Settings → Developer settings → Personal access tokens →
     Fine-grained tokens → Generate new token.
  2. Set **Resource owner** → `Bonkey-Apps`.
  3. Under **Permissions → Organization permissions** → **Self-hosted runners**
     → **Read and write**.
  4. Copy the token. (For repo-scoped registration instead, pick the repo under
     **Repository access** and grant **Administration → Read and write**.)

- **Where to put it:**
  - Local Terraform runs:
    ```bash
    export TF_VAR_github_runner_pat="github_pat_..."
    ```
  - GitHub Actions secret: `GH_RUNNER_PAT` — then pass as a Terraform var in
    your apply workflow.
  - `terraform.tfvars` (not recommended; use env var): `github_runner_pat = "..."`
    and `chmod 600 terraform.tfvars`.

---

## Prerequisites

- Terraform >= 1.9.0 — install via <https://developer.hashicorp.com/terraform/install>
- `gcloud` CLI authenticated with a service account that has the IAM roles
  listed above, **or** `GOOGLE_CREDENTIALS` env var set to the SA key JSON.
- GCP APIs enabled on the project:
  ```bash
  gcloud services enable compute.googleapis.com iam.googleapis.com
  ```
- The three secrets above provisioned.

---

## Usage

### 1. Clone and configure

```bash
cd gcp-runner
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set project_id at minimum.
# Set the PAT via env var (recommended):
export TF_VAR_github_runner_pat="github_pat_..."
# Point gcloud/Terraform at your SA key:
export GOOGLE_CREDENTIALS="$(cat /path/to/sa-key.json)"
```

### 2. Init, plan, apply

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Verify the runner registered

1. In your browser (org-level, default): **GitHub → Bonkey-Apps org → Settings
   → Actions → Runners**. (Repo-scoped registration lists them under the repo's
   own **Settings → Actions → Runners** instead.)
2. You should see `gce-gh-runner` (i.e. `gce-<runner_instance_name>`) with
   status **Idle / online** and labels `self-hosted`, `linux`, `x64`,
   `gce-free`. In **persistent** mode it stays listed and available; in
   **ephemeral** mode it appears, runs one job, then disappears. Each VM
   registers `runners_per_vm` agents (`gce-<name>`, `gce-<name>-2`, …).
3. Or check via the API (this is also emitted as the `verify_runner_command`
   Terraform output — it targets the resolved org or repo scope):
   ```bash
   # org-level (default):
   curl -H "Authorization: Bearer $GH_RUNNER_PAT" \
     https://api.github.com/orgs/Bonkey-Apps/actions/runners
   ```
   Look for `"name": "gce-gh-runner"`, `"status": "online"`, `"busy": false`.

> Startup takes a few minutes (apt installs + runner download). If the runner
> does not appear, check the serial console (see Runbook) for
> `[runner-startup]` log lines. The script `die`s loudly if registration or the
> systemd service fails.

### 4. Target the runner from a workflow

Add `runs-on` to any job:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, gce-free]
    steps:
      - uses: actions/checkout@v5
      - run: pnpm install && pnpm typecheck
```

> **Note:** Do NOT change `runs-on` in `.github/workflows/ci-monorepo.yml`
> until the runner has been verified live. That change is tracked in #145.

#### Concurrent jobs per VM (`runners_per_vm`) + the emulator host lock

A GitHub Actions runner **agent** runs exactly one job at a time, so the startup
script registers **`runners_per_vm` agents per VM** — each in its own directory
and systemd service (`gce-<instance>`, `gce-<instance>-2`, …) — giving the VM
that many parallel job slots. **Default: 3.**

**Every VM gets the same agent count — including emulator-capable ones.** The
emulator constraint is enforced at **runtime**, not by reducing agents, via a
host **readers/writer lock** wired into the runner's per-job hooks
(`ACTIONS_RUNNER_HOOK_JOB_STARTED` / `_COMPLETED`):

- A **regular job** takes a **shared** lock — up to `runners_per_vm` run at once.
- An **emulator job** takes an **exclusive** lock. A job declares itself an
  emulator job with the job-level env **`HOST_LOCK_MODE: exclusive`**. On start it
  waits for in-flight regular jobs on that VM to drain, then **blocks the other
  agents from starting new jobs until it finishes** (writer-preference: once it's
  waiting, new regular jobs block too). So the KVM emulator never contends with
  sibling agents, and the VM still runs 3 jobs the rest of the time.

Lock state lives in tmpfs (`/run/runner-hostlock`) so a reboot clears any leak; a
hard wait cap stops a crashed hook from wedging CI. Set `HOST_LOCK_MODE: none` to
opt a job out entirely. Because GitHub does NOT forward a job's `env:` to the
`ACTIONS_RUNNER_HOOK_JOB_STARTED` hook, the exclusive set is keyed on
`GITHUB_JOB` (the job id) — that list is the real mechanism; the jobs also set
`HOST_LOCK_MODE: exclusive` as intent, but it's inert in the hook. Keep it in
lockstep with the job IDs that should take the exclusive lock:
`maestro` (maestro-e2e), `emulator-smoke-test` (build-android-debug/release), and
`web-e2e` (ci-web-e2e — the heavy Playwright Tier-3 suite, which starves on a
shared VM). **Adding a job here only takes effect after the runners are
redeployed** (new startup script), e.g. via the *Deploy GCP Runner* workflow.

**Sizing.** `runners_per_vm × a regular job's peak RAM/CPU` must fit
`machine_type`. The `bonkey-puzzles` Always-Free `e2-micro` (1 GB RAM) and the
single-GPU graphics runner are pinned to `1` in their env configs.

On teardown/preemption the shutdown script deregisters **all** of a VM's agents
(the base name and every `-N` suffix).

### 5. Teardown / de-registration

```bash
terraform destroy
```

**De-registration behavior:**

- **Ephemeral mode:** the `--ephemeral` runner de-registers itself from GitHub
  automatically after its single job (GitHub removes ephemeral runners on
  completion), and the watchdog deletes the VM. No orphaned runner entry.
- **Persistent mode:** `terraform destroy` deletes the VM but does **not** call
  `config.sh remove` first, so GitHub is left with an **offline** runner entry.
  GitHub **auto-prunes offline self-hosted runners after ~14 days**, so this is
  self-healing. To remove it immediately, either:
  1. GitHub → org (or repo) **Settings → Actions → Runners** → `gce-gh-runner`
     → **Remove**, or
  2. mint a removal token and call the API (org-level shown; for repo-scoped use
     `repos/Bonkey-Apps/bonkey-puzzles-app` in place of `orgs/Bonkey-Apps`):
     ```bash
     REMOVE_TOKEN=$(curl -sf -X POST \
       -H "Authorization: Bearer $GH_RUNNER_PAT" \
       -H "Accept: application/vnd.github+json" \
       https://api.github.com/orgs/Bonkey-Apps/actions/runners/remove-token \
       | jq -r '.token')
     # then on the VM (before destroy): cd ~runner/actions-runner && ./config.sh remove --token "$REMOVE_TOKEN"
     ```

  > A clean automated `config.sh remove` on destroy would require a GCE
  > shutdown-script with PAT access; we deliberately rely on GitHub's offline
  > auto-prune to keep the destroy path simple and avoid leaving the PAT
  > reachable at shutdown. This is documented as the intended behavior.

---

## Free tier vs Android cost table

| Configuration | Machine | Disk | Est. cost/month | Notes |
|--------------|---------|------|----------------|-------|
| **Free-tier default** | `e2-micro` | 30 GB pd-standard | **$0** | Always Free (1 instance, us regions); set `enable_android_profile = false` |
| Android builds (no emulator) | `e2-standard-4` | 100 GB pd-standard | ~$60–$70 | LEAVES FREE TIER — billed |
| **Deployed profile** (Android + KVM emulator, Spot) | `c3-standard-4` + nested-virt, **Spot** | 120 GB pd-balanced | ~$15–$35* | LEAVES FREE TIER — billed; *Spot is ~60–80 % off on-demand and may be preempted |

\* Spot pricing is variable and region/zone dependent; the VM may be preempted at
any time and (in `persistent` mode) is **stopped**, not auto-restarted.

> **KVM / Android emulator note:** A hardware-accelerated Android emulator needs
> **nested virtualization (KVM)**, which GCP supports **only on Intel (non-E2)
> machines** — **never on AMD or Arm** (so an Arm `c4a`/`t2a` runner can build
> Android but cannot accelerate the emulator). This stack uses `c3-standard-4`
> (Intel Sapphire Rapids) with `enable_nested_virtualization = true`. The toggle
> is wired through Terraform variables:
>
> ```hcl
> enable_android_profile       = true            # c3 machine + bigger disk
> android_machine_type         = "c3-standard-4"
> android_disk_type            = "pd-balanced"   # C3 does not support pd-standard
> enable_nested_virtualization = true            # KVM
> enable_spot                  = true            # preemptible pricing
> ```
>
> The startup script installs `qemu-kvm` + a JDK and verifies `/dev/kvm`; the
> Android SDK/AVD itself is provisioned per-job by the workflow (e.g.
> `reactivecircus/android-emulator-runner`), which only needs a working
> `/dev/kvm` on the host.

---

## Graphics / GPU runner (`graphics-github-runner` — g2-standard-8 + NVIDIA L4)

A **separate, coexisting** GPU runner for graphics/GPU workloads (Part of #534,
Epic #135). It is **NOT** a profile of this bonkey-puzzles-app root MIG — it lives in
its own env root **`environments/graphics/`** with its **own Terraform state**
(GCS prefix `gcp-runner-graphics`), exactly like `environments/bonkey-puzzles/`.
Because the states are disjoint, deploying graphics can **never** read, lock,
mutate, or replace the live CI-runner MIG — the two MIGs run **side by side**.

GPU support lives in the shared module `modules/runner-mig/` behind an
**opt-in, default-OFF** `enable_gpu` flag, so every existing consumer (this
bonkey-puzzles-app root, the bonkey-puzzles env) is byte-unchanged; only
`environments/graphics/` sets `enable_gpu = true`.

| Setting | Value (hardcoded in `environments/graphics/main.tf`) |
|---------|-------|
| Machine | `g2-standard-8` (8 vCPU, Intel Cascade Lake) |
| GPU | **1× NVIDIA L4** (Ada) — module emits `guest_accelerator { type = "nvidia-l4", count = 1 }` |
| Boot disk | **100 GB `pd-balanced`** (g2 does **not** support `pd-standard`; sized for CUDA + model weights) |
| Host maintenance | **`TERMINATE`** — GPUs **cannot live-migrate** (module forces this whenever `enable_gpu = true`) |
| MIG | **zonal** (`environments/graphics` zone) — correct for GPU; pick a zone offering G2 + L4 |
| State | GCS prefix **`gcp-runner-graphics`** (disjoint from `gcp-runner` + `gcp-runner-puzzles`) |
| Runner labels | `self-hosted, linux, x64, gpu, graphics, l4, cuda` |

Deploy it via **Actions → Deploy GCP Runner (manual)** with
`runner_profile = graphics` (and `action = apply`, `confirm = DEPLOY`). For the
`graphics` profile the workflow **skips the profile→TF_VAR mapping** and instead
points Terraform at the graphics env root (`-chdir environments/graphics`),
which hardcodes the shape above. The other profiles (android-build /
android-emulator) keep running against this root, unchanged.

Or run it directly:

```bash
cd gcp-runner/environments/graphics
export TF_VAR_project_id=... TF_VAR_github_runner_pat=...
terraform init && terraform apply    # provisions the GPU MIG (billed)
terraform apply -var runner_target_size=0   # idle it to STOP billing
```

Target a GPU job at it with:

```yaml
jobs:
  render:
    runs-on: [self-hosted, linux, x64, gpu]
    steps:
      - uses: actions/checkout@v5
      - run: nvidia-smi
```

### ⚠️ GPU driver path is APPLY-TIME-UNVERIFIED

The module's startup script installs the NVIDIA driver + CUDA userspace on the
GPU path (`cuda-drivers` from NVIDIA's Debian 12 CUDA repo, DKMS-built against
the running kernel), then runs a **non-fatal** `nvidia-smi` check that only
**logs** status — it never fails the boot, so the runner still registers even if
the driver needs attention/a reboot. **There is no GPU in CI and no `terraform
apply` in the PR that authored this, so the driver path has NOT been
runtime-verified.** It MUST be validated on the **first real provision** (SSH in
/ serial console; confirm `nvidia-smi` reports the L4). If the driver isn't
ready, a reboot or a newer driver branch may be required.

### Quota — two MIGs count SIMULTANEOUSLY; grant BEFORE apply

The graphics MIG and the CI-runner MIG have separate states but share the ONE
project vCPU quota. **Both fleets' running vCPUs count against `CPUS_ALL_REGIONS`
= 24 at the same time.**

- **CPU:** `g2-standard-8` = **8 vCPU**. Keep `(CI-runner vCPUs) + 8 ≤ 24`.
  E.g. a 4–8 vCPU CI runner + graphics (8) = 12–16 ≤ 24. Keep the graphics MIG
  `target_size` at **1** and do **not** autoscale past quota. **Resize the
  graphics MIG to 0 when idle** (`-var runner_target_size=0`, or `gcloud …
  managed resize … --size=0`) to free both the vCPUs and the GPU billing.
- **GPU:** `NVIDIA_L4_GPUS` quota is **0 by default** in a new project — request
  ≥ 1 in the target region before apply, plus **G2 CPU** quota
  (`G2_CPUS` / committed) if the project enforces it.
- **Region/zone availability:** L4 + G2 availability is **narrower than T4** —
  pick a zone where **both** exist (the deploy workflow derives `<region>-a`;
  `us-central1-a` is a known-good L4 zone). If the zone lacks G2/L4 the MIG will
  fail to create instances.

> The graphics runner **provisions nothing** until an owner runs the deploy
> workflow with `action = apply` and `confirm = DEPLOY` (or `terraform apply` in
> `environments/graphics/`) **after** the L4 quota grant.

---

## Remote state (GCS backend)

State is stored in a **private, versioned GCS bucket**, configured in
`versions.tf`:

```hcl
backend "gcs" {
  bucket = "bonkey-apps-tfstate"
  prefix = "gcp-runner"
}
```

**Do not commit `*.tfstate` to git.** Terraform state stores secrets — including
the runner PAT — in plaintext, so git is the wrong place for it (`*.tfstate` is
gitignored). The GCS bucket is encrypted at rest, private
(`--public-access-prevention`), and has object versioning for rollback. One-time
bucket bootstrap:

```bash
gcloud storage buckets create gs://bonkey-apps-tfstate \
  --location=us-central1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://bonkey-apps-tfstate --versioning
```

## Project bootstrap (APIs + IAM + billing)

Enabling APIs and granting IAM require permissions Terraform's own SA cannot
self-grant. See **`SETUP-OWNER.md`** and **`bootstrap-owner.sh`** for the
one-time owner steps. The required APIs are declared in `apis.tf`
(`manage_project_services`) and runner-SA roles in `main.tf`
(`manage_project_iam`).

---

## Runbook

A full operator runbook (monitoring, log access, incident response, cost alerts)
is committed at `docs/gcp-runners.md` as part of the #145 milestone.

### Viewing startup logs

```bash
gcloud compute instances get-serial-port-output gh-runner \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

Or via GCP Console → Compute Engine → VM instances → gh-runner → Serial port 1.

### Checking runner service status (SSH)

```bash
gcloud compute ssh gh-runner --zone=us-central1-a
# On the VM:
sudo systemctl status "actions.runner.*.service"
sudo journalctl -u "actions.runner.*.service" -f
```

### Forced teardown (hung job)

The watchdog auto-kills after 60 minutes (`MAX_LIFETIME_MINUTES` in the startup
script). To force teardown immediately:

```bash
gcloud compute instances delete gh-runner \
  --zone=us-central1-a --project=YOUR_PROJECT_ID --quiet
```

---

## Security notes

- The PAT is stored in GCE instance metadata, which is encrypted at rest by
  GCP and accessible only to the VM itself (and project owners).
- The startup script reads the PAT once, uses it to mint a one-time token, then
  clears it from memory (`unset GH_PAT`).
- No inbound firewall ports are opened — the firewall rule explicitly denies all
  ingress on the `gh-runner` network tag.
- The runner SA has only `compute.instanceAdmin.v1` + `iam.serviceAccountUser`,
  not broad project owner/editor roles.

---

## Reusable module + multi-repo deployments

The runner-MIG logic is also published as a reusable child module at
[`modules/runner-mig/`](modules/runner-mig), so a runner can be stood up for more
than one repository without duplicating root configs. Each repo gets a thin root
under `environments/<repo>/` that instantiates the module with its own
parameters and its **own** Terraform state (a distinct GCS backend prefix), so
the deployments never share state.

| Deployment | Where | Repo | State prefix | Shape |
|------------|-------|------|--------------|-------|
| bonkey-puzzles-app (this root, live) | `gcp-runner/` | `Bonkey-Apps/bonkey-puzzles-app` | `gcp-runner` | billed `n2`-class / Android |
| bonkey-puzzles ([`environments/bonkey-puzzles/`](environments/bonkey-puzzles)) | child-module root | `Bonkey-Apps/bonkey-puzzles` | `gcp-runner-puzzles` | **Always-Free `e2-micro`** for the light Pages deploy |
| graphics ([`environments/graphics/`](environments/graphics)) | child-module root | `Bonkey-Apps/bonkey-puzzles-app` | `gcp-runner-graphics` | billed **`g2-standard-8` + 1× NVIDIA L4** GPU runner (coexists with CI; see the Graphics/GPU section above) |

> The files in **this** root (`main.tf`, `variables.tf`, `apis.tf`, `outputs.tf`,
> `versions.tf`, the `*.sh.tftpl` templates, `terraform.tfvars`) remain the live
> bonkey-puzzles-app config and are intentionally left as-is; they currently duplicate
> the module's logic. Migrating this root onto `modules/runner-mig` is a
> follow-up (it touches live state, so it is deliberately deferred).
>
> See [`environments/bonkey-puzzles/README.md`](environments/bonkey-puzzles/README.md)
> for the bonkey-puzzles runbook — including the required **bonkey-puzzles-scoped
> PAT** (the bonkey-puzzles-app `GH_RUNNER_PAT` will not register a bonkey-puzzles
> runner) and the `runs-on: [self-hosted, linux, x64, gce-free, bonkey-puzzles]`
> the Pages-deploy job uses.
