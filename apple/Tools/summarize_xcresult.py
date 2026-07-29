#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
from collections.abc import Iterable
from pathlib import Path
from typing import Any


def descendants(node: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for child in node.get("children", []):
        yield child
        yield from descendants(child)


def flaky_tests(payload: dict[str, Any]) -> list[str]:
    flaky: set[str] = set()
    duplicate_results: dict[str, list[str]] = {}

    def visit(node: dict[str, Any]) -> None:
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier") or node.get("name", "Unknown test")
            result = node.get("result")
            if result:
                duplicate_results.setdefault(identifier, []).append(result)

            run_results = {
                child["result"]
                for child in descendants(node)
                if child.get("nodeType") in {"Repetition", "Test Case Run"} and child.get("result")
            }
            if "Failed" in run_results and "Passed" in run_results:
                flaky.add(identifier)

        for child in node.get("children", []):
            visit(child)

    for root in payload.get("testNodes", []):
        visit(root)

    for identifier, results in duplicate_results.items():
        if "Failed" in results and "Passed" in results:
            flaky.add(identifier)

    return sorted(flaky)


def xcresult_json(command: str, result_bundle: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            command,
            "--path",
            str(result_bundle),
            "--compact"
        ],
        check=True,
        capture_output=True,
        text=True
    )
    return json.loads(completed.stdout)


def append_line(path_name: str, line: str) -> None:
    path = os.environ.get(path_name)
    if path:
        with open(path, "a", encoding="utf-8") as output:
            output.write(f"{line}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_bundle", type=Path)
    parser.add_argument("--label", default="UI tests")
    arguments = parser.parse_args()

    summary = xcresult_json("summary", arguments.result_bundle)
    tests = xcresult_json("tests", arguments.result_bundle)
    flaky = flaky_tests(tests)

    elapsed = max(0, summary.get("finishTime", 0) - summary.get("startTime", 0))
    summary_line = (
        f"| {arguments.label} | {summary.get('result', 'unknown')} | "
        f"{summary.get('passedTests', 0)}/{summary.get('totalTestCount', 0)} passed | "
        f"{elapsed:.1f}s |"
    )
    append_line("GITHUB_STEP_SUMMARY", summary_line)
    append_line("GITHUB_OUTPUT", f"retried={'true' if flaky else 'false'}")

    for identifier in flaky:
        print(f"::warning title=Flaky UI test::{identifier} passed after retry")
        append_line("GITHUB_STEP_SUMMARY", f"- Flaky retry: `{identifier}`")

    print(summary_line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
