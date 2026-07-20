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
# state across script boundaries (setup → run). setup.sh prefers
# /var/lib/docker (COS bare VM) and falls back to $HOME/.gcloud-eval when
# that is not writable (dashboard runner container).
for _gcloud_env in "/var/lib/docker/gcloud-env.sh" "$HOME/.gcloud-eval/gcloud-env.sh"; do
    if [ -f "$_gcloud_env" ]; then
        # shellcheck source=/dev/null
        source "$_gcloud_env" || true
        break
    fi
done

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
# Docker image reaper
# ===========================================================================
# Every SWE-bench instance pulls its own multi-GB base image (two tags: the
# registry tag and a docker.io/swebench re-tag) and builds a per-instance
# agent-server image on top. Nothing downstream ever deletes them, which
# filled the 200 GB Batch VM disk ~66 instances into a full 500-instance run
# (run 0bf4b460: ENOSPC after 3h10m).
#
# The sweep is REPOSITORY-based, never per-instance-key: the SDK build tags
# each agent-server image THREE times, and one variant truncates the instance
# id and appends a random hex ("...django-1143_tag_latest-f83ac7d09257-...").
# Instance-key matching misses that tag, which then pins the whole 5 GB image
# chain forever — a live 500-instance run (8481cf66) leaked ~100 GB exactly
# this way before a manual sweep saved it.
#
# Guards, per image:
#   - skip while any container (running or exited) references it
#   - agent-server images: skip if built < REAPER_MIN_AGE_SECONDS ago
#     (a fresh build whose container has not started yet)
#   - base images: skip if TAGGED locally < REAPER_MIN_AGE_SECONDS ago
#     (Metadata.LastTagTime = pull/re-tag time; .Created is the months-old
#     upstream build date, useless as a local-freshness signal). This
#     protects a just-pulled base whose build has not produced tags yet.
#   - bases still pinned by an agent-server image fail rmi harmlessly and
#     are retried next pass once the child images are gone.
# Worst-case miss: a critic re-run re-pulls/rebuilds its images (minutes);
# verdicts are unaffected (scoring uses only the patch + Step 2's own images).
REAPER_INTERVAL_SECONDS=180
REAPER_MIN_AGE_SECONDS=1800
REAPER_PID=""

# $1 = repo:tag, $2 = inspect format for the local-freshness timestamp
image_reaper_eligible() {
    local img="$1"
    local time_format="$2"
    local stamp epoch now
    if [ -n "$(docker ps -aq --filter "ancestor=${img}" 2>/dev/null)" ]; then
        return 1
    fi
    stamp=$(docker image inspect -f "$time_format" "$img" 2>/dev/null) || return 1
    # Trim sub-second precision (and any trailing zone text after it) so GNU
    # date parses both Go formats: "2026-07-20T09:31:50.75Z" and
    # "2026-07-20 09:31:50.75 +0000 UTC". Both are UTC, and the trim drops
    # the zone marker — parse with -u or a non-UTC host skews every age.
    epoch=$(date -u -d "${stamp%%.*}" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    [ $((now - epoch)) -ge "$REAPER_MIN_AGE_SECONDS" ]
}

image_reaper_pass() {
    local img err removed=0
    # Agent-server images first (children of the bases) — every tag shape.
    while IFS= read -r img; do
        image_reaper_eligible "$img" '{{.Created}}' || continue
        if err=$(docker rmi "$img" 2>&1 >/dev/null); then
            removed=$((removed + 1))
        else
            echo "[reaper] rmi failed ${img}: $(printf '%s' "$err" | head -1)"
        fi
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -F 'eval-agent-server' || true)
    # Base images (registry tag + docker.io/swebench re-tag). Pinned ones
    # fail quietly; they free up next pass after their children are gone.
    while IFS= read -r img; do
        image_reaper_eligible "$img" '{{.Metadata.LastTagTime}}' || continue
        docker rmi "$img" >/dev/null 2>&1 && removed=$((removed + 1))
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E 'sweb\.eval|sweverified-swebench-images' \
        | grep -vF 'eval-agent-server' || true)
    if [ "$removed" -gt 0 ]; then
        echo "[reaper] pass removed ${removed} image tag(s)"
    fi
    docker image prune -f >/dev/null 2>&1 || true
    # FORCE_BUILD=1 rebuilds the agent-server image per instance; each build
    # leaves BuildKit cache that `docker rmi`/`image prune` NEVER touch, so it
    # grows unbounded (154GB observed on a 500-run). Only `builder prune` frees
    # it. Plain `-f` (no --keep-storage: that flag is deprecated/version-gated
    # and would silently no-op on rejection). Inactive cache only — the daemon
    # protects active/in-progress builds; between-attempt rebuilds cost ~3min,
    # the same trade-off already accepted for reaped images above.
    docker builder prune -f >/dev/null 2>&1 || true
}

image_reaper_loop() {
    set +e
    local pass=0
    while true; do
        sleep "$REAPER_INTERVAL_SECONDS"
        pass=$((pass + 1))
        image_reaper_pass
        # Disk observability roughly every 15 minutes.
        if [ $((pass % 5)) -eq 1 ]; then
            echo "[reaper] runner disk: $(df -h . 2>/dev/null | tail -1)"
            docker system df 2>/dev/null | sed 's/^/[reaper] /' || true
        fi
    done
}

start_image_reaper() {
    command -v docker >/dev/null 2>&1 || return 0
    image_reaper_loop &
    REAPER_PID=$!
    echo "[reaper] started (pid=${REAPER_PID}, interval=${REAPER_INTERVAL_SECONDS}s, min-age=${REAPER_MIN_AGE_SECONDS}s)"
}

stop_image_reaper() {
    if [ -n "$REAPER_PID" ]; then
        kill "$REAPER_PID" 2>/dev/null || true
        wait "$REAPER_PID" 2>/dev/null || true
        REAPER_PID=""
        echo "[reaper] stopped"
    fi
}

# Bulk-remove all remaining per-instance images after Step 1 so Step 2's
# evaluation pulls start with a clean disk. No age guard needed: inference is
# over, only in-use images (none expected) are skipped.
cleanup_step1_images() {
    command -v docker >/dev/null 2>&1 || return 0
    echo "[reaper] final cleanup: removing remaining per-instance images"
    local pattern img
    # Children (agent-server) first so base tags become deletable.
    for pattern in 'eval-agent-server' 'sweb\.eval\.'; do
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E "$pattern" \
            | while IFS= read -r img; do
                if [ -z "$(docker ps -aq --filter "ancestor=${img}" 2>/dev/null)" ]; then
                    docker rmi "$img" >/dev/null 2>&1 || true
                fi
            done
    done
    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true
    echo "[reaper] post-cleanup runner disk: $(df -h . 2>/dev/null | tail -1)"
    docker system df 2>/dev/null | sed 's/^/[reaper] /' || true
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

# The eval-runner periodically syncs repo/logs and repo/output, and may
# inject an explicit output dir via EVAL_RUNNER_OUTPUT_DIR (honored when
# present, mirroring terminal-bench-v2-agentic). Keep scoring artifacts in
# logs/, OpenHands interactions/runtime logs plus the dashboard result under
# the output root, and never place Docker workspaces in either path.
OUTPUT_ROOT="${EVAL_RUNNER_OUTPUT_DIR:-./output}"
DASHBOARD_LOG_DIR="./logs/${RUN_ID}"
DASHBOARD_OUTPUT_DIR="${OUTPUT_ROOT}/${RUN_ID}"
RESULTS_FILE="${OUTPUT_ROOT}/${RUN_ID}_results.json"
export EVAL_LOG_DIR="${DASHBOARD_OUTPUT_DIR}/openhands_runtime_logs"
export OPENHANDS_INTERACTION_LOG_DIR="${DASHBOARD_OUTPUT_DIR}/openhands_agent_logs"
mkdir -p "$EVAL_LOG_DIR" "$OPENHANDS_INTERACTION_LOG_DIR" "$OUTPUT_ROOT"

# Always-write guard: if we exit for ANY reason without a results file, drop
# a zero-metric one so the dashboard reports metrics instead of a silent
# FAILED with no artifact. Disarmed after the real results are written.
write_fallback_results() {
    [ -f "$RESULTS_FILE" ] && return 0
    local reason="${1:-unknown}"
    cat > "$RESULTS_FILE" <<JSON
{
  "metrics": {
    "main": { "name": "Total Resolved", "value": 0 },
    "secondary": { "pass@1": 0, "resolved": 0, "unresolved": 0, "total_tasks": 0 },
    "additional": { "status": "no-results", "reason": "${reason}" }
  }
}
JSON
    echo "[run] WARNING: wrote fallback zero-metric results (${reason}) -> ${RESULTS_FILE}"
}
on_exit_fallback() {
    local rc=$?
    stop_image_reaper
    write_fallback_results "interrupted-or-error (exit ${rc})"
}
trap on_exit_fallback EXIT

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
# No IMAGE_TAG_PREFIX override: benchmarks/utils/version.py derives image
# tags and the eval output dir from the actual SDK submodule SHA, keeping
# both consistent with whatever `make build` checked out.
export FORCE_BUILD=1
export SWEBENCH_REGISTRY_IMAGE_PACKAGE="${SWEBENCH_REGISTRY_IMAGE_PACKAGE:-sweverified-swebench-images}"

# --- Derive output dir from the harness itself (single source of truth) ---
# construct_eval_output_dir uses the real SDK submodule short SHA and the raw
# llm.model string ("openai/<model>", slash intact); querying it here keeps
# bash and Python from ever drifting apart on the path. The base is absolute
# so result writes keep working even if a build step changes the process cwd
# mid-run (observed on run 4cbf23b5: ENOENT on relative ./eval_outputs paths).
OUTPUT_DIR=$(MODEL="$MODEL" MAX_ITERATIONS="$MAX_ITERATIONS" uv run python -c "
import os
from benchmarks.utils.evaluation_utils import construct_eval_output_dir
print(construct_eval_output_dir(
    os.path.join(os.getcwd(), 'eval_outputs'),
    'princeton-nlp__SWE-bench_Verified-test',
    'openai/' + os.environ['MODEL'],
    int(os.environ['MAX_ITERATIONS']),
    None,
))" | tail -n 1)
if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: could not derive evaluation output dir (is 'make build' complete?)"
    exit 1
fi
echo "=== Output dir: ${OUTPUT_DIR} ==="

# --- DooD detection: gate the agent-server host fix ---
# The .pth patch installed by setup.sh activates only when this is "1", and
# only the inference step needs it (DockerWorkspace lives there). Native VM
# runs keep SDK behavior byte-identical.
DOOD_GATE=0
if [ -S /var/run/docker.sock ] && { [ -f /.dockerenv ] || [ -n "${EVAL_RUNNER_WORK_DIR:-}" ]; }; then
    DOOD_GATE=1
    echo "=== DooD environment detected: agent-server host fix ENABLED ==="
fi

# --- Build select args for task range ---
SELECT_ARGS=""
if [ -n "$TASK_RANGE" ]; then
    RANGE_START=$(echo "$TASK_RANGE" | cut -d'-' -f1)
    RANGE_END=$(echo "$TASK_RANGE" | cut -d'-' -f2)
    # --n-limit runs the FIRST N instances and the range is inclusive, so
    # 0-49 means 50 instances. Ranges not starting at 0 cannot be expressed.
    if [ "$RANGE_START" != "0" ]; then
        echo "WARNING: task ranges must start at 0 (--n-limit is first-N only); running 0-${RANGE_END} instead of ${TASK_RANGE}"
    fi
    N_LIMIT=$((RANGE_END + 1))
    echo "=== Task range: ${TASK_RANGE} -> first ${N_LIMIT} instances ==="
    SELECT_ARGS="--n-limit ${N_LIMIT}"
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
start_image_reaper
echo "=== Step 1: Inference (model=${MODEL}, workers=${NUM_WORKERS}) ==="
SWEV_DOOD_HOST_FIX="$DOOD_GATE" uv run swebench-infer "$LLM_CONFIG" \
    --dataset princeton-nlp/SWE-bench_Verified \
    --split test \
    --max-iterations "$MAX_ITERATIONS" \
    --workspace docker \
    --num-workers "$NUM_WORKERS" \
    --output-dir "${PWD}/eval_outputs" \
    --n-critic-runs 3 \
    $SELECT_ARGS

# Inference done — stop the reaper and clear all remaining per-instance
# images so Step 2's evaluation pulls have a clean disk.
stop_image_reaper
cleanup_step1_images

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
# Canonical dashboard shape (same as swe-auto-eval generate_results_json and
# terminal-bench-v2-agentic): metrics.main / metrics.secondary (flat scalars,
# rendered as columns) / metrics.additional (nested detail).
# The report alone under-counts: aggregate_results drops instances whose final
# attempt errored (iterative.py "if entry.error: continue"), so they never
# reach the SWE-bench harness. The attempt files still contain every attempted
# instance, so totals are reconciled against them.
echo "=== Step 3: Writing dashboard results ==="
OUTPUT_DIR="$OUTPUT_DIR" RESULTS_FILE="$RESULTS_FILE" python3 <<'PYEOF'
import glob
import json
import os

output_dir = os.environ["OUTPUT_DIR"]
results_file = os.environ["RESULTS_FILE"]

with open(os.path.join(output_dir, "output.report.json")) as f:
    report = json.load(f)

resolved = report.get("resolved_instances", 0)
completed = report.get("completed_instances", 0)
unresolved = report.get("unresolved_instances", 0)
errors = report.get("error_instances", 0)

# Every attempted instance has a row in output.critic_attempt_*.jsonl, even
# ones whose final attempt errored; output.jsonl holds only the error-free
# rows that were submitted for evaluation. Lines embed full agent history
# (can be MBs), so stream one at a time and keep only the needed fields.
attempted_ids = set()
for attempt_file in glob.glob(
    os.path.join(output_dir, "output.critic_attempt_*.jsonl")
):
    with open(attempt_file) as f:
        for line in f:
            try:
                instance_id = json.loads(line).get("instance_id")
            except ValueError:
                continue
            if instance_id:
                attempted_ids.add(instance_id)

submitted_ids = set()
generated = 0
try:
    with open(os.path.join(output_dir, "output.jsonl")) as f:
        for line in f:
            try:
                data = json.loads(line)
            except ValueError:
                continue
            instance_id = data.get("instance_id")
            if not instance_id:
                continue
            submitted_ids.add(instance_id)
            if (data.get("test_result") or {}).get("git_patch"):
                generated += 1
except OSError:
    pass

if attempted_ids:
    total = len(attempted_ids)
    infer_errors = len(attempted_ids - submitted_ids)
else:
    # No attempt files (unexpected layout) - fall back to report-only totals.
    total = completed or report.get("total_instances", 500)
    infer_errors = 0
    generated = completed

empty_patches = max(total - generated, 0)
pass_at_1 = round(resolved / total, 4) if total > 0 else 0

if infer_errors:
    print(
        f"WARNING: {infer_errors} of {total} attempted instances were dropped "
        "from output.jsonl due to inference errors and never reached the "
        "SWE-bench harness (see output.critic_attempt_*.jsonl for details)."
    )

results = {
    "metrics": {
        "main": {"name": "Total Resolved", "value": resolved},
        "secondary": {
            "pass@1": pass_at_1,
            "resolved": resolved,
            "unresolved": total - resolved,
            "total_tasks": total,
        },
        "additional": {
            "pass@1": {
                "generated": generated,
                "resolved": resolved,
                "unresolved": unresolved,
                "errors": errors,
                "empty_patches": empty_patches,
                "infer_errors": infer_errors,
                "submitted": len(submitted_ids) or completed,
            }
        },
    }
}

tmp = results_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(results, f, indent=2)
os.replace(tmp, results_file)
print(f"Results written to {results_file}")
print(json.dumps(results, indent=2))
PYEOF

# Real results written — disarm the fallback guard.
trap - EXIT

echo "=== Done! ==="
