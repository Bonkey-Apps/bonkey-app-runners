#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ephemeral JIT runner — GCE startup script (standalone; NOT a Terraform template)
#
# Launched by runner-up.sh on a fresh, single-use GCE VM. Registers with a
# pre-minted GitHub JIT config (no registration token on disk), runs exactly ONE
# job (run.sh --jitconfig is inherently single-job + ephemeral), then SELF-DELETES
# the VM. A max-lifetime watchdog force-deletes a hung VM so it can't leak spend.
#
# Metadata keys (set by runner-up.sh):
#   jitconfig        — base64 GitHub JIT runner config (credential; metadata only)
#   enable-android   — "true"/"false": install KVM + JDK for the emulator
#   runner-version   — actions/runner version, e.g. "2.335.1"
#   runner-arch      — "x64" | "arm64"
#
# NOTE (interim): this duplicates the toolchain install from
# runner-startup.sh.tftpl. A baked image (#143 follow-up) would remove both the
# per-boot install cost and the duplication.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[jit-startup] $*"; }
die() { echo "[jit-startup] FATAL: $*" >&2; exit 1; }

META="http://metadata.google.internal/computeMetadata/v1"
HDR="Metadata-Flavor: Google"
md() { curl -sf -H "$HDR" "$META/instance/attributes/$1" 2>/dev/null || true; }

JITCONFIG="$(md jitconfig)"
ENABLE_ANDROID="$(md enable-android)"
RUNNER_VERSION="$(md runner-version)"
RUNNER_ARCH="$(md runner-arch)"
[ -n "$JITCONFIG" ] || die "jitconfig metadata is empty"
[ -n "$RUNNER_VERSION" ] || RUNNER_VERSION="2.335.1"
[ -n "$RUNNER_ARCH" ] || RUNNER_ARCH="x64"

INSTANCE_NAME="$(curl -sf -H "$HDR" "$META/instance/name")"
ZONE="$(curl -sf -H "$HDR" "$META/instance/zone" | awk -F/ '{print $NF}')"
PROJECT="$(curl -sf -H "$HDR" "$META/project/project-id")"

# Self-deletion: fires on ANY exit (job done, error, or watchdog) so the VM
# never lingers. gcloud auto-authenticates via the VM's attached SA.
self_delete() {
  log "Self-deleting $INSTANCE_NAME (zone=$ZONE)..."
  gcloud compute instances delete "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" --quiet || true
}
trap self_delete EXIT

# Hard max-lifetime watchdog — kills a hung job/VM even if run.sh never returns.
MAX_LIFETIME_MINUTES=60
( sleep "$((MAX_LIFETIME_MINUTES * 60))"; log "Max lifetime reached — forcing teardown"; self_delete ) &

log "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl jq git unzip tar libicu72 libssl3 ca-certificates sudo gnupg

log "Installing Node.js 24 + pnpm..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y -q nodejs
npm install -g pnpm@latest
npx -y playwright@latest install-deps chromium || true

# gcloud CLI (for self-deletion).
if ! command -v gcloud &>/dev/null; then
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    >/etc/apt/sources.list.d/google-cloud-sdk.list
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  apt-get update -q && apt-get install -y -q google-cloud-cli
fi

# Google Cloud Ops Agent (#408) — host metrics + syslog into Cloud Monitoring /
# Cloud Logging. Installed idempotently and BEFORE the runner registers below
# (run.sh --jitconfig), so this single job's output is already being captured.
# Requires roles/monitoring.metricWriter + roles/logging.logWriter on the
# runner SA and monitoring.googleapis.com / logging.googleapis.com enabled
# (see infra/gcp-runner/main.tf + apis.tf). errexit off: a failure here must
# never abort the job — an ephemeral VM is single-use so it just runs unmonitored.
log "Installing Google Cloud Ops Agent..."
set +e
if dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
  log "Google Cloud Ops Agent already installed — skipping (idempotent)."
else
  OPS_AGENT_SCRIPT="/tmp/add-google-cloud-ops-agent-repo.sh"
  if curl -sS https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh -o "$OPS_AGENT_SCRIPT"; then
    sudo bash "$OPS_AGENT_SCRIPT" --also-install \
      || log "WARN: Google Cloud Ops Agent install failed — job still runs without it."
    rm -f "$OPS_AGENT_SCRIPT"
  else
    log "WARN: could not fetch the Ops Agent install script — job still runs without it."
  fi
fi
if systemctl is-active --quiet google-cloud-ops-agent 2>/dev/null; then
  log "Google Cloud Ops Agent is active."
else
  log "WARN: Google Cloud Ops Agent is not active (see install output above)."
fi
set -e

RUNNER_USER="runner"
RUNNER_DIR="/home/$RUNNER_USER/actions-runner"
id "$RUNNER_USER" &>/dev/null || useradd -m -s /bin/bash "$RUNNER_USER"
echo "$RUNNER_USER ALL=(ALL) NOPASSWD: /usr/bin/gcloud" >/etc/sudoers.d/runner-gcloud
chmod 440 /etc/sudoers.d/runner-gcloud

if [ "$ENABLE_ANDROID" = "true" ]; then
  log "Android profile: KVM + JDK..."
  apt-get install -y -q qemu-kvm openjdk-17-jdk-headless
  groupadd -f kvm
  modprobe kvm 2>/dev/null || true
  modprobe kvm_intel 2>/dev/null || true
  [ -e /dev/kvm ] || die "/dev/kvm absent — VM must be Intel non-E2 with nested virtualization enabled"
  chgrp kvm /dev/kvm || true
  chmod 660 /dev/kvm || true
  usermod -aG kvm "$RUNNER_USER"
fi

log "Downloading actions/runner v$RUNNER_VERSION ($RUNNER_ARCH)..."
PKG="actions-runner-linux-$RUNNER_ARCH-$RUNNER_VERSION.tar.gz"
mkdir -p "$RUNNER_DIR"
curl -fsSL "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$PKG" -o "/tmp/$PKG"
tar -xzf "/tmp/$PKG" -C "$RUNNER_DIR"
rm -f "/tmp/$PKG"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

# Run exactly one job with the pre-minted JIT config, then fall through to the
# EXIT trap (self_delete). --jitconfig is single-job + ephemeral by definition.
log "Starting ephemeral runner (single job)..."
sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && ./run.sh --jitconfig '$JITCONFIG'" || \
  log "run.sh exited non-zero — proceeding to teardown anyway"

log "Job finished. Tearing down."
# EXIT trap fires self_delete.
