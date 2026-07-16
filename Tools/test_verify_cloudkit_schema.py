#!/usr/bin/python3

import tempfile
import unittest
from pathlib import Path

from verify_cloudkit_schema import parse_schema


class VerifyCloudKitSchemaTests(unittest.TestCase):
    def test_system_users_record_is_ignored(self) -> None:
        schema = """\
DEFINE SCHEMA
    RECORD TYPE Book (
        contentHash STRING
    );
    RECORD TYPE Users (
        roles LIST<INT64>,
        GRANT READ TO "_world"
    );
"""

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "schema.ckdb"
            path.write_text(schema, encoding="utf-8")

            self.assertEqual(
                parse_schema(path),
                {"Book": {"contentHash": "STRING"}},
            )


if __name__ == "__main__":
    unittest.main()
