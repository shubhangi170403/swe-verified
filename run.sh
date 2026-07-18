#!/bin/bash

# Re-exec under stdbuf when available so Docker, uv, Python, and the SWE-bench
# harness flush their output promptly when the dashboard runner redirects this
# script to a file. macOS does not ship stdbuf, so this remains a no-op there.
if [ -z "${STDBUF_APPLIED:-}" ] && command -v stdbuf &>/dev/null; then
    export STDBUF_APPLIED=1
    exec stdbuf -oL -eL "$0" "$@"
fi

# SWE-bench Verified — Dashboard run entry point
# Called by the eval dashboard with --flags from the UI.
#
# Usage (named-flag contract, invoked by the eval-runner harness):
#   ./run.sh [API_KEY] EVAL_RUN_ID [--flag value ...]
#
# - API_KEY is optional; the eval-runner prepends it only when grid_ai_api_key
#   is configured. Manual callers may omit it too.
# - EVAL_RUN_ID is always the first non-api-key positional arg.
# - All remaining args are named flags (derived from input_param.json; the
#   eval-runner translates JSON keys `_` -> `-`, so `max_passes` -> `--max-passes`).
#
# Example:
#   ./run.sh sk-xxx my_run --model glm-latest --num-workers 4 --max-iterations 100
#   ./run.sh my_run --model glm-latest --base-url http://localhost:8000
set -e

# Force line-buffered stdio for Python children so logs appear immediately
# when stdout is redirected to a file (e.g., by the eval-runner harness).
export PYTHONUNBUFFERED=1

# Dashboard runs should emit concise progress rather than every agent event.
# Full interaction streams and per-instance OpenHands stdout/stderr go to
# output/<run-id>/ so they are available in the dashboard's run artifacts.
export RICH_LOGGING=0
export NO_COLOR=1

# ===========================================================================
# Restore Artifact Registry auth from setup.sh
# ===========================================================================
# setup.sh writes gcloud/docker env vars to this file so we inherit auth
# state across script boundaries (setup → run).
if [ -f "/var/lib/docker/gcloud-env.sh" ]; then
    # shellcheck source=/dev/null
    source /var/lib/docker/gcloud-env.sh || true
fi

# ===========================================================================
# Artifact Registry credential helpers
# ===========================================================================
ARTIFACT_REGISTRY_HOST="us-central1-docker.pkg.dev"

# Refresh Docker credentials for Google Cloud Artifact Registry.
# GCP OAuth tokens from the metadata server expire in ~1 hour. This function
# fetches a fresh token right before evaluation so image pulls never hit an
# expired-credential error. Called from ensure_docker_running().
refresh_docker_auth() {
    if [ "$(uname -s)" != "Linux" ]; then
        return 0  # metadata server only available on GCP VMs
    fi

    local token
    token=$(curl -s --max-time 5 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
        | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null || true)

    if [ -n "$token" ]; then
        echo "$token" | docker login -u oauth2accesstoken --password-stdin \
            "https://${ARTIFACT_REGISTRY_HOST}" >/dev/null 2>&1 && \
            echo "[run] Docker credentials refreshed via GCP metadata server" || \
            echo "[run] WARNING: Docker credential refresh via metadata server failed"
    elif command -v gcloud &>/dev/null; then
        # Fallback: gcloud credential helper
        gcloud auth configure-docker "${ARTIFACT_REGISTRY_HOST}" --quiet 2>/dev/null && \
            echo "[run] Docker credentials refreshed via gcloud" || \
            echo "[run] WARNING: Docker credential refresh via gcloud failed"
    else
        echo "[run] WARNING: Could not refresh Docker credentials — image pulls may fail if token expired"
    fi
}

# Ensure Docker daemon is running and credentials are fresh.
# Called before every evaluation phase since the daemon may have died during
# long agent runs, and OAuth tokens may have expired.
ensure_docker_running() {
    if timeout 5 docker info &>/dev/null; then
        refresh_docker_auth
        return 0
    fi

    # On COS Batch VMs the host daemon socket is bind-mounted. If docker info
    # fails, the socket is unreachable — no recovery possible here.
    if [ -S /var/run/docker.sock ]; then
        echo "[run] WARNING: Docker socket exists but daemon not responding."
    else
        echo "[run] WARNING: Docker daemon not reachable (docker info timed out)."
    fi
    return 1
}

# ===========================================================================
# Argument Parsing
# ===========================================================================
print_usage() {
    echo "Usage: $0 [API_KEY] EVAL_RUN_ID [--flag value ...]"
    echo ""
    echo "Positional:"
    echo "  API_KEY               Optional; prepended by the eval-runner when configured."
    echo "  EVAL_RUN_ID           Required; unique ID for this evaluation run."
    echo ""
    echo "Named flags:"
    echo "  --model MODEL                     Model to use (required)"
    echo "  --base-url URL                    LLM API base URL (optional)"
    echo "  --num-workers N                   Parallel inference workers (default: 4)"
    echo "  --max-iterations N                Max agent iterations per instance (default: 100)"
    echo "  --eval-timeout SECONDS            Timeout for SWE-bench evaluation (default: 7200)"
    echo "  --task-range START-END            Dataset index range (e.g., 0-49)"
    echo "  --resume                          Resume from previous run"
}

# --- Positional args: pull API_KEY (optional) and EVAL_RUN_ID (required) ---
if [ $# -lt 1 ]; then
    echo "ERROR: Missing required arguments"
    print_usage
    exit 1
fi

# If $2 starts with "--", then no API_KEY was prepended and $1 is the run_id.
if [ $# -ge 2 ] && [[ "$2" != --* ]]; then
    API_KEY="$1"
    RUN_ID="$2"
    shift 2
else
    API_KEY=""
    RUN_ID="$1"
    shift
fi

# --- Defaults ---
MODEL=""
BASE_URL=""
NUM_WORKERS=4
MAX_ITERATIONS=100
EVAL_TIMEOUT=7200
TASK_RANGE=""
RESUME="false"

# --- Named-flag parser ---
while [ $# -gt 0 ]; do
    case "$1" in
        --model)                MODEL="$2"; shift 2 ;;
        --base-url|--base_url)  BASE_URL="$2"; shift 2 ;;
        --api-key|--api_key)    API_KEY="$2"; shift 2 ;;
        --num-workers|--num_workers)
                                NUM_WORKERS="$2"; shift 2 ;;
        --max-iterations|--max_iterations)
                                MAX_ITERATIONS="$2"; shift 2 ;;
        --eval-timeout|--eval_timeout)
                                EVAL_TIMEOUT="$2"; shift 2 ;;
        --task-range|--task_range)
                                TASK_RANGE="$2"; shift 2 ;;
        --run-id|--run_id)      RUN_ID="$2"; shift 2 ;;
        --resume)
            # Handle both --resume (boolean) and --resume true/false
            if [ $# -ge 2 ] && [[ "$2" == "true" || "$2" == "false" ]]; then
                RESUME="$2"; shift 2
            else
                RESUME="true"; shift
            fi
            ;;
        *)  echo "WARNING: Unknown flag: $1"; shift ;;
    esac
done

# --- Validate required fields ---
if [ -z "$RUN_ID" ]; then echo "ERROR: --run_id or EVAL_RUN_ID positional arg is required"; print_usage; exit 1; fi
if [ -z "$MODEL" ]; then echo "ERROR: --model is required"; print_usage; exit 1; fi

# The eval-runner periodically syncs repo/logs and repo/output. Keep scoring
# artifacts in logs/, OpenHands interactions/runtime logs plus the dashboard
# result in output/, and never place Docker workspaces in either path.
DASHBOARD_LOG_DIR="./logs/${RUN_ID}"
DASHBOARD_OUTPUT_DIR="./output/${RUN_ID}"
export EVAL_LOG_DIR="${DASHBOARD_OUTPUT_DIR}/openhands_runtime_logs"
export OPENHANDS_INTERACTION_LOG_DIR="${DASHBOARD_OUTPUT_DIR}/openhands_agent_logs"
mkdir -p "$EVAL_LOG_DIR" "$OPENHANDS_INTERACTION_LOG_DIR"

# --- Broadcast API key to all provider env vars ---
# Downstream tools check different env vars depending on the provider.
# Setting all of them ensures the key is available regardless of which
# provider the model uses.
if [ -n "$API_KEY" ]; then
    export ANTHROPIC_API_KEY="${API_KEY}"
    export ANTHROPIC_AUTH_TOKEN="${API_KEY}"
    export OPENAI_API_KEY="${API_KEY}"
    export GRID_AI_API_KEY="${API_KEY}"
    export LITE_LLM_API_KEY="${API_KEY}"
fi

# --- Ensure uv is on PATH ---
export PATH="$HOME/.local/bin:$PATH"

# --- Create LLM config ---
mkdir -p .llm_config
LLM_CONFIG=".llm_config/${MODEL}.json"
# Only include base_url and api_key if explicitly provided.
# When omitted, downstream tools use provider-specific env vars instead.
if [ -n "$BASE_URL" ] && [ -n "$API_KEY" ]; then
    cat > "$LLM_CONFIG" <<EOF
{
  "model": "openai/${MODEL}",
  "base_url": "${BASE_URL}",
  "api_key": "${API_KEY}"
}
EOF
elif [ -n "$BASE_URL" ]; then
    cat > "$LLM_CONFIG" <<EOF
{
  "model": "openai/${MODEL}",
  "base_url": "${BASE_URL}"
}
EOF
elif [ -n "$API_KEY" ]; then
    cat > "$LLM_CONFIG" <<EOF
{
  "model": "openai/${MODEL}",
  "api_key": "${API_KEY}"
}
EOF
else
    cat > "$LLM_CONFIG" <<EOF
{
  "model": "openai/${MODEL}"
}
EOF
fi
echo "=== LLM config written to ${LLM_CONFIG} ==="

# --- Environment ---
export IMAGE_TAG_PREFIX=43376f1
export FORCE_BUILD=1
export SWEBENCH_REGISTRY_IMAGE_PACKAGE="${SWEBENCH_REGISTRY_IMAGE_PACKAGE:-sweverified-swebench-images}"

# --- Derive output dir (matches OpenHands naming) ---
MODEL_SAFE=$(echo "openai-${MODEL}" | tr '/' '-')
OUTPUT_DIR="./eval_outputs/princeton-nlp__SWE-bench_Verified-test/${MODEL_SAFE}_sdk_43376f1_maxiter_${MAX_ITERATIONS}"

# --- Build select args for task range ---
SELECT_ARGS=""
if [ -n "$TASK_RANGE" ]; then
    echo "=== Task range: ${TASK_RANGE} ==="
    # task_range is like "0-49", meaning first 50 instances
    SELECT_ARGS="--n-limit $(echo "$TASK_RANGE" | cut -d'-' -f2)"
fi

# --- Resume check ---
if [ "$RESUME" = "true" ] && [ -d "$OUTPUT_DIR" ]; then
    if [ -f "${OUTPUT_DIR}/output.jsonl" ]; then
        COMPLETED=$(wc -l < "${OUTPUT_DIR}/output.jsonl" | tr -d ' ')
    else
        COMPLETED=0
    fi
    echo "=== Resuming: found ${COMPLETED} completed instances in ${OUTPUT_DIR} ==="
    echo "=== swebench-infer will automatically skip already-completed instances ==="
else
    if [ "$RESUME" = "true" ]; then
        echo "=== Resume requested but no previous output found at ${OUTPUT_DIR}. Starting fresh. ==="
    fi
fi

# --- Ensure Docker is ready and credentials are fresh before eval ---
ensure_docker_running || true

# --- Step 1: Inference ---
echo "=== Step 1: Inference (model=${MODEL}, workers=${NUM_WORKERS}) ==="
uv run swebench-infer "$LLM_CONFIG" \
    --dataset princeton-nlp/SWE-bench_Verified \
    --split test \
    --max-iterations "$MAX_ITERATIONS" \
    --workspace docker \
    --num-workers "$NUM_WORKERS" \
    $SELECT_ARGS

# --- Refresh credentials before evaluation (tokens may have expired during inference) ---
refresh_docker_auth || true

# --- Step 2: Evaluation ---
# SWE-bench has a fixed relative log path (logs/run_evaluation). For fresh
# runs, point it at the dashboard-synced scoring directory so test logs appear
# while scoring is in progress. Existing resume directories are left intact
# and copied after scoring for backwards compatibility.
SCORING_LOG_DIR="${DASHBOARD_LOG_DIR}/scoring"
mkdir -p "$SCORING_LOG_DIR" "${OUTPUT_DIR}/logs"
if [ ! -e "${OUTPUT_DIR}/logs/run_evaluation" ]; then
    SCORING_LOG_ABS=$(cd "$SCORING_LOG_DIR" && pwd -P)
    ln -s "$SCORING_LOG_ABS" "${OUTPUT_DIR}/logs/run_evaluation"
fi

echo "=== Step 2: Evaluation ==="
uv run swebench-eval "${OUTPUT_DIR}/output.jsonl" \
    --run-id "$RUN_ID" \
    --timeout "$EVAL_TIMEOUT" \
    --no-modal

# Persist the compact scoring inputs/results and the upstream SWE-bench test
# logs for dashboard retrieval. Deliberately do not copy output.jsonl or the
# conversation archives: those contain bulky duplicate agent histories and
# remain in eval_outputs for local debugging/resume during the job.
echo "=== Saving dashboard log artifacts ==="
ARTIFACT_LOG_DIR="${DASHBOARD_LOG_DIR}/artifacts"
mkdir -p "$ARTIFACT_LOG_DIR"
for artifact in metadata.json output.swebench.jsonl output.report.json cost_report.jsonl ERROR_LOGS.txt; do
    if [ -f "${OUTPUT_DIR}/${artifact}" ]; then
        cp "${OUTPUT_DIR}/${artifact}" "${ARTIFACT_LOG_DIR}/${artifact}"
    fi
done
if [ -d "${OUTPUT_DIR}/logs/run_evaluation" ] && [ ! -L "${OUTPUT_DIR}/logs/run_evaluation" ]; then
    cp -R "${OUTPUT_DIR}/logs/run_evaluation/." "$SCORING_LOG_DIR/"
fi

# --- Step 3: Convert results to dashboard format ---
echo "=== Step 3: Writing dashboard results ==="
mkdir -p output
python3 -c "
import json, sys

with open('${OUTPUT_DIR}/output.report.json') as f:
    report = json.load(f)

resolved = report.get('resolved_instances', 0)
total = report.get('completed_instances', 0) or report.get('total_instances', 500)
unresolved = report.get('unresolved_instances', 0)
pass_at_1 = resolved / total if total > 0 else 0

results = {
    'total_resolved': resolved,
    'pass@1': round(pass_at_1, 4),
    'resolved': resolved,
    'unresolved': unresolved,
    'total_tasks': total
}

out_path = 'output/${RUN_ID}_results.json'
with open(out_path, 'w') as f:
    json.dump(results, f, indent=2)
print(f'Results written to {out_path}')
print(json.dumps(results, indent=2))
"

echo "=== Done! ==="
