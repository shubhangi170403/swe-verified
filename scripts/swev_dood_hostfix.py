"""DooD host fix for OpenHands ``DockerWorkspace`` health checks.

On the eval-dashboard Batch runner this benchmark's Python process runs inside
a Debian container that talks to the COS host's Docker daemon through a
bind-mounted socket (Docker-outside-of-Docker). ``DockerWorkspace`` publishes
the agent-server port on the *host* network namespace and then health-checks
``http://127.0.0.1:<host_port>`` — an address that only exists on the host, so
every check times out even though the server is up (proven on run 739ac5ae:
"Uvicorn running on http://0.0.0.0:8000" 11s after start, health timeout 120s
later).

setup.sh copies this module into the project venv's site-packages next to a
``.pth`` loader, so it is imported at every interpreter start in that venv.
It is inert unless ``SWEV_DOOD_HOST_FIX=1`` (exported by run.sh only for the
inference step and only when a DooD environment is detected), keeping
native-VM behavior byte-identical.

When active it replaces ``DockerWorkspace._wait_for_health`` with a version
that probes a ladder of candidate base URLs and rewrites ``workspace.host`` to
the first one that answers ``/health`` (all later agent API traffic reads
``self.host``, so this fixes the whole session, not just the health check):

1. the original ``http://127.0.0.1:<host_port>`` (native path),
2. the runner's default-gateway IP with the published port (docker-proxy),
3. the agent container's own IP(s) on port 8000 (same-network path),
4. after 30s of failures: ``docker network connect`` the agent container to
   the runner's own network(s), then retry its new IP (forced same-network).

On timeout it proves whether the server is up via a ``docker exec`` probe run
*inside* the agent container (topology-independent), logs every candidate's
last socket error plus a network topology dump, and raises the exact same
error message as the original so harness retry classification is unchanged.
"""

from __future__ import annotations

import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
from urllib.request import urlopen


_PREFIX = "[swev-dood]"
_AGENT_PORT = 8000
_NETWORK_CONNECT_AFTER_SECONDS = 30.0
_TIMEOUT_ERROR = "Container failed to become healthy in time"


def _log(message: str) -> None:
    print(f"{_PREFIX} {message}", file=sys.stderr, flush=True)


def _run(cmd: list[str], timeout: float = 10.0) -> tuple[int, str, str]:
    """Run a command, never raising; returns (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode, proc.stdout, proc.stderr
    except Exception as exc:  # noqa: BLE001 - diagnostics must never crash
        return 125, "", repr(exc)


def _default_gateway() -> str | None:
    """Default-route gateway IP from /proc/net/route (the docker bridge/host)."""
    try:
        with open("/proc/net/route", encoding="utf-8") as handle:
            for line in handle.readlines()[1:]:
                fields = line.split()
                if len(fields) < 4:
                    continue
                dest, gateway, flags = fields[1], fields[2], fields[3]
                if dest == "00000000" and int(flags, 16) & 0x2:
                    return socket.inet_ntoa(struct.pack("<L", int(gateway, 16)))
    except Exception:  # noqa: BLE001
        return None
    return None


def _container_networks(container_id: str) -> dict[str, str]:
    """Map of network name -> container IP for a container, {} on failure."""
    if not container_id:
        return {}
    code, out, _err = _run(
        [
            "docker",
            "inspect",
            "-f",
            "{{json .NetworkSettings.Networks}}",
            container_id,
        ]
    )
    if code != 0:
        return {}
    try:
        networks = json.loads(out.strip() or "{}")
    except ValueError:
        return {}
    result: dict[str, str] = {}
    if isinstance(networks, dict):
        for name, info in networks.items():
            if isinstance(info, dict):
                ip = info.get("IPAddress")
                if isinstance(ip, str) and ip:
                    result[str(name)] = ip
    return result


def _self_container_id() -> str | None:
    """This process's own container id, if discoverable via hostname/cgroup."""
    hostname = socket.gethostname()
    if re.fullmatch(r"[0-9a-f]{12,64}", hostname):
        code, _out, _err = _run(["docker", "inspect", "-f", "{{.Id}}", hostname])
        if code == 0:
            return hostname
    try:
        with open("/proc/self/cgroup", encoding="utf-8") as handle:
            match = re.search(r"([0-9a-f]{64})", handle.read())
            if match:
                return match.group(1)[:12]
    except Exception:  # noqa: BLE001
        pass
    return None


def _exec_probe(container_id: str) -> str:
    """Probe /health from INSIDE the agent container (topology-independent)."""
    if not container_id:
        return "no-container-id"
    probe = (
        "from urllib.request import urlopen; "
        f"print(urlopen('http://localhost:{_AGENT_PORT}/health', timeout=5).status)"
    )
    for python in ("python3", "/agent-server/.venv/bin/python"):
        code, out, err = _run(
            ["docker", "exec", container_id, python, "-c", probe], timeout=30.0
        )
        if code == 0:
            return f"SERVER UP inside container (HTTP {out.strip()} via {python})"
        if "executable file not found" not in err:
            return f"probe via {python} failed rc={code}: {err.strip()[:200]}"
    return "no usable python found in agent container"


def _topology_dump(agent_container_id: str) -> str:
    """One-shot network topology summary for the failure report."""
    lines: list[str] = []
    lines.append(f"self hostname={socket.gethostname()}")
    lines.append(f"self container id guess={_self_container_id()}")
    lines.append(f"default gateway={_default_gateway()}")
    self_id = _self_container_id()
    if self_id:
        lines.append(f"runner networks={_container_networks(self_id)}")
    else:
        lines.append("runner networks=UNKNOWN (self id not discoverable)")
    lines.append(f"agent networks={_container_networks(agent_container_id)}")
    code, out, _err = _run(
        ["docker", "network", "ls", "--format", "{{.Name}} {{.Driver}}"]
    )
    lines.append(f"daemon networks={out.strip() if code == 0 else 'UNKNOWN'}")
    return "; ".join(lines)


def _connect_agent_to_runner_networks(agent_container_id: str) -> bool:
    """Attach the agent container to the runner's network(s). True if any new."""
    self_id = _self_container_id()
    if not self_id:
        _log("network-connect skipped: runner container id not discoverable")
        return False
    runner_networks = _container_networks(self_id)
    if not runner_networks:
        _log("network-connect skipped: runner networks not discoverable")
        return False
    agent_networks = _container_networks(agent_container_id)
    connected = False
    for network in runner_networks:
        if network in agent_networks:
            continue
        code, _out, err = _run(
            ["docker", "network", "connect", network, agent_container_id],
            timeout=20.0,
        )
        if code == 0:
            _log(f"network-connect: attached agent container to '{network}'")
            connected = True
        else:
            _log(f"network-connect to '{network}' failed: {err.strip()[:200]}")
    return connected


def _health_ok(base_url: str) -> bool:
    with urlopen(f"{base_url}/health", timeout=1.0) as resp:
        status = getattr(resp, "status", 200)
        return 200 <= int(status) < 300


def _install() -> None:
    from openhands.workspace.docker.workspace import DockerWorkspace

    def _wait_for_health_dood(self: DockerWorkspace, *, timeout: float) -> None:
        start = time.time()
        container_id = str(getattr(self, "_container_id", "") or "")
        host_port = int(getattr(self, "host_port", 0) or 0)
        original_host = str(getattr(self, "host", "") or "").rstrip("/")
        if not original_host:
            original_host = f"http://127.0.0.1:{host_port}"

        # label -> [base_url, last_error]
        candidates: dict[str, list[str]] = {"localhost-published": [original_host, ""]}
        gateway = _default_gateway()
        if gateway:
            candidates["gateway-published"] = [f"http://{gateway}:{host_port}", ""]

        def _add_container_ip_candidates() -> None:
            for network, ip in _container_networks(container_id).items():
                candidates.setdefault(
                    f"container-ip({network})", [f"http://{ip}:{_AGENT_PORT}", ""]
                )

        _add_container_ip_candidates()
        _log(
            "active; probing /health via: "
            + ", ".join(f"{k}={v[0]}" for k, v in candidates.items())
        )

        network_connect_done = False
        while time.time() - start < timeout:
            for label, entry in list(candidates.items()):
                try:
                    if _health_ok(entry[0]):
                        object.__setattr__(self, "host", entry[0])
                        _log(f"health OK via {label} -> host={entry[0]}")
                        return
                except Exception as exc:  # noqa: BLE001
                    entry[1] = repr(exc)

            # Preserve the original dead-container detection and message shape.
            if container_id:
                code, out, _err = _run(
                    [
                        "docker",
                        "inspect",
                        "-f",
                        "{{.State.Running}}",
                        container_id,
                    ]
                )
                if code == 0 and out.strip() != "true":
                    _code, logs_out, logs_err = _run(
                        ["docker", "logs", container_id], timeout=30.0
                    )
                    raise RuntimeError(
                        f"Container stopped unexpectedly. Logs:\n{logs_out}\n{logs_err}"
                    )

            if (
                not network_connect_done
                and time.time() - start > _NETWORK_CONNECT_AFTER_SECONDS
            ):
                network_connect_done = True
                if _connect_agent_to_runner_networks(container_id):
                    _add_container_ip_candidates()
            time.sleep(1)

        _log(
            f"HEALTH TIMEOUT after {timeout:.0f}s; exec-probe: "
            f"{_exec_probe(container_id)}"
        )
        for label, entry in candidates.items():
            _log(f"candidate {label} {entry[0]} last_error={entry[1] or 'none'}")
        _log(f"topology: {_topology_dump(container_id)}")
        raise RuntimeError(_TIMEOUT_ERROR)

    setattr(_wait_for_health_dood, "_swev_dood", True)
    setattr(DockerWorkspace, "_wait_for_health", _wait_for_health_dood)
    _log("DockerWorkspace._wait_for_health patched for DooD host resolution")


if os.environ.get("SWEV_DOOD_HOST_FIX") == "1":
    try:
        _install()
    except Exception as exc:  # noqa: BLE001 - never break interpreter startup
        _log(f"patch NOT applied: {exc!r}")
