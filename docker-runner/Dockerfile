# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Bonkey Apps — self-hosted GitHub Actions runner (local Docker, Mac-friendly).
#
# An ORG-level (Bonkey-Apps) runner you can host from a Mac with Docker Desktop.
# It bakes the FULL CI toolchain the three app repos (Puzzles / Cards / Math)
# install per job, so those `setup-*` steps become warm no-ops — pinned in
# lockstep with the self-hosted golden-image manifest
# (infra/gcp-runner/IMAGE-MANIFEST.md) and each repo's package.json.
#
# Baked (see that manifest):
#   CI (all repos, unconditional):
#     • Node 24, pnpm 10.33.0 (== packageManager)
#     • Playwright 1.61.1 Chromium browser + its OS libs  → /opt/pw-browsers
#     • GitHub CLI (gh), git, ripgrep, fd-find, jq, python3
#   Android BUILD (INSTALL_ANDROID=true, default):
#     • OpenJDK 17 (JAVA_HOME exported at runtime by entrypoint.sh)
#     • Android command-line tools + platform-tools + platforms;android-34
#       + build-tools;34.0.0 (licenses accepted)          → /opt/android-sdk
#     • bundletool 1.18.1                                  → /opt/bundletool
#     • Gradle wrapper distribution cache, pre-populated for GRADLE_VERSION
#       (GRADLE_USER_HOME)                                 → /opt/gradle-cache
#
# Deliberately NOT baked (cannot run in Docker Desktop on macOS):
#   • Android EMULATOR / Maestro (ADR 0008 Tier 4) — needs /dev/kvm, which
#     macOS Docker does not expose. Android *build* jobs (Gradle bundleRelease)
#     run fine without it; the emulator/system-image stays on the GCE kvm runners.
#   • The GPU / SDXL sprite-gen (diffusion) stack — graphics-env + NVIDIA-CUDA
#     only; impossible without a GPU. Keep spritegen on the GCE graphics runner.
#
# Multi-arch: TARGETARCH selects the actions/runner binary. Build/run as
# linux/amd64 (default, Rosetta on Apple Silicon) so the runner reports `x64`,
# matching the repos' `runs-on: [self-hosted, linux, x64]` jobs. NOTE: the
# Android SDK ships x86_64 host tools only — INSTALL_ANDROID requires amd64.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

# --- Version pins (keep in lockstep with IMAGE-MANIFEST.md + package.json) ---
ARG RUNNER_VERSION=2.335.1
ARG PNPM_VERSION=10.33.0
ARG PLAYWRIGHT_VERSION=1.61.1
# Android build toolchain (heavy, amd64-only) — set false for a lean JS/web image.
ARG INSTALL_ANDROID=true
ARG JAVA_VERSION=17
ARG ANDROID_CMDLINE_TOOLS=commandlinetools-linux-14742923_latest.zip
ARG ANDROID_PLATFORM=android-34
ARG ANDROID_BUILD_TOOLS=34.0.0
ARG BUNDLETOOL_VERSION=1.18.1
# Must track whatever `expo prebuild` pins in the generated
# gradle/wrapper/gradle-wrapper.properties (currently 9.3.1, confirmed from a
# live failure log — bonkey-cards-app#1032). Bump this in lockstep if that
# drifts, or the pre-baked cache below goes stale and jobs fall back to a
# network download.
ARG GRADLE_VERSION=9.3.1
# Populated automatically by BuildKit (amd64 / arm64).
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    BUNDLETOOL_JAR=/opt/bundletool/bundletool-all.jar

# --- CI base: OS deps + search tools (all repos) ---------------------------
RUN set -eux; \
    apt-get update -q; \
    apt-get install -y -q --no-install-recommends \
        ca-certificates curl git jq ripgrep fd-find python3 \
        unzip tar sudo gnupg libicu74 libssl3; \
    # GitHub CLI (gh) from the official apt repo (pinned channel, keyring-verified).
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update -q; \
    apt-get install -y -q --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# --- Node.js 24 + pnpm (pinned == packageManager) --------------------------
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -; \
    apt-get install -y -q --no-install-recommends nodejs; \
    npm install -g "pnpm@${PNPM_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

# --- Non-root runner user --------------------------------------------------
RUN useradd -m -s /bin/bash runner

# --- actions/runner (arch-correct binary) ----------------------------------
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) RUNNER_ARCH=x64 ;; \
        arm64) RUNNER_ARCH=arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /home/runner/actions-runner; \
    PKG="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${PKG}" \
        -o /tmp/runner.tar.gz; \
    tar -xzf /tmp/runner.tar.gz -C /home/runner/actions-runner; \
    rm -f /tmp/runner.tar.gz; \
    chown -R runner:runner /home/runner

# --- Playwright 1.61.1 Chromium + OS deps (baked to /opt/pw-browsers) -------
# --with-deps installs the apt libs Chromium needs (Tier 3 web-local e2e +
# screenshots). Owned by runner so jobs read it as a warm no-op.
RUN set -eux; \
    mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"; \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium; \
    chown -R runner:runner "${PLAYWRIGHT_BROWSERS_PATH}"; \
    rm -rf /var/lib/apt/lists/*

# --- Android BUILD toolchain (INSTALL_ANDROID=true, amd64 only) -------------
# Mirrors .github/actions/setup-android-build + setup-bundletool so Gradle
# bundleRelease jobs run warm. Emulator/system-image intentionally omitted
# (KVM unavailable on macOS Docker). No-op when INSTALL_ANDROID=false.
RUN set -eux; \
    if [ "${INSTALL_ANDROID}" = "true" ]; then \
      if [ "${TARGETARCH:-amd64}" != "amd64" ]; then \
        echo "INSTALL_ANDROID=true requires amd64 (Android SDK ships x86_64 host tools only); build with --build-arg INSTALL_ANDROID=false on arm64." >&2; \
        exit 1; \
      fi; \
      apt-get update -q; \
      apt-get install -y -q --no-install-recommends "openjdk-${JAVA_VERSION}-jdk-headless"; \
      rm -rf /var/lib/apt/lists/*; \
      # Android command-line tools → $ANDROID_SDK_ROOT/cmdline-tools/latest
      CMDLINE_DIR="${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
      mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
      curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
        "https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS}" \
        -o /tmp/cmdline-tools.zip; \
      python3 -m zipfile -e /tmp/cmdline-tools.zip /tmp/cmdline-extract/; \
      mv /tmp/cmdline-extract/cmdline-tools "${CMDLINE_DIR}"; \
      chmod -R +x "${CMDLINE_DIR}/bin"; \
      rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-extract; \
      # Accept licenses + install platform-tools, the target platform, build-tools.
      yes 2>/dev/null | "${CMDLINE_DIR}/bin/sdkmanager" --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null 2>&1 || true; \
      yes 2>/dev/null | "${CMDLINE_DIR}/bin/sdkmanager" --sdk_root="${ANDROID_SDK_ROOT}" \
        "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" >/dev/null; \
      # bundletool jar (single pinned version, matches setup-bundletool).
      mkdir -p /opt/bundletool; \
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
        "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
        -o "${BUNDLETOOL_JAR}"; \
      chown -R runner:runner "${ANDROID_SDK_ROOT}" /opt/bundletool; \
      # Fail the BAKE if the JDK we just installed is not actually runnable.
      # entrypoint.sh derives JAVA_HOME from this `java` at RUNTIME, and jobs
      # skip `actions/setup-java` on the strength of it — so a JDK that installs
      # but does not resolve must fail here, loudly, rather than at the next
      # release. Resolved via PATH (apt registers /usr/bin/java through
      # update-alternatives), so this stays arch-agnostic.
      command -v java >/dev/null \
        || { echo "openjdk-${JAVA_VERSION}-jdk-headless installed but 'java' is not on PATH — update-alternatives did not register it." >&2; exit 1; }; \
      java -version; \
      echo "JAVA_HOME will resolve to: $(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
      # Pre-bake the Gradle wrapper's OWN distribution cache (not just a
      # standalone `gradle` binary) so `./gradlew` in the actual job finds it
      # via the exact lookup a real distributionUrl produces — no network
      # fetch needed at job time, matching what this layer already does for
      # the Android command-line tools. We bootstrap with a throwaway Gradle
      # install, use it to generate a real wrapper for GRADLE_VERSION (which
      # writes the same https://services.gradle.org/... distributionUrl expo
      # prebuild's generated wrapper will use), then let THAT wrapper do a
      # real download into GRADLE_USER_HOME — so the cache directory hash is
      # computed by Gradle's own code, not guessed at here.
      GRADLE_ZIP="gradle-${GRADLE_VERSION}-bin.zip"; \
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
        "https://services.gradle.org/distributions/${GRADLE_ZIP}" \
        -o "/tmp/${GRADLE_ZIP}"; \
      mkdir -p /tmp/gradle-boot; \
      python3 -m zipfile -e "/tmp/${GRADLE_ZIP}" /tmp/gradle-boot/; \
      # python3 -m zipfile does not preserve the Unix executable bit stored in
      # the zip's external attributes (unlike `unzip`) — without this, the
      # extracted `bin/gradle` launcher script fails with "Permission denied".
      chmod +x "/tmp/gradle-boot/gradle-${GRADLE_VERSION}/bin/gradle"; \
      mkdir -p /tmp/gradle-wrapper-project; \
      (cd /tmp/gradle-wrapper-project && touch settings.gradle \
        && "/tmp/gradle-boot/gradle-${GRADLE_VERSION}/bin/gradle" wrapper \
             --gradle-version "${GRADLE_VERSION}" --distribution-type bin --no-daemon \
        && GRADLE_USER_HOME=/opt/gradle-cache ./gradlew --version --no-daemon); \
      rm -rf /tmp/gradle-boot /tmp/gradle-wrapper-project "/tmp/${GRADLE_ZIP}"; \
      chown -R runner:runner /opt/gradle-cache; \
    else \
      echo "INSTALL_ANDROID=false — skipping Java/Android SDK/bundletool bake."; \
    fi

# Android SDK on PATH (harmless when the layer was skipped).
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

# Points ./gradlew at the pre-baked wrapper cache above (harmless when the
# layer was skipped — Gradle just falls back to a fresh $HOME/.gradle).
ENV GRADLE_USER_HOME=/opt/gradle-cache

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /home/runner/actions-runner

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
