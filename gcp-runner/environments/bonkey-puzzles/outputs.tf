# Re-export the module's outputs at the root so `terraform output` surfaces the
# runner identity, verify command, and runs-on snippet for the operator.

output "instance_group_manager" {
  description = "Name of the Managed Instance Group that maintains the bonkey-puzzles runner VM."
  value       = module.runner.instance_group_manager
}

output "instance_group" {
  description = "Self-link of the MIG's instance group (use with gcloud to list/resize members)."
  value       = module.runner.instance_group
}

output "instance_template" {
  description = "Name of the instance template the MIG stamps runner VMs from."
  value       = module.runner.instance_template
}

output "runner_target_size" {
  description = "Current MIG target size (number of runner VMs; 1 for this free-tier deployment)."
  value       = module.runner.runner_target_size
}

output "instance_zone" {
  description = "Zone where the MIG runs its runner VM."
  value       = module.runner.instance_zone
}

output "service_account_email" {
  description = "Email of the service account attached to the runner VM."
  value       = module.runner.service_account_email
}

output "runner_labels" {
  description = "Comma-separated runner labels. Use these in 'runs-on' in bonkey-puzzles workflows."
  value       = module.runner.runner_labels
}

output "runner_name_pattern" {
  description = "Pattern the runners register under, as shown under bonkey-puzzles -> Settings -> Actions -> Runners."
  value       = module.runner.runner_name_pattern
}

output "runner_mode" {
  description = "Configured runner mode ('persistent')."
  value       = module.runner.runner_mode
}

output "verify_runner_command" {
  description = "API command to confirm the runner is registered and online against bonkey-puzzles (needs a bonkey-puzzles-scoped PAT with Administration read)."
  value       = module.runner.verify_runner_command
}

output "resize_command" {
  description = "Scale the runner MIG up/down without terraform."
  value       = module.runner.resize_command
}

output "runs_on_snippet" {
  description = "Copy-paste snippet for the bonkey-puzzles Pages-deploy job's 'runs-on'."
  value       = module.runner.runs_on_snippet
}
