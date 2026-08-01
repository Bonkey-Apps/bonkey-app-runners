# ---------------------------------------------------------------------------
# bonkey-puzzles free-tier self-hosted runner.
#
# A SECOND, self-contained deployment of the reusable runner-MIG module
# (../../modules/runner-mig), registered to Bonkey-Apps/bonkey-puzzles and sized
# for the GCP Always-Free tier. This root has its OWN state (GCS backend prefix
# "gcp-runner-puzzles" in versions.tf) and never touches the live bonkey-puzzles-app
# root or its state.
#
# Purpose: give bonkey-puzzles' LIGHT GitHub Pages deploy job a runner. The heavy
# Expo web export stays on the billed bonkey-puzzles-app runner — do NOT run heavy
# builds here (e2-micro has only 1 GB RAM).
# ---------------------------------------------------------------------------
module "runner" {
  source = "../../modules/runner-mig"

  # Target repo — registration is repo-scoped to bonkey-puzzles. Requires a
  # bonkey-puzzles-scoped PAT (Administration: read+write); the bonkey-puzzles-app
  # GH_RUNNER_PAT will NOT work here.
  github_repo       = "Bonkey-Apps/bonkey-puzzles"
  github_runner_pat = var.github_runner_pat

  # Project / location.
  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  # ---- Always-Free shape (do not change without leaving the free tier) ----
  machine_type      = "e2-micro"    # Always Free machine type (1 per account, us regions)
  boot_disk_size_gb = 30            # Always Free standard-PD allowance
  boot_disk_type    = "pd-standard" # pd-ssd LEAVES FREE TIER — billed

  # On-demand only — GCE deployments no longer run a standing fleet. Provision
  # via scripts/runner-up.sh (or a deliberate temporary resize) when the Pages
  # deploy job actually needs a target, rather than paying to idle between runs.
  runner_mode        = "ephemeral"
  runner_target_size = 0

  # ONE agent only — the module default is 3 concurrent jobs per VM, but an
  # e2-micro has just 1 GB RAM and cannot run parallel jobs without OOMing. The
  # light Pages deploy runs one job at a time here.
  runners_per_vm = 1

  # Distinct identity from the bonkey-puzzles-app runner.
  runner_instance_name = "gh-runner-puzzles"
  runner_labels        = ["self-hosted", "linux", "x64", "gce-free", "bonkey-puzzles"]
  network_tags         = ["gh-runner-puzzles"]

  # e2-micro is x64; no Android profile, no nested virt, no Spot (we want a
  # standing free-tier runner that survives host maintenance via live migration).
  runner_arch            = "x64"
  runner_version         = var.runner_version
  enable_android_profile = false
  enable_spot            = false

  # SA / API / IAM management. Default OFF: assume the owner enabled APIs and
  # granted the SA roles out of band (see SETUP-OWNER.md). Flip on only if the
  # provisioning identity holds serviceUsageAdmin / projectIamAdmin.
  service_account_email   = var.service_account_email
  manage_project_services = var.manage_project_services
  manage_project_iam      = var.manage_project_iam
}
