"""Local Agent readiness; no service configuration or model request is accessed."""
from importlib import import_module, metadata


# These are the runtime pins in pyproject.toml and requirements.txt, not detected
# versions. Health publishes only metadata actually read from this interpreter.
ASSISTANT_DISTRIBUTIONS = (
    ("pydantic-ai-harness", "harnessVersion", "0.52.0"),
    ("pydantic-ai-slim", "sdkVersion", "2.52.0"),
    ("ag-ui-protocol", "protocolVersion", "0.1.22"),
)
ASSISTANT_INSTALL_HINT = (
    "AI Agent dependencies are unavailable or incompatible. Follow docs/python-api.md: "
    "install python/requirements.txt in the local virtual environment, then restart the companion service. "
    "Ordinary Python generation remains available."
)


def assistant_runtime_status():
    """Check installed pins and the real entry points without invoking a model.

    Do not cache failures: a later check can recover after dependency repair.
    Raw import/metadata exceptions can contain paths and are never returned.
    """
    result = {"runtime": "Pydantic AI Harness", "ready": False}
    valid = True
    for distribution, field, expected in ASSISTANT_DISTRIBUTIONS:
        try:
            result[field] = metadata.version(distribution)
        except Exception:
            result[field] = None
        valid = valid and result[field] == expected
    if valid:
        try:
            import_module("ag_ui.core")
            import_module("ag_ui.encoder")
            import_module(f"{__package__}.assistant")
        except Exception:
            valid = False
    if valid:
        result["ready"] = True
    else:
        result["code"] = "ASSISTANT_DEPENDENCIES_UNAVAILABLE"
        result["error"] = ASSISTANT_INSTALL_HINT
    return result
