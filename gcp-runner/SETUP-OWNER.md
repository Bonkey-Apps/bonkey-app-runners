# One-time owner bootstrap — GCE runner on project `bonkey-apps`

Terraform cannot grant itself the rights needed to **enable APIs** or **set IAM**.
A project **owner** must do that bootstrap once; afterwards the provisioning
service account can run `terraform apply` on its own.

This documents the **x86 Spot + KVM Android-emulator** profile actually deployed
(see `terraform.tfvars`): `c3-standard-4`, Spot/preemptible, nested virtualization
on, `pd-balanced` 120 GB, persistent runner registered to `Bonkey-Apps/bonkey-puzzles-app`.

## Why these can't be done by Terraform's own SA

| Action | Permission required | `github@` SA had it? |
|--------|--------------------|----------------------|
| Enable a Google API | `serviceusage.services.enable` (serviceUsageAdmin / editor) | ❌ (403) until Editor granted |
| Grant project IAM | `resourcemanager.projects.setIamPolicy` (projectIamAdmin / owner) | ❌ (Editor alone can't either) |
| Create VM + firewall | `compute.admin` (or instanceAdmin.v1 + securityAdmin) | ✅ |
| Attach SA to VM | `iam.serviceAccounts.actAs` | ✅ |

## Bootstrap options

### Option A — run the helper script (as an owner)

```bash
# Authenticate as a project owner first (interactive):
#   ! gcloud auth login
cd gcp-runner
./bootstrap-owner.sh bonkey-apps github@bonkey-apps.iam.gserviceaccount.com [BILLING_ACCOUNT_ID]
```

It enables the required APIs, grants the provisioning SA `roles/compute.admin`
and `roles/iam.serviceAccountUser`, and (if you pass a billing account) links
billing. With APIs pre-enabled this way you can keep `manage_project_services =
false` in tfvars.

### Option B — temporary Editor (what we used)

A short-lived `roles/editor` grant on the provisioning SA lets **Terraform itself**
enable the APIs in-run (`manage_project_services = true`). Because
`google_project_service` uses `disable_on_destroy = false`, the APIs **stay
enabled after you revoke Editor**. Editor still can't `setIamPolicy`, so
`manage_project_iam` stays `false` — a persistent runner needs no extra runner-SA
roles to run CI.

```bash
# grant (owner):
gcloud projects add-iam-policy-binding bonkey-apps \
  --member="serviceAccount:github@bonkey-apps.iam.gserviceaccount.com" \
  --role="roles/editor" --condition=None
# ... terraform apply ...
# revoke afterwards:
gcloud projects remove-iam-policy-binding bonkey-apps \
  --member="serviceAccount:github@bonkey-apps.iam.gserviceaccount.com" \
  --role="roles/editor" --condition=None
```

After revoking Editor, the SA retains only `compute.admin` + `iam.serviceAccountUser`
(if you granted them) which is all a persistent runner re-apply needs. The
already-enabled APIs are read-only reconciled (no re-enable call) on future plans.

## Billing

`c3-standard-4` + Spot are **billable** (this profile leaves the Always-Free
tier). The project must be linked to a billing account or `instances.insert`
fails. Confirm:

```bash
gcloud beta billing projects describe bonkey-apps
```

## Secrets / credentials used

- **GCP creds:** `GOOGLE_CREDENTIALS="$(cat .secrets/bonkey-apps-5fcff7f25ad3.json)"`
  (the `github@` SA key). The `*-playstore@` key and the `client_secret_*.json`
  OAuth files are unrelated to this stack.
- **Runner PAT:** `TF_VAR_github_runner_pat` — a GitHub token with repo
  **Administration: read+write**. Here it comes from the `GIT_TOKEN` Codespaces/
  Actions secret. Never commit it; it lives only in env + (encrypted) VM metadata.

## State

State is stored in the **GCS backend** `gs://bonkey-apps-tfstate/gcp-runner/`
(versioned, private). State is **never** committed to git — it holds the PAT and
other secrets in plaintext (`*.tfstate` is gitignored).
