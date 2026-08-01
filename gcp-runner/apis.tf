# ---------------------------------------------------------------------------
# Required Google APIs (Service Usage)
#
# These enable the project APIs the runner stack depends on. Compute, IAM and
# Resource Manager must be ON before the instance / firewall / IAM resources can
# be created — hence the depends_on wiring from those resources to this set.
#
# IMPORTANT BOOTSTRAP NOTE:
#   Enabling a service calls serviceusage.services.enable, which requires the
#   *identity running Terraform* to hold roles/serviceusage.serviceUsageAdmin
#   (or owner). Terraform cannot grant itself that right, so if your provisioning
#   service account lacks it, `apply` fails here with PERMISSION_DENIED. Run the
#   one-time bootstrap in SETUP-OWNER.md (as a project owner) first, or set
#   manage_project_services = false if a platform team enables APIs out of band.
#
#   disable_on_destroy = false so `terraform destroy` never tears down APIs that
#   other workloads in the project may rely on.
# ---------------------------------------------------------------------------
locals {
  # Google Cloud Ops Agent (#408) requires these two APIs to export host
  # metrics/logs. Unioned in as a local rather than appended to the
  # var.project_services default so this file stays self-contained.
  ops_agent_project_services = [
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = var.manage_project_services ? toset(concat(var.project_services, local.ops_agent_project_services)) : toset([])

  project = var.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}
