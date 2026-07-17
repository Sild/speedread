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

    def test_accepts_reviewed_live_pages(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "AppStore").mkdir()
            (root / "AppStore/metadata.json").write_text(
                json.dumps(
                    {
                        "supportURL": "https://example.com/support.html",
                        "privacyPolicyURL": "https://example.com/privacy.html",
                    }
                ),
                encoding="utf-8",
            )
            pages = {
                "https://example.com/support.html": (
                    b'<title>FastReader Support</title><a href="mailto:help@example.com">Email</a>'
                ),
                "https://example.com/privacy.html": b"<title>FastReader Privacy Policy</title>",
            }

            SUBJECT.validate_live_pages(root, 1, opener=FakeOpener(pages))

    def test_rejects_live_support_page_without_email(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "AppStore").mkdir()
            (root / "AppStore/metadata.json").write_text(
                json.dumps(
                    {
                        "supportURL": "https://example.com/support.html",
                        "privacyPolicyURL": "https://example.com/privacy.html",
                    }
                ),
                encoding="utf-8",
            )
            pages = {
                "https://example.com/support.html": b"<title>FastReader Support</title>",
                "https://example.com/privacy.html": b"<title>FastReader Privacy Policy</title>",
            }

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "public email contact"):
                SUBJECT.validate_live_pages(root, 1, opener=FakeOpener(pages))

    def test_rejects_unreviewed_live_page(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "AppStore").mkdir()
            (root / "AppStore/metadata.json").write_text(
                json.dumps(
                    {
                        "supportURL": "https://example.com/support.html",
                        "privacyPolicyURL": "https://example.com/privacy.html",
                    }
                ),
                encoding="utf-8",
            )
            pages = {
                "https://example.com/support.html": b"<title>Repository Not Found</title>",
                "https://example.com/privacy.html": b"<title>FastReader Privacy Policy</title>",
            }

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "reviewed page title"):
                SUBJECT.validate_live_pages(root, 1, opener=FakeOpener(pages))

    def test_rejects_unreachable_public_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "AppStore").mkdir()
            (root / "AppStore/metadata.json").write_text(
                json.dumps(
                    {
                        "supportURL": "https://example.com/support.html",
                        "privacyPolicyURL": "https://example.com/privacy.html",
                    }
                ),
                encoding="utf-8",
            )
            pages = {
                "https://example.com/support.html": (
                    b'<title>FastReader Support</title><a href="mailto:help@example.com">Email</a>'
                    b'<a href="https://example.com/private">Help</a>'
                ),
                "https://example.com/privacy.html": b"<title>FastReader Privacy Policy</title>",
            }

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "public link is unreachable"):
                SUBJECT.validate_live_pages(root, 1, opener=FakeOpener(pages))


class JsonInput:
    def __init__(self, value: object):
        self.value = value

    def read(self, *_: object) -> str:
        return json.dumps(self.value)


class FakeOpener:
    def __init__(self, pages: dict[str, bytes]):
        self.pages = pages

    def __call__(self, request: object, **_: object) -> "FakeResponse":
        try:
            payload = self.pages[request.full_url]
        except KeyError as error:
            raise SUBJECT.URLError("not found") from error
        return FakeResponse(request.full_url, payload)


class FakeResponse:
    def __init__(self, url: str, payload: bytes):
        self.url = url
        self.payload = payload

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def geturl(self) -> str:
        return self.url

    def read(self, _: int) -> bytes:
        return self.payload


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
