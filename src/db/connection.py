from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from db.config import get_database_config
from utils.exceptions import DatabaseConnectionError, DatabaseQueryError
from utils.log import get_logger

_connection: Any | None = None
logger = get_logger(__name__)


def get_connection() -> Any:
    global _connection

    if _connection is not None:
        if _is_connection_usable(_connection):
            return _connection
        close_connection()

    _connection = _create_connection()
    return _connection


@contextmanager
def get_cursor() -> Iterator[Any]:
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            yield cursor
    except Exception as exc:
        raise DatabaseQueryError("Database cursor operation failed") from exc


@contextmanager
def transaction() -> Iterator[Any]:
    connection = get_connection()
    try:
        yield connection
        connection.commit()
    except Exception as exc:
        connection.rollback()
        if isinstance(exc, DatabaseQueryError):
            raise
        raise DatabaseQueryError("Database transaction failed") from exc


def close_connection() -> None:
    global _connection

    if _connection is not None and getattr(_connection, "open", False):
        _connection.close()

    _connection = None


def _create_connection() -> Any:
    config = get_database_config(required=True)
    try:
        import pymysql
        from pymysql.cursors import DictCursor

        connection = pymysql.connect(
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
        logger.info(
            "Database connection established",
            extra={"db_host": config.host, "db_name": config.database},
        )
        return connection
    except ModuleNotFoundError as exc:
        raise DatabaseConnectionError("PyMySQL dependency is not installed") from exc
    except Exception as exc:
        raise DatabaseConnectionError("Could not connect to Aurora MySQL") from exc


def _is_connection_usable(connection: Any) -> bool:
    if not getattr(connection, "open", False):
        return False

    try:
        connection.ping(reconnect=False)
        return True
    except Exception:
        logger.warning("Cached database connection is not usable")
        return False
