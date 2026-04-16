import os
from dataclasses import dataclass
from functools import lru_cache

from utils.exceptions import ConfigError


@dataclass(frozen=True, slots=True)
class AppConfig:
    app_env: str
    log_level: str
    provider_name: str


@dataclass(frozen=True, slots=True)
class DatabaseConfig:
    host: str
    port: int
    database: str
    user: str
    password: str
    connect_timeout_seconds: int


@dataclass(frozen=True, slots=True)
class Settings:
    app: AppConfig
    database: DatabaseConfig


def get_env(name: str, default: str | None = None, required: bool = False) -> str | None:
    value = os.getenv(name, default)
    if required and (value is None or value == ""):
        raise ConfigError(
            f"Missing required environment variable: {name}",
            error_code="missing_environment_variable",
        )
    return value


def get_int_env(name: str, default: int, required: bool = False) -> int:
    value = get_env(name, default=str(default), required=required)
    try:
        return int(value or default)
    except ValueError as exc:
        raise ConfigError(
            f"Environment variable {name} must be an integer",
            error_code="invalid_environment_variable",
        ) from exc


@lru_cache(maxsize=1)
def get_settings(validate_db: bool = False) -> Settings:
    return Settings(
        app=AppConfig(
            app_env=_get_app_env(),
            log_level=(get_env("LOG_LEVEL", default="INFO") or "INFO").upper(),
            provider_name=get_env("PROVIDER_NAME", default="botmaker") or "botmaker",
        ),
        database=get_database_config(required=validate_db),
    )


def get_app_config() -> AppConfig:
    return get_settings(validate_db=False).app


def get_database_config(required: bool = True) -> DatabaseConfig:
    return DatabaseConfig(
        host=get_env("DB_HOST", required=required) or "",
        port=get_int_env("DB_PORT", default=3306, required=required),
        database=get_env("DB_NAME", required=required) or "",
        user=get_env("DB_USER", required=required) or "",
        password=get_env("DB_PASSWORD", required=required) or "",
        connect_timeout_seconds=get_int_env(
            "DB_CONNECT_TIMEOUT_SECONDS",
            default=5,
            required=False,
        ),
    )


def clear_settings_cache() -> None:
    get_settings.cache_clear()


def _get_app_env() -> str:
    return get_env("APP_ENV") or get_env("ENVIRONMENT", default="dev") or "dev"
