# App Store Metadata

The credential-free metadata sources are:

- `AppStore/metadata.json`
- `AppStore/monetization.json`
- `Config/SpeedRead.storekit`
- `AppStore/Screenshots/`
- `docs/support.html`
- `docs/privacy.html`

Run `make app-store-check` before copying metadata into App Store Connect.
Account-holder contact details, legal ownership fields, API credentials,
sandbox accounts, offer codes, and transaction evidence must not be committed.

## Listing

- Name: SpeedRead: EPUB & PDF
- Subtitle: Read at your own pace
- Primary category: Books
- Secondary category: Education
- Support: <https://sild.github.io/speedread/support.html>
- Privacy: <https://sild.github.io/speedread/privacy.html>
- Terms: Apple's standard EULA

The canonical description, keywords, promotional text, URLs, version, and
review notes live in `AppStore/metadata.json`.

## SpeedRead Pro

`AppStore/monetization.json` defines the public product contract:

| Product | Type |
| --- | --- |
| SpeedRead Pro Monthly | Auto-renewable subscription |
| SpeedRead Pro Annual | Auto-renewable subscription |
| SpeedRead Pro Lifetime | Non-consumable |

All products grant the same Pro capabilities: an unlimited library and private
iCloud synchronization. StoreKit's verified current entitlement is
authoritative, and the app always renders Apple's localized price.

Family Sharing, introductory offers, external purchase links, and a custom
account are not used. The local StoreKit configuration mirrors the reviewed
product contract but does not create or validate products in App Store Connect.

## Screenshots

`make app-store-screenshots` captures deterministic scenes and writes only the
reviewed XCTest attachments:

- `AppStore/Screenshots/iPhone-6.9/`
- `AppStore/Screenshots/iPad-13/`

The checker accepts Apple's reviewed portrait or landscape dimensions, requires
8-bit PNG without alpha, and rejects missing or renamed images. Every image
still requires visual review at native resolution; dimensions alone cannot
detect rotation, clipping, stale product copy, or a poor scene.

The capture command requires the named simulator devices. It is intentionally
separate from normal pull-request CI.

## Privacy and compliance

Reassess these fields for every release:

- Tracking: No
- IDFA: not used
- custom account/backend: not used
- EPUB/PDF files and library state: local, with optional private CloudKit sync
- PDF extraction and OCR: on-device
- derived PDF text and OCR data: device-local
- encryption: Apple platform networking/security only
- content rights: user-provided DRM-free files

Verify `PrivacyInfo.xcprivacy` in the uploaded archive and re-audit every
dependency or service change.

## Review checklist

Before submitting a version:

1. Run `make app-store-check`.
2. Review the complete screenshot set.
3. Run `make app-store-live-check`.
4. Confirm the uploaded build version and privacy manifest.
5. Verify all purchase products and Restore Purchases in Apple sandbox or
   TestFlight.
6. Confirm free access, Pro access, entitlement loss, and offline behavior.
7. Confirm the production CloudKit schema for releases that change sync.
8. Enter private reviewer contact and legal ownership fields directly in App
   Store Connect.

Apple documentation used by the preflight:

- <https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information>
- <https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications>
- <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/>
- <https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases/>
- <https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/>
