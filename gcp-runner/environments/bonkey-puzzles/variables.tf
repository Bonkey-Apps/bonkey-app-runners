# ---------------------------------------------------------------------------
# Root variables for the bonkey-puzzles free-tier runner.
#
# Only values that must be supplied per-deploy live here. The free-tier shape
# (e2-micro / 30 GB pd-standard / us-central1 / persistent / target_size 1 /
# labels) is fixed as literals in main.tf so this deployment cannot accidentally
# drift off the Always-Free tier.
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID where the bonkey-puzzles runner VM will be created."
  type        = string
  # No default — must be explicitly provided (tfvars or TF_VAR_project_id).
}

# ---------------------------------------------------------------------------
# Region / zone
# Always Free Compute Engine quota is only available in us-west1, us-central1,
# and us-east1. Defaults keep this deployment in the Always Free tier.
# ---------------------------------------------------------------------------
variable "region" {
  description = "GCP region. Must be us-west1, us-central1, or us-east1 to stay in Always Free tier."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone. Must be within an Always Free region (us-west1/us-central1/us-east1)."
  type        = string
  default     = "us-central1-a"
}

# ---------------------------------------------------------------------------
# GitHub PAT — bonkey-puzzles-scoped, with Administration: Read & Write.
#
# IMPORTANT: the existing GH_RUNNER_PAT is scoped to bonkey-puzzles-app and will NOT
# register a runner against Bonkey-Apps/bonkey-puzzles. A NEW fine-grained PAT
# scoped to bonkey-puzzles is required. Provide it ONLY via
#   export TF_VAR_github_runner_pat="$(gcloud secrets versions access latest --secret=...)"
# Never commit it. Marked sensitive so Terraform redacts it from plan/apply/state.
# ---------------------------------------------------------------------------
variable "github_runner_pat" {
  description = "Fine-grained GitHub PAT scoped to Bonkey-Apps/bonkey-puzzles with repo Administration (read+write). Used at boot to mint a JIT runner registration token. NEVER commit this value."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Service account
# Leave empty to create a dedicated SA for this runner. If your provisioning
# identity cannot create SAs / set IAM, pre-create one out of band and pass its
# email here (mirrors the bonkey-puzzles-app reuse-existing-SA path; see SETUP-OWNER.md).
# ---------------------------------------------------------------------------
variable "service_account_email" {
  description = "Email of an existing GCP service account to attach to the runner VM. Leave empty to create a new one."
  type        = string
  default     = ""
}

variable "runner_version" {
  description = "Version of the actions/runner agent to install (without leading 'v'). See https://github.com/actions/runner/releases."
  type        = string
  default     = "2.335.1"
}

# ---------------------------------------------------------------------------
# Project API / IAM management toggles. Default OFF (the owner enables APIs and
# grants SA roles out of band per SETUP-OWNER.md) so an under-privileged
# provisioning identity does not need serviceUsageAdmin / projectIamAdmin.
# ---------------------------------------------------------------------------
variable "manage_project_services" {
  description = "When true, Terraform enables the required Google APIs (needs serviceusage.serviceUsageAdmin). Set false if APIs are managed out of band."
  type        = bool
  default     = false
}

variable "manage_project_iam" {
  description = "When true, Terraform grants runner_sa_roles to the runner service account (needs resourcemanager.projectIamAdmin). Set false if granted out of band."
  type        = bool
  default     = false
}
