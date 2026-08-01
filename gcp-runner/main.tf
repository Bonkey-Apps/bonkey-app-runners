# ---------------------------------------------------------------------------
# Locals: resolve Android profile overrides
# ---------------------------------------------------------------------------
locals {
  effective_machine_type = var.enable_android_profile ? var.android_machine_type : var.machine_type
  effective_disk_size_gb = var.enable_android_profile ? var.android_disk_size_gb : var.boot_disk_size_gb
  effective_disk_type    = var.enable_android_profile ? var.android_disk_type : var.boot_disk_type
  create_service_account = var.service_account_email == ""
  runner_labels_csv      = join(",", var.runner_labels)

  # Registration scope. When github_org is set (the default), runners register at
  # the ORG level so one fleet serves every repo in the org; otherwise they fall
  # back to repo-scoped registration via github_repo. These two derived values are
  # all the startup/shutdown scripts need:
  #   github_api_scope — the api.github.com path segment: "orgs/<org>" or
  #                      "repos/<owner>/<repo>" (used for the registration-token
  #                      mint and the runner list/delete calls).
  #   github_scope_url — the config.sh --url: https://github.com/<org> or
  #                      https://github.com/<owner>/<repo>.
  registration_is_org = var.github_org != ""
  github_api_scope    = local.registration_is_org ? "orgs/${var.github_org}" : "repos/${var.github_repo}"
  github_scope_url    = local.registration_is_org ? "https://github.com/${var.github_org}" : "https://github.com/${var.github_repo}"
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
# *.actions.githubusercontent.com, etc.) and Google APIs. We DENY all ingress on
# the runner tag to reduce attack surface, then (when enable_ssh_ingress = true,
# the default) allow ONLY tcp/22 from the configured ssh_source_ranges — by
# default Google's IAP TCP-forwarding range — via a higher-priority rule, so you
# can SSH in for debugging without exposing port 22 to the public internet.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "runner_deny_ingress" {
  name    = "gh-runner-deny-ingress"
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

# Allow SSH (tcp/22) INTO the runner VMs so you can `gcloud compute ssh
# --tunnel-through-iap <vm>` or use the Cloud Console SSH button for debugging
# (e.g. checking /dev/kvm on the emulator runner). Priority 900 < the deny rule's
# 1000, so SSH is permitted while every other inbound stays denied. Default
# source is Google's IAP TCP-forwarding range (35.235.240.0/20) — no public
# port-22 exposure; add your own CIDR to ssh_source_ranges for direct SSH over
# the VM's external IP.
resource "google_compute_firewall" "runner_allow_ssh" {
  count   = var.enable_ssh_ingress ? 1 : 0
  name    = "gh-runner-allow-ssh"
  network = "default"

  direction = "INGRESS"
  priority  = 900

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = var.network_tags

  description = "Allow SSH (tcp/22) to runner VMs from ssh_source_ranges (default: Google IAP range). Overrides the deny-all ingress for port 22 only."

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
  scheduling {
    provisioning_model          = var.enable_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.enable_spot
    automatic_restart           = var.enable_spot ? false : true
    instance_termination_action = var.enable_spot ? "STOP" : null
    on_host_maintenance         = var.enable_spot ? "TERMINATE" : var.on_host_maintenance
  }

  # Nested virtualization (KVM) — only emitted when requested. Required for a
  # hardware-accelerated Android emulator; valid only on Intel non-E2 machines.
  dynamic "advanced_machine_features" {
    for_each = var.enable_nested_virtualization ? [1] : []
    content {
      enable_nested_virtualization = true
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
    # Informational metadata: the resolved registration scope (org or owner/repo).
    github-scope   = local.registration_is_org ? var.github_org : var.github_repo
    runner-labels  = local.runner_labels_csv
    runner-version = var.runner_version
    # Each VM registers under its OWN instance name (unique in the MIG), so
    # runners never collide on a single registration entry.
    startup-script = templatefile("${path.module}/runner-startup.sh.tftpl", {
      runner_version   = var.runner_version
      runner_arch      = var.runner_arch
      github_scope_url = local.github_scope_url
      github_api_scope = local.github_api_scope
      runner_labels    = local.runner_labels_csv
      runner_mode      = var.runner_mode
      instance_name    = var.runner_instance_name
      enable_android   = var.enable_android_profile
      runners_per_vm   = var.runners_per_vm
    })
    # On scale-down / preemption / delete, deregister this VM's runner from
    # GitHub so the MIG doesn't leave offline "zombie" runners behind.
    shutdown-script = templatefile("${path.module}/runner-shutdown.sh.tftpl", {
      github_api_scope = local.github_api_scope
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
# REGIONAL Managed Instance Group — maintains target_size runner VMs from the
# template, placing them in ANY zone of var.region. Only the REGION is pinned;
# GCP picks the zone(s) and retries other zones on a zonal capacity stockout
# (distribution_policy_zones is omitted → all zones in the region are eligible).
#   - Set runner_target_size = 0 to scale to zero (no compute cost) when idle.
#   - Raise it (via tfvars + apply, or `gcloud … managed resize --region`) for
#     parallel CI capacity. Autoscaling on queued jobs is a follow-on (#262).
#   - Spot VMs that get preempted are recreated automatically to hold the size.
#
# NOTE (cross-region): a MIG lives in ONE region — it cannot fail over to another
# region on its own. To move regions, change var.region (validated to the allowed
# set) and re-apply; that REPLACES the MIG in the new region.
#
# No explicit update_policy: a regional MIG's fixed max_surge/max_unavailable are
# constrained by the region's zone count, and GCP's DEFAULT version-change
# behavior is already opportunistic (a template change is applied to NEW instances
# only, never proactively tearing down a running job — an operator triggers a
# rolling update explicitly if desired). Omitting it keeps that safe default
# without coupling to per-region zone counts.
# ---------------------------------------------------------------------------
resource "google_compute_region_instance_group_manager" "runner" {
  name               = var.runner_instance_name
  base_instance_name = var.runner_instance_name
  description        = "bonkey-puzzles-app runners"
  region             = var.region
  target_size        = var.runner_target_size

  version {
    instance_template = google_compute_instance_template.runner.id
  }

  # Runners are outbound-only with no health-check port; GitHub tracks liveness.
  # Don't block `terraform apply` waiting for instances to report healthy.
  wait_for_instances = false

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
