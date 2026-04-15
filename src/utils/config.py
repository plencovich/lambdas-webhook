import os


def get_env(name: str, default: str | None = None, required: bool = False) -> str | None:
    value = os.getenv(name, default)
    if required and (value is None or value == ""):
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def get_int_env(name: str, default: int, required: bool = False) -> int:
    value = get_env(name, default=str(default), required=required)
    try:
        return int(value or default)
    except ValueError as exc:
        raise RuntimeError(f"Environment variable {name} must be an integer") from exc
