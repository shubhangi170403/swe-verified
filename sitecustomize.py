"""
Top-level sitecustomize for narrowly scoped SWE-bench startup adapters.

Python will auto-import ``sitecustomize`` if it is importable on ``sys.path``.
During evaluation ``/workspace/benchmarks`` is on ``PYTHONPATH``, so placing
this file at the repo root guarantees the adapters run before swebench is used.
"""

import sys


print("benchmarks sitecustomize imported", file=sys.stderr, flush=True)


from benchmarks.utils.swebench_registry_layout import apply_swebench_registry_layout_patch

try:
    apply_swebench_registry_layout_patch()
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
