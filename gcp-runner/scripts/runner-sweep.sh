#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# runner-sweep.sh — reconcile/teardown safety net for ephemeral runners (#144).
#
# Belt-and-suspenders for runner-up.sh: even though each ephemeral VM self-deletes
# (EXIT trap) and has a max-lifetime watchdog, this sweep catches anything that
# slipped through:
#   1. Delete `managed=runner-up` instances older than MAX_AGE_MINUTES.
#   2. Prune offline `gce-jit-*` runners from the GitHub repo.
# Idempotent and safe to run on a schedule (Cloud Scheduler / cron).
#
# Auth: same as runner-up.sh (GH_PAT env + GCP ADC).
# Usage: GH_PAT=ghp_xxx ./runner-sweep.sh [--project P] [--max-age-minutes N] [--repo owner/repo]
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[sweep] $*"; }
die() { echo "[sweep] ERROR: $*" >&2; exit 1; }

META="http://metadata.google.internal/computeMetadata/v1"
md() { curl -sf -H "Metadata-Flavor: Google" "$META/$1" 2>/dev/null || true; }

MAX_AGE_MINUTES=90
REPO="${GITHUB_REPOSITORY:-Bonkey-Apps/bonkey-puzzles-app}"
PROJECT="$(md project/project-id)"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --max-age-minutes) MAX_AGE_MINUTES="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die "could not determine project; pass --project"
command -v gcloud >/dev/null || die "gcloud not found"
command -v jq >/dev/null || die "jq not found"

# --- 1. Delete stale ephemeral instances -----------------------------------
# creationTimestamp is RFC3339; compare against an absolute cutoff so we don't
# rely on per-row date math in the filter.
CUTOFF="$(date -u -d "-${MAX_AGE_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"
log "Deleting managed=runner-up instances created before $CUTOFF ..."
mapfile -t STALE < <(gcloud compute instances list \
  --project="$PROJECT" \
  --filter="labels.managed=runner-up AND creationTimestamp<$CUTOFF" \
  --format="value(name,zone)" 2>/dev/null || true)

if [ "${#STALE[@]}" -eq 0 ]; then
  log "No stale instances."
else
  for row in "${STALE[@]}"; do
    name="$(printf '%s' "$row" | cut -f1)"
    zone="$(printf '%s' "$row" | cut -f2 | awk -F/ '{print $NF}')"
    log "  deleting $name ($zone)"
    gcloud compute instances delete "$name" --zone="$zone" --project="$PROJECT" --quiet || true
  done
fi

# --- 2. Prune offline gce-jit-* runners from GitHub ------------------------
if [ -n "${GH_PAT:-}" ]; then
  log "Pruning offline gce-jit-* runners from $REPO ..."
  runners="$(curl -sf \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_PAT" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/actions/runners?per_page=100")"
  echo "$runners" | jq -r '.runners[] | select(.name|startswith("gce-jit-")) | select(.status=="offline") | "\(.id)\t\(.name)"' \
  | while IFS=$'\t' read -r id name; do
      [ -n "$id" ] || continue
      log "  removing offline runner $name (id=$id)"
      curl -sf -X DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GH_PAT" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$REPO/actions/runners/$id" || true
    done
else
  log "GH_PAT not set — skipping GitHub offline-runner prune."
fi

log "Sweep complete."
