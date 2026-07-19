#!/bin/bash
# SWE-bench Verified — setup
# Installs everything needed to run the benchmark from scratch, on either a
# bare VM (root/sudo available) or the eval-dashboard runner container
# (Debian on a COS Batch VM: runs as root, no sudo binary, no systemd,
# Docker reachable only through the bind-mounted host socket — DooD).
# Includes Google Cloud Artifact Registry authentication so eval runners
# can pull pre-built images instead of building from Docker Hub.

# Re-exec under stdbuf when available so apt, curl, and make flush their
# output promptly when the dashboard runner redirects this script to a file.
if [ -z "${STDBUF_APPLIED:-}" ] && command -v stdbuf &>/dev/null; then
    export STDBUF_APPLIED=1
    exec stdbuf -oL -eL "$0" "$@"
fi

# No `set -e`: package and auth steps are best-effort with warnings; only
# genuinely fatal steps (uv missing, make build) exit explicitly.
set -u

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

echo "=== SWE-bench Verified: Setup ==="

# Privilege wrapper: the dashboard runner container executes this as root
# with no sudo binary; bare VMs may run it as a sudoer. Use sudo only when
# needed AND available.
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo &> /dev/null; then
    SUDO="sudo"
fi

# --- System packages ---
if command -v apt-get &> /dev/null; then
    echo "[setup] Installing system packages..."
    $SUDO apt-get update -qq || \
        echo "[setup] WARNING: apt-get update failed; continuing with cached indexes"
    $SUDO apt-get install -y -qq \
        git curl wget \
        build-essential gcc make \
        python3 python3-pip python3-venv python3-dev \
        libffi-dev libssl-dev \
        ca-certificates gnupg lsb-release || \
        echo "[setup] WARNING: some system packages failed to install; continuing"
fi

# --- Docker ---
# Two supported layouts:
#   1. Runner container (DooD): the COS host daemon socket is bind-mounted at
#      /var/run/docker.sock — install the docker CLI + buildx plugin only,
#      never a daemon (no systemd here anyway).
#   2. Bare VM: no socket, no CLI — install the full engine.
install_docker_apt_repo() {
    $SUDO install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" | \
        $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return 1
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(lsb_release -cs) stable" | \
        $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null || return 1
    $SUDO apt-get update -qq || return 1
}

if command -v docker &> /dev/null; then
    echo "[setup] Docker CLI already installed."
elif [ -S /var/run/docker.sock ]; then
    echo "[setup] Host Docker socket found — installing docker-ce-cli only (DooD)..."
    if install_docker_apt_repo; then
        # Pin the CLI to 24.x for client/server protocol compatibility with
        # the COS host daemon (Docker 24.0.x); fall back to latest.
        CLI_24=$(apt-cache madison docker-ce-cli 2>/dev/null \
            | awk -F'[| ]+' '$3~/^5:24\./{print $3;exit}')
        if [ -n "$CLI_24" ]; then
            $SUDO apt-get install -y -qq --allow-downgrades "docker-ce-cli=${CLI_24}" || \
                echo "[setup] WARNING: pinned docker-ce-cli install failed"
        else
            $SUDO apt-get install -y -qq docker-ce-cli || \
                echo "[setup] WARNING: docker-ce-cli install failed"
        fi
        # The agent-server image build path uses `docker buildx build`.
        $SUDO apt-get install -y -qq docker-buildx-plugin || \
            echo "[setup] WARNING: docker-buildx-plugin install failed"
    else
        echo "[setup] WARNING: could not configure Docker apt repo; docker CLI unavailable"
    fi
else
    echo "[setup] Installing Docker engine (bare VM)..."
    if install_docker_apt_repo; then
        $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin || \
            echo "[setup] WARNING: Docker engine install failed"
        $SUDO usermod -aG docker "${USER:-root}" 2>/dev/null || true
        if command -v systemctl &> /dev/null; then
            $SUDO systemctl start docker || true
        elif command -v service &> /dev/null; then
            $SUDO service docker start || true
        fi
    else
        echo "[setup] WARNING: could not configure Docker apt repo; skipping engine install"
    fi
fi

# Health check — warn-only; run.sh re-checks before every phase.
if command -v docker &> /dev/null; then
    if timeout 10 docker info &> /dev/null; then
        echo "[setup] Docker daemon reachable (server $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
    elif [ -S /var/run/docker.sock ]; then
        echo "[setup] WARNING: Docker socket present but daemon not responding — check the Batch job's bind mount"
    else
        echo "[setup] WARNING: Docker daemon not reachable"
    fi
else
    echo "[setup] WARNING: docker CLI not available — image pulls and DockerWorkspace will fail at run time"
fi

# ===========================================================================
# Google Cloud Artifact Registry authentication
#
# Configures Docker to pull pre-built eval images from Artifact Registry,
# avoiding Docker Hub rate limits when running 500+ instances.
#
# Authentication methods (tried in order):
#   1. gcloud credential helper (writes credHelpers into Docker config.json)
#   2. GCP metadata server OAuth token (direct docker login, always works
#      on GCP VMs regardless of gcloud installation)
#
# The env vars (DOCKER_CONFIG, CLOUDSDK_CONFIG, PATH) are persisted to
# /var/lib/docker/gcloud-env.sh so run.sh can restore them.
# ===========================================================================
ARTIFACT_REGISTRY_HOST="us-central1-docker.pkg.dev"

# Base dir for the gcloud SDK + docker/gcloud config. Prefer /var/lib/docker
# (the writable data partition on COS bare VMs); fall back to $HOME when it
# is not writable (e.g. inside the dashboard runner container).
GCLOUD_BASE="/var/lib/docker"
if ! mkdir -p "${GCLOUD_BASE}" 2>/dev/null || ! touch "${GCLOUD_BASE}/.write-probe" 2>/dev/null; then
    GCLOUD_BASE="${HOME}/.gcloud-eval"
    mkdir -p "${GCLOUD_BASE}"
    echo "[setup] /var/lib/docker not writable — using ${GCLOUD_BASE} for gcloud state"
else
    rm -f "${GCLOUD_BASE}/.write-probe"
fi
GCLOUD_INSTALL_DIR="${GCLOUD_BASE}/google-cloud-sdk"
GCLOUD_BIN="${GCLOUD_INSTALL_DIR}/bin"
GCLOUD_CONFIG_DIR="${GCLOUD_BASE}/gcloud-config"
DOCKER_CONFIG_DIR="${GCLOUD_BASE}/docker-config"
GCLOUD_ENV_FILE="${GCLOUD_BASE}/gcloud-env.sh"

setup_artifact_registry_auth() {
    echo "[setup] Configuring Google Cloud Artifact Registry authentication..."

    # --- Install gcloud CLI (tarball, no apt dependency) ---
    # On COS (Container-Optimized OS) the root filesystem is read-only and
    # apt-get is unavailable; ${GCLOUD_BASE} is chosen to be writable above.
    if [ ! -x "${GCLOUD_BIN}/gcloud" ]; then
        echo "[setup] Installing Google Cloud SDK from tarball..."
        local gcloud_tgz="${GCLOUD_BASE}/google-cloud-cli-linux-x86_64.tar.gz"
        curl -fsSL \
            "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz" \
            -o "${gcloud_tgz}" 2>/dev/null || {
            echo "[setup] WARNING: Failed to download Google Cloud SDK tarball"
        }
        if [ -f "${gcloud_tgz}" ]; then
            tar -xf "${gcloud_tgz}" -C "${GCLOUD_BASE}/" || echo "[setup] WARNING: Failed to extract gcloud tarball"
            rm -f "${gcloud_tgz}"
        fi
    else
        echo "[setup] Google Cloud SDK already installed at ${GCLOUD_INSTALL_DIR}"
    fi

    # --- Configure gcloud credential helper ---
    if [ -x "${GCLOUD_BIN}/gcloud" ]; then
        echo "[setup] gcloud binary found at ${GCLOUD_BIN}/gcloud"

        # Use writable config dirs (avoids read-only /root/.config on COS)
        export CLOUDSDK_CONFIG="${GCLOUD_CONFIG_DIR}"
        export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"
        mkdir -p "${GCLOUD_CONFIG_DIR}" "${DOCKER_CONFIG_DIR}"

        export PATH="${GCLOUD_BIN}:${PATH}"

        echo "[setup] Configuring Docker credential helper for ${ARTIFACT_REGISTRY_HOST}..."
        "${GCLOUD_BIN}/gcloud" auth configure-docker "${ARTIFACT_REGISTRY_HOST}" \
            --quiet 2>/dev/null && \
            echo "[setup] gcloud Docker credential helper configured" || \
            echo "[setup] WARNING: gcloud auth configure-docker failed"
    else
        echo "[setup] WARNING: gcloud binary not found — will use metadata-token auth"
    fi

    # --- Direct docker login via GCP metadata server token ---
    # This is the belt-and-suspenders approach: works on all GCP VMs
    # regardless of gcloud installation, and handles edge cases where
    # the credential helper path isn't inherited by child processes.
    echo "[setup] Authenticating Docker via GCP metadata server..."
    local metadata_token
    metadata_token=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || true)

    if [ -n "${metadata_token}" ]; then
        echo "${metadata_token}" | docker login -u oauth2accesstoken --password-stdin \
            "https://${ARTIFACT_REGISTRY_HOST}" 2>/dev/null && \
            echo "[setup] Docker authenticated with Artifact Registry via metadata token" || \
            echo "[setup] WARNING: docker login with metadata token failed"
    else
        echo "[setup] WARNING: Could not retrieve metadata token (not on a GCP VM?)"
    fi

    # --- Persist env vars for run.sh ---
    # run.sh sources this file to inherit gcloud/docker auth state.
    if [ -n "${DOCKER_CONFIG_DIR:-}" ]; then
        cat > "${GCLOUD_ENV_FILE}" <<ENVEOF
export DOCKER_CONFIG=${DOCKER_CONFIG_DIR}
export CLOUDSDK_CONFIG=${GCLOUD_CONFIG_DIR}
export PATH=${GCLOUD_BIN}:\${PATH}
ENVEOF
        echo "[setup] Auth env vars written to ${GCLOUD_ENV_FILE}"
    fi

    echo "[setup] Artifact Registry authentication configured."
}

# Only run AR auth on Linux (GCP VMs are always Linux)
if [ "$(uname -s)" = "Linux" ]; then
    setup_artifact_registry_auth
fi

# --- uv (Python package manager) ---
if ! command -v uv &> /dev/null; then
    echo "[setup] Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh || \
        echo "[setup] WARNING: uv installer failed"
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "[setup] uv already installed."
fi
if ! command -v uv &> /dev/null; then
    echo "[setup] ERROR: uv is required to build and run the benchmark"
    exit 1
fi

# --- OpenHands benchmarks ---
# Hard failure: without the synced environment run.sh cannot work, and the
# dashboard must surface this as a setup failure.
echo "[setup] Building OpenHands benchmarks..."
if ! make build; then
    echo "[setup] ERROR: make build failed (git submodule init / uv sync)"
    exit 1
fi

# --- DooD host-fix patch (agent-server health checks) ---
# On the Batch runner (DooD) DockerWorkspace health-checks 127.0.0.1:<port>,
# which lives in the COS host's netns, not ours — every instance fails with
# "Container failed to become healthy in time" (proven on run 739ac5ae).
# Install scripts/swev_dood_hostfix.py + a .pth loader into the project venv;
# the patch is inert unless run.sh exports SWEV_DOOD_HOST_FIX=1.
install_dood_hostfix() {
    echo "[setup] Installing DooD host-fix patch into project venv..."
    local sp
    sp=$(uv run python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])" 2>/dev/null | tail -n 1)
    if [ -z "$sp" ] || [ ! -d "$sp" ]; then
        echo "[setup] WARNING: could not locate venv site-packages; DooD host fix NOT installed"
        return 1
    fi
    cp scripts/swev_dood_hostfix.py "$sp/swev_dood_hostfix.py" || {
        echo "[setup] WARNING: failed to copy patch module"; return 1; }
    printf 'import swev_dood_hostfix\n' > "$sp/swev_dood_hostfix.pth" || {
        echo "[setup] WARNING: failed to write .pth loader"; return 1; }

    # Self-verify both gate states (mirrors the terminal-bench .pth pattern).
    if ! uv run python -c "
from openhands.workspace.docker.workspace import DockerWorkspace as W
assert not getattr(W._wait_for_health, '_swev_dood', False), 'patched with gate OFF'
print('[setup] DooD host-fix gate-off: unpatched (correct)')"; then
        echo "[setup] WARNING: DooD host-fix gate-off verification failed"
        return 1
    fi
    if ! SWEV_DOOD_HOST_FIX=1 uv run python -c "
from openhands.workspace.docker.workspace import DockerWorkspace as W
assert getattr(W._wait_for_health, '_swev_dood', False), 'gate ON but not patched'
print('[setup] DooD host-fix gate-on: patched (correct)')"; then
        echo "[setup] WARNING: DooD host-fix gate-on verification failed"
        return 1
    fi
    echo "[setup] DooD host-fix installed and verified."
}

if ! install_dood_hostfix; then
    # Without the patch, a DooD run deterministically fails at the first
    # health check — surface that at setup time instead of 20 minutes in.
    if [ -S /var/run/docker.sock ] && [ -f /.dockerenv ]; then
        echo "[setup] ERROR: DooD environment detected but the host-fix patch could not be installed."
        echo "[setup]        Agent health checks WILL fail (run 739ac5ae failure mode). Aborting."
        exit 1
    fi
    echo "[setup] WARNING: DooD host-fix unavailable (harmless on native VMs)."
fi

# --- Verification summary (warn-only) ---
echo "[setup] Verification:"
for tool in git docker python3 uv; do
    if command -v "$tool" &> /dev/null; then
        echo "[setup]   $tool: $(command -v "$tool")"
    else
        echo "[setup]   WARNING: $tool not found"
    fi
done
if [ -S /var/run/docker.sock ]; then
    echo "[setup]   docker socket: present"
else
    echo "[setup]   docker socket: absent"
fi
if [ -f "${GCLOUD_ENV_FILE}" ]; then
    echo "[setup]   gcloud env: ${GCLOUD_ENV_FILE}"
else
    echo "[setup]   gcloud env: not written"
fi

echo "=== Setup complete ==="
