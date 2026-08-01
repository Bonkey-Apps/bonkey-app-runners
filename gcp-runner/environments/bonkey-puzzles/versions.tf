terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44"
    }
  }

  # Remote state in the same private, versioned GCS bucket as the bonkey-puzzles-app
  # runner, but under a DISTINCT prefix so the two roots NEVER share state. The
  # bonkey-puzzles-app root uses prefix = "gcp-runner"; this bonkey-puzzles root uses
  # prefix = "gcp-runner-puzzles". Disjoint prefixes => disjoint state objects:
  # applying here can never read, lock, or mutate the live bonkey-puzzles-app state.
  #
  # NOTE: if your GCP credentials are not authorized for gs://bonkey-apps-tfstate
  # you can run this root with local state instead by initializing with
  # `terraform init -backend=false` (validation only) or by deleting this backend
  # block in a fork. Do NOT change the prefix to "gcp-runner" — that would alias
  # the live bonkey-puzzles-app state.
  backend "gcs" {
    bucket = "bonkey-apps-tfstate"
    prefix = "gcp-runner-puzzles"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
