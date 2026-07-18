#!/usr/bin/env bash
# =============================================================================
# seed_artifact_registry.sh
#
# Standalone seeder script that pushes all locally-built eval Docker images
# to Google Cloud Artifact Registry so they are available for pulling during
# evals (avoiding Docker Hub rate limits).
#
# This script:
#   1. Authenticates to Artifact Registry via GCP metadata server or gcloud.
#   2. Discovers all locally-built eval images (agent-server, base, builder).
#   3. Re-tags each image with the Artifact Registry prefix.
#   4. Pushes each re-tagged image to the registry.
#
# No Python or pip dependencies required — pure bash + docker + curl.
#
# Usage:
#   ./seed_artifact_registry.sh                        # push all images
#   ./seed_artifact_registry.sh --dry-run              # list what would be pushed
#   ./seed_artifact_registry.sh --filter "django"      # push only matching images
#   ./seed_artifact_registry.sh --dry-run --filter "django"  # dry-run with filter
#   ./seed_artifact_registry.sh --parallel 4           # push 4 images concurrently
#   ./seed_artifact_registry.sh --help                 # show usage
#
# Environment variables:
#   DOCKER_REGISTRY_URL   Target registry (default: us-central1-docker.pkg.dev/xyne-dev-461113/eval-dashboard)
#   SEED_IMAGE_PREFIXES   Comma-separated local image prefixes to seed
#                         (default: ghcr.io/openhands/eval-agent-server,ghcr.io/openhands/eval-base,ghcr.io/openhands/eval-builder)
#   SEED_TIMEOUT          Timeout per push in seconds (default: 600)
#   GOOGLE_APPLICATION_CREDENTIALS  Path to SA key file (optional, for non-GCP VMs)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REGISTRY_URL="${DOCKER_REGISTRY_URL:-us-central1-docker.pkg.dev/xyne-dev-461113/eval-dashboard}"
IMAGE_PREFIXES="${SEED_IMAGE_PREFIXES:-ghcr.io/openhands/eval-agent-server,ghcr.io/openhands/eval-base,ghcr.io/openhands/eval-builder}"
PUSH_TIMEOUT="${SEED_TIMEOUT:-600}"
DRY_RUN=0
FILTER=""
PARALLEL=1
VERBOSE=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { echo "[$(_ts)] [INFO]    $*"; }
log_success() { echo "[$(_ts)] [OK]      $*"; }
log_warning() { echo "[$(_ts)] [WARNING] $*"; }
log_error()   { echo "[$(_ts)] [ERROR]   $*" >&2; }
log_debug()   { [[ "$VERBOSE" -eq 1 ]] && echo "[$(_ts)] [DEBUG]   $*" || true; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: seed_artifact_registry.sh [OPTIONS]

Push locally-built eval Docker images to Google Cloud Artifact Registry.

OPTIONS:
  --dry-run            List images that would be pushed, without pushing
  --filter PATTERN     Only process images whose name contains PATTERN
  --parallel N         Push N images concurrently (default: 1)
  --registry URL       Override target registry URL
  --verbose            Enable debug logging
  --help               Show this help message

ENVIRONMENT VARIABLES:
  DOCKER_REGISTRY_URL              Target registry (default: us-central1-docker.pkg.dev/xyne-dev-461113/eval-dashboard)
  SEED_IMAGE_PREFIXES              Comma-separated local image repo prefixes to discover
  SEED_TIMEOUT                     Per-push timeout in seconds (default: 600)
  GOOGLE_APPLICATION_CREDENTIALS   Path to GCP service account key (for non-GCP VMs)

EXAMPLES:
  # Dry run — see what would be pushed:
  ./seed_artifact_registry.sh --dry-run

  # Push all images:
  ./seed_artifact_registry.sh

  # Push only django-related images:
  ./seed_artifact_registry.sh --filter django

  # Push with 4 concurrent workers:
  ./seed_artifact_registry.sh --parallel 4

  # Use a custom registry:
  ./seed_artifact_registry.sh --registry us-east1-docker.pkg.dev/my-project/my-repo
USAGE
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --filter)     FILTER="$2"; shift 2 ;;
        --parallel)   PARALLEL="$2"; shift 2 ;;
        --registry)   REGISTRY_URL="$2"; shift 2 ;;
        --verbose)    VERBOSE=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        *)            log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    log_info "Running preflight checks..."

    # Docker CLI
    if ! command -v docker &>/dev/null; then
        log_error "docker CLI not found in PATH. Install Docker first."
        exit 1
    fi

    # Docker daemon reachable
    if ! timeout 10 docker info &>/dev/null; then
        log_error "Docker daemon not reachable (docker info failed)."
        exit 1
    fi

    # curl (needed for GCP metadata auth)
    if ! command -v curl &>/dev/null; then
        log_warning "curl not found — GCP metadata auth will be skipped."
    fi

    log_info "Registry URL: ${REGISTRY_URL}"
    log_info "Image prefixes: ${IMAGE_PREFIXES}"
    log_info "Parallel workers: ${PARALLEL}"
    log_info "Push timeout: ${PUSH_TIMEOUT}s"
    [[ "$DRY_RUN" -eq 1 ]] && log_info "Mode: DRY RUN (no images will be pushed)"

    log_success "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Authenticate to Artifact Registry
# ---------------------------------------------------------------------------
authenticate() {
    local registry_host
    registry_host="${REGISTRY_URL%%/*}"

    log_info "Authenticating to ${registry_host}..."

    # Method 1: GCP metadata server (on GCP VMs)
    if command -v curl &>/dev/null; then
        local token
        token=$(curl -sf --max-time 5 \
            -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
            | _extract_json_field "access_token" || true)

        if [[ -n "${token:-}" ]]; then
            echo "${token}" | docker login -u oauth2accesstoken --password-stdin \
                "https://${registry_host}" &>/dev/null && {
                log_success "Authenticated via GCP metadata server"
                return 0
            }
        fi
    fi

    # Method 2: gcloud credential helper
    if command -v gcloud &>/dev/null; then
        gcloud auth configure-docker "${registry_host}" --quiet &>/dev/null && {
            log_success "Authenticated via gcloud credential helper"
            return 0
        }
    fi

    # Method 3: Service account key file
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
        local sa_token
        sa_token=$(gcloud auth print-access-token 2>/dev/null || true)
        if [[ -n "${sa_token:-}" ]]; then
            echo "${sa_token}" | docker login -u oauth2accesstoken --password-stdin \
                "https://${registry_host}" &>/dev/null && {
                log_success "Authenticated via service account key"
                return 0
            }
        fi
    fi

    # Method 4: Existing Docker credentials (already logged in)
    if docker pull "https://${registry_host}/v2/" &>/dev/null 2>&1 || true; then
        log_warning "No explicit auth configured — relying on existing Docker credentials."
        log_warning "If pushes fail with 401/403, run: gcloud auth configure-docker ${registry_host}"
        return 0
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Minimal JSON field extractor (no jq dependency)
# ---------------------------------------------------------------------------
_extract_json_field() {
    local field="$1"
    # Handles: "field": "value" or "field":"value"
    python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('${field}', ''))
" 2>/dev/null || {
        # Fallback: grep + sed for minimal environments without python3
        grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 \
            | sed "s/\"${field}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
    }
}

# ---------------------------------------------------------------------------
# Image name transformation: local -> registry
#
# Matches the to_registry_image() function in registry_utils.py:
#   ghcr.io/openhands/eval-agent-server:tag
#   -> us-central1-docker.pkg.dev/proj/repo/openhands-eval-agent-server:tag
#
# Steps:
#   1. Strip the original registry hostname (first component with '.' or ':')
#   2. Replace the first '/' with '-' to flatten the namespace
#   3. Prepend REGISTRY_URL
# ---------------------------------------------------------------------------
to_registry_image() {
    local local_image="$1"
    local tag=""
    local name=""

    # Split tag/digest from name
    # Handle both name:tag and name@sha256:digest
    if [[ "$local_image" == *"@"* ]]; then
        name="${local_image%%@*}"
        tag="@${local_image#*@}"
    elif [[ "${local_image##*/}" == *":"* ]]; then
        # Tag is after the last slash's colon (not registry:port)
        name="${local_image%:*}"
        tag=":${local_image##*:}"
    else
        name="$local_image"
        tag=""
    fi

    # Split into path components
    IFS='/' read -ra parts <<< "$name"

    # Strip registry hostname (first component containing '.' or ':')
    if [[ "${parts[0]}" == *"."* || "${parts[0]}" == *":"* || "${parts[0]}" == "localhost" ]]; then
        parts=("${parts[@]:1}")
    fi

    # Flatten: first '/' -> '-'
    if [[ ${#parts[@]} -gt 1 ]]; then
        local first="${parts[0]}"
        local rest
        rest=$(IFS='/'; echo "${parts[*]:1}")
        local flat_name="${first}-${rest}"
    elif [[ ${#parts[@]} -eq 1 ]]; then
        local flat_name="${parts[0]}"
    else
        local flat_name="$name"
    fi

    local registry
    registry="${REGISTRY_URL%/}"

    echo "${registry}/${flat_name}${tag}"
}

# ---------------------------------------------------------------------------
# Discover all local images matching our prefixes
# ---------------------------------------------------------------------------
discover_images() {
    local -a all_images=()

    IFS=',' read -ra prefixes <<< "$IMAGE_PREFIXES"
    for prefix in "${prefixes[@]}"; do
        prefix=$(echo "$prefix" | xargs)  # trim whitespace
        log_debug "Discovering images with prefix: ${prefix}"

        # List all images matching this prefix (repo:tag format)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Apply filter if set
            if [[ -n "$FILTER" && "$line" != *"$FILTER"* ]]; then
                continue
            fi
            all_images+=("$line")
        done < <(docker images --format '{{.Repository}}:{{.Tag}}' \
                    --filter "reference=${prefix}:*" 2>/dev/null \
                 | grep -v '<none>' \
                 | sort -u)
    done

    printf '%s\n' "${all_images[@]}"
}

# ---------------------------------------------------------------------------
# Push a single image
# ---------------------------------------------------------------------------
push_single_image() {
    local local_image="$1"
    local registry_image
    registry_image=$(to_registry_image "$local_image")

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [DRY RUN] ${local_image}"
        echo "         -> ${registry_image}"
        return 0
    fi

    log_info "Tagging:  ${local_image} -> ${registry_image}"
    if ! docker tag "$local_image" "$registry_image" 2>/dev/null; then
        log_error "Failed to tag ${local_image} as ${registry_image}"
        return 1
    fi

    log_info "Pushing:  ${registry_image}"
    local push_output
    if push_output=$(timeout "${PUSH_TIMEOUT}" docker push "$registry_image" 2>&1); then
        log_success "Pushed:   ${registry_image}"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Push timed out after ${PUSH_TIMEOUT}s: ${registry_image}"
        else
            log_error "Push failed (exit ${exit_code}): ${registry_image}"
            log_error "  ${push_output}"
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    preflight

    if [[ "$DRY_RUN" -eq 0 ]]; then
        authenticate
    fi

    log_info "Discovering local images..."
    local -a images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done < <(discover_images)

    local total=${#images[@]}
    if [[ $total -eq 0 ]]; then
        log_warning "No images found matching prefixes: ${IMAGE_PREFIXES}"
        [[ -n "$FILTER" ]] && log_warning "  (with filter: '${FILTER}')"
        log_info "Make sure images are built locally before running the seeder."
        log_info "  Example: cd benchmarks && python -m benchmarks.swebench.build_images --dataset princeton-nlp/SWE-bench_Verified --split test"
        exit 0
    fi

    log_info "Found ${total} image(s) to seed"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo ""
        echo "============================================"
        echo "  DRY RUN — Images that would be pushed:"
        echo "============================================"
        echo ""
        local count=0
        for img in "${images[@]}"; do
            count=$((count + 1))
            echo "[${count}/${total}]"
            push_single_image "$img"
            echo ""
        done
        echo "============================================"
        echo "  Total: ${total} image(s)"
        echo "  Registry: ${REGISTRY_URL}"
        echo "============================================"
        echo ""
        log_info "Re-run without --dry-run to push these images."
        exit 0
    fi

    # Push images (with optional parallelism)
    local succeeded=0
    local failed=0
    local count=0

    if [[ "$PARALLEL" -le 1 ]]; then
        # Sequential push
        for img in "${images[@]}"; do
            count=$((count + 1))
            log_info "[${count}/${total}] Processing: ${img}"
            if push_single_image "$img"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
        done
    else
        # Parallel push using background jobs
        local -a pids=()
        local -a pid_images=()
        local running=0

        for img in "${images[@]}"; do
            count=$((count + 1))
            log_info "[${count}/${total}] Queuing: ${img}"

            push_single_image "$img" &
            pids+=($!)
            pid_images+=("$img")
            running=$((running + 1))

            # Wait for a slot if we've hit the parallel limit
            if [[ $running -ge $PARALLEL ]]; then
                # Wait for any one child to finish
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null && succeeded=$((succeeded + 1)) || failed=$((failed + 1))
                        unset 'pids[i]'
                        unset 'pid_images[i]'
                        running=$((running - 1))
                        break
                    fi
                done
                # Compact arrays
                pids=("${pids[@]}")
                pid_images=("${pid_images[@]}")

                # If still at limit, wait for the oldest
                if [[ $running -ge $PARALLEL && ${#pids[@]} -gt 0 ]]; then
                    wait "${pids[0]}" 2>/dev/null && succeeded=$((succeeded + 1)) || failed=$((failed + 1))
                    pids=("${pids[@]:1}")
                    pid_images=("${pid_images[@]:1}")
                    running=$((running - 1))
                fi
            fi
        done

        # Wait for remaining jobs
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null && succeeded=$((succeeded + 1)) || failed=$((failed + 1))
        done
    fi

    # Summary
    echo ""
    echo "============================================"
    echo "  Seeding Complete"
    echo "============================================"
    echo "  Registry:  ${REGISTRY_URL}"
    echo "  Total:     ${total}"
    echo "  Succeeded: ${succeeded}"
    echo "  Failed:    ${failed}"
    echo "============================================"

    if [[ $failed -gt 0 ]]; then
        log_error "${failed} image(s) failed to push. Re-run to retry."
        exit 1
    fi

    log_success "All ${succeeded} image(s) seeded successfully."
}

main "$@"
