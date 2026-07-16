#!/usr/bin/python3

import argparse
import plistlib
import re
import sys
from pathlib import Path


CONTAINER_IDENTIFIER = "iCloud.com.sild.fastreader"
RECORD_TYPE_PATTERN = re.compile(
    r"\bRECORD\s+TYPE\s+([A-Za-z][A-Za-z0-9_]*)\s*\((.*?)\)\s*;",
    re.IGNORECASE | re.DOTALL,
)
FIELD_PATTERN = re.compile(
    r'^\s*(?:"([^"]+)"|([A-Za-z][A-Za-z0-9_]*))\s+'
    r"(ASSET|BYTES|DOUBLE|INT64|LOCATION|NUMBER(?:\s+PREFERRED\s+AS\s+(?:INT64|DOUBLE))?"
    r"|REFERENCE|STRING|TIMESTAMP|LIST\s*<\s*[A-Za-z0-9_ ]+\s*>)\b",
    re.IGNORECASE,
)


class VerificationError(Exception):
    pass


def strip_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    source = re.sub(r"//.*?$", "", source, flags=re.MULTILINE)
    return re.sub(r"--.*?$", "", source, flags=re.MULTILINE)


def parse_schema(path: Path) -> dict[str, dict[str, str]]:
    source = strip_comments(path.read_text(encoding="utf-8"))
    if not re.search(r"\bDEFINE\s+SCHEMA\b", source, flags=re.IGNORECASE):
        raise VerificationError(f"{path}: missing DEFINE SCHEMA")

    records: dict[str, dict[str, str]] = {}
    for record_match in RECORD_TYPE_PATTERN.finditer(source):
        record_type = record_match.group(1)
        if record_type in records:
            raise VerificationError(f"{path}: duplicate record type {record_type}")

        fields: dict[str, str] = {}
        declarations = re.sub(
            r'\bGRANT\b.*?\bTO\s+(?:"[^"]+"|[A-Za-z][A-Za-z0-9_]*)',
            "",
            record_match.group(2),
            flags=re.IGNORECASE | re.DOTALL,
        )
        for declaration in declarations.split(","):
            field_match = FIELD_PATTERN.match(declaration)
            if field_match is None:
                if declaration.strip():
                    raise VerificationError(
                        f"{path}: unsupported declaration in {record_type}: {declaration.strip()}"
                    )
                continue
            field_name = field_match.group(1) or field_match.group(2)
            if field_name.startswith("___"):
                continue
            field_type = re.sub(r"\s+", " ", field_match.group(3).upper())
            if field_name in fields:
                raise VerificationError(
                    f"{path}: duplicate field {record_type}.{field_name}"
                )
            fields[field_name] = field_type
        records[record_type] = fields

    if not records:
        raise VerificationError(f"{path}: no record types found")
    return records


def require_equal(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise VerificationError(f"{label}: expected {expected!r}, got {actual!r}")


def verify_local(args: argparse.Namespace) -> None:
    records = parse_schema(args.schema)

    record_source = args.record_source.read_text(encoding="utf-8")
    swift_record_types = set(
        re.findall(r'^\s*case\s+\w+\s*=\s*"([A-Za-z][A-Za-z0-9_]*)"', record_source, re.MULTILINE)
    )
    require_equal("CloudKit record types", set(records), swift_record_types)

    codec_source = args.codec_source.read_text(encoding="utf-8")
    swift_fields = set(
        re.findall(r'^\s*static\s+let\s+\w+\s*=\s*"([A-Za-z][A-Za-z0-9_]*)"', codec_source, re.MULTILINE)
    )
    schema_fields = {field for fields in records.values() for field in fields}
    require_equal("CloudKit field names", schema_fields, swift_fields)

    with args.entitlements.open("rb") as source:
        entitlements = plistlib.load(source)
    require_equal(
        "iCloud container entitlement",
        entitlements.get("com.apple.developer.icloud-container-identifiers"),
        [CONTAINER_IDENTIFIER],
    )
    require_equal(
        "iCloud services entitlement",
        entitlements.get("com.apple.developer.icloud-services"),
        ["CloudKit"],
    )
    require_equal(
        "CloudKit environment entitlement",
        entitlements.get("com.apple.developer.icloud-container-environment"),
        "$(CLOUDKIT_ENVIRONMENT)",
    )
    require_equal(
        "push environment entitlement",
        entitlements.get("aps-environment"),
        "$(APS_ENVIRONMENT)",
    )

    project_source = args.project.read_text(encoding="utf-8")
    if "PRODUCT_BUNDLE_IDENTIFIER: com.sild.fastreader" not in project_source:
        raise VerificationError("project.yml: FastReader bundle identifier is missing")

    debug_source = args.debug_config.read_text(encoding="utf-8")
    release_source = args.release_config.read_text(encoding="utf-8")
    for label, source, aps, cloudkit in (
        ("Debug", debug_source, "development", "Development"),
        ("Release", release_source, "production", "Production"),
    ):
        if f"APS_ENVIRONMENT = {aps}" not in source:
            raise VerificationError(f"{label} config: APS_ENVIRONMENT must be {aps}")
        if f"CLOUDKIT_ENVIRONMENT = {cloudkit}" not in source:
            raise VerificationError(
                f"{label} config: CLOUDKIT_ENVIRONMENT must be {cloudkit}"
            )


def verify_export(args: argparse.Namespace) -> None:
    expected = parse_schema(args.schema)
    actual = parse_schema(args.exported_schema)
    require_equal("deployed CloudKit schema", actual, expected)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify FastReader's CloudKit schema")
    subparsers = parser.add_subparsers(dest="command", required=True)

    local = subparsers.add_parser("local", help="compare schema, code, entitlements, and configs")
    local.add_argument("--schema", type=Path, required=True)
    local.add_argument("--record-source", type=Path, required=True)
    local.add_argument("--codec-source", type=Path, required=True)
    local.add_argument("--entitlements", type=Path, required=True)
    local.add_argument("--project", type=Path, required=True)
    local.add_argument("--debug-config", type=Path, required=True)
    local.add_argument("--release-config", type=Path, required=True)

    exported = subparsers.add_parser("export", help="compare deployed and committed schemas")
    exported.add_argument("--schema", type=Path, required=True)
    exported.add_argument("--exported-schema", type=Path, required=True)

    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        if args.command == "local":
            verify_local(args)
        else:
            verify_export(args)
    except (OSError, plistlib.InvalidFileException, VerificationError) as error:
        print(f"CloudKit schema verification failed: {error}", file=sys.stderr)
        return 1
    print("CloudKit schema verification passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
