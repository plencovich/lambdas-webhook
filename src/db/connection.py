from typing import Any

from db.config import get_database_config

_connection: Any | None = None


def get_connection() -> Any:
    global _connection

    if _connection is not None and getattr(_connection, "open", False):
        return _connection

    import pymysql
    from pymysql.cursors import DictCursor

    config = get_database_config(required=True)
    _connection = pymysql.connect(
        host=config.host,
        port=config.port,
        user=config.user,
        password=config.password,
        database=config.database,
        connect_timeout=config.connect_timeout_seconds,
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=False,
    )
    return _connection


def close_connection() -> None:
    global _connection

    if _connection is not None and getattr(_connection, "open", False):
        _connection.close()

    _connection = None
