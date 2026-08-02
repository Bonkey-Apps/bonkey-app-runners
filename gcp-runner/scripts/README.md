# On-demand ephemeral runners (#144 — interim)

The persistent runner (Terraform, in the parent dir) handles steady CI. These
scripts add **on-demand, single-use runners** for parallelism/burst, without an
always-on orchestrator: the bring-up runs on the existing persistent runner, so
it needs no GitHub-hosted minutes.

> **Note:** the `runner-dispatch.yml` GitHub Actions workflow was **removed** so
> the repo has a single GCP Terraform action (`deploy-gcp-runner.yml`, canonical).
> These scripts are now invoked **directly** — locally, or manually on the
> persistent runner — not via a workflow. The diagram below is retained as the
> design reference for the script chain.

```
runner-dispatch.yml (workflow_dispatch, runs-on the persistent runner)
   └─ runner-up.sh ──┬─ POST generate-jitconfig (GitHub)         → single-use JIT config
                     └─ gcloud compute instances create (Spot)   → ephemeral VM
                            └─ runner-jit-startup.sh (on the VM)
                                   ├─ install toolchain (+KVM if --android)
                                   ├─ run.sh --jitconfig   → runs exactly ONE job
                                   └─ self-delete (EXIT trap + max-lifetime watchdog)
runner-dispatch.yml (schedule, hourly)
   └─ runner-sweep.sh → delete stale ephemeral VMs + prune offline gce-jit-* runners
```

## Why this shape
A single runner agent runs **one job at a time**. Each ephemeral VM here is its
own runner → real parallelism, one fresh environment per job, zero idle cost
(Spot, self-deleting). Teardown is self-managed (trap + watchdog); the sweep is
a belt-and-suspenders reconcile.

## Usage
- **Local / manual:** `GH_PAT=ghp_xxx ./runner-up.sh --count 2 --android` (needs
  gcloud ADC), run locally or on the persistent runner. (The *Runner dispatch*
  workflow was removed — see the note at the top.)

## Requirements
- `GH_PAT` env var (repo **Administration: read+write**) — mints JIT configs.
- The runner SA (`github@`) needs `compute.instanceAdmin`/`compute.admin` to
  create + self-delete instances (already granted).
- `--android` requires an Intel non-E2 machine (KVM/nested-virt); it adds
  `--enable-nested-virtualization`.

## Relationship to the proper #144 design
This is the **interim** (option 2). The target design is **serverless**: a GitHub
`workflow_job` webhook → Cloud Run/Function that creates a VM per queued job and
deletes on completion, with Cloud Scheduler running the sweep — no persistent
runner in the loop at all. Tracked in #144.
