# Runner image manifest — baked toolchain (auditable, pinned)

Auditable record of what the self-hosted GCE runners have **pre-installed** so
workflows don't install it inline per job. This is the interim, startup-script
form of the **golden image (#262)** and the pinned record for the
**bake-list (#267)**. Every row is version-pinned per the CLAUDE.md Actions
security policy; no secrets/telemetry are baked (ADR 0001).

While the golden image (#262) is not yet built, these bakes are applied by the
runner **startup script** (`modules/runner-mig/runner-startup.sh.tftpl`), guarded
by per-profile toggles so each runner only installs what it needs.

## CI toolchain — all runners (#262/#267)

Baked unconditionally on every runner so the per-job setup steps become fast
no-ops. Each row's inline installer still runs as a fallback (idempotent), so a
bake miss degrades to today's behavior rather than breaking a job.

| Component | Pinned version | Baked to | Exposed to jobs via | Replaces per-job step |
|---|---|---|---|---|
| Node.js | `24.x` (NodeSource) | system | PATH | (already baked) |
| pnpm | `10.33.0` (== `packageManager`) | global npm | PATH | `setup-js` on-box check |
| Playwright system libs | `chromium` deps (`playwright install-deps`) | system | — | (already baked) |
| **GitHub CLI (`gh`)** | apt `stable` channel | system | PATH | `./.github/actions/ensure-gh` |
| **Playwright Chromium browser** | keyed to `@playwright/test` — **`1.62.1` _and_ `1.61.1`, both baked** | `/opt/pw-browsers` (one `chromium-<rev>/` per version) | `PLAYWRIGHT_BROWSERS_PATH` (runner `.env`) | `playwright install chromium` (ci-web-e2e, ci-screenshots) |
| **Docker Engine** | Debian 12 apt (`docker.io`) | system | PATH; `runner` user in the `docker` group | any job shelling out to `docker`, incl. `build-docker-runner-image.yml` |

**Playwright is baked once per pin in use across the app repos, not once
overall** (BC-132). Playwright resolves its browser by *revision* —
`playwright install` writes `chromium-<rev>/` and leaves no version-agnostic
`chromium` entry — and the per-job `playwright install` is banned by repo rule,
so a runner carrying exactly one revision hard-fails e2e for every repo pinned
to a different `@playwright/test`. These runners serve all three app repos and
the repos drift apart during an upgrade: `bonkey-cards-app` is on `1.62.1`
while `bonkey-puzzles-app` and `bonkey-math-app` are still on `1.61.1`.

The list lives in `PLAYWRIGHT_VERSIONS` in **both** `runner-startup.sh.tftpl`
copies (root and `modules/runner-mig/`) and as
`PLAYWRIGHT_VERSION` / `PLAYWRIGHT_VERSION_PREV` in
`docker-runner/Dockerfile`. **Add** an entry when a repo moves to a new pin;
**remove** one only once no repo pins it. The per-version marker
(`/opt/pw-browsers/.baked-<ver>`) makes each bake idempotent and forces a
re-bake when a version is added.

## Android SDK + emulator — `enable_android` runners only (#262/#267)

Baked only when `enable_android = true` (the KVM/emulator profile). Turns the
`./.github/actions/setup-android-build` SDK bootstrap AND
`reactivecircus/android-emulator-runner`'s SDK/system-image install into a warm
no-op (both honor `ANDROID_SDK_ROOT`/`ANDROID_HOME`, exported via the runner
`.env`). The Android Gradle Plugin still auto-downloads any extra
platform/build-tools a project declares. **APPLY-TIME-UNVERIFIED** (no Android
SDK/KVM in CI).

| Package | Pin | Notes |
|---|---|---|
| command-line tools | `commandlinetools-linux-14742923_latest.zip` | same build as `setup-android-build`; extracted with the python stdlib (no `unzip`) |
| platform-tools | latest via sdkmanager | `adb` etc. |
| platforms;android-34 | API 34 | matches the emulator/target below |
| build-tools;34.0.0 | 34.0.0 | best-effort; AGP pulls the project's exact version if different |
| emulator | latest via sdkmanager | headless KVM emulator |
| system-images;android-34;google_apis;x86_64 | API 34 · google_apis · x86_64 | **matches `maestro-e2e.yml`'s `android-emulator-runner` (api-level 34 / google_apis / x86_64)** — the ~1.5 GB download this bake eliminates per job |

Baked to `/opt/android-sdk` (runner-owned). Bump the emulator API/target here in
lockstep with `maestro-e2e.yml`'s `android-emulator-runner` inputs.

## Diffusion / SDXL sprite-gen stack (graphics GPU runner only) — #562

Guarded by `enable_diffusion = true` **and** `enable_gpu = true`; opted in **only**
by `environments/graphics`. The CI-runner root and the `bonkey-puzzles` env leave
`enable_diffusion` at its module default of `false`, so they never install this.

Baked into a persistent venv at `/opt/spritegen/venv` (boot disk, survives a Spot
stop/restart). **Source of truth: `tools/spritegen/py/requirements.txt` (#561,
#585)** — these pins MUST match that file; bump both in lockstep.

| Package | Pinned version | Notes |
|---|---|---|
| torch | `2.5.1` | cu124 wheel via `--extra-index-url https://download.pytorch.org/whl/cu124` (bundles the CUDA 12.4 runtime; no separate `cuda-toolkit`) |
| diffusers | `0.31.0` | ships `load_ip_adapter` / `set_ip_adapter_scale` (#585) — no new dep for IP-Adapter |
| transformers | `4.46.3` | provides `CLIPVisionModelWithProjection` — the ViT-H image encoder diffusers auto-loads for `ip-adapter-plus_sdxl_vit-h` |
| accelerate | `1.1.1` | |
| safetensors | `0.4.5` | |
| Pillow | `11.0.0` | (#585) `generate.py` opens the reference image via `PIL.Image` directly (also a transitive diffusers dep) |
| peft | `0.13.2` | (#594) LoRA adapter on the UNet for `train_lora.py`; also loads the trained LoRA in `generate.py` |
| bitsandbytes | `0.44.1` | (#594) 8-bit Adam optimizer — keeps LoRA training within the L4's 24 GB VRAM. **CUDA-specific**; installs only on the GPU runner |
| numpy | `2.1.3` | (#594) used directly by `train_lora.py`'s latent pipeline (also a transitive torch/diffusers dep) |
| rembg | `2.0.59` | (Epic #135 follow-up) transparent-background matting — `generate.py` alpha-cuts each frame to a clean RGBA cutout via u2net. Imported lazily; JS CI (no onnx/GPU) is unaffected |
| onnxruntime | `1.20.1` | (Epic #135 follow-up) rembg/u2net inference backend. **CPU build on purpose** — u2net matting is light, and CPU onnxruntime avoids CUDA/cuDNN coupling with the torch cu124 pin (onnxruntime-gpu would need a matching CUDA runtime and can conflict) |

Supporting bake (already present via `enable_gpu`):

| Component | Pin / source | Notes |
|---|---|---|
| NVIDIA `cuda-drivers` | NVIDIA Debian 12 CUDA repo (`cuda-keyring_1.1-1`) | kernel driver + userspace (`nvidia-smi`); DKMS-built. APPLY-TIME-UNVERIFIED. |
| Persistent HF cache | `HF_HOME=/opt/spritegen/hf-cache` | Model weights cached on the boot disk; exported to jobs via the runner `.env`. See the model table below. |
| Persistent pip cache | `PIP_CACHE_DIR=/opt/spritegen/pip-cache` | baked wheels; makes the workflow fallback install offline/fast. |
| rembg u2net cache | `~/.u2net` (rembg default) | The ~176 MB u2net matting model downloads here on the first generation and is reused after; the workflow also caches it via `actions/cache`. Negligible vs the disk budget below. |

### HF-cached model weights (graphics runner, #585)

Pulled once into `HF_HOME` on the first generation and reused on every later run
(no per-job re-download). All three are OPEN — **no `HF_TOKEN`** for the defaults.

| Model | HF id / weight | Approx size | Role |
|---|---|---|---|
| Base checkpoint | `Lykon/dreamshaper-xl-1-0` | ~7 GB (fp16 SDXL) | plush/3D-cartoon SDXL render (#585, replaces SDXL-base as the default) |
| IP-Adapter | `h94/IP-Adapter` → `sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors` | ~1 GB | identity lock to the Bonkey reference image |
| CLIP image encoder | `h94/IP-Adapter` → `models/image_encoder` (ViT-H) | ~2.5 GB | auto-loaded by diffusers for the plus/vit-h IP-Adapter |
| SDXL-base (fallback) | `stabilityai/stable-diffusion-xl-base-1.0` | ~7 GB | only pulled if the `SPRITEGEN_DISABLE_IP_ADAPTER` fallback path is exercised |

The default stack (DreamShaperXL + IP-Adapter + encoder) is **~10.5 GB**; the
optional SDXL-base fallback adds ~7 GB only if used.

**Disk:** graphics boot disk is 100 GB pd-balanced. Base ~4 GB + driver ~3 GB +
venv ~10 GB + pip cache ~6 GB + **default model weights ~10.5 GB** (DreamShaperXL
~7 GB + IP-Adapter ~1 GB + ViT-H encoder ~2.5 GB) + **u2net matte model ~176 MB**
≈ **~34 GB**, leaving ~66 GB headroom. Even with the optional SDXL-base fallback
(+~7 GB) it is **~41 GB** / ~59 GB headroom — comfortably within the 100 GB
budget (rembg adds a couple GB of CPU-onnx wheels to the venv + the ~176 MB
model — immaterial here).

**LoRA training (#594).** `train_lora.py` reuses the same base checkpoint (no new
model download) plus the training deps above (peft/bitsandbytes/datasets add
~1–2 GB to the venv). **VRAM:** SDXL LoRA at rank 16, resolution 1024, batch 1
with gradient checkpointing + 8-bit Adam fits within the L4's **24 GB**. **Disk:**
the trained `bonkey-lora.safetensors` output is **~50–120 MB** (uploaded as a
workflow artifact, not baked). No net change to the disk budget above.

**Validation (apply-time, on the live L4 runner — no GPU in CI):**

```
sudo -u runner /opt/spritegen/venv/bin/python - <<'PY'
import torch, diffusers
print("torch", torch.__version__, "diffusers", diffusers.__version__,
      "cuda", torch.cuda.is_available())
PY
```

Expect `cuda True`. The bake's own import check logs but never fails boot.

**Bump procedure:** edit `tools/spritegen/py/requirements.txt` (#561) → mirror the
pins into `diffusion_pip_packages` (module `variables.tf`) and the table above →
`terraform apply` the graphics env. The bake marker hash keys on the pin set, so a
change forces a re-install on the next boot. See
`docs/migration/562-bake-diffusion-stack.md`.

### ControlNet OpenPose — walk-cycle pose control (graphics runner, #674)

Layers an SDXL **ControlNet (OpenPose)** pass on top of the IP-Adapter/LoRA stack
so a `walk` clip renders a coherent stride from a committed per-frame pose
sequence (`tools/spritegen/poses/walk/`). **No new pip dependency:** diffusers
`0.31.0` already ships `ControlNetModel` + `StableDiffusionXLControlNetPipeline`,
and the committed OpenPose skeleton PNGs ARE the control images (no
`controlnet_aux` preprocessing). Only a new HF model download is added; it warms
into the existing persistent `HF_HOME` cache on first pose-controlled generation.

| Model | HF id / weight | Approx size | Role |
|---|---|---|---|
| ControlNet (OpenPose) | `thibaud/controlnet-openpose-sdxl-1.0` | ~2.5 GB (fp16) | per-frame stride pose control for pose-controlled clips (#674) |

All-OPEN — **no `HF_TOKEN`**. If OpenPose maps poorly onto the plush bunny, swap
for a scribble/lineart (e.g. `xinsir/controlnet-scribble-sdxl-1.0`) or depth
ControlNet (owner-validated on the L4; see
`docs/migration/674-controlnet-walkcycle.md`).

**Disk:** adds ~2.5 GB to the model cache — current graphics footprint ~34 GB +
~2.5 GB ≈ **~36.5 GB** of the **100 GB** pd-balanced boot disk (~63 GB headroom).
Comfortably within budget.

## Cross-references

- Bake-list living tracker: **#267** · Golden image + MIG: **#262**
- Diffusion engine + workflow: **#561** · This bake: **#562** · Epic: **#135**
