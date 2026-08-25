---
name: get-runner-pat
description: Fetch the GH_PAT used by docker-runner (and GHCR login) from GCP Secret Manager. Use when setting up docker-runner/.env, when GH_PAT is missing/expired, or when a `docker compose pull` from ghcr.io/bonkey-apps fails with "unauthorized".
---

# Get the runner PAT

The org runner-admin PAT lives in **GCP Secret Manager**, project `bonkey-apps`,
secret name **`CI_RUNNER_PAT`** (there's also a `GH_RUNNER_PAT` secret in the
same project — it looks like a match by name but `CI_RUNNER_PAT` is the one
confirmed to work for both runner registration and GHCR pulls).

## Prerequisites

- `gcloud` CLI installed (`winget install --id Google.CloudSDK -e`) and on PATH.
  It also requires a real Python install — the Windows Store `python.exe` stub
  does not work; install one with `winget install --id Python.Python.3.12 -e --scope user`
  if `gcloud` complains "Python was not found".
- Authenticated with an account that has access to the `bonkey-apps` GCP
  project — `larrygenelanejr@gmail.com` does NOT have access; use
  `bonkey.apps@gmail.com` instead:
  ```
  gcloud auth login --no-launch-browser
  gcloud config set project bonkey-apps
  ```
  (`--no-launch-browser` is interactive — it prints a URL to open and asks you
  to paste back a verification code, so run it directly in your own terminal,
  not through a tool that can't handle interactive prompts.)

## Fetch the secret

```bash
gcloud secrets versions access latest --secret=CI_RUNNER_PAT --project bonkey-apps
```

To drop it straight into `docker-runner/.env` as `GH_PAT`:

```powershell
$token = gcloud secrets versions access latest --secret=CI_RUNNER_PAT --project bonkey-apps
$example = Get-Content "docker-runner\.env.example" -Raw
$envContent = $example -replace '(?m)^GH_PAT=\r?$', "GH_PAT=$token"
Set-Content -Path "docker-runner\.env" -Value $envContent -NoNewline -Encoding utf8
```

(Note the `\r?` in the regex — `.env.example` has CRLF line endings, so a
plain `$` anchor after `GH_PAT=` fails to match and silently leaves the line
empty.)

## Same token unlocks GHCR pulls

If `docker compose pull` fails with `unauthorized` on
`ghcr.io/bonkey-apps/bonkey-apps-runner`, it's because Docker has no stored
GHCR credentials — the PAT in `.env` was never presented to the registry.
Log in once with the same token:

```bash
grep "^GH_PAT=" docker-runner/.env | cut -d'=' -f2 | docker login ghcr.io -u bonkey-apps --password-stdin
```

Username `bonkey-apps` matches the org PAT's owning account. After that,
`docker compose pull` succeeds and there's no need to fall back to
`docker compose up --build -d` (slower local build).
