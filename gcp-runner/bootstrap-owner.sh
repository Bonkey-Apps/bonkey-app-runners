#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap-owner.sh — ONE-TIME project bootstrap, run by a project OWNER.
#
# Terraform cannot grant itself the permission required to enable APIs or set
# IAM. This script does that bootstrap so the provisioning service account can
# then run `terraform apply`. Run it ONCE per project as an owner.
#
# Auth: run as a user/SA with roles/owner (or resourcemanager.projectIamAdmin +
# serviceusage.serviceUsageAdmin + billing.projectManager). For an interactive
# owner login, in this Codespace type:  ! gcloud auth login
#
# Usage:
#   ./bootstrap-owner.sh <PROJECT_ID> <PROVISIONER_SA_EMAIL> [BILLING_ACCOUNT_ID]
# Example:
#   ./bootstrap-owner.sh bonkey-apps github@bonkey-apps.iam.gserviceaccount.com 0123AB-4567CD-89EF01
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_ID="${1:?Usage: bootstrap-owner.sh <PROJECT_ID> <PROVISIONER_SA_EMAIL> [BILLING_ACCOUNT_ID]}"
SA_EMAIL="${2:?Provide the provisioning service-account email (e.g. github@${PROJECT_ID:-PROJECT}.iam.gserviceaccount.com)}"
BILLING_ACCOUNT_ID="${3:-}"

echo "==> Project:      $PROJECT_ID"
echo "==> Provisioner:  $SA_EMAIL"

# 1) Enable the APIs the runner stack needs (so Terraform's google_project_service
#    is a no-op, and so basic project access works).
echo "==> Enabling required APIs..."
gcloud services enable \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  --project="$PROJECT_ID"

# 2) Grant the provisioning SA the roles Terraform needs to create the runner.
#    - compute.admin: create/delete the VM AND the firewall rule
#      (compute.instanceAdmin.v1 alone does NOT cover firewalls).
#    - iam.serviceAccountUser: attach a service account to the VM (actAs).
#    Add serviceusage.serviceUsageAdmin / resourcemanager.projectIamAdmin only if
#    you want Terraform itself to manage APIs/IAM (manage_project_services /
#    manage_project_iam = true). With the APIs already enabled above, you can
#    leave those Terraform toggles off and skip these two broader grants.
echo "==> Granting roles to $SA_EMAIL..."
for role in \
  roles/compute.admin \
  roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
  echo "    granted $role"
done

# Optional broader grants — uncomment to let Terraform manage APIs + project IAM
# (then set manage_project_services = true / manage_project_iam = true in tfvars):
# for role in roles/serviceusage.serviceUsageAdmin roles/resourcemanager.projectIamAdmin; do
#   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
#     --member="serviceAccount:$SA_EMAIL" --role="$role" --condition=None --quiet >/dev/null
#   echo "    granted $role"
# done

# 3) Billing — C3 + Spot are billable; the project MUST be linked to a billing
#    account or instances.insert fails.
if [[ -n "$BILLING_ACCOUNT_ID" ]]; then
  echo "==> Linking billing account $BILLING_ACCOUNT_ID..."
  gcloud services enable cloudbilling.googleapis.com --project="$PROJECT_ID" || true
  gcloud beta billing projects link "$PROJECT_ID" \
    --billing-account="$BILLING_ACCOUNT_ID"
else
  echo "==> NOTE: no BILLING_ACCOUNT_ID passed. Confirm billing is linked:"
  echo "         gcloud beta billing projects describe $PROJECT_ID"
  echo "         (C3-standard-4 Spot is billable — apply will fail without billing.)"
fi

echo "==> Bootstrap complete. The provisioning SA can now run terraform apply."
