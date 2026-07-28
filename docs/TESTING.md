# Testing and Release Workflow

## Strategy

Use a test pyramid:

- native macOS Swift Testing suites for pure domain and state-machine behavior;
- focused integration suites for SwiftData, files, Readium, and lifecycle;
- a small XCTest UI suite for critical journeys and accessibility;
- manual visual/device checks for the reader surfaces.

All automated tests are deterministic and offline. Tests own their temporary
directories, model containers, clocks, and publication fixtures.

## Fast Development Loop

Start with the native macOS target. It compiles the same production domain
sources as the app but does not link Readium, SwiftData, CloudKit, PDF, or UIKit:

```sh
make logic-test
make logic-test TEST=DomainLogicTests/speedTokenizationAndORP
```

Use one shared `.build/DerivedData` directory throughout a task. Run only the
affected iOS integration or UI method:

```sh
make test-one TEST=SpeedReadTests/DomainIntegrationTests/libraryStatusToggle
make ui-test UI_TEST=testCompactLibraryAndFacetedFilters
make ui-test UI_TEST=PDFUITests/testImportNativePDFAndPrepareLocalOCRSpeedMode
make device-deploy
```

The deploy target auto-detects a paired physical iPhone and local Apple
Development identity, performs an incremental Debug build, installs it, and
launches SpeedRead. Device and team overrides are command-line environment
values and are never written into the Xcode project. Signed DerivedData is
isolated by physical-device UDID so switching between iPhone and iPad cannot
replace a thinned asset catalog without resealing the app bundle. Run
`make format-check`, `make lint`, the iOS integration plan, and the complete
no-retry `make test` plan only after the interaction has stabilized; reserve
archive validation for project or release surface changes. Normal and focused
test plans do not collect code coverage because no coverage threshold consumes
it.

## Unit Coverage

- status transition table, manual-status preservation, and progress clamping;
- tag canonicalization and AND filtering with search/status/tags;
- tag-selection draft filtering, trimming, multiword creation,
  case/Unicode-equivalent matching, toggling, dirty state, and final output;
- locator serialization and speed offset persistence;
- preservation of the exact speed locator and cursor across normalized
  regular-reader saves, repeated mode switches, and invalidation after
  navigation to another content element;
- grapheme-safe Latin/Cyrillic tokenization, leading punctuation, and ORP index;
- adaptive duration precedence, WPM bounds/steps, pause/resume, seeking,
  completion, cancellation, and background behavior;
- import state transitions, duplicate identity, rollback decisions, and
  user-facing error mapping;
- schema migration and repository validation.
- deterministic CloudKit record identities and codec round trips;
- independent metadata/status/position conflict merges, backward progress,
  tombstones, reimport, EPUB/PDF outbox behavior, and in-flight mutation safety;
- saved-mutation engine wakeups, durable failed-asset retry, and out-of-order
  membership dependency recovery;
- account-state reset that preserves local data and drops old-account work;
- PDF startup backfill, format-aware asset staging, remote metadata paths, and
  deletion journaling.
- free/Pro feature policy, the three-book commit boundary, duplicate repair at
  the limit, deletion freeing a slot, all purchase/restore paths, and resolution
  of active, expired, revoked, upgraded, and offline-cached entitlements.

## StoreKit Validation

Automated tests use a process-local purchase seam and never contact the App
Store. Launch UI tests with `-ui-testing-free` to exercise the three-book gate,
free Speed/OCR access, three-offer paywall, purchase transition, and Restore
Purchases; the default UI-test bootstrap starts with Pro so unrelated reader and
sync tests retain their intended feature surface.

`Config/SpeedRead.storekit` is the credential-free transaction fixture. The
shared Run scheme loads it in Xcode, and `make app-store-check` verifies its exact
products, prices, subscription relationship, localizations, disabled offers and
Family Sharing, default error state, and scheme wiring. Use Xcode's StoreKit
transaction manager for local purchase-state walkthroughs. Local StoreKit data
does not prove App Store Connect setup, receipt behavior, regional availability,
or sandbox restoration.

Before submission, create the exact subscription group and three products in
`AppStore/monetization.json`, attach them to version 1.0, and use Sandbox Apple
Accounts on physical devices. Verify monthly, annual, and lifetime purchase;
cancel; pending; restore after reinstall; subscription management and expiry;
offline launch with a cached verified transaction; and revocation/refund. Confirm
Family Sharing and introductory offers are absent. Record StoreKit country/price
availability separately because the app displays localized StoreKit prices.

## iCloud Sync Validation

Automated sync tests stay offline. They exercise the app-owned merge, codec,
SwiftData outbox, mutation-token, asset-staging, and account-policy boundaries
without requiring an Apple account. UI-test bootstrap does not start CloudKit.

Maintainer release validation uses the intended signed CloudKit container and
physical devices. It covers first merge, divergent offline metadata and
position edits, newer backward movement, membership removal, book
deletion/reimport, sign-out, account switching, reinstall reconstruction,
quota/error presentation, and final device convergence. EPUB and PDF originals
and library state must converge while derived PDF text and OCR caches remain
device-local. Both formats must remain readable offline throughout.

Use `make cloudkit-check` before membership activation. After activation, follow
`docs/CLOUDKIT_ACTIVATION.md` to validate/import the committed development
schema, verify the production export, deploy the signed build, and record the
live matrix without persisting team or device identifiers.

## EPUB Fixtures and Integration

Keep minimal project-owned fixtures for:

- EPUB 2 reflowable;
- EPUB 3 reflowable with cover, table of contents, and multiple chapters;
- EPUB 3 fixed layout;
- Latin and Cyrillic paragraphs with punctuation and long words;
- absent title/author/cover;
- malformed container/package/navigation;
- protected publication metadata;
- large chapter and many small resources;
- identical bytes under different filenames.

Integration assertions cover atomic stage/commit/rollback, streaming hash,
metadata/cover/layout extraction, duplicate reuse and file repair, relative
paths, deletion, locator round trip, relaunch resume, and regular/speed
position handoff. Regular-reader seek-target coverage verifies content-position
snapping and clamped endpoints; the mounted real-fixture UI flow verifies
navigation and persisted locator restoration. The unloaded-navigator path
verifies recoverable navigation failure. Sharing coverage verifies the EPUB
type, safe suggested filename, exact source bytes, and missing-file failure.
The basic import integration verifies that a speed token's locator and highlight
are accepted by the regular navigator. Focused mode-continuity coverage uses a
mounted long EPUB from a later bounded content chunk, waits until Readium
replaces the exact token selector with its settled selector-less page locator,
then directly asserts that the new speed session still displays the same token.
The same test proves that an explicit regular-reader seek invalidates that
cursor. The adjacent PDF test repeats the complete regular/speed reconstruction
for an exact token from a later bounded page segment. Manufactured selector-less
locators are intentionally excluded because they previously hid the real
navigator behavior.

## PDF Fixtures and Integration

Keep deterministic offline PDFs for metadata and outlines, missing metadata,
Latin/Cyrillic embedded text, image-only OCR, clear two-column prose, ambiguous
layout, malformed input, password locking, copy restriction, long-document page
navigation, and a 40-page scanned document used for bounded-memory OCR checks.

Integration assertions cover signature-based format validation, `.pdf`
content-addressed storage, duplicate repair and rollback, bounded first-page
covers, native locator/outline behavior, fixed-layout preferences, paginated
and scrolling completion, regular/speed page handoff, grapheme-bounded
segmentation, OCR and layout gates, successful/failure cache reuse, extractor
version isolation, derived-data deletion, and prefetch lifecycle. Regression
coverage also verifies the PDF-specific default scrolling/whole-page fit,
same-baseline OCR fragment assembly with character-weighted confidence, and
single-column prose with isolated left/right page furniture. Seek-target
coverage verifies PDF page snapping and endpoint locators; the mounted
real-fixture UI flow verifies midpoint navigation, the explicit 100% scrolling
endpoint, and navigation back from the endpoint. Sharing coverage verifies the
PDF type, suggested filename, and exact source bytes. A long cached page also
verifies that repeated regular/speed round trips restore the exact word from a
later bounded PDF segment rather than restarting at the page's first segment.

## UI Automation

Use deterministic launch arguments for an isolated in-memory or temporary
library and fixture injection. Cover:

- empty library and import entry points;
- successful and failed import, including simulated external open;
- search, one-status filter, all-tag filter, editing, and deletion;
- searchable transactional tag selection, existing and multiword tag choices,
  persistence after reopen, cancel rollback, orphan-filter removal, and
  save-failure draft retention;
- responsive three/four-plus-column density, accessibility-width fallback,
  constrained covers and separated progress tracks, stacked Status/Tags
  headers, always-visible tag facets, status toggle-off, and faceted count
  updates across search and multiple selected tags;
- regular navigation, table of contents, appearance, progress scrubbing,
  relaunch, and the Share Book context-menu entry;
- speed compatibility, focus presentation, WPM, adaptive toggle, playback,
  seeking, background pause, completion, shared-selector mode switching, and
  Back-to-library behavior from speed mode;
- shared 52-point Back hit regions on iPhone/iPad, near-edge Back taps that do
  not start speed playback, and per-book Regular/Speed restoration after Back;
- single-baseline previous/active/next context, exact active-token highlighting
  after returning to regular mode, the same token after repeated mode switches
  and book reopen, identical selector X/Y placement across modes, WPM centered
  beneath the selector and outside the progression row, the single
  minus/selector/plus rail, and minimum playback/WPM hit regions;
- native PDF open, fixed-layout controls, local OCR preparation, speed playback,
  page restoration, and unavailable-state explanations;
- dark mode, accessibility text sizes, VoiceOver metadata, and iOS 17+
  `performAccessibilityAudit` where supported.
- shared iPhone/iPad library navigation, absence of the obsolete sidebar,
  bottom search placement, live filtering, and clear-to-restore behavior;
- free launch, three-book limit explanation, free EPUB Speed and PDF OCR, all
  three purchase options, annual Best value treatment, active subscription and
  lifetime states, Restore Purchases, and no import mutation while the paywall
  is shown.

Do not automate system share sheets or Files UI as the primary proof. Verify
the activity payload directly, exercise the same application URL/import
boundary, and retain manual EPUB/PDF share-sheet and Open With checks for
release validation.

## Simulator and Manual Matrix

- compact iPhone on the minimum supported iOS runtime;
- current large-screen iPhone on the pinned current runtime;
- iPad in portrait, landscape, and approximately half-width Split View;
- light, dark, Increase Contrast, Reduce Motion, and largest accessibility text;
- app background/foreground, memory-pressure relaunch, missing local file, and
  no-network operation.

## Performance

Measure rather than invent fixed targets. Record baselines for import duration,
peak memory, library scrolling with a generated large library, reader startup,
content-element tokenization, and 1000 WPM scheduling. Regressions require a
profile and an explicit decision before acceptance.

## CI Gates

`make ci-fast` runs the local equivalent of normal GitHub validation:

1. Xcode/tooling version check.
2. Credential-free CloudKit schema, code, entitlement, and configuration check.
3. Credential-free App Store metadata, page, icon, privacy-manifest, and
   screenshot-package check.
4. XcodeGen generation and clean-diff verification.
5. SwiftFormat check.
6. Warning-free SwiftLint.
7. Native macOS logic tests.
8. One iOS build-for-testing.
9. iOS integration tests without rebuilding.
10. Four UI journeys without rebuilding: empty launch, EPUB regular-to-speed
    reading, PDF/OCR reading, and the free-limit/paywall path.

Pull requests and direct `main` pushes run this fast gate. Documentation and
App Store metadata-only changes run the portable preflight without starting
Xcode; workflow, tool, project, configuration, source, and test changes always
run every fast phase. GitHub permits one native Xcode UI retry. A passing retry
is reported as a visible flaky-test warning and retains its `.xcresult` for
seven days; failed UI runs retain the same artifact. Named, bounded phases and
the job summary keep simulator, build, integration, and UI durations visible.

`make ci` is the complete local release gate: it never retries and adds every UI
and screenshot test plus unsigned archive validation. The manually dispatched
`Full Validation` workflow runs the same broad surface with one reported UI
retry and a 45-minute job bound.

No live network, Apple credentials, signing identity, CloudKit container, or
private fixture is required in CI.

## App Store Screenshot Package

Run `make app-store-screenshots` to execute only
`testAppStoreScreenshots` on the installed iPhone 17 Pro Max and iPad Pro
13-inch simulator classes. The capture flow fixes the status bar, exports only
attachments prefixed with `AppStore-`, preserves the captured device
orientation, and writes the reviewed assets under `AppStore/Screenshots/`.

Run `make app-store-check` after capture and in CI. It rejects a missing or
renamed image, unsupported App Store dimensions, alpha-bearing PNGs, metadata
limit drift, version/bundle/category drift, Pro product ID/type/duration/level,
price, localization, Family Sharing, or introductory-offer drift, an invalid app
icon, a missing privacy manifest, or unresolved support/privacy page templates.
Visual review is still required because
dimensions alone cannot detect a poor product scene.

After the public pages are deployed, run `make app-store-live-check`. This
networked release check verifies the reviewed HTTPS titles, public support email,
and linked public pages; it is intentionally separate from offline CI.

## Release Readiness

Before submitting a release:

- all CI-equivalent local checks pass on the pinned full Xcode;
- the relevant simulator/device and accessibility matrix is complete;
- app icon, launch assets, privacy manifest, version/build numbers, supported
  orientations, document declarations, and usage descriptions are inspected;
- unsigned and signed archive checks succeed;
- App Store privacy answers match the shipped behavior;
- known Readium compatibility gaps and speed-mode limitations are documented;
- the final diff and repository status are clean.

Keep account, signing, device, reviewer, and transaction evidence in the
maintainer's private release records, not in this repository.
