import os

from swebench.harness.test_spec.test_spec import TestSpec


def apply_swebench_registry_layout_patch() -> None:
    """Apply the GAR package/tag mapping without importing OpenHands."""
    registry_repository = os.getenv("OPENHANDS_SWEBENCH_REGISTRY_REPOSITORY")
    if not registry_repository:
        return

    current_getter = getattr(TestSpec.instance_image_key, "fget", None)
    if getattr(current_getter, "_openhands_registry_layout_patch", False):
        return

    def _registry_instance_image_key(self: TestSpec) -> str:
        instance = self.instance_id.lower().replace("__", "_1776_")
        image_tag = f"sweb.eval.{self.arch}.{instance}"
        return f"{registry_repository.rstrip('/')}:{image_tag}"

    _registry_instance_image_key._openhands_registry_layout_patch = True  # type: ignore[attr-defined]
    TestSpec.instance_image_key = property(_registry_instance_image_key)  # type: ignore[assignment]
