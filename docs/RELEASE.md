# Release Runbook

This document contains reproducible release steps. Apple account details,
signing identities, device identifiers, reviewer contact information, sandbox
accounts, and operational evidence must remain outside the repository.

## Version sources

- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.yml`.
- `AppStore/metadata.json` mirrors the App Store version and build.
- `SpeedRead.xcodeproj` is generated from `project.yml` and is committed.
- Readium is pinned exactly in `project.yml` and `Package.resolved`.

Increment the build number for every upload. Change the marketing version only
for a new App Store version.

## Credential-free validation

Run:

```sh
make bootstrap
make generate
make format-check
make lint
make test
make project-check
make app-store-check
make archive-check
```

`make generate` and `make project-check` must leave the generated Xcode project
unchanged. `make archive-check` creates an unsigned archive and does not require
an Apple account.

Fast CI runs for pull requests and `main`. Full Validation is manually
dispatched for release candidates. Both workflows use read-only repository
permissions and standard GitHub-hosted runners.

## Signed validation

Maintainers perform signed validation without persisting credentials:

1. Confirm Xcode is signed into the intended Apple Developer account.
2. Pass `DEVELOPMENT_TEAM`, `DEVICE_UDID`, or `CORE_DEVICE_ID` only at runtime
   when automatic selection is insufficient.
3. Run `make device-deploy` for each device included in the release matrix.
4. Verify import, regular reading, speed reading, PDF OCR, purchase restoration,
   and iCloud behavior relevant to the release.
5. Store device and account evidence privately.

Never commit a development team, provisioning profile, certificate, API key,
management token, export-options file, sandbox account, or device identifier.

## App Store package

Before upload:

1. Run `make app-store-screenshots` when the reviewed screenshot set changes.
2. Inspect every exported image at native resolution.
3. Run `make app-store-check`.
4. Verify the deployed Support and Privacy URLs with
   `make app-store-live-check`.
5. Confirm App Privacy, age rating, pricing, availability, agreements, and
   product metadata directly in App Store Connect.
6. Archive the exact reviewed commit with the intended signing identity.
7. Upload through Xcode Organizer and wait for processing.

Private App Review contact and legal ownership fields belong only in App Store
Connect.

## StoreKit validation

`Config/SpeedRead.storekit` is a credential-free local fixture. It supports
local purchase, restoration, expiration, refund, revocation, and error-state
walkthroughs but does not prove App Store Connect configuration.

Before release, use Apple sandbox/TestFlight flows on a physical iPhone for:

- monthly, annual, and lifetime purchase
- cancellation or pending purchase
- restore after reinstall
- subscription management
- expiration, refund, and revocation
- offline launch with a verified cached entitlement

Store account identifiers and transaction evidence privately.

## CloudKit validation

Automated sync tests stay offline. Before a release that changes sync behavior,
validate the signed production container on the intended device matrix:

- initial upload and download
- divergent offline edits and reconnection
- deletion and reimport
- account sign-out and explicit account-change confirmation
- reinstall reconstruction
- EPUB/PDF asset integrity
- confirmation that OCR and derived PDF text stay device-local

Container administration is documented in
[CLOUDKIT_ACTIVATION.md](CLOUDKIT_ACTIVATION.md). Do not store account or device
evidence in source control.

## Publication

After App Store processing:

1. Confirm the version is available in the intended regions.
2. Verify the direct App Store, Support, and Privacy links from a signed-out
   browser.
3. Create an annotated Git tag matching the released version.
4. Publish concise user-facing release notes.
5. Keep rollback and operational notes in the private maintainer log.
