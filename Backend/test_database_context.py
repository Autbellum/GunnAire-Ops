"""Database scopes must release their handles without changing transactions."""
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class DatabaseContextTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        patch = mock.patch.object(backend, "DB_PATH", Path(directory.name) / "fixture.sqlite3")
        patch.start()
        self.addCleanup(patch.stop)

    def assertClosed(self, connection):
        with self.assertRaises(sqlite3.ProgrammingError):
            connection.execute("SELECT 1")

    def test_success_commits_preserves_rows_and_closes_connection(self):
        with backend.db() as connection:
            self.addCleanup(connection.close)
            connection.execute("CREATE TABLE entries (value TEXT)")
            connection.execute("INSERT INTO entries VALUES ('saved')")
            row = connection.execute("SELECT value FROM entries").fetchone()
        self.assertEqual(row["value"], "saved")
        with backend.db() as reader:
            self.addCleanup(reader.close)
            self.assertEqual(reader.execute("SELECT value FROM entries").fetchone()["value"], "saved")
        self.assertClosed(connection)
        self.assertClosed(reader)

    def test_body_failure_rolls_back_and_closes_connection(self):
        with backend.db() as setup:
            self.addCleanup(setup.close)
            setup.execute("CREATE TABLE entries (value TEXT)")
        failure = RuntimeError("synthetic interruption")
        with self.assertRaises(RuntimeError) as caught:
            with backend.db() as connection:
                self.addCleanup(connection.close)
                connection.execute("INSERT INTO entries VALUES ('unsaved')")
                raise failure
        self.assertIs(caught.exception, failure)
        with backend.db() as reader:
            self.addCleanup(reader.close)
            self.assertEqual(reader.execute("SELECT COUNT(*) FROM entries").fetchone()[0], 0)
        self.assertClosed(connection)

    def test_commit_failure_rolls_back_and_closes_connection(self):
        with backend.db() as setup:
            self.addCleanup(setup.close)
            setup.execute("CREATE TABLE parents (id INTEGER PRIMARY KEY)")
            setup.execute("CREATE TABLE children (parent_id INTEGER REFERENCES parents(id) "
                          "DEFERRABLE INITIALLY DEFERRED)")
        with self.assertRaises(sqlite3.IntegrityError):
            with backend.db() as connection:
                self.addCleanup(connection.close)
                connection.execute("PRAGMA foreign_keys = ON")
                connection.execute("INSERT INTO children VALUES (999)")
        with backend.db() as reader:
            self.addCleanup(reader.close)
            self.assertEqual(reader.execute("SELECT COUNT(*) FROM children").fetchone()[0], 0)
        self.assertClosed(connection)

    def test_nested_scopes_have_independent_handles(self):
        with backend.db() as outer:
            self.addCleanup(outer.close)
            with backend.db() as inner:
                self.addCleanup(inner.close)
                self.assertIsNot(inner, outer)
                self.assertEqual(inner.execute("SELECT 1").fetchone()[0], 1)
            self.assertEqual(outer.execute("SELECT 2").fetchone()[0], 2)
            self.assertClosed(inner)
        self.assertClosed(outer)


if __name__ == "__main__":
    unittest.main()
