#!/usr/bin/env bash
# =============================================================================
# seed_artifact_registry.sh
#
# Mirror the official per-instance SWE-bench images into Google Cloud Artifact
# Registry. OpenHands still builds its agent-server derivative locally during
# inference; only the canonical images used as that build's base and by the
# scoring harness are persisted in Artifact Registry.
#
# For the 500-instance SWE-bench Verified test split this seeds exactly 500
# image tags (before applying --filter or --limit) under one Artifact Registry
# package, matching the storage convention used by SWE-Pro and SWE-Atlas:
#
#   docker.io/swebench/sweb.eval.x86_64.<instance>:latest
#     -> <registry>/sweverified-swebench-images:sweb.eval.x86_64.<instance>
#
# Inference and scoring translate this registry-only name back to the official
# SWE-bench image identity. Image contents and benchmark behavior are unchanged.
# =============================================================================

set -euo pipefail

REGISTRY_URL="${DOCKER_REGISTRY_URL:-us-central1-docker.pkg.dev/xyne-dev-461113/eval-dashboard}"
IMAGE_PACKAGE="${SWEBENCH_REGISTRY_IMAGE_PACKAGE:-sweverified-swebench-images}"
DATASET="princeton-nlp/SWE-bench_Verified"
SPLIT="test"
PUSH_TIMEOUT="${SEED_TIMEOUT:-600}"
PULL_TIMEOUT="${SEED_PULL_TIMEOUT:-600}"
PLATFORM="${SEED_PLATFORM:-linux/amd64}"
DRY_RUN=0
SKIP_PULL=0
FILTER=""
PARALLEL=1
LIMIT=200
VERBOSE=0
DEPRECATED_BUILD_WORKERS=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { echo "[$(_ts)] [INFO]    $*"; }
log_success() { echo "[$(_ts)] [OK]      $*"; }
log_warning() { echo "[$(_ts)] [WARNING] $*"; }
log_error()   { echo "[$(_ts)] [ERROR]   $*" >&2; }
log_debug()   { [[ "$VERBOSE" -eq 1 ]] && echo "[$(_ts)] [DEBUG]   $*" || true; }

usage() {
    cat <<'USAGE'
Usage: seed_artifact_registry.sh [OPTIONS]

Mirror official SWE-bench images into Google Cloud Artifact Registry.

OPTIONS:
  --dry-run            List source and destination images without changing anything
  --skip-pull          Use only official images already present locally
  --skip-build         Deprecated alias for --skip-pull
  --dataset NAME       Dataset to seed (default: princeton-nlp/SWE-bench_Verified)
  --split NAME         Dataset split to seed (default: test)
  --limit N            Process at most N missing images (default: 200; 0 = all)
  --filter PATTERN     Only process image names containing PATTERN
  --parallel N         Pull/push N images concurrently (default: 1)
  --registry URL       Override the destination Artifact Registry repository
  --image-package NAME Override the single Artifact Registry package name
  --verbose            Enable debug logging
  --help, -h           Show this help

ENVIRONMENT VARIABLES:
  DOCKER_REGISTRY_URL            Destination registry repository
  SWEBENCH_REGISTRY_IMAGE_PACKAGE Single package containing per-instance tags
  SEED_TIMEOUT                   Per-push timeout in seconds (default: 600)
  SEED_PULL_TIMEOUT              Per-pull timeout in seconds (default: 600)
  SEED_PLATFORM                  Image platform (default: linux/amd64)
  GOOGLE_APPLICATION_CREDENTIALS Service-account key for non-GCP machines

EXAMPLES:
  # Show all 500 Verified image mappings:
  ./scripts/seed_artifact_registry.sh --dry-run --limit 0

  # Seed the next 200 missing images, eight at a time:
  ./scripts/seed_artifact_registry.sh --limit 200 --parallel 8

  # Process every missing image in one invocation:
  ./scripts/seed_artifact_registry.sh --limit 0 --parallel 8

  # Seed only images already downloaded locally:
  ./scripts/seed_artifact_registry.sh --skip-pull
USAGE
}

require_value() {
    local option="$1"
    local remaining="$2"
    if [[ "$remaining" -lt 2 ]]; then
        log_error "${option} requires a value"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-pull|--skip-build)
            SKIP_PULL=1
            shift
            ;;
        --dataset)
            require_value "$1" "$#"
            DATASET="$2"
            shift 2
            ;;
        --split)
            require_value "$1" "$#"
            SPLIT="$2"
            shift 2
            ;;
        --limit)
            require_value "$1" "$#"
            LIMIT="$2"
            shift 2
            ;;
        --filter)
            require_value "$1" "$#"
            FILTER="$2"
            shift 2
            ;;
        --parallel)
            require_value "$1" "$#"
            PARALLEL="$2"
            shift 2
            ;;
        --registry)
            require_value "$1" "$#"
            REGISTRY_URL="$2"
            shift 2
            ;;
        --image-package)
            require_value "$1" "$#"
            IMAGE_PACKAGE="$2"
            shift 2
            ;;
        --build-workers)
            require_value "$1" "$#"
            DEPRECATED_BUILD_WORKERS="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    log_error "--parallel must be a positive integer"
    exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
    log_error "--limit must be a non-negative integer"
    exit 1
fi

run_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
    else
        "$@"
    fi
}

preflight() {
    log_info "Running preflight checks..."

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker CLI not found in PATH"
        exit 1
    fi
    if ! run_with_timeout 10 docker info >/dev/null 2>&1; then
        log_error "Docker daemon not reachable"
        exit 1
    fi
    if ! command -v uv >/dev/null 2>&1; then
        log_error "uv not found in PATH"
        exit 1
    fi

    [[ -n "$DEPRECATED_BUILD_WORKERS" ]] && \
        log_warning "--build-workers is ignored; this workflow does not build images"
    [[ "$SKIP_PULL" -eq 1 ]] && \
        log_info "Source pulls disabled; using only locally available official images"
    [[ "$DRY_RUN" -eq 1 ]] && log_info "Mode: DRY RUN"

    log_info "Dataset: ${DATASET} (${SPLIT})"
    log_info "Registry: ${REGISTRY_URL%/}"
    log_info "Image package: ${IMAGE_PACKAGE}"
    log_info "Platform: ${PLATFORM}"
    log_info "Parallel workers: ${PARALLEL}"
    log_success "Preflight checks passed"
}

authenticate() {
    local registry_host
    registry_host="${REGISTRY_URL%%/*}"
    log_info "Authenticating to ${registry_host}..."

    if command -v curl >/dev/null 2>&1; then
        local token
        token=$(curl -sf --max-time 5 \
            -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
            2>/dev/null | python3 -c \
            'import json, sys; print(json.load(sys.stdin).get("access_token", ""))' \
            2>/dev/null || true)
        if [[ -n "${token:-}" ]]; then
            if echo "$token" | docker login -u oauth2accesstoken --password-stdin \
                "https://${registry_host}" >/dev/null 2>&1; then
                log_success "Authenticated via GCP metadata server"
                return 0
            fi
        fi
    fi

    if command -v gcloud >/dev/null 2>&1; then
        if gcloud auth configure-docker "$registry_host" --quiet >/dev/null 2>&1; then
            log_success "Configured gcloud Docker credential helper"
            return 0
        fi
    fi

    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && \
          -f "${GOOGLE_APPLICATION_CREDENTIALS}" && \
          -x "$(command -v gcloud 2>/dev/null || true)" ]]; then
        local service_account_token
        service_account_token=$(gcloud auth print-access-token 2>/dev/null || true)
        if [[ -n "$service_account_token" ]]; then
            if echo "$service_account_token" | docker login \
                -u oauth2accesstoken --password-stdin \
                "https://${registry_host}" >/dev/null 2>&1; then
                log_success "Authenticated with service-account credentials"
                return 0
            fi
        fi
    fi

    log_warning "No new registry credentials were configured; using existing Docker credentials"
}

list_official_images() {
    (
        cd "$SCRIPT_DIR"
        uv run python - "$DATASET" "$SPLIT" <<'PY'
import sys

from datasets import load_dataset

dataset, split = sys.argv[1:3]
rows = load_dataset(dataset, split=split)
instance_ids = sorted({str(row["instance_id"]) for row in rows})
for instance_id in instance_ids:
    repo, name = instance_id.split("__", 1)
    image = (
        "docker.io/swebench/"
        f"sweb.eval.x86_64.{repo}_1776_{name}:latest"
    ).lower()
    print(f"__SWE_IMAGE__{image}")
PY
    )
}

# Consolidate official images into one Artifact Registry package. The official
# image basename becomes the tag, which is unique for every Verified instance:
# docker.io/swebench/sweb.eval.x86_64.foo:latest
#   -> <registry>/<package>:sweb.eval.x86_64.foo
to_registry_image() {
    local source_image="$1"
    local name="$source_image"

    if [[ "$name" == *"@"* ]]; then
        name="${name%%@*}"
    elif [[ "${name##*/}" == *":"* ]]; then
        name="${name%:*}"
    fi

    local image_tag="${name##*/}"
    image_tag=$(printf '%s' "$image_tag" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$image_tag" =~ ^[a-z0-9_][a-z0-9_.-]{0,127}$ ]]; then
        log_error "Official image name cannot be used as a registry tag: ${image_tag}"
        return 1
    fi

    echo "${REGISTRY_URL%/}/${IMAGE_PACKAGE}:${image_tag}"
}

image_exists_in_registry() {
    local registry_image="$1"
    docker manifest inspect "$registry_image" >/dev/null 2>&1
}

push_single_image() {
    local source_image="$1"
    local registry_image
    registry_image=$(to_registry_image "$source_image")
    local source_was_local=0
    local destination_was_local=0

    if docker image inspect "$source_image" >/dev/null 2>&1; then
        source_was_local=1
        log_debug "Using existing local source image: ${source_image}"
    elif [[ "$SKIP_PULL" -eq 1 ]]; then
        log_error "Official image is not available locally: ${source_image}"
        return 1
    else
        log_info "Pulling:  ${source_image}"
        local pull_output
        if ! pull_output=$(run_with_timeout "$PULL_TIMEOUT" \
            docker pull --platform "$PLATFORM" "$source_image" 2>&1); then
            log_error "Pull failed: ${source_image}"
            log_error "  ${pull_output}"
            return 1
        fi
    fi

    if docker image inspect "$registry_image" >/dev/null 2>&1; then
        local source_id
        local destination_id
        source_id=$(docker image inspect --format '{{.Id}}' "$source_image")
        destination_id=$(docker image inspect --format '{{.Id}}' "$registry_image")
        if [[ "$source_id" != "$destination_id" ]]; then
            log_error "Refusing to overwrite existing local tag: ${registry_image}"
            [[ "$source_was_local" -eq 0 ]] && \
                docker rmi "$source_image" >/dev/null 2>&1 || true
            return 1
        fi
        destination_was_local=1
        log_debug "Preserving existing local destination tag: ${registry_image}"
    else
        log_info "Tagging:  ${source_image} -> ${registry_image}"
        if ! docker tag "$source_image" "$registry_image"; then
            log_error "Failed to tag ${source_image} as ${registry_image}"
            [[ "$source_was_local" -eq 0 ]] && \
                docker rmi "$source_image" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    log_info "Pushing:  ${registry_image}"
    local push_output
    if ! push_output=$(run_with_timeout "$PUSH_TIMEOUT" docker push "$registry_image" 2>&1); then
        log_error "Push failed: ${registry_image}"
        log_error "  ${push_output}"
        [[ "$destination_was_local" -eq 0 ]] && \
            docker rmi "$registry_image" >/dev/null 2>&1 || true
        # Retain a newly pulled source after a failed push so a retry need not
        # redownload it. Pre-existing local images are always left untouched.
        return 1
    fi

    log_success "Pushed:   ${registry_image}"
    if [[ "$destination_was_local" -eq 0 ]]; then
        docker rmi "$registry_image" >/dev/null 2>&1 || true
    fi
    if [[ "$source_was_local" -eq 0 ]]; then
        docker rmi "$source_image" >/dev/null 2>&1 || true
    fi
    return 0
}

main() {
    preflight

    local -a all_images=()
    log_info "Loading official image names from the dataset..."
    while IFS= read -r image; do
        [[ "$image" != __SWE_IMAGE__* ]] && continue
        image="${image#__SWE_IMAGE__}"
        [[ -n "$FILTER" && "$image" != *"$FILTER"* ]] && continue
        all_images+=("$image")
    done < <(list_official_images)

    if [[ ${#all_images[@]} -eq 0 ]]; then
        log_error "No official images were found"
        [[ -n "$FILTER" ]] && log_error "Filter: ${FILTER}"
        exit 1
    fi

    log_info "Found ${#all_images[@]} unique official image(s)"

    local -a pending_images=()
    local skipped=0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        pending_images=("${all_images[@]}")
    else
        authenticate
        log_info "Checking Artifact Registry for images already seeded..."
        local image
        for image in "${all_images[@]}"; do
            if image_exists_in_registry "$(to_registry_image "$image")"; then
                skipped=$((skipped + 1))
                log_debug "Already seeded: $(to_registry_image "$image")"
            else
                pending_images+=("$image")
            fi
        done
    fi

    if [[ ${#pending_images[@]} -eq 0 ]]; then
        log_success "All ${#all_images[@]} official image(s) are already seeded"
        exit 0
    fi

    local available=${#pending_images[@]}
    local -a images=()
    if [[ "$LIMIT" -gt 0 && "$available" -gt "$LIMIT" ]]; then
        images=("${pending_images[@]:0:$LIMIT}")
    else
        images=("${pending_images[@]}")
    fi

    local total=${#images[@]}
    local remaining=$((available - total))

    if [[ "$DRY_RUN" -eq 1 ]]; then
        local count=0
        local source_image
        for source_image in "${images[@]}"; do
            count=$((count + 1))
            echo "[${count}/${total}] ${source_image}"
            echo "             -> $(to_registry_image "$source_image")"
        done
        echo ""
        echo "Total listed: ${total}"
        [[ "$remaining" -gt 0 ]] && echo "Remaining after limit: ${remaining}"
        exit 0
    fi

    log_info "Processing ${total} image(s); ${skipped} already seeded"

    local succeeded=0
    local failed=0
    local queued=0

    if [[ "$PARALLEL" -eq 1 ]]; then
        local source_image
        for source_image in "${images[@]}"; do
            queued=$((queued + 1))
            log_info "[${queued}/${total}] ${source_image}"
            if push_single_image "$source_image"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
        done
    else
        local -a pids=()
        local source_image
        for source_image in "${images[@]}"; do
            queued=$((queued + 1))
            log_info "[${queued}/${total}] Queueing ${source_image}"
            push_single_image "$source_image" &
            pids+=("$!")

            if [[ ${#pids[@]} -ge "$PARALLEL" ]]; then
                if wait "${pids[0]}"; then
                    succeeded=$((succeeded + 1))
                else
                    failed=$((failed + 1))
                fi
                pids=("${pids[@]:1}")
            fi
        done

        local pid
        for pid in "${pids[@]}"; do
            if wait "$pid"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
        done
    fi

    echo ""
    echo "============================================"
    echo "  Official SWE-bench Image Seeding Complete"
    echo "============================================"
    echo "  Registry:       ${REGISTRY_URL%/}"
    echo "  Processed:      ${total}"
    echo "  Succeeded:      ${succeeded}"
    echo "  Failed:         ${failed}"
    echo "  Already seeded: ${skipped}"
    [[ "$remaining" -gt 0 ]] && echo "  Remaining:      ${remaining}"
    echo "============================================"

    if [[ "$failed" -gt 0 ]]; then
        log_error "${failed} image(s) failed; rerun to retry"
        exit 1
    fi

    log_success "Seeded ${succeeded} official image(s) successfully"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
