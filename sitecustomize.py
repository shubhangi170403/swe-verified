"""
Top-level sitecustomize for narrowly scoped SWE-bench startup adapters.

Python will auto-import ``sitecustomize`` if it is importable on ``sys.path``.
During evaluation ``/workspace/benchmarks`` is on ``PYTHONPATH``, so placing
this file at the repo root guarantees the adapters run before swebench is used.
"""

import os
import sys


print("benchmarks sitecustomize imported", file=sys.stderr, flush=True)


def _apply_swebench_registry_layout_patch() -> None:
    """Apply the GAR package/tag mapping without importing OpenHands."""
    registry_repository = os.getenv("OPENHANDS_SWEBENCH_REGISTRY_REPOSITORY")
    if not registry_repository:
        return

    from swebench.harness.test_spec.test_spec import TestSpec

    current_getter = getattr(TestSpec.instance_image_key, "fget", None)
    if getattr(current_getter, "_openhands_registry_layout_patch", False):
        return

    def _registry_instance_image_key(self: TestSpec) -> str:
        instance = self.instance_id.lower().replace("__", "_1776_")
        image_tag = f"sweb.eval.{self.arch}.{instance}"
        return f"{registry_repository.rstrip('/')}:{image_tag}"

    _registry_instance_image_key._openhands_registry_layout_patch = True  # type: ignore[attr-defined]
    TestSpec.instance_image_key = property(_registry_instance_image_key)  # type: ignore[assignment]


try:
    _apply_swebench_registry_layout_patch()
except Exception as exc:
    # Do not break unrelated Python startup, but surface a useful cause when
    # the scoring subprocess explicitly requested the registry adapter.
    print(
        f"WARNING: failed to apply SWE-bench registry layout adapter: {exc}",
        file=sys.stderr,
        flush=True,
    )

try:
    # Reuse the actual patch logic that lives alongside the benchmarks package.
    from benchmarks.utils.sitecustomize import _apply_modal_logging_patch

    _apply_modal_logging_patch()
except Exception:
    # Avoid breaking startup for non-swebench runs; logging is best-effort.
    pass
