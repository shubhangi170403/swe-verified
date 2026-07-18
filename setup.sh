#!/bin/bash
# SWE-bench Verified — bare VM setup
# Installs everything needed to run the benchmark from scratch.
# Includes Google Cloud Artifact Registry authentication so eval runners
# can pull pre-built images instead of building from Docker Hub.
set -e

echo "=== SWE-bench Verified: Setup ==="

# --- System packages ---
if command -v apt-get &> /dev/null; then
    echo "[setup] Installing system packages..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        git curl wget \
        build-essential gcc make \
        python3 python3-pip python3-venv python3-dev \
        libffi-dev libssl-dev \
        ca-certificates gnupg lsb-release
fi

# --- Docker ---
if ! command -v docker &> /dev/null; then
    echo "[setup] Installing Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    sudo usermod -aG docker "$USER" || true
    sudo systemctl start docker || sudo service docker start || true
    echo "[setup] Docker installed."
else
    echo "[setup] Docker already installed."
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
GCLOUD_INSTALL_DIR="/var/lib/docker/google-cloud-sdk"
GCLOUD_BIN="${GCLOUD_INSTALL_DIR}/bin"
GCLOUD_CONFIG_DIR="/var/lib/docker/gcloud-config"
DOCKER_CONFIG_DIR="/var/lib/docker/docker-config"
GCLOUD_ENV_FILE="/var/lib/docker/gcloud-env.sh"

setup_artifact_registry_auth() {
    echo "[setup] Configuring Google Cloud Artifact Registry authentication..."

    # --- Install gcloud CLI (tarball, no apt dependency) ---
    # On COS (Container-Optimized OS) the root filesystem is read-only and
    # apt-get is unavailable. /var/lib/docker is a writable data partition.
    if [ ! -x "${GCLOUD_BIN}/gcloud" ]; then
        echo "[setup] Installing Google Cloud SDK from tarball..."
        local gcloud_tgz="/var/lib/docker/google-cloud-cli-linux-x86_64.tar.gz"
        curl -fsSL \
            "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz" \
            -o "${gcloud_tgz}" 2>/dev/null || {
            echo "[setup] WARNING: Failed to download Google Cloud SDK tarball"
        }
        if [ -f "${gcloud_tgz}" ]; then
            tar -xf "${gcloud_tgz}" -C /var/lib/docker/ || echo "[setup] WARNING: Failed to extract gcloud tarball"
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
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "[setup] uv already installed."
fi

# --- OpenHands benchmarks ---
echo "[setup] Building OpenHands benchmarks..."
make build

echo "=== Setup complete ==="
