import re
from collections.abc import Callable, Mapping, Sequence
from contextlib import contextmanager
from typing import Any

from db.connection import get_connection
from utils.exceptions import DatabaseQueryError

SqlParams = Sequence[Any] | Mapping[str, Any] | None

_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class BaseRepository:
    def __init__(self, connection_factory: Callable[[], Any] = get_connection) -> None:
        self._connection_factory = connection_factory

    def execute(self, query: str, params: SqlParams = None, *, commit: bool = True) -> int:
        connection = self._connection_factory()
        try:
            with connection.cursor() as cursor:
                rowcount = cursor.execute(query, params)
            if commit:
                connection.commit()
            return rowcount
        except Exception as exc:
            if commit:
                connection.rollback()
            raise DatabaseQueryError("Database execute operation failed") from exc

    def fetch_one(self, query: str, params: SqlParams = None) -> dict[str, Any] | None:
        connection = self._connection_factory()
        try:
            with connection.cursor() as cursor:
                cursor.execute(query, params)
                return cursor.fetchone()
        except Exception as exc:
            raise DatabaseQueryError("Database fetch_one operation failed") from exc

    def fetch_all(self, query: str, params: SqlParams = None) -> list[dict[str, Any]]:
        connection = self._connection_factory()
        try:
            with connection.cursor() as cursor:
                cursor.execute(query, params)
                return list(cursor.fetchall())
        except Exception as exc:
            raise DatabaseQueryError("Database fetch_all operation failed") from exc

    def insert_one(
        self,
        table_name: str,
        data: Mapping[str, Any],
        *,
        commit: bool = True,
    ) -> int:
        if not data:
            raise DatabaseQueryError("Insert data cannot be empty")

        _validate_identifier(table_name)
        for column in data:
            _validate_identifier(column)

        columns = list(data.keys())
        placeholders = ", ".join(["%s"] * len(columns))
        column_names = ", ".join(f"`{column}`" for column in columns)
        query = f"INSERT INTO `{table_name}` ({column_names}) VALUES ({placeholders})"

        connection = self._connection_factory()
        try:
            with connection.cursor() as cursor:
                cursor.execute(query, tuple(data[column] for column in columns))
                lastrowid = int(cursor.lastrowid or 0)
            if commit:
                connection.commit()
            return lastrowid
        except Exception as exc:
            if commit:
                connection.rollback()
            raise DatabaseQueryError("Database insert operation failed") from exc

    @contextmanager
    def transaction(self) -> Any:
        connection = self._connection_factory()
        try:
            yield connection
            connection.commit()
        except Exception as exc:
            connection.rollback()
            if isinstance(exc, DatabaseQueryError):
                raise
            raise DatabaseQueryError("Database transaction failed") from exc


def _validate_identifier(identifier: str) -> None:
    if not _IDENTIFIER_PATTERN.match(identifier):
        raise DatabaseQueryError("Invalid SQL identifier")
