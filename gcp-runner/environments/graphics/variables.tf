# ---------------------------------------------------------------------------
# Root variables for the graphics GPU runner (Part of #534).
#
# Only values that must be supplied per-deploy live here. The GPU shape
# (g2-standard-8 / 1× NVIDIA L4 / 100 GB pd-balanced / persistent / GPU labels)
# is fixed as literals in main.tf so this deployment cannot accidentally drift
# off the intended machine/accelerator.
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID where the graphics runner VM will be created."
  type        = string
  # No default — must be explicitly provided (tfvars or TF_VAR_project_id).
}

# ---------------------------------------------------------------------------
# Region / zone
# G2 + NVIDIA L4 availability is NARROWER than T4 — the zone MUST offer both
# g2-standard-8 and NVIDIA L4. us-central1-a is a common L4 zone; confirm
# availability before apply (gcloud compute accelerator-types list --filter L4).
# This LEAVES FREE TIER regardless of region (GPU VMs are always billed).
# ---------------------------------------------------------------------------
variable "region" {
  description = "GCP region for the graphics runner MIG. Must offer the selected GPU machine type (G2/L4: us-central1/us-east1/…; G4/RTX PRO 6000: us-central1/us-east1/us-east4/europe-west4). Regional MIG picks any zone within it (billed)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Unused — the graphics env uses a REGIONAL MIG (any zone in var.region). Kept for module compatibility; passed by the workflow but ignored."
  type        = string
  default     = "us-central1-a"
}

# ---------------------------------------------------------------------------
# GitHub PAT — bonkey-puzzles-app-scoped, with Administration: Read & Write.
# Same repo/PAT as the CI runner (Bonkey-Apps/bonkey-puzzles-app). Provide it ONLY via
#   export TF_VAR_github_runner_pat="$(...)"
# Never commit it. Marked sensitive so Terraform redacts it from plan/apply/state.
# ---------------------------------------------------------------------------
variable "github_runner_pat" {
  description = "Fine-grained GitHub PAT scoped to Bonkey-Apps/bonkey-puzzles-app with repo Administration (read+write). Used at boot to mint a JIT runner registration token. NEVER commit this value."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# MIG size. Default 0 — on-demand only, no standing GPU runner (GPU VMs are
# billed while running). RESIZE UP deliberately before a generation run, and
# back to 0 after:
#   terraform apply -var runner_target_size=1   # before a run
#   terraform apply -var runner_target_size=0   # after
#   # or, without terraform:
#   gcloud compute instance-groups managed resize graphics-github-runner \
#     --zone=<zone> --size=0 --project=<project>
# Do NOT autoscale past quota (8 vCPU/VM).
# ---------------------------------------------------------------------------
variable "runner_target_size" {
  description = "GPU runner VMs the MIG maintains. Default 0 (on-demand only — no standing GPU runner); resize up deliberately before a generation run, back to 0 after. Each VM is 8 vCPU + 1 L4 — do not exceed quota."
  type        = number
  default     = 0

  validation {
    condition     = var.runner_target_size >= 0
    error_message = "runner_target_size must be >= 0."
  }
}

# ---------------------------------------------------------------------------
# GPU shape — parameterized so the deploy workflow's `graphics_machine` input can
# select among supported machine types. G2 (g2-standard-4/8) uses NVIDIA L4; G4
# (g4-standard-6/12) uses NVIDIA RTX PRO 6000 (Blackwell). Defaults = g2-standard-8.
# ---------------------------------------------------------------------------
variable "machine_type" {
  description = "GPU machine type: g2-standard-4/8 (NVIDIA L4) or g4-standard-6/12 (NVIDIA RTX PRO 6000)."
  type        = string
  default     = "g2-standard-8"

  validation {
    condition     = contains(["g2-standard-4", "g2-standard-8", "g4-standard-6", "g4-standard-12"], var.machine_type)
    error_message = "machine_type must be one of: g2-standard-4, g2-standard-8 (NVIDIA L4), g4-standard-6, g4-standard-12 (NVIDIA RTX PRO 6000)."
  }
}

variable "gpu_type" {
  description = "GPU accelerator type matching machine_type: 'nvidia-l4' for G2; for G4 verify the exact string with `gcloud compute accelerator-types list`."
  type        = string
  default     = "nvidia-l4"
}

# ---------------------------------------------------------------------------
# Regional-MIG placement. The GPU is only offered in SOME zones of a region
# (us-east1 L4 = -c/-d, NOT -a/-b), and Spot GPU capacity is scarce, so:
#   * pin the candidate zones to the accelerator-capable ones (never attempt a
#     no-GPU zone → no LOCATION_POLICY_VIOLATED), and
#   * use target_shape = ANY so a per-zone stockout ("does not have enough
#     resources") falls through to the OTHER capable zone instead of retry-
#     looping on the dead one.
# The deploy workflow sets these per region/GPU family; the defaults below match
# the workflow's default (us-east1 + L4).
# ---------------------------------------------------------------------------
variable "distribution_policy_zones" {
  description = "Accelerator-capable zones the regional MIG may place the GPU runner in. Empty = all zones in var.region. Default = us-east1 L4 zones."
  type        = list(string)
  default     = ["us-east1-c", "us-east1-d"]
}

variable "distribution_policy_target_shape" {
  description = "EVEN or ANY. ANY (default here) places the GPU wherever capacity exists so a zonal Spot stockout falls through to another capable zone."
  type        = string
  default     = "ANY"
}

variable "gpu_count" {
  description = "Attached GPUs for a guest_accelerator block: 1 for g2-standard-4/8 (L4). Use 0 for G4 fractional-vGPU shapes (g4-standard-6 = 1/8, g4-standard-12 = 1/4 RTX PRO 6000) where the GPU is BUILT INTO the machine type and no guest_accelerator block is allowed."
  type        = number
  default     = 1

  validation {
    condition     = var.gpu_count >= 0
    error_message = "gpu_count must be >= 0 (0 = GPU built into the machine type; no guest_accelerator block)."
  }
}

variable "boot_disk_size_gb" {
  description = "Boot disk size (GB). >=100 for CUDA + SDXL weights; bump for FLUX / larger-VRAM G4 GPUs."
  type        = number
  default     = 100
}

variable "boot_disk_type" {
  description = "Boot disk type. pd-balanced for G2 (g2 does NOT support pd-standard). G4/Blackwell may require hyperdisk-balanced — verify per family."
  type        = string
  default     = "pd-balanced"
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
