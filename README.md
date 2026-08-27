# bonkey-app-runners

Self-hosted GitHub Actions runner infrastructure for the **Bonkey Apps** org
(`bonkey-cards-app`, `bonkey-puzzles-app`, `bonkey-math-app`, and related
repos like `bonkey-puzzles`). Migrated out of `bonkey-puzzles-app`'s
`infra/` directory so the runner infra isn't nested inside one app's repo —
it serves all of them.

## Layout

| Path | What |
|---|---|
| [`docker-runner/`](docker-runner) | A containerised runner you can host from any Mac with Docker Desktop / Rancher Desktop — registers at the `Bonkey-Apps` org level, serves CI for any Bonkey-Apps repo. |
| [`gcp-runner/`](gcp-runner) | Terraform for GCE-hosted runners: the live `bonkey-puzzles-app` root, a reusable `modules/runner-mig/` child module, and per-repo `environments/` (graphics/GPU, bonkey-puzzles Pages-deploy). |
| [`.github/workflows/build-docker-runner-image.yml`](.github/workflows/build-docker-runner-image.yml) | Builds + publishes the Docker runner image to GHCR. |
| [`.github/workflows/deploy-gcp-runner.yml`](.github/workflows/deploy-gcp-runner.yml) | `workflow_dispatch` action for the GCE Terraform: `plan` / `apply` / `destroy` / `resize`. |

See each subdirectory's own README for setup and configuration details.

## On-demand only

GCE deployments are **on-demand only** — there is no standing, always-on
runner fleet. `runner_mode` defaults to `"ephemeral"` and `runner_target_size`
defaults to `0` across the Terraform (root, module, and all `environments/`).
Provision a runner only when CI actually needs one, via
[`gcp-runner/scripts/runner-up.sh`](gcp-runner/scripts/runner-up.sh) or a
deliberate, temporary resize — not by leaving a fleet idling and billing
between runs.

The local Docker runner (`docker-runner/`) is unaffected by this policy — it
runs on your own Mac, not billed GCE compute, so it's fine to leave it up
persistently if you want standing local capacity.

## History

This repo's content was migrated from `Bonkey-Apps/bonkey-puzzles-app`'s
`infra/docker-runner/` and `infra/gcp-runner/` directories (see that repo's
git history for the pre-migration history of these files).


## Runner liveness (BI-26)

`scripts/Watch-Runner.ps1` runs two independent checks. They are separate
because they fail differently.

**1. Self-heal.** If the container is absent, recreate it with
`docker compose up -d`.

The check is `docker ps -a`, not `docker ps`, and that distinction is the whole
point. On 2026-08-26 the container had been **removed**, not stopped.
`restart: unless-stopped` recovers a stopped container and does nothing for a
removed one, so CI queued for **19 hours** across three repos with every
dashboard green — queued reads as *busy*, not *broken*.

**2. Stuck queue.** Warn when work is waiting and nothing is starting.

A backlog is not a fault: one ephemeral runner drains strictly one job at a
time, so a deep queue is normal. The signal that separates *busy* from *dead*
is that a draining fleet keeps **starting** jobs. So the alert requires **both**
`oldest queued > 60m` **and** `nothing started for 30m`. Either alone is noise —
age alone fires on a legitimate backlog, and a presence check is useless under
`RUNNER_EPHEMERAL=true`, where "no runner registered right now" is normal.

Check 2 also covers what check 1 cannot: a runner that exists but cannot claim
jobs, through a label mismatch or a wedged process.

Log: `%ProgramData%onkeyunner-watch.log`.

### Installing

Deliberately **not** automatic — a scheduled task is a persistent change to the
host. Run elevated:

```powershell
.\scripts\Register-RunnerWatch.ps1          # every 10 minutes
.\scripts\Register-RunnerWatch.ps1 -Remove  # uninstall
```

Dry run first if you want to see it decide without acting:

```powershell
.\scripts\Watch-Runner.ps1 -WhatIf
```

Uses no GCE, per the owner's standing rule.
