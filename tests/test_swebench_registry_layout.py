from swebench.harness.test_spec.test_spec import TestSpec

from sitecustomize import _apply_swebench_registry_layout_patch


def test_registry_layout_patch_uses_one_package_and_instance_tag(monkeypatch) -> None:
    original_property = TestSpec.instance_image_key
    monkeypatch.setattr(TestSpec, "instance_image_key", original_property)
    monkeypatch.setenv(
        "OPENHANDS_SWEBENCH_REGISTRY_REPOSITORY",
        "us-central1-docker.pkg.dev/project/evals/sweverified-swebench-images",
    )

    _apply_swebench_registry_layout_patch()

    spec = object.__new__(TestSpec)
    spec.instance_id = "django__django-12345"
    spec.arch = "x86_64"
    assert spec.instance_image_key == (
        "us-central1-docker.pkg.dev/project/evals/"
        "sweverified-swebench-images:"
        "sweb.eval.x86_64.django_1776_django-12345"
    )
