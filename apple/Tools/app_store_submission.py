#!/usr/bin/python3

import argparse
import json
import plistlib
import re
import shutil
import struct
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


SCREENSHOT_PREFIX = re.compile(r"^AppStore-(\d{2})-([A-Za-z0-9-]+)_")
SCREENSHOT_SETS = {
    "iPhone-6.9": {
        (1260, 2736),
        (1290, 2796),
        (1320, 2868),
        (2736, 1260),
        (2796, 1290),
        (2868, 1320),
    },
    "iPad-13": {
        (2048, 2732),
        (2064, 2752),
        (2732, 2048),
        (2752, 2064),
    },
}
EXPECTED_SCREENSHOT_NAMES = {
    "iPhone-6.9": {
        "01-library.png",
        "02-regular-reader.png",
        "03-speed-reader.png",
    },
    "iPad-13": {
        "01-library.png",
        "02-tag-organization.png",
        "03-speed-reader.png",
    },
}
LIVE_PAGES = {
    "supportURL": "SpeedRead Support",
    "privacyPolicyURL": "SpeedRead Privacy Policy",
}
MAX_LIVE_PAGE_BYTES = 1_000_000
STANDARD_EULA_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
EXPECTED_CODE_OFFER = {
    "referenceName": "SpeedRead Pro Complimentary Year",
    "paymentMode": "free",
    "duration": "P1Y",
    "eligibility": ["new", "existing", "expired"],
    "stacksWithIntroductoryOffer": False,
    "autoRenewsAfterOffer": False,
}


class SubmissionError(Exception):
    pass


class PublicLinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: set[str] = set()

    def handle_starttag(self, tag: str, attributes: list[tuple[str, Optional[str]]]) -> None:
        if tag != "a":
            return
        for name, value in attributes:
            if name == "href" and value:
                self.links.add(value)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SubmissionError(message)


def png_info(path: Path) -> tuple[int, int, int, int]:
    with path.open("rb") as source:
        header = source.read(29)
    require(header[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG")
    require(header[12:16] == b"IHDR", f"{path}: missing PNG IHDR")
    require(struct.unpack(">I", header[8:12])[0] == 13, f"{path}: invalid PNG IHDR")
    width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", header[16:29])
    return width, height, bit_depth, color_type


def normalized_attachment_name(suggested_name: str) -> Optional[str]:
    match = SCREENSHOT_PREFIX.match(suggested_name)
    if match is None:
        return None
    sequence, title = match.groups()
    return f"{sequence}-{title.lower()}.png"


def device_id(device_name: str) -> None:
    simulator_data = json.load(sys.stdin)
    matches = [
        device["udid"]
        for devices in simulator_data.get("devices", {}).values()
        for device in devices
        if device.get("isAvailable", True) and device.get("name") == device_name
    ]
    require(matches, f"Simulator '{device_name}' is unavailable")
    require(
        len(matches) == 1,
        f"Simulator '{device_name}' exists in multiple runtimes; pass a unique simulator name",
    )
    print(matches[0])


def export_screenshots(args: argparse.Namespace) -> None:
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    exported: dict[str, Path] = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            normalized = normalized_attachment_name(
                attachment.get("suggestedHumanReadableName", "")
            )
            if normalized is None:
                continue
            require(normalized not in exported, f"duplicate screenshot attachment {normalized}")
            exported[normalized] = args.attachments / attachment["exportedFileName"]

    expected_names = EXPECTED_SCREENSHOT_NAMES[args.device_set]
    require(set(exported) == expected_names, f"expected {sorted(expected_names)}, got {sorted(exported)}")
    args.output.mkdir(parents=True, exist_ok=True)
    for existing in args.output.glob("*.png"):
        existing.unlink()
    for name, source in exported.items():
        require(source.is_file(), f"missing exported attachment {source}")
        shutil.copyfile(source, args.output / name)


def validate_https_url(label: str, value: object) -> None:
    require(isinstance(value, str), f"{label} must be a string")
    parsed = urlparse(value)
    require(parsed.scheme == "https" and bool(parsed.netloc), f"{label} must be an HTTPS URL")


def validate_app_description(description: str) -> None:
    require(STANDARD_EULA_URL in description, "description must link to the standard Apple Terms of Use")


def validate_monetization(root: Path) -> None:
    product_path = root / "AppStore/monetization.json"
    contract = json.loads(product_path.read_text(encoding="utf-8"))
    require(
        set(contract) == {"automaticPriceLocalization", "subscriptionGroup", "products"},
        "monetization fields do not match the reviewed schema",
    )
    require(contract["automaticPriceLocalization"] is True, "prices must use automatic localization")

    group = contract["subscriptionGroup"]
    require(
        group
        == {
            "referenceName": "SpeedRead Pro",
            "localizations": {"en-US": {"displayName": "SpeedRead Pro"}},
        },
        "subscription group does not match the reviewed contract",
    )

    products = contract["products"]
    require(isinstance(products, list) and len(products) == 3, "exactly three Pro products are required")
    expected = {
        "com.sild.speedread.pro.monthly": {
            "type": "auto-renewable-subscription",
            "referenceName": "SpeedRead Pro Monthly",
            "duration": "P1M",
            "price": "4.99",
            "sourceCase": "monthly",
            "codeOffer": EXPECTED_CODE_OFFER,
        },
        "com.sild.speedread.pro.annual": {
            "type": "auto-renewable-subscription",
            "referenceName": "SpeedRead Pro Annual",
            "duration": "P1Y",
            "price": "29.99",
            "sourceCase": "annual",
            "codeOffer": None,
        },
        "com.sild.speedread.pro.lifetime": {
            "type": "non-consumable",
            "referenceName": "SpeedRead Pro Lifetime",
            "duration": None,
            "price": "79.99",
            "sourceCase": "lifetime",
            "codeOffer": None,
        },
    }

    purchase_manager = (
        root / "SpeedRead/Core/Monetization/PurchaseManager.swift"
    ).read_text(encoding="utf-8")
    paywall = (
        root / "SpeedRead/Features/Monetization/ProPaywallView.swift"
    ).read_text(encoding="utf-8")
    for required_url in (
        "https://sild.github.io/speedread/support.html",
        "https://sild.github.io/speedread/privacy.html",
        "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/",
    ):
        require(required_url in paywall, f"paywall is missing required link {required_url}")
    require(".offerCodeRedemption(" in paywall, "paywall is missing native offer-code redemption")
    require(
        'accessibilityIdentifier("pro.redeemOfferCode")' in paywall,
        "paywall is missing the offer-code accessibility identifier",
    )
    found_identifiers: set[str] = set()
    for product in products:
        product_id = product.get("productIdentifier")
        require(product_id in expected, f"unexpected Pro product identifier {product_id}")
        require(product_id not in found_identifiers, f"duplicate Pro product identifier {product_id}")
        found_identifiers.add(product_id)
        reviewed = expected[product_id]
        common_fields = {
            "productIdentifier",
            "type",
            "referenceName",
            "familySharing",
            "plannedLaunchPriceUSD",
            "localizations",
        }
        subscription_fields = {"subscriptionDuration", "subscriptionLevel", "introductoryOffer"}
        if reviewed["codeOffer"] is not None:
            subscription_fields.add("codeOffer")
        expected_fields = common_fields | (subscription_fields if reviewed["duration"] else set())
        require(set(product) == expected_fields, f"{product_id}: fields do not match the reviewed schema")
        require(product["type"] == reviewed["type"], f"{product_id}: unexpected product type")
        require(product["referenceName"] == reviewed["referenceName"], f"{product_id}: reference name drift")
        require(product["familySharing"] is False, f"{product_id}: Family Sharing must remain disabled")
        require(product["plannedLaunchPriceUSD"] == reviewed["price"], f"{product_id}: launch price drift")
        if reviewed["duration"]:
            require(product["subscriptionDuration"] == reviewed["duration"], f"{product_id}: duration drift")
            require(product["subscriptionLevel"] == 1, f"{product_id}: subscription level drift")
            require(product["introductoryOffer"] is False, f"{product_id}: introductory offer drift")
            if reviewed["codeOffer"] is not None:
                require(product["codeOffer"] == reviewed["codeOffer"], f"{product_id}: code offer drift")

        localizations = product["localizations"]
        require(set(localizations) == {"en-US"}, f"{product_id}: missing reviewed en-US localization")
        localization = localizations["en-US"]
        require(
            set(localization) == {"displayName", "description"},
            f"{product_id}: localization fields do not match the reviewed schema",
        )
        require(2 <= len(localization["displayName"]) <= 30, f"{product_id}: display name length")
        require(2 <= len(localization["description"]) <= 45, f"{product_id}: description length")
        expected_declaration = f'case {reviewed["sourceCase"]} = "{product_id}"'
        require(expected_declaration in purchase_manager, f"{product_id}: PurchaseManager identifier drift")

    require(found_identifiers == set(expected), "reviewed Pro product set is incomplete")
    validate_storekit_configuration(root, expected)


def validate_storekit_configuration(root: Path, expected: dict[str, dict[str, object]]) -> None:
    configuration_path = root / "Config/SpeedRead.storekit"
    configuration = json.loads(configuration_path.read_text(encoding="utf-8"))
    require(
        configuration.get("version") == {"major": 6, "minor": 3},
        "StoreKit configuration version drift",
    )
    require(configuration.get("nonRenewingSubscriptions") == [], "unexpected non-renewing product")

    groups = configuration.get("subscriptionGroups")
    require(isinstance(groups, list) and len(groups) == 1, "exactly one StoreKit group is required")
    group = groups[0]
    require(group.get("name") == "SpeedRead Pro", "StoreKit group name drift")
    group_id = group.get("id")
    require(isinstance(group_id, str) and bool(group_id), "StoreKit group ID is missing")
    require(
        group.get("localizations")
        == [
            {
                "description": "Unlimited books and private iCloud sync.",
                "displayName": "SpeedRead Pro",
                "locale": "en_US",
            }
        ],
        "StoreKit group localization drift",
    )

    configured: set[str] = set()
    subscriptions = group.get("subscriptions")
    require(isinstance(subscriptions, list) and len(subscriptions) == 2, "exactly two subscriptions required")
    for subscription in subscriptions:
        product_id = subscription.get("productID")
        require(product_id in expected, f"unexpected StoreKit subscription {product_id}")
        reviewed = expected[product_id]
        require(reviewed["duration"] is not None, f"{product_id}: expected a subscription")
        require(product_id not in configured, f"duplicate StoreKit product {product_id}")
        configured.add(product_id)
        require(subscription.get("type") == "RecurringSubscription", f"{product_id}: StoreKit type drift")
        require(subscription.get("referenceName") == reviewed["referenceName"], f"{product_id}: StoreKit name drift")
        require(subscription.get("recurringSubscriptionPeriod") == reviewed["duration"], f"{product_id}: StoreKit duration drift")
        require(subscription.get("displayPrice") == reviewed["price"], f"{product_id}: StoreKit price drift")
        require(subscription.get("subscriptionGroupID") == group_id, f"{product_id}: StoreKit group drift")
        require(subscription.get("groupNumber") == 1, f"{product_id}: StoreKit level drift")
        require(subscription.get("familyShareable") is False, f"{product_id}: StoreKit Family Sharing")
        for offers in ("adHocOffers", "introductoryOffers", "winbackOffers"):
            require(subscription.get(offers) == [], f"{product_id}: StoreKit {offers} must remain empty")
        expected_code_offers = []
        if reviewed["codeOffer"] is not None:
            configured_code_offers = subscription.get("codeOffers")
            require(
                isinstance(configured_code_offers, list) and len(configured_code_offers) == 1,
                f"{product_id}: exactly one StoreKit code offer is required",
            )
            configured_code_offer = configured_code_offers[0]
            require(
                isinstance(configured_code_offer, dict),
                f"{product_id}: invalid StoreKit code offer",
            )
            code_offer_id = configured_code_offer.get("internalID")
            require(
                isinstance(code_offer_id, str) and bool(code_offer_id),
                f"{product_id}: StoreKit code offer ID is missing",
            )
            expected_code_offers = [
                {
                    "billingPlanType": "BILLED_UPFRONT",
                    "eligibility": reviewed["codeOffer"]["eligibility"],
                    "internalID": code_offer_id,
                    "isStackable": reviewed["codeOffer"]["stacksWithIntroductoryOffer"],
                    "numberOfPeriods": 1,
                    "paymentMode": reviewed["codeOffer"]["paymentMode"],
                    "referenceName": reviewed["codeOffer"]["referenceName"],
                    "subscriptionPeriod": reviewed["codeOffer"]["duration"],
                }
            ]
        require(
            subscription.get("codeOffers") == expected_code_offers,
            f"{product_id}: StoreKit code offer drift",
        )
        require_storekit_localization(subscription, product_id, reviewed["referenceName"])
        billing_plans = subscription.get("billingPlans")
        require(
            isinstance(billing_plans, list) and len(billing_plans) == 1,
            f"{product_id}: exactly one StoreKit billing plan is required",
        )
        billing_plan = billing_plans[0]
        require(isinstance(billing_plan, dict), f"{product_id}: invalid StoreKit billing plan")
        billing_plan_id = billing_plan.get("internalID")
        require(
            isinstance(billing_plan_id, str) and bool(billing_plan_id),
            f"{product_id}: StoreKit billing plan ID is missing",
        )
        require(
            billing_plans
            == [
                {
                    "billingPlanType": "BILLED_UPFRONT",
                    "commitmentDisplayPrice": reviewed["price"],
                    "displayPrice": reviewed["price"],
                    "internalID": billing_plan_id,
                    "isEnabled": True,
                }
            ],
            f"{product_id}: StoreKit billing plan drift",
        )

    products = configuration.get("products")
    require(isinstance(products, list) and len(products) == 1, "exactly one StoreKit non-consumable required")
    lifetime = products[0]
    product_id = lifetime.get("productID")
    reviewed = expected.get(product_id)
    require(reviewed is not None and reviewed["duration"] is None, "unexpected StoreKit non-consumable")
    configured.add(product_id)
    require(lifetime.get("type") == "NonConsumable", f"{product_id}: StoreKit type drift")
    require(lifetime.get("referenceName") == reviewed["referenceName"], f"{product_id}: StoreKit name drift")
    require(lifetime.get("displayPrice") == reviewed["price"], f"{product_id}: StoreKit price drift")
    require(lifetime.get("familyShareable") is False, f"{product_id}: StoreKit Family Sharing")
    require_storekit_localization(lifetime, product_id, reviewed["referenceName"])
    require(configured == set(expected), "StoreKit product set is incomplete")

    settings = configuration.get("settings", {})
    require(settings.get("_locale") == "en_US", "StoreKit locale drift")
    require(settings.get("_storefront") == "USA", "StoreKit storefront drift")
    require(settings.get("_failTransactionsEnabled") is False, "StoreKit failures must default off")
    require(settings.get("_storeKitErrors") == [], "StoreKit simulated errors must default off")

    project = (root / "project.yml").read_text(encoding="utf-8")
    require("- Config/SpeedRead.storekit" in project, "project is missing StoreKit file group")
    require(
        "storeKitConfiguration: Config/SpeedRead.storekit" in project,
        "Run scheme is missing StoreKit configuration",
    )


def require_storekit_localization(
    product: dict[str, object],
    product_id: str,
    display_name: object,
) -> None:
    require(
        product.get("localizations")
        == [
            {
                "description": "Unlimited books and private iCloud sync.",
                "displayName": display_name,
                "locale": "en_US",
            }
        ],
        f"{product_id}: StoreKit localization drift",
    )


def validate_metadata(root: Path, public_docs_root: Optional[Path] = None) -> None:
    validate_monetization(root)
    metadata_path = root / "AppStore/metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    required = {
        "name",
        "subtitle",
        "bundleIdentifier",
        "sku",
        "primaryLanguage",
        "primaryCategory",
        "secondaryCategory",
        "marketingVersion",
        "buildNumber",
        "keywords",
        "promotionalText",
        "description",
        "supportURL",
        "privacyPolicyURL",
        "reviewNotes",
    }
    require(set(metadata) == required, "App Store metadata fields do not match the reviewed schema")
    require(2 <= len(metadata["name"]) <= 30, "name must contain 2...30 characters")
    require(len(metadata["subtitle"]) <= 30, "subtitle exceeds 30 characters")
    require(len(metadata["promotionalText"]) <= 170, "promotional text exceeds 170 characters")
    require(len(metadata["description"]) <= 4000, "description exceeds 4000 characters")
    validate_app_description(metadata["description"])
    require(len(metadata["reviewNotes"].encode("utf-8")) <= 4000, "review notes exceed 4000 bytes")
    require(len(metadata["keywords"].encode("utf-8")) <= 100, "keywords exceed 100 bytes")
    keywords = metadata["keywords"].split(",")
    require(all(len(keyword.strip()) > 2 for keyword in keywords), "each keyword must exceed 2 characters")
    validate_https_url("supportURL", metadata["supportURL"])
    validate_https_url("privacyPolicyURL", metadata["privacyPolicyURL"])

    require(metadata["bundleIdentifier"] == "com.sild.speedread.app", "unexpected bundle identifier")
    require(metadata["marketingVersion"] == "1.0.0", "unexpected marketing version")
    require(metadata["buildNumber"] == "4", "unexpected build number")
    require(metadata["primaryCategory"] == "Books", "primary category must remain Books")

    project = (root / "project.yml").read_text(encoding="utf-8")
    for expected in (
        "CURRENT_PROJECT_VERSION: 4",
        "MARKETING_VERSION: 1.0.0",
        "PRODUCT_BUNDLE_IDENTIFIER: com.sild.speedread.app",
        "LSApplicationCategoryType: public.app-category.books",
        "ITSAppUsesNonExemptEncryption: false",
    ):
        require(expected in project, f"project.yml is missing {expected}")

    with (root / "SpeedRead/Resources/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == "$(PRODUCT_BUNDLE_IDENTIFIER)", "Info.plist bundle drift")
    require(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)", "Info.plist version drift")
    require(info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)", "Info.plist build drift")
    require(info.get("ITSAppUsesNonExemptEncryption") is False, "Info.plist encryption flag drift")

    docs_root = public_docs_root or root / "docs"
    for page, required_text in (
        (docs_root / "support.html", "SpeedRead Support"),
        (docs_root / "privacy.html", "SpeedRead Privacy Policy"),
    ):
        source = page.read_text(encoding="utf-8")
        require(required_text in source, f"{page}: missing page title")
        require("{{" not in source and "}}" not in source, f"{page}: unresolved template marker")

    icon = root / "SpeedRead/Resources/Assets.xcassets/AppIcon.appiconset/SpeedReadIcon.png"
    width, height, bit_depth, color_type = png_info(icon)
    require((width, height) == (1024, 1024), "App Store icon must be 1024 x 1024")
    require(bit_depth == 8 and color_type in {0, 2}, "App Store icon must not contain alpha")
    require((root / "SpeedRead/Resources/PrivacyInfo.xcprivacy").is_file(), "privacy manifest is missing")


def validate_live_pages(root: Path, timeout: float, opener=None) -> None:
    require(timeout > 0, "live-page timeout must be positive")
    metadata = json.loads((root / "AppStore/metadata.json").read_text(encoding="utf-8"))
    open_url = opener or urlopen
    page_urls = {metadata.get(label) for label in LIVE_PAGES}
    linked_urls: set[str] = set()
    for label, expected_title in LIVE_PAGES.items():
        url = metadata.get(label)
        validate_https_url(label, url)
        request = Request(url, headers={"User-Agent": "SpeedRead-AppStore-Preflight/1.0"})
        try:
            with open_url(request, timeout=timeout) as response:
                final_url = response.geturl()
                validate_https_url(f"{label} final URL", final_url)
                payload = response.read(MAX_LIVE_PAGE_BYTES + 1)
        except (HTTPError, URLError, TimeoutError) as error:
            raise SubmissionError(f"{label} is unreachable: {error}") from error
        require(len(payload) <= MAX_LIVE_PAGE_BYTES, f"{label} exceeds the live-page size limit")
        try:
            source = payload.decode("utf-8")
        except UnicodeDecodeError as error:
            raise SubmissionError(f"{label} is not UTF-8 HTML") from error
        require(
            f"<title>{expected_title}</title>" in source,
            f"{label} does not contain the reviewed page title",
        )
        parser = PublicLinkParser()
        parser.feed(source)
        support_email_found = False
        for link in parser.links:
            parsed_link = urlparse(link)
            if parsed_link.scheme == "mailto":
                if label == "supportURL" and parsed_link.path.strip():
                    support_email_found = True
                continue
            resolved = urljoin(final_url, link)
            validate_https_url(f"{label} public link", resolved)
            linked_urls.add(resolved)
        if label == "supportURL":
            require(support_email_found, "supportURL does not contain a public email contact")

    for url in sorted(linked_urls - page_urls):
        request = Request(url, headers={"User-Agent": "SpeedRead-AppStore-Preflight/1.0"})
        try:
            with open_url(request, timeout=timeout) as response:
                validate_https_url("public link final URL", response.geturl())
                response.read(1)
        except (HTTPError, URLError, TimeoutError) as error:
            raise SubmissionError(f"public link is unreachable: {url}: {error}") from error


def validate_screenshot_set(
    path: Path,
    allowed_dimensions: set[tuple[int, int]],
    expected_names: set[str],
) -> None:
    screenshots = sorted(path.glob("*.png"))
    require(1 <= len(screenshots) <= 10, f"{path}: expected 1...10 PNG screenshots")
    require(
        {screenshot.name for screenshot in screenshots} == expected_names,
        f"{path}: screenshot names do not match the reviewed set",
    )
    for screenshot in screenshots:
        width, height, bit_depth, color_type = png_info(screenshot)
        require((width, height) in allowed_dimensions, f"{screenshot}: unsupported dimensions")
        require(bit_depth == 8, f"{screenshot}: expected 8-bit color")
        require(color_type in {0, 2}, f"{screenshot}: alpha or palette transparency is not allowed")


def check_submission(args: argparse.Namespace) -> None:
    validate_metadata(args.root, args.public_docs_root)
    for directory, dimensions in SCREENSHOT_SETS.items():
        validate_screenshot_set(
            args.screenshots_root / directory,
            dimensions,
            EXPECTED_SCREENSHOT_NAMES[directory],
        )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare and verify SpeedRead App Store assets")
    subparsers = parser.add_subparsers(dest="command", required=True)

    find_device = subparsers.add_parser("device-id", help="find one available named simulator")
    find_device.add_argument("--name", required=True)

    export = subparsers.add_parser("export", help="export named screenshots from xcresult attachments")
    export.add_argument("--manifest", type=Path, required=True)
    export.add_argument("--attachments", type=Path, required=True)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--device-set", choices=sorted(SCREENSHOT_SETS), required=True)

    check = subparsers.add_parser("check", help="verify metadata, pages, icon, and screenshots")
    check.add_argument("--root", type=Path, required=True)
    check.add_argument("--public-docs-root", type=Path)
    check.add_argument("--screenshots-root", type=Path, required=True)

    live_check = subparsers.add_parser("live-check", help="verify the published support and privacy pages")
    live_check.add_argument("--root", type=Path, required=True)
    live_check.add_argument("--timeout", type=float, default=10)

    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        if args.command == "device-id":
            device_id(args.name)
        elif args.command == "export":
            export_screenshots(args)
        elif args.command == "live-check":
            validate_live_pages(args.root, args.timeout)
        else:
            check_submission(args)
    except (OSError, json.JSONDecodeError, plistlib.InvalidFileException, SubmissionError) as error:
        print(f"App Store submission verification failed: {error}", file=sys.stderr)
        return 1
    if args.command == "check":
        print("SpeedRead App Store submission assets are locally complete")
    elif args.command == "live-check":
        print("SpeedRead public support and privacy pages are live")
    return 0


if __name__ == "__main__":
    sys.exit(main())
