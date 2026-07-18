import os


OUTPUT_FILENAME = "output.jsonl"

# Image name for agent server (can be overridden via env var)
EVAL_AGENT_SERVER_IMAGE = os.getenv(
    "OPENHANDS_EVAL_AGENT_SERVER_IMAGE", "ghcr.io/openhands/eval-agent-server"
)

# Google Cloud Artifact Registry URL for pulling pre-built eval images.
# Eval runners pull images from this registry instead of building from Docker
# Hub base images, avoiding Docker Hub rate limits.
# NOTE: No http:// or https:// prefix - Docker image names use bare hostnames.
DOCKER_REGISTRY_URL = os.getenv(
    "DOCKER_REGISTRY_URL",
    "us-central1-docker.pkg.dev/xyne-dev-461113/eval-dashboard",
)

# Toggle registry pulls on/off. Enabled by default.
# Set to "0" to disable pulls and fall back to local builds.
DOCKER_REGISTRY_PULL_ENABLED = os.getenv("DOCKER_REGISTRY_PULL", "1").lower() in (
    "1",
    "true",
    "yes",
) and bool(DOCKER_REGISTRY_URL)

# Model identifier used in swebench-style prediction entries.
# The swebench harness uses this value to create log directory structures
# (logs/run_evaluation/{run_id}/{model_name_or_path}/{instance_id}/)
# and to name the final evaluation report file ({model_name_or_path}.{run_id}.json).
MODEL_NAME_OR_PATH = "OpenHands"
