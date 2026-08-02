output "instance_group_manager" {
  description = "Name of the Managed Instance Group that maintains the runner VMs."
  value       = local.active_mig_name
}

output "instance_group" {
  description = "Self-link of the MIG's instance group (use with gcloud to list/resize members)."
  value       = local.active_mig_group
}

output "instance_template" {
  description = "Name of the instance template the MIG stamps runner VMs from."
  value       = google_compute_instance_template.runner.name
}

output "runner_target_size" {
  description = "Current MIG target size (number of runner VMs; 0 = scaled to zero)."
  value       = local.active_mig_size
}

output "instance_zone" {
  description = "Where the MIG runs its VMs: the zone (zonal MIG) or, for a regional MIG, the region (any zone within it)."
  value       = var.regional ? var.region : var.zone
}

output "service_account_email" {
  description = "Email of the service account attached to the runner VMs."
  value       = local.runner_sa_email
}

output "runner_labels" {
  description = "Comma-separated runner labels. Use these in 'runs-on' in workflow files."
  value       = local.runner_labels_csv
}

output "runner_name_pattern" {
  description = "Pattern the runners register under (gce-<base>-<suffix>) as shown under repo Settings -> Actions -> Runners."
  value       = "gce-${var.runner_instance_name}-*"
}

output "runner_mode" {
  description = "Configured runner mode: 'persistent' (always available) or 'ephemeral' (one-shot, self-deletes)."
  value       = var.runner_mode
}

output "verify_runner_command" {
  description = "API command to confirm runners are registered and online. Requires the same PAT (GH_RUNNER_PAT) with Administration read access."
  value       = "curl -H \"Authorization: Bearer $GH_RUNNER_PAT\" https://api.github.com/repos/${var.github_repo}/actions/runners"
}

output "resize_command" {
  description = "Scale the runner MIG up/down (e.g. SIZE=0 to idle, SIZE=3 for burst) without terraform."
  value       = var.regional ? "gcloud compute instance-groups managed resize ${var.runner_instance_name} --region=${var.region} --size=SIZE --project=${var.project_id}" : "gcloud compute instance-groups managed resize ${var.runner_instance_name} --zone=${var.zone} --size=SIZE --project=${var.project_id}"
}

output "runs_on_snippet" {
  description = "Copy-paste snippet for workflow 'runs-on' to target these runners."
  value       = "runs-on: [${join(", ", [for l in var.runner_labels : "\"${l}\""])}]"
}
