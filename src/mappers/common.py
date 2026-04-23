from typing import Any

_NULL_LIKE_TEXT_VALUES = {
    "null",
    "none",
    "undefined",
    "n/a",
    "na",
}


def normalize_optional_text(value: Any) -> str | None:
    if value is None:
        return None

    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return None
        if stripped.lower() in _NULL_LIKE_TEXT_VALUES:
            return None
        return stripped

    return str(value)


def split_name(value: str | None) -> tuple[str | None, str | None]:
    normalized = normalize_optional_text(value)
    if not normalized:
        return None, None

    parts = normalized.split(maxsplit=1)
    first_name = normalize_optional_text(parts[0]) if parts else None
    last_name = normalize_optional_text(parts[1]) if len(parts) > 1 else None
    return first_name, last_name
