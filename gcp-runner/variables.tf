variable "project_id" {
  description = "GCP project ID where the runner VM will be created."
  type        = string
  # No default — must be explicitly provided.
}

# ---------------------------------------------------------------------------
# Region (regional MIG — any zone within it)
# Only the REGION is configurable; the regional MIG places runner VMs in any
# zone of this region and retries other zones on a capacity stockout (main.tf).
# A MIG cannot span regions — to move, change this and re-apply (replaces the
# MIG in the new region). Allowed set: us-central1, us-east1, us-south1.
# (us-central1 / us-east1 are Always-Free regions; the billed Android/emulator
# profile leaves the free tier regardless of region. us-south1 is not free-tier.)
# ---------------------------------------------------------------------------
variable "region" {
  description = "GCP region for the runner MIG (any zone within it). One of: us-central1, us-east1, us-south1."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1", "us-south1"], var.region)
    error_message = "region must be one of: us-central1, us-east1, us-south1."
  }
}

# ---------------------------------------------------------------------------
# Machine type
# e2-micro is the Always Free machine type (one per account, us regions only).
# For Android builds you need at least e2-standard-4 — LEAVES FREE TIER — billed.
# ---------------------------------------------------------------------------
variable "machine_type" {
  description = "GCE machine type. Default e2-micro is Always Free. Use e2-standard-4 or larger for Android builds (LEAVES FREE TIER — billed)."
  type        = string
  default     = "e2-micro"
}

# ---------------------------------------------------------------------------
# Boot disk
# Always Free includes 30 GB of standard persistent disk total.
# Increasing beyond 30 GB or using pd-ssd LEAVES FREE TIER — billed.
# Android SDK + NDK + Gradle caches typically need 80–120 GB — billed.
# ---------------------------------------------------------------------------
variable "boot_disk_size_gb" {
  description = "Boot disk size in GB. Default 30 is the Always Free standard-PD allowance. Android builds typically need 100+ GB (LEAVES FREE TIER — billed)."
  type        = number
  default     = 30
}

variable "boot_disk_type" {
  description = "Boot disk type. pd-standard is free; pd-ssd LEAVES FREE TIER — billed."
  type        = string
  default     = "pd-standard"
}

# ---------------------------------------------------------------------------
# Android build profile
# Set enable_android_profile = true to bump machine/disk to Android-capable
# values. This LEAVES FREE TIER — billed.
#
# IMPORTANT — KVM / nested virtualisation for Android emulators:
#   e2 machine family does NOT support nested virtualisation.
#   To run the Android emulator you must use a machine that supports it, e.g.
#   n1-standard-4 with --enable-nested-virtualization. This is a separate
#   decision from machine_type. Document your choice in tfvars and README.
#   The android_machine_type / android_disk_size_gb variables below control
#   what gets used when enable_android_profile = true.
# ---------------------------------------------------------------------------
variable "enable_android_profile" {
  description = "When true, overrides machine_type and boot_disk_size_gb with android_machine_type / android_disk_size_gb. LEAVES FREE TIER — billed."
  type        = bool
  default     = false
}

variable "android_machine_type" {
  # LEAVES FREE TIER — billed. e2-standard-4 has no nested-virt; use n1-standard-4
  # (or n2-standard-4) with advanced_machine_features { enable_nested_virtualization = true }
  # if you need the Android emulator.
  # n2-standard-8 (Intel Cascade/Ice Lake, 8 vCPU) supports nested virtualization,
  # so it can run a KVM-accelerated Android emulator. AMD (c3d/n2d) and Arm
  # (c4a/t2a) CANNOT do nested virtualization and so cannot hardware-accelerate it.
  # QUOTA: n2-standard-8 counts as 8 vCPU against the project CPUS_ALL_REGIONS
  # ceiling (24), shared across ALL fleets — keep target_size × 8 ≤ quota
  # (3 VMs = 24, at the cap). Do NOT plan capacity past quota (see CLAUDE.md).
  description = "Machine type when enable_android_profile = true. Use an Intel non-E2 type (e.g. n2-standard-8) for a KVM-accelerated emulator. LEAVES FREE TIER — billed."
  type        = string
  default     = "n2-standard-8"
}

variable "android_disk_size_gb" {
  # LEAVES FREE TIER — billed. Android SDK + NDK + Gradle cache + emulator system
  # images + build artefacts typically consume 80–120 GB. GCP cannot shrink a
  # boot disk in place — changing this value forces disk (and instance
  # template) recreation on the next apply, not a resize.
  description = "Boot disk size (GB) when enable_android_profile = true. LEAVES FREE TIER — billed."
  type        = number
  default     = 100
}

variable "android_disk_type" {
  # n2 supports pd-standard / pd-balanced / pd-ssd. pd-balanced is the default —
  # noticeably faster than pd-standard for SDK/Gradle/emulator I/O.
  description = "Boot disk type when enable_android_profile = true. n2 supports pd-standard/pd-balanced/pd-ssd; pd-balanced recommended."
  type        = string
  default     = "pd-balanced"
}

# ---------------------------------------------------------------------------
# GitHub runner settings
#
# Registration scope — ORG vs REPO.
#   github_org (default "Bonkey-Apps"): when non-empty, the runners register at
#     the ORGANIZATION level, so a SINGLE fleet serves EVERY repo in the org
#     (no per-repo runner deployments). This is the default. Org registration
#     hits POST /orgs/{org}/actions/runners/registration-token and configures
#     with --url https://github.com/{org}; it requires an ORG-scoped PAT with
#     Administration (organization self-hosted runners) read+write.
#   github_repo: used ONLY when github_org is empty ("") — then registration is
#     repo-scoped (POST /repos/{owner}/{repo}/... , --url .../{owner}/{repo})
#     and the PAT need only be repo-scoped. Set github_org = "" to opt back into
#     the legacy single-repo behavior.
# github_org takes precedence: if it is non-empty, github_repo is ignored for
# registration/deregistration.
# ---------------------------------------------------------------------------
variable "github_org" {
  description = "GitHub organization to register the runners against (org-level runners serve every repo in the org). Default 'Bonkey-Apps'. Set to \"\" to fall back to repo-scoped registration via github_repo. When set, requires an ORG-scoped PAT with Administration (self-hosted runners) read+write."
  type        = string
  default     = "Bonkey-Apps"
}

variable "github_repo" {
  description = "GitHub repository to register the runner against, in 'owner/repo' format (e.g. 'Bonkey-Apps/bonkey-puzzles-app'). Used ONLY when github_org is empty; ignored for org-level registration."
  type        = string
  default     = "Bonkey-Apps/bonkey-puzzles-app"
}

variable "runner_labels" {
  description = "Extra labels to assign to the runner beyond 'self-hosted,linux,x64'."
  type        = list(string)
  default     = ["self-hosted", "linux", "x64", "gce-free"]
}

# ---------------------------------------------------------------------------
# Concurrent jobs per VM
# A GitHub Actions runner AGENT runs exactly one job at a time, so N concurrent
# jobs on one VM means N registered agents. The startup script installs this many
# agents (each in its own directory + systemd service, named gce-<instance>,
# gce-<instance>-2, …). Default 2 = two job slots per VM. A heavier 3/VM setup
# once caused e2e starvation false-reds on the post-rename fleet —
# codeword.conformance timed out 4/4 on PR #707 — but the host readers/writer
# lock (#721, below) now promotes the heavy Tier-3 web-e2e job to an EXCLUSIVE
# host lock, so it never contends with a sibling agent. Keep this modest and
# well under machine RAM/CPU; only push past 2 once a real workload proves the
# isolation holds under more concurrency.
#
# EMULATOR is NOT a provisioning-time clamp: every VM (emulator-capable or not)
# gets the same agent count. Instead, a host readers/writer lock installed via the
# runner's per-job hooks serializes at RUNTIME — a job that declares itself an
# emulator job (env HOST_LOCK_MODE=exclusive) takes an exclusive lock: it waits
# for in-flight regular jobs on that VM to drain, then blocks the other agents
# from starting new jobs until the emulator job finishes. Regular jobs take a
# shared lock (up to runners_per_vm at once). See runner-startup.sh.tftpl.
#
# Sizing: runners_per_vm × a regular job's peak RAM/CPU must fit machine_type
# (an e2-micro has only 1 GB RAM — override to 1 there).
# ---------------------------------------------------------------------------
variable "runners_per_vm" {
  description = "How many GitHub Actions runner agents to register per VM = how many regular jobs the VM runs concurrently. Emulator jobs (env HOST_LOCK_MODE=exclusive) take a host-wide exclusive lock at runtime instead of reducing this count. Must fit machine_type RAM/CPU."
  type        = number
  default     = 2

  validation {
    condition     = var.runners_per_vm >= 1
    error_message = "runners_per_vm must be >= 1."
  }
}

variable "runner_version" {
  description = "Version of the actions/runner agent to install (without leading 'v'), e.g. '2.335.1'. See https://github.com/actions/runner/releases."
  type        = string
  default     = "2.335.1"
}

# ---------------------------------------------------------------------------
# Runner mode
#   persistent — runner registers and STAYS available across jobs. Installed as
#                a systemd service that auto-restarts and survives reboot. No
#                --ephemeral flag, no self-deletion watchdog.
#   ephemeral  — one-shot: runner registers with --ephemeral, runs exactly one
#                job, then the VM self-deletes. Use for on-demand JIT runs.
#
# Default is now "ephemeral": GCE deployments are on-demand only going
# forward, not a standing always-on fleet. Pair with runner_target_size = 0
# below — a "persistent" runner with target_size = 0 is a no-op (nothing to
# stay available), and this repo's on-demand scripts (scripts/runner-up.sh)
# are the supported path for provisioning a runner when CI actually needs one.
# ---------------------------------------------------------------------------
variable "runner_mode" {
  description = "Runner lifecycle mode: 'persistent' (stays available across jobs, survives reboot) or 'ephemeral' (one-shot, self-deletes after a job). Default 'ephemeral' — GCE deployments are on-demand only."
  type        = string
  default     = "ephemeral"

  validation {
    condition     = contains(["persistent", "ephemeral"], var.runner_mode)
    error_message = "runner_mode must be either 'persistent' or 'ephemeral'."
  }
}

# ---------------------------------------------------------------------------
# GitHub PAT — used at boot to mint a one-time JIT registration token.
# Mark sensitive so Terraform redacts it from plan/apply output and state.
#
# Required scopes (fine-grained PAT) depend on the registration scope:
#   - ORG-level (github_org set, the default): Organization permissions →
#     "Self-hosted runners": Read and write. This is what mints an
#     org registration token (POST /orgs/{org}/actions/runners/...).
#   - REPO-level (github_org = ""): Repository permissions → Administration:
#     Read and write (POST /repos/{owner}/{repo}/actions/runners/...).
#
# Set via TF_VAR_github_runner_pat environment variable or a *.tfvars file
# that is NEVER committed to the repository.
# ---------------------------------------------------------------------------
variable "github_runner_pat" {
  description = "Fine-grained GitHub PAT used at boot to mint a JIT runner registration token. For org-level registration (github_org set) it needs Organization 'Self-hosted runners' read+write; for repo-level it needs repo Administration read+write. NEVER commit this value."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Service account
# If left empty, a dedicated SA is created for the runner VM.
# ---------------------------------------------------------------------------
variable "service_account_email" {
  description = "Email of an existing GCP service account to attach to the runner VM. Leave empty to create a new one."
  type        = string
  default     = ""
}

variable "runner_instance_name" {
  description = "Name of the GCE instance template / MIG and the base name for runner VMs. Keep it short — GCE names are ≤63 chars."
  type        = string
  default     = "gh-runner-emulator-enabled"
}

# ---------------------------------------------------------------------------
# Managed Instance Group size
#   0 — scale to zero (no compute cost) when CI is idle. DEFAULT — GCE
#       deployments are on-demand only; nothing sits standing between runs.
#   N — N runner VMs for parallel CI capacity, provisioned on demand (see
#       scripts/runner-up.sh) rather than left running.
# Change this and `terraform apply` to scale, or resize the MIG directly with
# `gcloud compute instance-groups managed resize`. On-demand autoscaling driven
# by queued jobs is a follow-on (#262).
# ---------------------------------------------------------------------------
variable "runner_target_size" {
  description = "Number of runner VMs the MIG maintains. Default 0 (on-demand only, no standing fleet); raise only for a deliberate, temporary burst of parallel CI capacity."
  type        = number
  default     = 0

  validation {
    condition     = var.runner_target_size >= 0
    error_message = "runner_target_size must be >= 0."
  }
}

variable "network_tags" {
  description = "Network tags to apply to the runner instance."
  type        = list(string)
  default     = ["gh-runner"]
}

# ---------------------------------------------------------------------------
# SSH ingress (for debugging the runner VMs)
# The deny-all ingress rule blocks inbound by default. Set enable_ssh_ingress
# (default true) to add a higher-priority rule permitting tcp/22 from
# ssh_source_ranges. The default source is Google's IAP TCP-forwarding range, so
# `gcloud compute ssh --tunnel-through-iap` and the Cloud Console SSH button work
# WITHOUT exposing port 22 publicly. Using IAP also requires the human user to
# hold roles/iap.tunnelResourceAccessor + a compute SSH role (or OS Login), and
# the iap.googleapis.com API enabled (included in project_services below).
# ---------------------------------------------------------------------------
variable "enable_ssh_ingress" {
  description = "Allow SSH (tcp/22) ingress to runner VMs from ssh_source_ranges. Lets you gcloud/Console SSH in for debugging. Default true."
  type        = bool
  default     = true
}

variable "ssh_source_ranges" {
  description = "Source CIDRs allowed to SSH into runner VMs. Default is Google's IAP TCP-forwarding range (35.235.240.0/20) — secure, no public port-22 exposure. Add your own IP/CIDR for direct SSH over the external IP."
  type        = list(string)
  default     = ["35.235.240.0/20"]
}

# ---------------------------------------------------------------------------
# Spot (preemptible) provisioning
# Spot VMs are 60–91% cheaper but can be reclaimed by GCP at any time. For a
# persistent runner we use instance_termination_action = "STOP" so a preempted
# VM is stopped (not deleted) and can be restarted with `terraform apply` /
# `gcloud compute instances start`. NOTE: a Spot VM does NOT auto-restart after
# preemption — that is the cost/availability trade-off.
# ---------------------------------------------------------------------------
variable "enable_spot" {
  description = "Provision the runner as a Spot VM (cheaper, but GCP may preempt it at any time; it will not auto-restart)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Nested virtualization (KVM)
# Required for a hardware-accelerated Android emulator. ONLY works on Intel
# (non-E2, non-memory-optimized) machines. Unsupported on AMD and Arm. Enabling
# this on an unsupported machine type makes `terraform apply` fail.
# ---------------------------------------------------------------------------
variable "enable_nested_virtualization" {
  description = "Enable nested virtualization (KVM) so the VM can hardware-accelerate the Android emulator. Requires an Intel non-E2 machine_type (e.g. c3-standard-4). Unsupported on AMD/Arm."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Minimum CPU platform
# Pins the VM to a CPU generation floor. Nested virtualization (KVM) requires
# at least "Intel Haswell"; older auto-selected platforms cannot pass through
# VT-x. Leave empty ("") to let GCP auto-select (STANDARD boots). Set to e.g.
# "Intel Haswell" alongside enable_nested_virtualization = true.
# ---------------------------------------------------------------------------
variable "min_cpu_platform" {
  description = "Minimum CPU platform floor (e.g. 'Intel Haswell'). Required for nested virtualization. Empty string lets GCP auto-select."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# On-host maintenance behavior (non-Spot VMs only)
# MIGRATE  — GCP live-migrates the VM during host maintenance; the runner keeps
#            running and in-flight jobs survive. This is the default and the
#            right choice for a persistent runner.
# TERMINATE — VM is stopped on host maintenance. Required when the machine/feature
#            combination (e.g. some nested-virt families) does not support live
#            migration. Spot VMs always force TERMINATE regardless of this value.
# ---------------------------------------------------------------------------
variable "on_host_maintenance" {
  description = "Host-maintenance behavior for STANDARD (non-Spot) VMs: 'MIGRATE' (live-migrate, default) or 'TERMINATE'. Spot VMs always force TERMINATE."
  type        = string
  default     = "MIGRATE"

  validation {
    condition     = contains(["MIGRATE", "TERMINATE"], var.on_host_maintenance)
    error_message = "on_host_maintenance must be either 'MIGRATE' or 'TERMINATE'."
  }
}

# ---------------------------------------------------------------------------
# Runner agent CPU architecture
# Controls which actions/runner release the startup script downloads.
#   x64   — Intel/AMD (e2, n2, c3, ...)
#   arm64 — Arm (c4a / t2a)   (NOTE: Arm cannot do nested virt / KVM emulator)
# ---------------------------------------------------------------------------
variable "runner_arch" {
  description = "actions/runner agent architecture matching machine_type: 'x64' (Intel/AMD) or 'arm64' (Arm/C4A)."
  type        = string
  default     = "x64"

  validation {
    condition     = contains(["x64", "arm64"], var.runner_arch)
    error_message = "runner_arch must be either 'x64' or 'arm64'."
  }
}

# ---------------------------------------------------------------------------
# Project API enablement (managed by Terraform)
# Enabling a service requires the *provisioning identity* to hold
# roles/serviceusage.serviceUsageAdmin. Terraform cannot grant itself that
# permission — see gcp-runner/SETUP-OWNER.md for the one-time bootstrap.
# Set manage_project_services = false if your platform team enables APIs out of
# band (then these become a no-op and Terraform won't touch Service Usage).
# ---------------------------------------------------------------------------
variable "manage_project_services" {
  description = "When true, Terraform enables the required Google APIs (needs serviceusage.serviceUsageAdmin on the provisioning identity). Set false if APIs are managed out of band."
  type        = bool
  default     = true
}

variable "project_services" {
  description = "Google APIs the runner stack requires. Enabled via google_project_service when manage_project_services = true."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    # Identity-Aware Proxy — required for `gcloud compute ssh --tunnel-through-iap`
    # and the Cloud Console SSH button to reach the runner VMs (see enable_ssh_ingress).
    "iap.googleapis.com",
  ]
}

# ---------------------------------------------------------------------------
# Project IAM for the runner service account (managed by Terraform)
# Granting these requires the provisioning identity to hold
# roles/resourcemanager.projectIamAdmin. Set manage_project_iam = false if the
# SA's roles are granted out of band (the default reuse-existing-SA path assumes
# the owner already granted them per SETUP-OWNER.md).
# ---------------------------------------------------------------------------
variable "manage_project_iam" {
  description = "When true, Terraform grants runner_sa_roles to the runner service account (needs resourcemanager.projectIamAdmin on the provisioning identity)."
  type        = bool
  default     = false
}

variable "runner_sa_roles" {
  description = "Project roles to grant the runner service account when manage_project_iam = true."
  type        = list(string)
  default = [
    "roles/compute.instanceAdmin.v1",
    "roles/iam.serviceAccountUser",
  ]
}
