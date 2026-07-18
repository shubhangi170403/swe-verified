import json

from benchmarks.utils.conversation import (
    MAX_EVENT_SIZE_BYTES,
    build_event_persistence_callback,
)


class FakeEvent:
    def __init__(self, payload: str) -> None:
        self.payload = payload
        self.id = "event-1"
        self.source = "agent"

    def model_dump_json(self, exclude_none: bool = True) -> str:
        return json.dumps({"payload": self.payload, "source": self.source})


def test_interaction_log_retains_normal_events(tmp_path) -> None:
    callback = build_event_persistence_callback(
        run_id="run-1",
        instance_id="django__django-1234",
        show_trajectory=False,
        interaction_log_dir=tmp_path,
    )

    callback(FakeEvent("agent message"))  # type: ignore[arg-type]

    record = json.loads((tmp_path / "django__django-1234.jsonl").read_text().strip())
    assert record["instance_id"] == "django__django-1234"
    assert record["event_type"] == "FakeEvent"
    assert record["event"]["payload"] == "agent message"
    assert "truncated" not in record


def test_interaction_log_truncates_abnormally_large_events(tmp_path) -> None:
    callback = build_event_persistence_callback(
        run_id="run-1",
        instance_id="django__django-1234",
        show_trajectory=False,
        interaction_log_dir=tmp_path,
    )

    callback(FakeEvent("x" * (MAX_EVENT_SIZE_BYTES + 1)))  # type: ignore[arg-type]

    record = json.loads((tmp_path / "django__django-1234.jsonl").read_text().strip())
    assert record["truncated"] is True
    assert record["event_size"] > MAX_EVENT_SIZE_BYTES
    assert "event" not in record
