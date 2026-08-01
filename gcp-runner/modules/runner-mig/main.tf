# ---------------------------------------------------------------------------
# Locals: resolve Android profile overrides
# ---------------------------------------------------------------------------
locals {
  effective_machine_type = var.enable_android_profile ? var.android_machine_type : var.machine_type
  effective_disk_size_gb = var.enable_android_profile ? var.android_disk_size_gb : var.boot_disk_size_gb
  effective_disk_type    = var.enable_android_profile ? var.android_disk_type : var.boot_disk_type
  create_service_account = var.service_account_email == ""
  runner_labels_csv      = join(",", var.runner_labels)

  # Diffusion bake (#562). Resolve the HF cache dir and a marker hash keyed on
  # the FULL install recipe — the pin set AND the torch index URL. Bumping either
  # changes the marker, forcing the next boot to re-install instead of
  # short-circuiting on a stale venv (a cu124→cuXYZ index change with unchanged
  # pins would otherwise leave the wrong CUDA build in place). join() renders the
  # pins as a single space-separated pip argument list.
  diffusion_hf_home_effective = var.diffusion_hf_home != "" ? var.diffusion_hf_home : "${var.diffusion_root}/hf-cache"
  diffusion_pip_packages_csv  = join(" ", var.diffusion_pip_packages)
  diffusion_marker            = substr(sha256("${var.diffusion_torch_index_url} ${local.diffusion_pip_packages_csv}"), 0, 12)
}

# ---------------------------------------------------------------------------
# Service account (created only when service_account_email is not provided)
# ---------------------------------------------------------------------------
resource "google_service_account" "runner" {
  count        = local.create_service_account ? 1 : 0
  account_id   = "gh-runner-sa"
  display_name = "GitHub Actions Self-Hosted Runner"
  description  = "Minimal SA for the GCE self-hosted runner VM."
}

locals {
  runner_sa_email = local.create_service_account ? google_service_account.runner[0].email : var.service_account_email
}

# Google Cloud Ops Agent (#408) roles the runner SA needs to export host
# metrics/logs. Unioned in as a local rather than appended to the
# var.runner_sa_roles default so this file stays self-contained.
locals {
  ops_agent_sa_roles = [
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
  ]
}

# Project roles for the runner service account (compute admin for instance
# self-management / ephemeral self-deletion; serviceAccountUser so the VM can act
# as itself; plus the Ops Agent export roles above). Managed only when
# manage_project_iam = true, which requires the provisioning identity to hold
# roles/resourcemanager.projectIamAdmin. By default this is OFF: the
# reuse-existing-SA path assumes the owner granted these out of band (see
# SETUP-OWNER.md), so the under-privileged provisioning SA never needs
# setIamPolicy.
resource "google_project_iam_member" "runner_sa_roles" {
  for_each = var.manage_project_iam ? toset(concat(var.runner_sa_roles, local.ops_agent_sa_roles)) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.runner_sa_email}"

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Firewall
# The runner only makes OUTBOUND connections to GitHub (api.github.com,
# *.actions.githubusercontent.com, etc.) and Google APIs. No inbound ports
# are required. We add a tag-scoped rule to allow all egress (GCP default)
# and explicitly DENY all ingress on the runner tag to reduce attack surface.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "runner_deny_ingress" {
  name    = var.firewall_name
  network = "default"

  direction = "INGRESS"
  priority  = 1000

  deny {
    protocol = "all"
  }

  # An INGRESS rule must declare a source; 0.0.0.0/0 = deny inbound from anywhere.
  source_ranges = ["0.0.0.0/0"]
  target_tags   = var.network_tags

  description = "Block all inbound traffic to self-hosted runner VMs. Runners are outbound-only."

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Instance template — the immutable blueprint every runner VM in the MIG is
# stamped from. Editing it forces a NEW template (name_prefix + CBD); the MIG
# rolls instances onto the new version via its update_policy.
# ---------------------------------------------------------------------------
resource "google_compute_instance_template" "runner" {
  name_prefix  = "${var.runner_instance_name}-"
  machine_type = local.effective_machine_type
  region       = var.region
  tags         = var.network_tags

  # min_cpu_platform pins the VM to a CPU generation. Nested virtualization
  # requires at least "Intel Haswell" (Google's documented floor for KVM
  # passthrough). Only emitted when an explicit platform is requested.
  min_cpu_platform = var.min_cpu_platform != "" ? var.min_cpu_platform : null

  disk {
    source_image = "debian-cloud/debian-12"
    disk_size_gb = local.effective_disk_size_gb
    disk_type    = local.effective_disk_type
    auto_delete  = true
    boot         = true
  }

  # Spot scheduling. GCP requires Spot VMs in a MIG to use STOP (not DELETE) as
  # the termination action; the MIG then recreates the stopped instance to hold
  # target_size. A STANDARD MIG uses var.on_host_maintenance (default MIGRATE) so
  # the runner survives host maintenance without interrupting a job. NOTE: nested
  # virt is incompatible with live migration on some families — set TERMINATE.
  # GPUs also CANNOT live-migrate: when enable_gpu is set we force TERMINATE
  # regardless of var.on_host_maintenance (GCP rejects MIGRATE on an accelerator
  # VM). With enable_gpu = false this expression is identical to before, so the
  # non-GPU consumers (bonkey-puzzles-app root, bonkey-puzzles env) are unchanged.
  scheduling {
    provisioning_model          = var.enable_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.enable_spot
    automatic_restart           = var.enable_spot ? false : true
    instance_termination_action = var.enable_spot ? "STOP" : null
    on_host_maintenance         = (var.enable_spot || var.enable_gpu) ? "TERMINATE" : var.on_host_maintenance
  }

  # Nested virtualization (KVM) — only emitted when requested. Required for a
  # hardware-accelerated Android emulator; valid only on Intel non-E2 machines.
  dynamic "advanced_machine_features" {
    for_each = var.enable_nested_virtualization ? [1] : []
    content {
      enable_nested_virtualization = true
    }
  }

  # Guest accelerator (GPU) — emitted only for machine families where the GPU is
  # ATTACHED (G2 + NVIDIA L4: gpu_count >= 1). For families where the GPU is
  # BUILT INTO the machine type — notably G4 fractional-vGPU shapes
  # (g4-standard-6 = 1/8, g4-standard-12 = 1/4 of an RTX PRO 6000) — you must NOT
  # declare guest_accelerator (a fractional count can't be expressed and GCP
  # rejects the block); set gpu_count = 0 so the machine type carries the GPU.
  # enable_gpu still drives on_host_maintenance = TERMINATE (GPUs can't
  # live-migrate) and the NVIDIA driver install regardless of gpu_count.
  # QUOTA: the GPU VM's vCPUs count against CPUS_ALL_REGIONS (24) SIMULTANEOUSLY
  # with the CI runner; also needs the matching GPU quota (NVIDIA_L4_GPUS for G2,
  # the RTX PRO 6000 quota for G4). See variables.tf and environments/graphics.
  dynamic "guest_accelerator" {
    for_each = (var.enable_gpu && var.gpu_count > 0) ? [1] : []
    content {
      type  = var.gpu_type
      count = var.gpu_count
    }
  }

  network_interface {
    network = "default"
    # Ephemeral public IP for outbound GitHub/Google access. Inbound is denied
    # by google_compute_firewall.runner_deny_ingress (target_tags = network_tags).
    access_config {}
  }

  service_account {
    email  = local.runner_sa_email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # PAT passed as metadata (sensitive). The startup/shutdown scripts read it
    # from the metadata server and NEVER echo it.
    github-runner-pat = var.github_runner_pat
    github-repo       = var.github_repo
    runner-labels     = local.runner_labels_csv
    runner-version    = var.runner_version
    # Each VM registers under its OWN instance name (unique in the MIG), so
    # runners never collide on a single registration entry.
    startup-script = templatefile("${path.module}/runner-startup.sh.tftpl", {
      runner_version = var.runner_version
      runner_arch    = var.runner_arch
      github_repo    = var.github_repo
      runner_labels  = local.runner_labels_csv
      runner_mode    = var.runner_mode
      instance_name  = var.runner_instance_name
      enable_android = var.enable_android_profile
      runners_per_vm = var.runners_per_vm
      enable_gpu     = var.enable_gpu
      # Diffusion (SDXL) bake (#562). Default OFF; guarded to GPU runners.
      enable_diffusion          = var.enable_diffusion
      diffusion_root            = var.diffusion_root
      diffusion_hf_home         = local.diffusion_hf_home_effective
      diffusion_pip_packages    = local.diffusion_pip_packages_csv
      diffusion_torch_index_url = var.diffusion_torch_index_url
      diffusion_marker          = local.diffusion_marker
    })
    # On scale-down / preemption / delete, deregister this VM's runner from
    # GitHub so the MIG doesn't leave offline "zombie" runners behind.
    shutdown-script = templatefile("${path.module}/runner-shutdown.sh.tftpl", {
      github_repo = var.github_repo
    })
  }

  labels = {
    purpose = "gh-runner"
    managed = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.runner_sa_roles,
  ]
}

# ---------------------------------------------------------------------------
# Managed Instance Group — maintains target_size runner VMs from the template.
#   - Set runner_target_size = 0 to scale to zero (no compute cost) when idle.
#   - Raise it (via tfvars + apply, or `gcloud … managed resize`) for parallel
#     CI capacity. Autoscaling on queued jobs is a follow-on (#262).
#   - Spot VMs that get preempted are recreated automatically to hold the size.
# ---------------------------------------------------------------------------
resource "google_compute_instance_group_manager" "runner" {
  count              = var.regional ? 0 : 1
  name               = var.runner_instance_name
  base_instance_name = var.runner_instance_name
  zone               = var.zone
  target_size        = var.runner_target_size

  version {
    instance_template = google_compute_instance_template.runner.id
  }

  # Runners are outbound-only with no health-check port; GitHub tracks liveness.
  # Don't block `terraform apply` waiting for instances to report healthy.
  wait_for_instances = false

  # OPPORTUNISTIC: a template change (e.g. new startup tooling) does NOT
  # proactively destroy running instances — so an in-flight CI job is never
  # interrupted by a `terraform apply`. The new template rolls in as instances
  # are naturally cycled (Spot preemption) or when an operator recreates idle
  # ones (`gcloud compute instance-groups managed rolling-action ...`).
  # When a roll DOES happen, SUBSTITUTE is build-before-destroy: a replacement
  # is created before the old instance is removed (max_unavailable = 0).
  update_policy {
    type                  = "OPPORTUNISTIC"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
    replacement_method    = "SUBSTITUTE"
  }

  # target_size is managed out-of-band (gcloud resize / future autoscaler) so we
  # can scale for bursts without terraform reverting it. Change runner_target_size
  # + apply only when you want terraform to own the baseline again.
  lifecycle {
    ignore_changes = [target_size]
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.runner_sa_roles,
  ]
}

# ---------------------------------------------------------------------------
# REGIONAL variant (var.regional = true). Places the runner VM in ANY zone of
# var.region and retries other zones on a zonal stockout / unsupported-in-zone
# error — the right shape for a GPU runner whose accelerator (e.g. NVIDIA L4) is
# only offered in SOME zones of a region (a single hardcoded zone would fail
# LOCATION_POLICY_VIOLATED / resource-not-in-zone). No explicit update_policy: a
# regional MIG's fixed surge/unavailable are constrained by the region's zone
# count, and GCP's default version-change behavior (new instances only) is
# already opportunistic — mirroring the standalone bonkey-puzzles-app root.
# ---------------------------------------------------------------------------
resource "google_compute_region_instance_group_manager" "runner" {
  count              = var.regional ? 1 : 0
  name               = var.runner_instance_name
  base_instance_name = var.runner_instance_name
  region             = var.region
  target_size        = var.runner_target_size

  # Restrict candidate zones to the accelerator-capable ones (empty list = all
  # region zones), and use ANY for scarce/Spot GPUs so a per-zone stockout falls
  # through to another capable zone instead of retry-looping on the dead zone.
  distribution_policy_zones        = length(var.distribution_policy_zones) > 0 ? var.distribution_policy_zones : null
  distribution_policy_target_shape = var.distribution_policy_target_shape

  version {
    instance_template = google_compute_instance_template.runner.id
  }

  wait_for_instances = false

  lifecycle {
    ignore_changes = [target_size]
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.runner_sa_roles,
  ]
}

# Select the active MIG (zonal or regional) for outputs. Splat + one() yields the
# single element or null without indexing a zero-count resource.
locals {
  active_mig_name  = var.regional ? one(google_compute_region_instance_group_manager.runner[*].name) : one(google_compute_instance_group_manager.runner[*].name)
  active_mig_group = var.regional ? one(google_compute_region_instance_group_manager.runner[*].instance_group) : one(google_compute_instance_group_manager.runner[*].instance_group)
  active_mig_size  = var.regional ? one(google_compute_region_instance_group_manager.runner[*].target_size) : one(google_compute_instance_group_manager.runner[*].target_size)
}
