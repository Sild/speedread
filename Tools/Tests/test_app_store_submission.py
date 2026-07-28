#!/usr/bin/python3

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional


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
    def test_rejects_app_description_without_terms_link(self) -> None:
        with self.assertRaisesRegex(SUBJECT.SubmissionError, "standard Apple Terms of Use"):
            SUBJECT.validate_app_description("SpeedRead is a private local reader.")

    def test_accepts_reviewed_monetization_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root)

            SUBJECT.validate_monetization(root)

    def test_rejects_monetization_product_identifier_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, source_annual_id="com.example.wrong")

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "identifier drift"):
                SUBJECT.validate_monetization(root)

    def test_rejects_enabled_family_sharing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, family_sharing=True)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "Family Sharing"):
                SUBJECT.validate_monetization(root)

    def test_rejects_subscription_level_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, subscription_level=2)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "subscription level drift"):
                SUBJECT.validate_monetization(root)

    def test_rejects_missing_paywall_legal_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, includes_terms_link=False)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "paywall is missing required link"):
                SUBJECT.validate_monetization(root)

    def test_rejects_missing_paywall_support_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, includes_support_link=False)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "speedread/support.html"):
                SUBJECT.validate_monetization(root)

    def test_rejects_storekit_price_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, storekit_annual_price="39.99")

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "StoreKit price drift"):
                SUBJECT.validate_monetization(root)

    def test_rejects_storekit_family_sharing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, storekit_family_sharing=True)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "StoreKit Family Sharing"):
                SUBJECT.validate_monetization(root)

    def test_rejects_storekit_code_offer_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, storekit_code_offer_duration="P6M")

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "StoreKit code offer drift"):
                SUBJECT.validate_monetization(root)

    def test_rejects_missing_storekit_scheme_wiring(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_monetization_contract(root, wires_storekit_scheme=False)

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "Run scheme"):
                SUBJECT.validate_monetization(root)

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

    def test_accepts_native_portrait_ipad_screenshot_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected_names = SUBJECT.EXPECTED_SCREENSHOT_NAMES["iPad-13"]
            for name in expected_names:
                write_png_header(root / name, 2064, 2752)
            SUBJECT.validate_screenshot_set(
                root,
                SUBJECT.SCREENSHOT_SETS["iPad-13"],
                expected_names,
            )

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
                    b'<title>SpeedRead Support</title><a href="mailto:help@example.com">Email</a>'
                ),
                "https://example.com/privacy.html": b"<title>SpeedRead Privacy Policy</title>",
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
                "https://example.com/support.html": b"<title>SpeedRead Support</title>",
                "https://example.com/privacy.html": b"<title>SpeedRead Privacy Policy</title>",
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
                "https://example.com/privacy.html": b"<title>SpeedRead Privacy Policy</title>",
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
                    b'<title>SpeedRead Support</title><a href="mailto:help@example.com">Email</a>'
                    b'<a href="https://example.com/private">Help</a>'
                ),
                "https://example.com/privacy.html": b"<title>SpeedRead Privacy Policy</title>",
            }

            with self.assertRaisesRegex(SUBJECT.SubmissionError, "public link is unreachable"):
                SUBJECT.validate_live_pages(root, 1, opener=FakeOpener(pages))

    def write_monetization_contract(
        self,
        root: Path,
        *,
        source_annual_id: str = "com.sild.speedread.pro.annual",
        family_sharing: bool = False,
        subscription_level: int = 1,
        includes_support_link: bool = True,
        includes_terms_link: bool = True,
        storekit_annual_price: str = "29.99",
        storekit_family_sharing: bool = False,
        storekit_code_offer_duration: str = "P1Y",
        wires_storekit_scheme: bool = True,
    ) -> None:
        (root / "AppStore").mkdir()
        source = root / "SpeedRead/Core/Monetization"
        source.mkdir(parents=True)
        (root / "AppStore/monetization.json").write_text(
            json.dumps(
                {
                    "automaticPriceLocalization": True,
                    "subscriptionGroup": {
                        "referenceName": "SpeedRead Pro",
                        "localizations": {"en-US": {"displayName": "SpeedRead Pro"}},
                    },
                    "products": [
                        {
                            "productIdentifier": "com.sild.speedread.pro.monthly",
                            "type": "auto-renewable-subscription",
                            "referenceName": "SpeedRead Pro Monthly",
                            "subscriptionDuration": "P1M",
                            "subscriptionLevel": subscription_level,
                            "familySharing": family_sharing,
                            "introductoryOffer": False,
                            "codeOffer": SUBJECT.EXPECTED_CODE_OFFER,
                            "plannedLaunchPriceUSD": "4.99",
                            "localizations": {
                                "en-US": {
                                    "displayName": "SpeedRead Pro Monthly",
                                    "description": "Unlimited books and private iCloud sync.",
                                }
                            },
                        },
                        {
                            "productIdentifier": "com.sild.speedread.pro.annual",
                            "type": "auto-renewable-subscription",
                            "referenceName": "SpeedRead Pro Annual",
                            "subscriptionDuration": "P1Y",
                            "subscriptionLevel": subscription_level,
                            "familySharing": family_sharing,
                            "introductoryOffer": False,
                            "plannedLaunchPriceUSD": "29.99",
                            "localizations": {
                                "en-US": {
                                    "displayName": "SpeedRead Pro Annual",
                                    "description": "Unlimited books and private iCloud sync.",
                                }
                            },
                        },
                        {
                            "productIdentifier": "com.sild.speedread.pro.lifetime",
                            "type": "non-consumable",
                            "referenceName": "SpeedRead Pro Lifetime",
                            "familySharing": family_sharing,
                            "plannedLaunchPriceUSD": "79.99",
                            "localizations": {
                                "en-US": {
                                    "displayName": "SpeedRead Pro Lifetime",
                                    "description": "Unlimited books and private iCloud sync.",
                                }
                            },
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        (source / "PurchaseManager.swift").write_text(
            'case monthly = "com.sild.speedread.pro.monthly"\n'
            f'case annual = "{source_annual_id}"\n'
            'case lifetime = "com.sild.speedread.pro.lifetime"\n',
            encoding="utf-8",
        )
        paywall = root / "SpeedRead/Features/Monetization"
        paywall.mkdir(parents=True)
        paywall_source = ""
        if includes_support_link:
            paywall_source += "https://sild.github.io/speedread/support.html\n"
        paywall_source += "https://sild.github.io/speedread/privacy.html\n"
        if includes_terms_link:
            paywall_source += "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/\n"
        paywall_source += '.offerCodeRedemption(isPresented: $isPresented)\n'
        paywall_source += 'accessibilityIdentifier("pro.redeemOfferCode")\n'
        (paywall / "ProPaywallView.swift").write_text(paywall_source, encoding="utf-8")
        (root / "Config").mkdir()
        storekit_products = [
            self.storekit_subscription(
                "com.sild.speedread.pro.monthly",
                "SpeedRead Pro Monthly",
                "P1M",
                "4.99",
                "monthly",
                storekit_family_sharing,
                code_offer_duration=storekit_code_offer_duration,
            ),
            self.storekit_subscription(
                "com.sild.speedread.pro.annual",
                "SpeedRead Pro Annual",
                "P1Y",
                storekit_annual_price,
                "annual",
                storekit_family_sharing,
            ),
        ]
        (root / "Config/SpeedRead.storekit").write_text(
            json.dumps(
                {
                    "identifier": "configuration",
                    "nonRenewingSubscriptions": [],
                    "products": [
                        {
                            "displayPrice": "79.99",
                            "familyShareable": storekit_family_sharing,
                            "internalID": "lifetime",
                            "localizations": [
                                {
                                    "description": "Unlimited books and private iCloud sync.",
                                    "displayName": "SpeedRead Pro Lifetime",
                                    "locale": "en_US",
                                }
                            ],
                            "productID": "com.sild.speedread.pro.lifetime",
                            "referenceName": "SpeedRead Pro Lifetime",
                            "type": "NonConsumable",
                        }
                    ],
                    "settings": {
                        "_failTransactionsEnabled": False,
                        "_locale": "en_US",
                        "_storefront": "USA",
                        "_storeKitErrors": [],
                    },
                    "subscriptionGroups": [
                        {
                            "id": "group",
                            "localizations": [
                                {
                                    "description": "Unlimited books and private iCloud sync.",
                                    "displayName": "SpeedRead Pro",
                                    "locale": "en_US",
                                }
                            ],
                            "name": "SpeedRead Pro",
                            "subscriptions": storekit_products,
                        }
                    ],
                    "version": {"major": 6, "minor": 3},
                }
            ),
            encoding="utf-8",
        )
        project = "fileGroups:\n  - Config/SpeedRead.storekit\n"
        if wires_storekit_scheme:
            project += "storeKitConfiguration: Config/SpeedRead.storekit\n"
        (root / "project.yml").write_text(project, encoding="utf-8")

    def storekit_subscription(
        self,
        product_id: str,
        reference_name: str,
        duration: str,
        price: str,
        internal_id: str,
        family_sharing: bool,
        code_offer_duration: Optional[str] = None,
    ) -> dict[str, object]:
        return {
            "adHocOffers": [],
            "billingPlans": [
                {
                    "billingPlanType": "BILLED_UPFRONT",
                    "commitmentDisplayPrice": price,
                    "displayPrice": price,
                    "internalID": f"{internal_id}-billing",
                    "isEnabled": True,
                }
            ],
            "codeOffers": (
                [
                    {
                        "billingPlanType": "BILLED_UPFRONT",
                        "eligibility": ["new", "existing", "expired"],
                        "internalID": f"{internal_id}-code-offer",
                        "isStackable": False,
                        "numberOfPeriods": 1,
                        "paymentMode": "free",
                        "referenceName": "SpeedRead Pro Complimentary Year",
                        "subscriptionPeriod": code_offer_duration,
                    }
                ]
                if code_offer_duration is not None
                else []
            ),
            "displayPrice": price,
            "familyShareable": family_sharing,
            "groupNumber": 1,
            "internalID": internal_id,
            "introductoryOffers": [],
            "localizations": [
                {
                    "description": "Unlimited books and private iCloud sync.",
                    "displayName": reference_name,
                    "locale": "en_US",
                }
            ],
            "productID": product_id,
            "recurringSubscriptionPeriod": duration,
            "referenceName": reference_name,
            "subscriptionGroupID": "group",
            "type": "RecurringSubscription",
            "winbackOffers": [],
        }


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
