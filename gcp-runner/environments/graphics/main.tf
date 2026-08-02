# ---------------------------------------------------------------------------
# graphics GPU self-hosted runner (Part of #534, Epic #135).
#
# A SEPARATE, self-contained deployment of the reusable runner-MIG module
# (../../modules/runner-mig), registered to Bonkey-Apps/bonkey-puzzles-app for
# GPU/graphics workloads. The GPU shape is PARAMETERIZED (var.machine_type /
# gpu_type / gpu_count / boot_disk_*) — the deploy workflow's graphics_machine
# input selects among g2-standard-4/8 (NVIDIA L4) and g4-standard-6/12 (NVIDIA
# RTX PRO 6000); defaults = g2-standard-8 + L4. This root has its OWN state (GCS
# backend prefix "gcp-runner-graphics" in versions.tf) and NEVER touches the live
# bonkey-puzzles-app CI-runner root or its state — the two MIGs COEXIST. Deploying
# graphics can never replace the CI runner.
#
# LEAVES FREE TIER — billed, and needs an NVIDIA_L4_GPUS quota grant. Provisions
# nothing until an owner runs `terraform apply` (via the deploy workflow with
# confirm=DEPLOY) AFTER the quota grant.
#
# ⚠️ The module's NVIDIA driver install path is APPLY-TIME-UNVERIFIED (no GPU in
# CI, no apply here) — validate `nvidia-smi` reports the L4 on the first real
# provision. See the module's runner-startup.sh.tftpl and the README.
#
# QUOTA (CPUS_ALL_REGIONS = 24, shared across ALL fleets/states): g2-standard-8
# = 8 vCPU, counted SIMULTANEOUSLY with the CI-runner MIG's vCPUs. Keep
# (CI runner vCPUs) + 8 <= 24. Resize this MIG to 0 when idle to stop billing.
# ---------------------------------------------------------------------------
module "runner" {
  source = "../../modules/runner-mig"

  # Target repo — registration is repo-scoped to bonkey-puzzles-app (same repo the CI
  # runner serves), using the same GH_RUNNER_PAT (Administration: read+write).
  github_repo       = "Bonkey-Apps/bonkey-puzzles-app"
  github_runner_pat = var.github_runner_pat

  # Project / location. G2 + L4 availability is NARROWER than T4 — pick a
  # region/zone where g2-standard-8 + NVIDIA L4 both exist (default us-central1).
  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  # ---- GPU / graphics shape (parameterized; the deploy workflow's
  # graphics_machine input maps a chosen shape to these vars) ----
  #   g2-standard-4 / g2-standard-8 → 1× NVIDIA L4 (24 GB), pd-balanced
  #   g4-standard-6 / g4-standard-12 → NVIDIA RTX PRO 6000 (Blackwell) — VERIFY
  #     the accelerator type string, per-shape GPU count, and disk requirement.
  machine_type      = var.machine_type
  enable_gpu        = true
  gpu_type          = var.gpu_type
  gpu_count         = var.gpu_count
  boot_disk_size_gb = var.boot_disk_size_gb
  boot_disk_type    = var.boot_disk_type

  # Pre-bake the pinned SDXL diffusion stack (torch+CUDA/diffusers/… == #561's
  # tools/spritegen/py/requirements.txt) into a persistent venv so the
  # spritegen.yml install is a fast no-op on a baked runner (#562). This is the
  # ONLY env that opts in — the module default is OFF, so the CI-runner root and
  # the bonkey-puzzles env never install it. The module's startup block also
  # double-guards on enable_gpu = true. Bake pins live in the module's
  # diffusion_pip_packages default; bump them in lockstep with #561 (see
  # docs/migration/562-bake-diffusion-stack.md). APPLY-TIME-UNVERIFIED (no GPU in
  # CI) — validate torch.cuda.is_available()==True + import diffusers on the first
  # real provision, same as the NVIDIA driver caveat.
  enable_diffusion = true

  # REGIONAL MIG: place the runner in ANY zone of var.region, not a hardcoded
  # <region>-a. NVIDIA L4 is only offered in SOME zones of a region (e.g. in
  # us-east1 it is in -c/-d, not -a), so a zonal MIG pinned to <region>-a fails
  # `LOCATION_POLICY_VIOLATED` / resource-not-in-zone. Regional lets GCP pick an
  # L4-capable zone and retry others on stockout — matching the CI runner root.
  regional = true

  # Pin the candidate zones to the accelerator-capable ones and use ANY target
  # shape so a Spot L4 stockout in one zone ("does not have enough resources")
  # falls through to the OTHER capable zone instead of retry-looping on the dead
  # one — and never attempts a no-GPU zone (us-east1-a/-b). Set per region/GPU
  # family by the deploy workflow.
  distribution_policy_zones        = var.distribution_policy_zones
  distribution_policy_target_shape = var.distribution_policy_target_shape

  # On-demand only — GCE deployments no longer run a standing GPU runner.
  # Resize up deliberately before a generation run (see resize_command output /
  # runner_target_size var) and back to 0 after, rather than idling billed GPU
  # time. NOTE: the generation workflow previously assumed an always-available
  # runner; if it doesn't already handle "no runner yet" it needs a resize-up
  # step added as a follow-up.
  runner_mode        = "ephemeral"
  runner_target_size = var.runner_target_size

  # ONE agent only — the module default is 3 concurrent jobs per VM, but this VM
  # has a single L4 GPU; parallel sprite-gen jobs would contend for the one GPU.
  # Keep it to a single job at a time.
  runners_per_vm = 1

  # Distinct identity from the CI runner and the puzzles runner. Labels advertise
  # GPU capability so a job targets it with runs-on: [self-hosted, linux, x64, gpu].
  runner_instance_name = "graphics-github-runner"
  runner_labels        = ["self-hosted", "linux", "x64", "gpu", "graphics", "l4", "cuda"]
  network_tags         = ["graphics-github-runner"]

  # The module's firewall name is hardcoded-by-default and the SA is created-by-
  # default — both would 409 against the CI runner's identically-named resources
  # already in this project (separate Terraform STATE does not isolate GCP resource
  # NAMES). Give the graphics deploy a UNIQUE firewall name; the shared SA is reused
  # below rather than recreated.
  firewall_name = "graphics-github-runner-deny-ingress"

  # g2 is x64; no Android profile, no nested virt. on_host_maintenance is forced
  # to TERMINATE by the module whenever enable_gpu = true (GPUs can't live-migrate).
  runner_arch            = "x64"
  runner_version         = var.runner_version
  enable_android_profile = false
  # Spot (preemptible) GPU VM — cheapest option for occasional sprite generation.
  # GPUs already force on_host_maintenance=TERMINATE; the module sets
  # provisioning_model=SPOT + instance_termination_action=STOP, so a preempted VM
  # is STOPPED and the MIG recreates it to hold target_size — it does NOT auto-
  # restart in place. Tradeoff: a generation run in flight when preemption hits
  # must be re-dispatched (don't rely on the same VM surviving to finish/clean up).
  # Set enable_spot=false for zero-gap availability.
  enable_spot = true

  # SA / API / IAM management. Default OFF: assume the owner enabled APIs and
  # granted the SA roles out of band (see SETUP-OWNER.md). Flip on only if the
  # provisioning identity holds serviceUsageAdmin / projectIamAdmin.
  # Reuse the EXISTING shared runner SA (gh-runner-sa) that the CI-runner deploy
  # already created and role-granted, instead of recreating it (which 409s).
  # Override with TF_VAR_service_account_email to attach a dedicated SA instead.
  service_account_email   = var.service_account_email != "" ? var.service_account_email : "gh-runner-sa@${var.project_id}.iam.gserviceaccount.com"
  manage_project_services = var.manage_project_services
  manage_project_iam      = var.manage_project_iam
}
