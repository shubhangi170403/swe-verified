"""Utilities for pulling pre-built Docker images from a container registry.

This module enables eval runners to pull images from Google Cloud Artifact
Registry (or any Docker-compatible registry) instead of building from Docker
Hub base images, avoiding Docker Hub rate limits.

The main entry point is :func:`pull_from_registry`.  When
``DOCKER_REGISTRY_URL`` is unset the function is a no-op and returns
``False``, preserving backward-compatible behavior.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys

from benchmarks.utils.constants import (
    DOCKER_REGISTRY_PULL_ENABLED,
    DOCKER_REGISTRY_URL,
)


logger = logging.getLogger(__name__)

# Pull timeout in seconds (large images may take a while over slow links).
_PULL_TIMEOUT = int(os.getenv("DOCKER_REGISTRY_PULL_TIMEOUT", "600"))


def refresh_gcp_auth(registry_url: str) -> bool:
    """Refresh Docker credentials using the GCP metadata server.

    On Google Cloud VMs the instance metadata server provides short-lived
    OAuth2 access tokens for the attached service account.  This function
    fetches a fresh token and runs ``docker login`` so that subsequent
    ``docker pull`` commands authenticate against Artifact Registry.

    The function is intentionally best-effort: it returns ``False`` on any
    failure (non-GCP environment, network issue, missing Docker CLI) so that
    the caller can fall back to existing credentials or a local build.
    """
    if sys.platform != "linux":
        return False

    try:
        meta = subprocess.run(
            [
                "curl",
                "-sf",
                "-H",
                "Metadata-Flavor: Google",
                "http://metadata.google.internal/computeMetadata/v1/"
                "instance/service-accounts/default/token",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if meta.returncode != 0:
            return False

        token = json.loads(meta.stdout).get("access_token", "")
        if not token:
            return False

        # Extract the registry hostname for the docker login command.
        # DOCKER_REGISTRY_URL is e.g. "us-central1-docker.pkg.dev/project/repo"
        # and we need just the hostname ("us-central1-docker.pkg.dev").
        registry_host = registry_url.split("/")[0]

        login = subprocess.run(
            [
                "docker",
                "login",
                "-u",
                "oauth2accesstoken",
                "--password-stdin",
                f"https://{registry_host}",
            ],
            input=token,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            timeout=10,
        )
        if login.returncode == 0:
            logger.debug("Docker credentials refreshed via GCP metadata server")
            return True

        logger.debug(
            "docker login failed (exit %d): %s",
            login.returncode,
            (login.stderr or "").strip(),
        )
        return False

    except Exception:
        # Non-fatal — the caller will fall back to local build.
        return False


def to_registry_image(local_image: str, registry_url: str) -> str:
    """Map a local image reference to its registry-qualified name.

    The convention (matching swe-auto-eval) is:
    1. Strip the original registry prefix (the first path component that
       looks like a hostname, i.e. contains a ``.`` or ``:``).
    2. Replace the first ``/`` in the remaining path with ``-`` so the
       image sits in a flat namespace inside the artifact registry repo.
    3. Prepend ``registry_url/``.

    Examples::

        >>> to_registry_image(
        ...     "ghcr.io/openhands/eval-agent-server:abc-tag",
        ...     "us-central1-docker.pkg.dev/proj/repo",
        ... )
        'us-central1-docker.pkg.dev/proj/repo/openhands-eval-agent-server:abc-tag'

        >>> to_registry_image(
        ...     "docker.io/swebench/sweb.eval.x86_64.foo:latest",
        ...     "us-central1-docker.pkg.dev/proj/repo",
        ... )
        'us-central1-docker.pkg.dev/proj/repo/swebench-sweb.eval.x86_64.foo:latest'
    """
    # Split off the tag/digest first so we only manipulate the name part.
    tag_sep = "@" if "@" in local_image else ":"
    if tag_sep in local_image.rsplit("/", 1)[-1]:
        name, tag = local_image.rsplit(tag_sep, 1)
    else:
        name, tag = local_image, ""

    parts = name.split("/")

    # Detect and strip the registry hostname (first component with '.' or ':').
    if parts and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        parts = parts[1:]

    # Flatten: join remaining parts with '-' for the first separator, keep
    # the rest as-is. E.g. ["openhands", "eval-agent-server"] -> "openhands-eval-agent-server"
    if len(parts) > 1:
        flat_name = parts[0] + "-" + "/".join(parts[1:])
    elif parts:
        flat_name = parts[0]
    else:
        flat_name = name

    registry_url = registry_url.rstrip("/")
    result = f"{registry_url}/{flat_name}"
    if tag:
        result = f"{result}{tag_sep}{tag}"
    return result


def pull_from_registry(local_image: str) -> bool:
    """Pull *local_image* from the configured artifact registry.

    Returns ``True`` if the image was successfully pulled and re-tagged with
    *local_image* so that downstream code can reference it by its original
    name.  Returns ``False`` on any failure or when registry pulling is
    disabled — **never raises**.

    The function is safe to call unconditionally; when
    ``DOCKER_REGISTRY_URL`` is unset it short-circuits immediately.
    """
    if not DOCKER_REGISTRY_PULL_ENABLED:
        return False

    registry_image = to_registry_image(local_image, DOCKER_REGISTRY_URL)
    logger.info(
        "Attempting to pull image from registry: %s",
        registry_image,
    )

    # Refresh GCP credentials (best-effort).
    refresh_gcp_auth(DOCKER_REGISTRY_URL)

    # Pull using the Docker CLI (not docker-py) to avoid credHelper
    # resolution issues with docker-py 7.x.
    try:
        pull = subprocess.run(
            ["docker", "pull", registry_image],
            env=os.environ.copy(),
            capture_output=True,
            text=True,
            timeout=_PULL_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        logger.warning(
            "docker pull timed out after %ds for %s",
            _PULL_TIMEOUT,
            registry_image,
        )
        return False
    except FileNotFoundError:
        logger.warning("docker CLI not found in PATH")
        return False

    if pull.returncode != 0:
        err = (pull.stderr or pull.stdout or "").strip()
        logger.warning(
            "docker pull failed (exit %d) for %s: %s",
            pull.returncode,
            registry_image,
            err,
        )
        return False

    logger.info("Successfully pulled %s from registry", registry_image)

    # Re-tag with the local image name so callers can reference it as usual.
    try:
        tag_result = subprocess.run(
            ["docker", "tag", registry_image, local_image],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if tag_result.returncode != 0:
            logger.warning(
                "docker tag failed for %s -> %s: %s",
                registry_image,
                local_image,
                (tag_result.stderr or "").strip(),
            )
            return False
    except Exception as exc:
        logger.warning(
            "Failed to re-tag %s as %s: %s", registry_image, local_image, exc
        )
        return False

    logger.info("Tagged registry image as %s", local_image)
    return True
