#!/usr/bin/python3

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "app_store_submission.py"
SPEC = importlib.util.spec_from_file_location("app_store_submission", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT}")
SUBJECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUBJECT)


def write_png_header(path: Path, width: int, height: int, color_type: int = 2) -> None:
    header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
    header += struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    path.write_bytes(header)


class AppStoreSubmissionTests(unittest.TestCase):
    def test_normalizes_only_reviewed_screenshot_attachments(self) -> None:
        self.assertEqual(
            SUBJECT.normalized_attachment_name("AppStore-02-Regular-Reader_0_ID.png"),
            "02-regular-reader.png",
        )
        self.assertIsNone(SUBJECT.normalized_attachment_name("UI Snapshot 2026-07-16"))

    def test_device_lookup_requires_one_available_exact_match(self) -> None:
        simulator_data = {
            "devices": {
                "runtime": [
                    {"name": "iPhone 17 Pro Max", "udid": "expected", "isAvailable": True},
                    {"name": "iPhone 17 Pro Max", "udid": "ignored", "isAvailable": False},
                ]
            }
        }
        previous_stdin = sys.stdin
        try:
            sys.stdin = JsonInput(simulator_data)
            with CapturedOutput() as output:
                SUBJECT.device_id("iPhone 17 Pro Max")
            self.assertEqual(output.value.strip(), "expected")
        finally:
            sys.stdin = previous_stdin

    def test_accepts_reviewed_rgb_screenshot_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected_names = SUBJECT.EXPECTED_SCREENSHOT_NAMES["iPhone-6.9"]
            for name in expected_names:
                write_png_header(root / name, 1320, 2868)
            SUBJECT.validate_screenshot_set(root, {(1320, 2868)}, expected_names)

    def test_rejects_alpha_channel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected_names = SUBJECT.EXPECTED_SCREENSHOT_NAMES["iPhone-6.9"]
            for name in expected_names:
                write_png_header(root / name, 1320, 2868, color_type=6)
            with self.assertRaisesRegex(SUBJECT.SubmissionError, "alpha"):
                SUBJECT.validate_screenshot_set(root, {(1320, 2868)}, expected_names)

    def test_rejects_wrong_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected_names = SUBJECT.EXPECTED_SCREENSHOT_NAMES["iPhone-6.9"]
            for name in expected_names:
                write_png_header(root / name, 1179, 2556)
            with self.assertRaisesRegex(SUBJECT.SubmissionError, "unsupported dimensions"):
                SUBJECT.validate_screenshot_set(root, {(1320, 2868)}, expected_names)


class JsonInput:
    def __init__(self, value: object):
        self.value = value

    def read(self, *_: object) -> str:
        return json.dumps(self.value)


class CapturedOutput:
    def __enter__(self) -> "CapturedOutput":
        import io

        self.previous = sys.stdout
        self.stream = io.StringIO()
        sys.stdout = self.stream
        return self

    def __exit__(self, *_: object) -> None:
        sys.stdout = self.previous

    @property
    def value(self) -> str:
        return self.stream.getvalue()


if __name__ == "__main__":
    unittest.main()
