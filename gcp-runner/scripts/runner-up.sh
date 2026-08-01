#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# runner-up.sh — on-demand ephemeral runner bring-up (#144, interim).
#
# For each requested runner: mint a single-use GitHub JIT config
# (POST .../actions/runners/generate-jitconfig) and create a Spot GCE VM that
# registers with it, runs ONE job, then self-deletes (see runner-jit-startup.sh).
#
# Run manually — on the existing persistent runner (gcloud auto-auths from the
# VM's attached SA) or locally with an activated SA. (The runner-dispatch.yml
# workflow was removed; deploy-gcp-runner.yml is the single GCP Terraform action.)
# No long-lived runner registration is ever stored on disk.
#
# Auth:
#   GH_PAT env — GitHub token with repo Administration:write (mint JIT configs).
#   GCP — Application Default Credentials (attached SA on a GCE VM, or
#         `gcloud auth activate-service-account` locally).
#
# Usage:
#   GH_PAT=ghp_xxx ./runner-up.sh [--count N] [--machine-type T] [--android]
#                                 [--labels a,b,c] [--repo owner/repo]
#                                 [--zone Z] [--project P]
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[runner-up] $*"; }
die() { echo "[runner-up] ERROR: $*" >&2; exit 1; }

META="http://metadata.google.internal/computeMetadata/v1"
md() { curl -sf -H "Metadata-Flavor: Google" "$META/$1" 2>/dev/null || true; }

# ---- defaults (metadata-derived when run on a GCE VM) ----------------------
COUNT=1
MACHINE_TYPE="c3-standard-4"
ANDROID="false"
LABELS="self-hosted,linux,x64,gce-c3-spot,ephemeral"
REPO="${GITHUB_REPOSITORY:-Bonkey-Apps/bonkey-puzzles-app}"
RUNNER_VERSION="2.335.1"
RUNNER_ARCH="x64"
DISK_SIZE="120"
DISK_TYPE="pd-balanced"
SA_EMAIL="github@bonkey-apps.iam.gserviceaccount.com"
PROJECT="$(md project/project-id)"
ZONE="$(md instance/zone | awk -F/ '{print $NF}')"

while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --machine-type) MACHINE_TYPE="$2"; shift 2 ;;
    --android) ANDROID="true"; shift ;;
    --labels) LABELS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "${GH_PAT:-}" ] || die "GH_PAT env is required (repo Administration:write)"
[ -n "$PROJECT" ] || die "could not determine project; pass --project"
[ -n "$ZONE" ] || die "could not determine zone; pass --zone"
command -v gcloud >/dev/null || die "gcloud not found"
command -v jq >/dev/null || die "jq not found"

STARTUP="$(dirname "$0")/runner-jit-startup.sh"
[ -f "$STARTUP" ] || die "missing $STARTUP"

# labels JSON array for the GitHub API
LABELS_JSON="$(printf '%s' "$LABELS" | jq -R 'split(",")')"

EXTRA_FLAGS=()
if [ "$ANDROID" = "true" ]; then
  EXTRA_FLAGS+=(--enable-nested-virtualization)
fi

log "Bringing up $COUNT ephemeral runner(s) in $PROJECT/$ZONE ($MACHINE_TYPE, android=$ANDROID)"

for i in $(seq 1 "$COUNT"); do
  NAME="gce-jit-$(date +%s)-$RANDOM"
  log "[$i/$COUNT] minting JIT config for $NAME..."
  JIT="$(curl -sf -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/actions/runners/generate-jitconfig" \
    -d "$(jq -nc --arg n "$NAME" --argjson l "$LABELS_JSON" \
          '{name:$n, runner_group_id:1, labels:$l, work_folder:"_work"}')" \
    | jq -r '.encoded_jit_config')"
  [ -n "$JIT" ] && [ "$JIT" != "null" ] || die "failed to mint JIT config (check GH_PAT Administration:write)"

  log "[$i/$COUNT] creating Spot VM $NAME..."
  gcloud compute instances create "$NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --provisioning-model=SPOT --instance-termination-action=DELETE \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size="${DISK_SIZE}GB" --boot-disk-type="$DISK_TYPE" \
    --service-account="$SA_EMAIL" --scopes=cloud-platform \
    --tags=gh-runner \
    --labels=purpose=gh-runner-ephemeral,managed=runner-up \
    --metadata="enable-android=$ANDROID,runner-version=$RUNNER_VERSION,runner-arch=$RUNNER_ARCH,jitconfig=$JIT" \
    --metadata-from-file=startup-script="$STARTUP" \
    "${EXTRA_FLAGS[@]}" \
    --quiet
  log "[$i/$COUNT] $NAME launching; it will register, run one job, and self-delete."
done

log "Done. Watch: gh api repos/$REPO/actions/runners --jq '.runners[].name'"
