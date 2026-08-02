#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# entrypoint.sh — register a containerised GitHub Actions runner at the
# Bonkey-Apps ORG layer, run jobs, and deregister cleanly on stop.
#
# Auth (one of):
#   GH_PAT        A GitHub PAT with org runner-admin rights (classic: admin:org;
#                 fine-grained: Organization "Self-hosted runners" read+write).
#                 The entrypoint exchanges it for a short-lived registration
#                 token at startup — the PAT itself is never written to disk.
#   RUNNER_TOKEN  A pre-minted org registration token (from the org runner
#                 settings page or the API). Used as-is; no PAT needed.
#
# Config env (all optional, sane defaults):
#   GITHUB_ORG      org login          (default: Bonkey-Apps)
#   RUNNER_NAME     runner name        (default: docker-mac-<short-random>)
#   RUNNER_LABELS   extra labels CSV   (default: docker,docker-mac,local)
#   RUNNER_GROUP    runner group name  (default: Default)
#   RUNNER_EPHEMERAL true|false        (default: true — one job then exit)
#   RUNNER_REPLACE   true|false        (default: true — replace a same-named runner)
#   BONKEY_NATIVE_BUILD_JOBS  ninja/CMake concurrency cap for Android native
#                             builds (default: 2, tuned to this container's
#                             CPU/memory ceiling — see the derivation below)
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

GITHUB_ORG="${GITHUB_ORG:-Bonkey-Apps}"
API="${GITHUB_API_URL:-https://api.github.com}"
RUNNER_URL="https://github.com/${GITHUB_ORG}"
# `|| true` on the inner substitution: under `set -o pipefail`, head closing the
# pipe after 6 bytes sends tr a SIGPIPE (exit 141), which pipefail would
# otherwise propagate as a script-ending failure even though the random suffix
# came out fine.
RAND_SUFFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c6 || true)"
RUNNER_NAME="${RUNNER_NAME:-docker-mac-${RAND_SUFFIX}}"
# Base labels mirror the CLAUDE.md taxonomy; x64/arm64 is added automatically
# by config.sh from the runner's own arch. Add local Docker capability labels.
RUNNER_LABELS="${RUNNER_LABELS:-docker,docker-mac,local}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
RUNNER_REPLACE="${RUNNER_REPLACE:-true}"

command -v jq >/dev/null || die "jq missing from image"

# --- JAVA_HOME (only when a JDK is actually baked in) -----------------------
# The Android layer (INSTALL_ANDROID=true) installs a JDK; the lean/arm64 image
# deliberately does not. Deriving this at RUNTIME rather than as a Dockerfile
# ENV gets both properties a static ENV cannot have at once:
#
#   • arch-correct — resolves to ...-amd64 or ...-arm64 from the real binary,
#     rather than hard-coding one and being wrong on the other;
#   • absent when there is no JDK — a JAVA_HOME that is SET but points nowhere
#     is worse than none at all, because jobs skip `actions/setup-java` on the
#     strength of it and would fail later, further from the cause.
#
# Jobs inherit this from the runner process, which is why it belongs here and
# not in a login profile (Actions steps do not source one).
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  export JAVA_HOME
  log "JAVA_HOME=${JAVA_HOME} (derived from the baked JDK)"
fi

# --- Native (ninja/CMake) build concurrency ---------------------------------
# CORRECTION, measured on bonkey-cards-app#1032 across 3 release runs / 3
# --max-workers settings (uncapped, 4, 2): concurrent clang++ count never
# moved. Android Gradle Plugin invokes ninja DIRECTLY, not through
# `cmake --build` — so neither Gradle's --max-workers nor
# CMAKE_BUILD_PARALLEL_LEVEL reach it. Ninja instead picks its own -j from
# `nproc`, and Docker's time-quota `cpus:` does NOT change what nproc reports
# inside a container (verified empirically) — only `cpuset:` (core pinning,
# see docker-compose.yml) actually throttles it.
#
# BONKEY_NATIVE_BUILD_JOBS is still exported here — it's the right lever for
# GRADLE's own task-level --max-workers (a real, separate, working knob), and
# for any OTHER consumer whose native build goes through `cmake --build`
# rather than AGP's direct ninja invocation. Just don't expect it to bound
# ninja's own parallelism in an Expo/AGP build — that's docker-compose.yml's
# `cpuset:` job now. Keep the default here in lockstep with however many
# cores that pins (currently 2).
BONKEY_NATIVE_BUILD_JOBS="${BONKEY_NATIVE_BUILD_JOBS:-2}"
export BONKEY_NATIVE_BUILD_JOBS
CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-${BONKEY_NATIVE_BUILD_JOBS}}"
export CMAKE_BUILD_PARALLEL_LEVEL
log "BONKEY_NATIVE_BUILD_JOBS=${BONKEY_NATIVE_BUILD_JOBS} (CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}; note: neither reaches ninja under AGP's direct invocation — see docker-compose.yml's cpuset)"

# --- Resolve a registration token ------------------------------------------
if [ -z "${RUNNER_TOKEN:-}" ]; then
  [ -n "${GH_PAT:-}" ] || die "provide GH_PAT (org runner admin) or RUNNER_TOKEN"
  log "Minting an org registration token for ${GITHUB_ORG} from GH_PAT..."
  RUNNER_TOKEN="$(curl -sf -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
    | jq -r '.token')"
  [ -n "$RUNNER_TOKEN" ] && [ "$RUNNER_TOKEN" != "null" ] \
    || die "failed to mint registration token (check GH_PAT org runner-admin rights)"
fi

# --- Deregister on stop (SIGINT/SIGTERM) or ephemeral exit ------------------
# For ephemeral runners the config auto-removes after the single job; this trap
# handles `docker stop` (and long-lived non-ephemeral runners) gracefully so we
# don't leak "offline" runner entries in the org settings.
#
# IMPORTANT: this must NOT deregister out from under an in-flight job. On
# SIGINT/SIGTERM we forward the signal to the backgrounded run.sh and WAIT for
# it to actually exit (run.sh/Runner.Listener has its own graceful-shutdown
# handling — it lets an active job finish reporting before it stops) before
# touching the registration. Deregistering first (as this used to do) could
# race an in-progress job and cut off its result upload to GitHub.
RUN_PID=""
deregister() {
  if [ -n "$RUN_PID" ] && kill -0 "$RUN_PID" 2>/dev/null; then
    log "Forwarding signal to runner (pid $RUN_PID) and waiting for it to finish the current job..."
    kill -TERM "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" || true
  fi
  log "Removing runner registration..."
  local remove_token="${RUNNER_TOKEN}"
  if [ -n "${GH_PAT:-}" ]; then
    remove_token="$(curl -sf -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_PAT}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}/orgs/${GITHUB_ORG}/actions/runners/remove-token" \
      | jq -r '.token')" || remove_token="${RUNNER_TOKEN}"
  fi
  ./config.sh remove --token "${remove_token}" >/dev/null 2>&1 || true
  exit 0
}
trap deregister SIGINT SIGTERM

# --- Configure -------------------------------------------------------------
CONFIG_FLAGS=(
  --unattended
  --url "${RUNNER_URL}"
  --token "${RUNNER_TOKEN}"
  --name "${RUNNER_NAME}"
  --labels "${RUNNER_LABELS}"
  --runnergroup "${RUNNER_GROUP}"
  --work "_work"
)
[ "${RUNNER_REPLACE}" = "true" ]   && CONFIG_FLAGS+=(--replace)
[ "${RUNNER_EPHEMERAL}" = "true" ] && CONFIG_FLAGS+=(--ephemeral)

# `restart: unless-stopped` restarts THIS SAME container (same writable layer)
# rather than recreating it, so .runner/.credentials from a prior cycle can
# still be sitting on disk. For an ephemeral runner that's stale: GitHub
# deletes the registration server-side once that one job completes, so
# reusing the old files here would authenticate with dead credentials and
# fail with "Registration ... was not found". Always wipe and re-register
# fresh when ephemeral; only reuse existing config for a long-lived
# (non-ephemeral) runner.
if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
  rm -f .runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated
fi

if [ ! -f .runner ]; then
  log "Configuring runner '${RUNNER_NAME}' against ${RUNNER_URL} (group=${RUNNER_GROUP}, ephemeral=${RUNNER_EPHEMERAL})..."
  ./config.sh "${CONFIG_FLAGS[@]}"
else
  log "Reusing existing runner configuration from this container's prior run."
fi

# --- Run -------------------------------------------------------------------
log "Starting runner '${RUNNER_NAME}'..."
./run.sh &
RUN_PID=$!
wait "$RUN_PID"
