import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "summarize_xcresult.py"
SPEC = importlib.util.spec_from_file_location("summarize_xcresult", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FlakyTestsTests(unittest.TestCase):
    def test_finds_failed_then_passed_repetitions(self) -> None:
        payload = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "name": "testReader",
                    "nodeIdentifier": "SpeedReadUITests/testReader",
                    "result": "Passed",
                    "children": [
                        {"nodeType": "Repetition", "name": "1", "result": "Failed"},
                        {"nodeType": "Repetition", "name": "2", "result": "Passed"}
                    ]
                }
            ]
        }

        self.assertEqual(
            MODULE.flaky_tests(payload),
            ["SpeedReadUITests/testReader"]
        )

    def test_ignores_tests_that_pass_once(self) -> None:
        payload = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "name": "testReader",
                    "nodeIdentifier": "SpeedReadUITests/testReader",
                    "result": "Passed"
                }
            ]
        }

        self.assertEqual(MODULE.flaky_tests(payload), [])


if __name__ == "__main__":
    unittest.main()
