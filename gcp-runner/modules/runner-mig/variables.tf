variable "project_id" {
  description = "GCP project ID where the runner VM will be created."
  type        = string
  # No default — must be explicitly provided.
}

# ---------------------------------------------------------------------------
# Region / zone
# Always Free Compute Engine quota is only available in us-west1, us-central1,
# and us-east1. Changing to another region LEAVES FREE TIER — billed.
# ---------------------------------------------------------------------------
variable "region" {
  description = "GCP region. Must be us-west1, us-central1, or us-east1 to stay in Always Free tier."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone. Must be within an Always Free region (us-west1/us-central1/us-east1). Used only when regional = false."
  type        = string
  default     = "us-central1-a"
}

# ---------------------------------------------------------------------------
# Regional vs zonal MIG
# false (default): a ZONAL MIG pinned to var.zone.
# true: a REGIONAL MIG placed in ANY zone of var.region, retrying other zones on
#   a zonal stockout / unsupported-in-zone error. Use this for a GPU runner whose
#   accelerator (e.g. NVIDIA L4) is only offered in SOME zones of a region, so a
#   single hardcoded zone (e.g. <region>-a) would fail LOCATION_POLICY_VIOLATED /
#   resource-not-in-zone. var.zone is ignored when this is true.
# ---------------------------------------------------------------------------
variable "regional" {
  description = "When true, use a REGIONAL MIG (any zone in var.region) instead of a zonal MIG pinned to var.zone. Right for GPU runners where the accelerator is only in some zones."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Regional MIG distribution policy (ignored when var.regional = false).
#
# distribution_policy_zones: restrict the candidate zones the regional MIG may
# place instances in. Empty ([]) = every zone in var.region. PIN this to the
# zones that actually offer the accelerator (e.g. us-east1 L4 = -c/-d), so the
# MIG never wastes a create attempt on a zone with no GPU (LOCATION_POLICY /
# resource-not-in-zone).
#
# distribution_policy_target_shape: EVEN (default — balance across zones) vs ANY
# (place wherever capacity exists). For SCARCE resources — GPUs, and especially
# Spot GPUs — use ANY so a per-zone stockout falls through to another capable
# zone instead of retry-looping on the dead one.
# ---------------------------------------------------------------------------
variable "distribution_policy_zones" {
  description = "Regional MIG only: explicit zones the MIG may place instances in. Empty = all zones in var.region. Pin to the accelerator-capable zones (e.g. [\"us-east1-c\",\"us-east1-d\"] for L4) so the MIG never attempts a no-GPU zone."
  type        = list(string)
  default     = []
}

variable "distribution_policy_target_shape" {
  description = "Regional MIG only: EVEN (balance across zones) or ANY (place wherever capacity exists — recommended for scarce/Spot GPUs so a zonal stockout falls through to another capable zone)."
  type        = string
  default     = "EVEN"

  validation {
    condition     = contains(["EVEN", "ANY", "BALANCED"], var.distribution_policy_target_shape)
    error_message = "distribution_policy_target_shape must be one of: EVEN, ANY, BALANCED."
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
  # c3-standard-4 (Intel Sapphire Rapids) supports nested virtualization, so it can
  # run a KVM-accelerated Android emulator. AMD (c3d/n2d) and Arm (c4a/t2a) CANNOT
  # do nested virtualization and so cannot hardware-accelerate the emulator.
  description = "Machine type when enable_android_profile = true. Use an Intel non-E2 type (e.g. c3-standard-4) for a KVM-accelerated emulator. LEAVES FREE TIER — billed."
  type        = string
  default     = "c3-standard-4"
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
  # C3 does NOT support pd-standard; it requires pd-balanced / pd-ssd / hyperdisk.
  description = "Boot disk type when enable_android_profile = true. C3 requires pd-balanced or pd-ssd (pd-standard is unsupported)."
  type        = string
  default     = "pd-balanced"
}

# ---------------------------------------------------------------------------
# GitHub runner settings
# ---------------------------------------------------------------------------
variable "github_repo" {
  description = "GitHub repository to register the runner against, in 'owner/repo' format (e.g. 'Bonkey-Apps/bonkey-puzzles-app')."
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
# gce-<instance>-2, …). Default 3 gives a VM three parallel job slots.
#
# EMULATOR is NOT a provisioning-time clamp: every VM (emulator-capable or not)
# gets the same agent count. A host readers/writer lock installed via the runner's
# per-job hooks serializes at RUNTIME — a job that declares itself an emulator job
# (env HOST_LOCK_MODE=exclusive) takes an exclusive lock: it waits for in-flight
# regular jobs on that VM to drain, then blocks the other agents from starting new
# jobs until it finishes. Regular jobs take a shared lock (up to runners_per_vm at
# once). See runner-startup.sh.tftpl.
#
# Sizing: runners_per_vm × a regular job's peak RAM/CPU must fit machine_type (an
# e2-micro has only 1 GB RAM, and a single-GPU runner should stay at 1 to avoid
# GPU contention — set it to 1 in those environments).
# ---------------------------------------------------------------------------
variable "runners_per_vm" {
  description = "How many GitHub Actions runner agents to register per VM = how many regular jobs the VM runs concurrently. Emulator jobs (env HOST_LOCK_MODE=exclusive) take a host-wide exclusive lock at runtime instead of reducing this count. Must fit machine_type RAM/CPU (and GPU count). Default 1 — multi-agent contention caused e2e false-reds (#721); both env consumers already pin 1."
  type        = number
  default     = 1

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
# forward, not a standing always-on fleet.
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
# Required scopes (fine-grained PAT, repo-level):
#   - Contents: read-only  (to read runner registration endpoint)
#   - Administration: read & write  (to create self-hosted runner JIT configs)
#
# Set via TF_VAR_github_runner_pat environment variable or a *.tfvars file
# that is NEVER committed to the repository.
# ---------------------------------------------------------------------------
variable "github_runner_pat" {
  description = "Fine-grained GitHub PAT with repo Administration (read+write) permission, used at boot to mint a JIT runner registration token. NEVER commit this value."
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
  default     = "gh-runner"
}

# ---------------------------------------------------------------------------
# Managed Instance Group size
#   0 — scale to zero (no compute cost) when CI is idle. DEFAULT.
#   N — N runner VMs for parallel CI capacity, provisioned on demand.
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
# Firewall name
# The deny-all-ingress firewall's name must be UNIQUE per GCP project. When more
# than one deployment of this module (or the standalone root) targets the same
# project, each needs a distinct firewall name or `terraform apply` 409s on the
# already-existing resource. Default preserves the historical name so existing
# deployments are unchanged; a second fleet (e.g. the graphics GPU runner) must
# override it.
# ---------------------------------------------------------------------------
variable "firewall_name" {
  description = "Name of the deny-all-ingress firewall rule. Must be unique per project across all runner deployments. Override for a second fleet in the same project."
  type        = string
  default     = "gh-runner-deny-ingress"
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
# GPU (graphics) profile — attach a guest accelerator to the runner VM.
#
# Opt-in and DEFAULT OFF: with enable_gpu = false no guest_accelerator block is
# emitted and scheduling is unchanged, so every existing consumer of this module
# (bonkey-puzzles-app root, bonkey-puzzles env) plans exactly as before. When
# enable_gpu = true the instance template gains a
# `guest_accelerator { type = gpu_type, count = gpu_count }` block AND is forced
# to on_host_maintenance = "TERMINATE" (GPUs CANNOT live-migrate — GCP rejects
# MIGRATE on an accelerator VM).
#
# The graphics env root (environments/graphics) uses g2-standard-8 (8 vCPU,
# Intel Cascade Lake) + 1× NVIDIA L4 (Ada). g2 does NOT support pd-standard, so
# the boot disk must be pd-balanced (or pd-ssd) and large enough for CUDA
# userspace + model weights (>= 100 GB).
#
# QUOTA (CLAUDE.md "GCP quota discipline"): g2-standard-8 = 8 vCPU against the
# project CPUS_ALL_REGIONS ceiling (24), shared across ALL fleets/states. The
# graphics MIG's vCPUs count SIMULTANEOUSLY with the CI-runner MIG's — keep the
# sum <= 24. Also, NVIDIA_L4_GPUS quota (default 0 in a new project) must be
# granted before apply. LEAVES FREE TIER — billed.
# ---------------------------------------------------------------------------
variable "enable_gpu" {
  description = "Attach a guest accelerator (GPU) to the runner VM. When true, emits a guest_accelerator block and forces on_host_maintenance = TERMINATE (GPUs cannot live-migrate). Requires a GPU-capable machine_type (e.g. g2-standard-8) + pd-balanced/pd-ssd disk. LEAVES FREE TIER — billed; needs NVIDIA GPU quota granted."
  type        = bool
  default     = false
}

variable "gpu_type" {
  description = "Guest accelerator type when enable_gpu = true (e.g. 'nvidia-l4', 'nvidia-tesla-t4'). Must be available in the target zone; L4/G2 availability is narrower than T4."
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_count" {
  description = "Number of GPUs to attach when enable_gpu = true. g2-standard-8 pairs with exactly 1× L4."
  type        = number
  default     = 1

  validation {
    condition     = var.gpu_count >= 1
    error_message = "gpu_count must be >= 1 when enable_gpu is set."
  }
}

# ---------------------------------------------------------------------------
# Diffusion (SDXL sprite-gen) stack bake — pre-install torch/CUDA + diffusers on
# the GPU runner so the spritegen.yml workflow's install is a fast no-op (#562).
#
# Opt-in and DEFAULT OFF: with enable_diffusion = false the startup script's
# diffusion block never runs, so every non-graphics consumer of this module
# (bonkey-puzzles-app root, bonkey-puzzles env) is byte-for-byte unchanged. The
# graphics env (environments/graphics) opts in. The startup block ALSO
# double-guards on enable_gpu = true, so the heavy stack can only ever land on a
# GPU runner even if this toggle were mis-set on a non-GPU profile.
#
# ⚠️ APPLY-TIME-UNVERIFIED: no GPU/driver/CUDA in CI — the bake's import check
# LOGS but never fails boot (torch.cuda.is_available() needs the live L4).
# Validate on the first real graphics provision (see environments/graphics and
# docs/migration/562-bake-diffusion-stack.md).
# ---------------------------------------------------------------------------
variable "enable_diffusion" {
  description = "Pre-install the pinned SDXL Python stack (torch+CUDA/diffusers/transformers/accelerate/safetensors) into a persistent venv so the spritegen workflow's install is a no-op. Requires enable_gpu = true (the startup block double-guards on it). DEFAULT OFF — only the graphics env opts in; CI/puzzles runners are untouched."
  type        = bool
  default     = false
}

variable "diffusion_pip_packages" {
  # SOURCE OF TRUTH: tools/spritegen/py/requirements.txt (#561). These MUST match
  # that file exactly — mismatched pins break generation. Bump BOTH in lockstep
  # (see docs/migration/562-bake-diffusion-stack.md). A change here changes the
  # bake marker hash, forcing a re-install on the next boot instead of reusing a
  # stale venv.
  description = "EXACT pinned diffusion deps to bake, mirroring tools/spritegen/py/requirements.txt (#561). Bump in lockstep with that file."
  type        = list(string)
  default = [
    "torch==2.5.1",
    "diffusers==0.31.0",
    "transformers==4.46.3",
    "accelerate==1.1.1",
    "safetensors==0.4.5",
    "Pillow==11.0.0",
    # Local Bonkey LoRA training (#594) — peft/bitsandbytes/numpy.
    "peft==0.13.2",
    "bitsandbytes==0.44.1",
    "numpy==2.1.3",
    # Transparent-background matting (Epic #135 follow-up) — rembg/u2net alpha-cuts
    # each rendered frame to a clean transparent RGBA cutout. CPU onnxruntime on
    # purpose (u2net matting is light; avoids CUDA/cuDNN coupling with the torch
    # cu124 pin). The ~176 MB u2net model downloads to the rembg ~/.u2net cache on
    # first run (negligible vs the 100 GB disk budget).
    "rembg==2.0.59",
    "onnxruntime==1.20.1",
  ]
}

variable "diffusion_torch_index_url" {
  # The torch cu124 (CUDA 12.4) wheels for the L4 (Ada, sm_89). Matches #561's
  # requirements.txt install recipe. cu124 wheels bundle the CUDA 12.4 runtime,
  # so no separate cuda-toolkit is baked.
  description = "Extra pip index URL for the CUDA-matched torch wheels (cu124 for the L4). Must match #561's requirements.txt install recipe."
  type        = string
  default     = "https://download.pytorch.org/whl/cu124"
}

variable "diffusion_root" {
  description = "Persistent root dir on the boot disk for the baked diffusion venv, pip cache, and HF model cache. Survives a Spot stop/restart (not a full MIG REPLACE)."
  type        = string
  default     = "/opt/spritegen"
}

variable "diffusion_hf_home" {
  description = "HF_HOME the bake exports to CI jobs (persistent SDXL weight cache). Empty falls back to diffusion_root/hf-cache."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# ControlNet OpenPose pose control (#674) — NO new pip pin.
# diffusion_pip_packages above is unchanged: diffusers 0.31.0 already ships
# ControlNetModel + StableDiffusionXLControlNetPipeline, and the committed
# per-frame OpenPose skeletons (tools/spritegen/poses/<clip>/) ARE the control
# images (no controlnet_aux preprocessing). generate.py pulls the OpenPose
# ControlNet model `thibaud/controlnet-openpose-sdxl-1.0` (~2.5 GB fp16, OPEN, no
# HF token) at generation time; it warms into the SAME persistent HF weight cache
# (diffusion_hf_home) on first pose-controlled run — no new bake step. Disk: the
# ~2.5 GB model lifts the graphics footprint to ~36.5 GB of the 100 GB budget.
# See gcp-runner/IMAGE-MANIFEST.md and
# docs/migration/674-controlnet-walkcycle.md.
# ---------------------------------------------------------------------------

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
