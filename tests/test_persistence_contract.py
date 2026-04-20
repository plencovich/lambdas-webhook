import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))


DDL_PATH = ROOT / "database" / "init_db.sql"
REPOSITORY_PATH = ROOT / "src" / "repositories" / "webhook_repository.py"


def ddl_columns_by_table() -> dict[str, set[str]]:
    ddl = DDL_PATH.read_text()
    tables: dict[str, set[str]] = {}
    for match in re.finditer(
        r"CREATE TABLE IF NOT EXISTS\s+(\w+)\s+\((.*?)\n\) ENGINE",
        ddl,
        flags=re.DOTALL,
    ):
        table_name = match.group(1)
        body = match.group(2)
        columns: set[str] = set()
        for raw_line in body.splitlines():
            line = raw_line.strip().rstrip(",")
            if not line:
                continue
            first_token = line.split()[0]
            if first_token in {"PRIMARY", "UNIQUE", "KEY", "CONSTRAINT", "FOREIGN", "ON"}:
                continue
            columns.add(first_token.strip("`"))
        tables[table_name] = columns
    return tables


def repository_insert_columns() -> list[tuple[str, set[str]]]:
    source = REPOSITORY_PATH.read_text()
    inserts: list[tuple[str, set[str]]] = []
    for match in re.finditer(
        r"INSERT(?:\s+IGNORE)?\s+INTO\s+(\w+)\s+\((.*?)\)\s+VALUES",
        source,
        flags=re.DOTALL,
    ):
        table_name = match.group(1)
        columns = {
            column.strip().strip("`")
            for column in match.group(2).split(",")
            if column.strip()
        }
        inserts.append((table_name, columns))
    return inserts


class PersistenceContractTest(unittest.TestCase):
    def test_repository_insert_columns_exist_in_ddl(self):
        ddl_tables = ddl_columns_by_table()
        self.assertTrue(ddl_tables, "DDL tables were not parsed")

        for table_name, columns in repository_insert_columns():
            with self.subTest(table=table_name):
                self.assertIn(table_name, ddl_tables)
                self.assertFalse(columns - ddl_tables[table_name])

    def test_endpoint_tables_are_explicit_and_supported_by_ddl(self):
        ddl_tables = ddl_columns_by_table()
        expected_tables = {
            "webhook_events_raw",
            "customers",
            "operators",
            "conversations",
            "messages",
            "conversation_snapshots",
            "conversation_contexts",
        }

        self.assertTrue(expected_tables <= set(ddl_tables))
        self.assertEqual(
            {table for table, _ in repository_insert_columns()},
            expected_tables,
        )


if __name__ == "__main__":
    unittest.main()
