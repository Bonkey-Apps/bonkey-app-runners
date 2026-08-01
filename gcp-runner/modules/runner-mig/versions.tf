# ---------------------------------------------------------------------------
# Provider requirements for the reusable runner-MIG module.
#
# A child module declares the providers it needs (so version constraints
# resolve) but MUST NOT declare a `backend` or a `provider` block — those belong
# to the calling root. Each root configures the google provider and its own
# state backend, then passes config into this module via variables.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44"
    }
  }
}
