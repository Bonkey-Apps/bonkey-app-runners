# Local Docker runner (Mac) — Bonkey-Apps org layer

A containerised **self-hosted GitHub Actions runner** you can host from a Mac
with Docker Desktop. It registers at the **organisation** layer
(`https://github.com/Bonkey-Apps`), so it can serve CI for **any** Bonkey-Apps
repo (Puzzles / Cards / Math), not just one.

It bakes the **full CI toolchain** the three app repos install per job — pinned
in lockstep with the self-hosted golden-image manifest
([`gcp-runner/IMAGE-MANIFEST.md`](../gcp-runner/IMAGE-MANIFEST.md)) and
each repo's `package.json` — so those `setup-*` steps become warm no-ops.

> This directory is **infra/config only** (no `apps/**` / `packages/**` /
> `tools/**` runtime surface), so the path-filtered product CI does not run on
> changes to it — that's expected and test-exempt per CLAUDE.md.

## Baked toolchain

Pre-installed so per-job `setup-*` steps are warm no-ops (versions pinned to the
golden-image manifest + each repo's `package.json`):

| Layer | Contents | Notes |
|---|---|---|
| **CI (all repos, always)** | Node 24, **pnpm 10.33.0**, **Playwright 1.62.1** Chromium + OS libs (`/opt/pw-browsers`, one `chromium-<rev>/` per version — see below), GitHub CLI (`gh`), git, ripgrep, fd-find, jq, python3 | Serves typecheck / lint / format / `pnpm -r test` / web-export / Tier 3 web-local e2e / screenshots |
| **Android build** (`INSTALL_ANDROID=true`, default) | OpenJDK 17 with **`JAVA_HOME` exported by `entrypoint.sh`** (so jobs can skip `actions/setup-java`; derived from the real `java`, so it is arch-correct and stays UNSET on a `INSTALL_ANDROID=false` image rather than pointing at a JDK that isn't there), Android command-line tools + platform-tools + `platforms;android-34` + `build-tools;34.0.0` (`/opt/android-sdk`), **bundletool 1.18.1** (`/opt/bundletool`) | Serves Gradle `bundleRelease` (AAB) jobs. **amd64 only** — the Android SDK ships x86_64 host tools; set `INSTALL_ANDROID=false` on arm64 |

### Why two Playwright versions are baked

Playwright resolves its browser by **revision**, not by a stable path.
`playwright install` writes `$PLAYWRIGHT_BROWSERS_PATH/chromium-<rev>/`, and
there is no version-agnostic `chromium` entry — the app repos'
`playwright.config.ts` probes for one, finds nothing, and falls through to the
revision lookup. Since `playwright install` is **banned in CI** by repo rule,
there is no per-job fallback: a runner baking exactly one revision hard-fails
e2e for every repo pinned to a different `@playwright/test`.

This is an **org-level** runner — one container serves Puzzles, Cards and Math —
and they can drift apart during an upgrade. The image therefore bakes **one
Chromium per pin in use**, in separate `chromium-<rev>/` directories that do not
conflict, and the build asserts that every expected revision actually landed.

As of BC-138 all three repos are on 1.62.1, so there is a single entry. Add an
ARG plus its `RUN` line when a repo adopts a new pin (BC-132 did this for
1.61.1); remove one only once no repo pins it.

## What it is / isn't

| ✅ Runs here | ❌ Not here |
|---|---|
| typecheck, lint, format, `pnpm -r test` | **Android emulator / Maestro (Tier 4)** — needs `/dev/kvm`, which Docker Desktop on macOS does **not** expose. Keep those on the GCE `kvm`-labelled runners. |
| `expo export -p web` + pack-diff oracle | **GPU / SDXL sprite-gen (diffusion) jobs** — graphics-env + NVIDIA-CUDA only; stays on the GCE graphics runner. |
| Tier 3 web-local Playwright e2e (Chromium) | Anything requiring nested virtualisation or a real device |
| Android **build** jobs — Gradle `bundleRelease` (no emulator) | |

## Prerequisites

- **Docker Desktop for Mac** (Apple Silicon or Intel).
- On **Apple Silicon**, enable **Settings → General → "Use Rosetta for x86/amd64
  emulation"** — the default build runs `linux/amd64` so the runner reports the
  `x64` label the repo's jobs require (`runs-on: [self-hosted, linux, x64]`).
- A GitHub **PAT with org runner-admin rights**:
  - Classic: scope **`admin:org`**
  - Fine-grained: Organization → **"Self-hosted runners" = Read and write**

## Quick start

The image is published to **GHCR** by
[`build-docker-runner-image.yml`](../.github/workflows/build-docker-runner-image.yml)
as `ghcr.io/bonkey-apps/bonkey-apps-runner:latest`, so you can pull it
instead of building locally:

```bash
cd docker-runner
cp .env.example .env
# edit .env → set GH_PAT=...
docker compose pull            # fetch the prebuilt, fully-baked image from GHCR
docker compose up -d
docker compose logs -f          # watch it register + pick up jobs
```

GHCR pull needs a one-time `docker login ghcr.io -u <you> -p <PAT-with-read:packages>`
if the package is private. To rebuild the image locally instead of pulling
(e.g. after editing the Dockerfile), use `docker compose up --build -d`, or point
`RUNNER_IMAGE` in `.env` at a specific published tag.

Confirm it's online:

```bash
# Org runners page: https://github.com/organizations/Bonkey-Apps/settings/actions/runners
# or via API (needs the same PAT):
curl -s -H "Authorization: Bearer $GH_PAT" \
  https://api.github.com/orgs/Bonkey-Apps/actions/runners \
  | jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Tear down (deregisters cleanly on stop):

```bash
docker compose down
```

## Local build (behind a corporate TLS-inspecting proxy)

If your Mac sits behind a corporate proxy that MITMs HTTPS (Netskope, Zscaler,
Palo Alto, etc. — check `security find-certificate -a
/Library/Keychains/System.keychain` for names like your company's), the
**committed** `Dockerfile` will fail: the container's OS trust store doesn't
know about the proxy's re-signing CA that your Mac already trusts. Both apt/curl
downloads at build time *and* the runner binary itself at runtime need this.
`docker compose pull` (GHCR) sidesteps the problem entirely if the image is
published — try that first.

If you must build locally, **never edit the committed `Dockerfile`** with
machine-specific trust — it's shared by the whole org and any dev without your
proxy. Instead:

1. Export your Mac's trusted root CAs to a local, gitignored file:
   ```bash
   security find-certificate -a -p /Library/Keychains/System.keychain \
     > docker-runner/system-roots.pem.local-build-only
   ```
2. Copy `Dockerfile` → `Dockerfile.local` and add a CA-trust stage right after
   the `ENV` block (before any `apt-get`/`curl`):
   ```dockerfile
   COPY system-roots.pem.local-build-only /usr/local/share/ca-certificates/local-system-roots.crt
   RUN apt-get update -q \
       && apt-get install -y -q --no-install-recommends ca-certificates \
       && update-ca-certificates \
       && rm -rf /var/lib/apt/lists/*
   ```
   (Also worth defaulting `ARG INSTALL_ANDROID=false` in `Dockerfile.local` —
   `sdkmanager` is a JVM tool with its own trust store, unvalidated with this
   fix.)
3. Add `Dockerfile.local` and `system-roots.pem.local-build-only` to
   `.git/info/exclude` (NOT `.gitignore` — this is a personal, per-machine
   exclusion, not a repo-wide rule) so `git status` stays clean and neither
   file is ever accidentally committed.
4. Create `docker-runner/docker-compose.override.yml` (also
   `.git/info/exclude`'d) so `docker compose up --build` / `docker compose
   build` use `Dockerfile.local` automatically — no manual `-f` flag to
   remember, and no risk of swapping files in place (which defeats the whole
   point: the committed `Dockerfile` must stay portable):
   ```yaml
   services:
     runner:
       build:
         dockerfile: Dockerfile.local
   ```
   Compose merges `docker-compose.override.yml` on top of `docker-compose.yml`
   automatically — no `-f` flags needed on the CLI.

**Why not just `curl -k` / disable TLS verification everywhere?** It covers
apt/curl/npm at build time, but the actual runner process
(`Runner.Listener`, a compiled .NET binary) validates TLS against the OS trust
store at *runtime* to hold its connection to GitHub's Actions service, and
has no insecure-mode flag — so `-k`-style flags alone leave the container
completely unable to register or run jobs. Trusting the CA once, properly,
is the only fix that works end-to-end.

## How it works

1. **`entrypoint.sh`** exchanges `GH_PAT` for a short-lived **org registration
   token** at startup (the PAT is never written to disk), or uses a pre-minted
   `RUNNER_TOKEN` if you set one instead.
2. It runs `config.sh --url https://github.com/Bonkey-Apps … --ephemeral` then
   `run.sh`.
3. **Ephemeral by default** (`RUNNER_EPHEMERAL=true`): the runner takes exactly
   one job, then exits; `restart: unless-stopped` brings up a fresh registration
   for the next job. This mirrors the GCE ephemeral-JIT model (one clean
   environment per job) and avoids stale state between runs.
4. On `docker stop` / `SIGTERM` (or a non-ephemeral shutdown) the entrypoint
   mints a **remove-token** and calls `config.sh remove`, so you don't leak
   "offline" entries in the org runner list.

Run **more than one** at a time for parallelism (one runner = one job at a time):

```bash
docker compose --profile x2 up -d
```

`--profile x2` starts 2 runners, `--profile x3` starts 3. Each is its own
service pinned to its **own** cores (`0-1`, `2-3`, `4-5` by default), so they
run in parallel rather than contending.

Each runner is capped at `RUNNER_MEM_LIMIT` (default `6g`, swap disabled) and
gets an absolute `-Xmx` via `JAVA_TOOL_OPTIONS`. **Both are needed together** —
see "Memory" below. Budget before adding runners: the Docker VM's total is
`docker info --format '{{.MemTotal}}'`; 2 x 6g against a 15.31 GiB VM leaves
~3 GiB for the VM and other containers, and `--profile x3` at 6g would
oversubscribe it. Lower `RUNNER_MEM_LIMIT` to `4g` for a 3-runner layout, and
treat that as a JS/web configuration rather than one for native Android builds.

**Do not use `--scale runner=N`.** Compose applies one `cpuset` to every
replica, so scaled runners all land on the *same* two cores — N concurrent
jobs fighting over 2 cores while the rest of the host idles. Confirmed on
2026-08-23: two scaled runners were both pinned to `0-1` on a 24-core host,
each reporting `nproc` = 2. Check the host actually has the cores
(`docker info --format '{{.NCPU}}'`) and override `RUNNER_CPUSET`,
`RUNNER_CPUSET_2`, `RUNNER_CPUSET_3` in `.env` if the layout differs.

## Memory

Runners had **no** memory limit before this. An overrunning build was killed by
the **VM-wide** OOM killer, which picks its own victim — the *other* runner's
job, or a runner agent — which is the "job died with an unreadable log" shape.
A per-container `mem_limit` makes the overrun land on the container that caused
it: `docker inspect -f '{{.State.OOMKilled}}' <container>` says so plainly, and
the ephemeral restart brings a clean runner straight back.

`mem_limit` must not ship alone, because **the JVM does not size its heap from
the container limit on Docker Desktop/WSL2.** Measured 2026-08-23 with this
image, `UseContainerSupport=true` and the correct cgroup value visible inside:

| container `-m` | cgroup `memory.max` | JVM default max heap |
|---|---|---|
| 1g | 1073741824 | 3920 MiB |
| 2g | 2147483648 | 3920 MiB |
| 4g | 4294967296 | 3920 MiB |
| none | max | 3920 MiB |

It sizes from the **VM's** 15.31 GiB every time (`MaxRAMPercentage=50` gives
7840 MiB, confirming the base). So a Gradle JVM would grow a 3.8 GiB heap
inside a 6g container and be OOM-killed mid-build. Percentage-based sizing is
useless here; **absolute `-Xmx` is honoured** (`-Xmx1500m` -> exactly 1500 MiB),
which is why `JAVA_TOOL_OPTIONS=-Xmx2g` is set alongside the limit.

Caveat: `android/` is generated by `expo prebuild`, so a template-supplied
`org.gradle.jvmargs` would take precedence for the Gradle daemon specifically.
Confirm against a real Android build before trusting `-Xmx2g` to bound that
JVM — it still governs every other java process. Set
`RUNNER_JAVA_TOOL_OPTIONS=` (empty) in `.env` to opt out.

### Why the cpusets stay narrow on a big host

Cores are priced in memory: ninja takes its `-j` from `nproc`, so each core
added to a runner buys another concurrent `clang++` (~1 GiB) inside the same
`mem_limit`. On a 24-core / 15.31 GiB box, memory binds long before cores do —
2 runners x 2 cores x 6g uses 4 of 24 cores **by necessity**, not by oversight.
Widening is fine once the per-core peak is measured on the host; move
`BONKEY_NATIVE_BUILD_JOBS` in `entrypoint.sh` in lockstep when you do.

## Configuration

All via `.env` (see `.env.example` for the full annotated list):

| Var | Default | Purpose |
|---|---|---|
| `GH_PAT` | — | Org runner-admin PAT (or use `RUNNER_TOKEN`) |
| `RUNNER_TOKEN` | — | Pre-minted org registration token (alternative to `GH_PAT`) |
| `GITHUB_ORG` | `Bonkey-Apps` | Org to register under |
| `RUNNER_NAME` | `bonkey-runner-<rand>` | Runner name shown in settings |
| `RUNNER_LABELS` | `docker,local` | Extra labels (arch `x64`/`arm64` is added automatically) |
| `RUNNER_GROUP` | `Default` | Org runner group |
| `RUNNER_EPHEMERAL` | `true` | One job then exit (recommended) |
| `RUNNER_VERSION` | `2.335.1` | `actions/runner` version — keep in lockstep with the GCE runners |
| `PNPM_VERSION` | `10.33.0` | Baked pnpm (== each repo's `packageManager`) |
| `PLAYWRIGHT_VERSION` | `1.62.1` | Primary baked Playwright (== `bonkey-cards-app`'s `@playwright/test`) |
| `INSTALL_ANDROID` | `true` | Bake Java 17 + Android SDK + bundletool (amd64 only; `false` for lean/arm64) |
| `RUNNER_PLATFORM` | `linux/amd64` | `linux/amd64` (→ `x64`) or `linux/arm64` |
| `RUNNER_CPUSET` | `0-1` (2 cores) | Pins the container to a core SET (`cpuset`, not a time-quota `cpus` limit) — this is the lever that actually throttles ninja's native-build concurrency in an Expo/AGP build, since AGP invokes ninja directly and ninja picks its own `-j` from `nproc`. Keep `BONKEY_NATIVE_BUILD_JOBS`'s default in lockstep with however many cores this pins. |
| `BONKEY_NATIVE_BUILD_JOBS` | `2` | Gradle's own `--max-workers` cap (a real, separate, working knob) — does **not** bound ninja under AGP's direct invocation; that's `RUNNER_CPUSET`'s job. Useful for other consumers whose native build goes through `cmake --build` rather than AGP. See the export in `entrypoint.sh` for the full evidence trail. |

### amd64 vs arm64

The repo's workflows target `runs-on: [self-hosted, linux, x64, …]`, so the
default `linux/amd64` platform is what you want — it reports the `x64` label and
jobs schedule onto it. Native `linux/arm64` is faster on Apple Silicon but only
matches jobs that don't require `x64`; set `RUNNER_PLATFORM=linux/arm64` only if
you know the target jobs allow it — and pair it with `INSTALL_ANDROID=false`,
since the Android SDK ships x86_64 host tools only.

## Security notes

- `.env` is gitignored — **never commit a token**. `GH_PAT` is used only to mint
  short-lived registration/remove tokens and is never persisted in the image or
  a layer.
- The runner runs as the non-root `runner` user inside the container.
- Self-hosted runners execute arbitrary workflow code. Only register against
  repos/orgs you trust; prefer **ephemeral** so each job starts clean.

## Relationship to the GCE runners

The GCE fleet (`gcp-runner/`) remains the primary, always-available CI
capacity (persistent Spot VM + on-demand ephemeral JIT VMs), including the
**Android/KVM** tier this container cannot serve. This local Docker runner is a
**supplementary, zero-cloud-cost** option for burst capacity or offline/local
CI from a Mac — it does not replace the GCE runners or change the GCP quota
discipline in the root `CLAUDE.md`.
