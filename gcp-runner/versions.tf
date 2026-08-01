terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44"
    }
  }

  # Remote state in a private, versioned GCS bucket. This is the correct way to
  # persist/share Terraform state — NOT git: state stores secrets (the runner
  # PAT, etc.) in plaintext, so it must never be committed. The bucket has object
  # versioning enabled for history/rollback and is encrypted at rest by GCP.
  # Bootstrap (one-time, already done):
  #   gcloud storage buckets create gs://bonkey-apps-tfstate \
  #     --location=us-central1 --uniform-bucket-level-access --public-access-prevention
  #   gcloud storage buckets update gs://bonkey-apps-tfstate --versioning
  backend "gcs" {
    bucket = "bonkey-apps-tfstate"
    prefix = "gcp-runner"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  # No default zone: the runner MIG is REGIONAL (any zone in var.region). There
  # are no zonal resources left that would need a provider-default zone.
}
