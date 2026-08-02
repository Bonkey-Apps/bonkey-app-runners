terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44"
    }
  }

  # Remote state in the same private, versioned GCS bucket as the other runner
  # roots, but under a DISTINCT prefix so the graphics MIG NEVER shares state
  # with the CI runner. The bonkey-puzzles-app root uses prefix = "gcp-runner"; the
  # bonkey-puzzles root uses "gcp-runner-puzzles"; this graphics root uses
  # prefix = "gcp-runner-graphics". Disjoint prefixes => disjoint state objects:
  # applying here can never read, lock, or mutate the live bonkey-puzzles-app CI-runner
  # state — the graphics runner is a genuinely COEXISTING second MIG.
  #
  # NOTE: if your GCP credentials are not authorized for gs://bonkey-apps-tfstate
  # you can run this root with local state instead by initializing with
  # `terraform init -backend=false` (validation only) or by deleting this backend
  # block in a fork. Do NOT change the prefix to "gcp-runner" or
  # "gcp-runner-puzzles" — that would alias another root's live state.
  backend "gcs" {
    bucket = "bonkey-apps-tfstate"
    prefix = "gcp-runner-graphics"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
