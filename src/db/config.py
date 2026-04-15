from dataclasses import dataclass

from utils.config import get_env, get_int_env


@dataclass(frozen=True, slots=True)
class DatabaseConfig:
    host: str
    port: int
    database: str
    user: str
    password: str
    connect_timeout_seconds: int


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
