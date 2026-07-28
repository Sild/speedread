# AGENTS.md

## Scope

These self-contained rules apply to the SpeedRead repository.

## Product Boundaries

- The shipped product is the local-first DRM-free EPUB/PDF reader described in
  `docs/PRODUCT.md`.
- Preserve offline operation. Do not add accounts, analytics, advertising, or a
  custom backend without an explicit product decision.
- Treat `ROADMAP.md` as public product direction. Keep private release,
  account, signing, transaction, and device evidence outside the repository.

## Architecture

- Target iOS/iPadOS 17 or newer with Swift 6 strict concurrency.
- SwiftUI owns application UI. A UIKit bridge may exist only around Readium
  navigator view controllers.
- Keep Readium types inside the publication adapter. Persist serialized Readium
  locators, never page numbers, as the canonical reading position.
- Access persistence and files through `BookRepository`, `BookFileStore`,
  `PublicationService`, `ReadingProgressStore`, and `SpeedContentProviding`.
- UI state belongs on `@MainActor`. Import, hashing, file I/O, and speed-reader
  scheduling require explicit actor or task ownership.
- Every owned task must have cancellation behavior for pause, dismissal,
  backgrounding, and deinitialization as applicable.
- Do not use `!`, `try!`, `fatalError`, `preconditionFailure`, or
  panic-driven recovery in production code. Present recoverable errors through
  typed states and user-facing messages.
- Do not add aliases, forwarding wrappers, empty protocols, or speculative
  abstractions. Add an adapter only at an actual framework or storage boundary.

## Data and Import Invariants

- Import into a staging location, hash and validate there, and commit the file
  plus database record atomically. Remove staging data on every failure path.
- Use SHA-256 file content as duplicate identity. A duplicate import reuses the
  existing book and repairs a missing local file without replacing user data.
- `BookStatus` contains exactly `new`, `reading`, `done`, and `canceled`.
- Automatic status changes are limited to `new -> reading` and
  `reading -> done`; never overwrite `canceled` or explicit `done`.
- A library filter accepts at most one status and requires all selected tags.
  Search, status, and tag predicates combine with AND.
- Normalize tag identity with trimmed, Unicode-normalized, case-insensitive
  text while preserving the first display spelling.

## Speed Reader Invariants

- The focus grapheme stays optically anchored while surrounding context moves.
- Tokenization must be Unicode-grapheme-safe for Latin and Cyrillic text.
- Show three context tokens before and after the active token.
- Playback uses an owned `ContinuousClock` task, defaults to 300 WPM, and is
  constrained to 100...1000 WPM in steps of 25.
- Cache bounded content elements or chapters; do not materialize an entire
  publication merely to start playback.
- When Readium cannot extract textual content, disable speed mode with a clear
  explanation while preserving regular reading.

## Project and Dependencies

- `project.yml` is the Xcode project source of truth. Commit the generated
  `SpeedRead.xcodeproj` and require regeneration to produce no diff.
- Pin Readium to exactly 3.8.0. Upgrade it only in a dedicated dependency task
  with fixture and reader regression checks.
- Keep tooling versions documented and reproducible. Do not silently use a
  different Xcode, simulator runtime, formatter, or linter in CI.

## Tests and Validation

- Use Swift Testing for domain, persistence, import, and speed-engine behavior.
  Use XCTest/XCUIAutomation only for UI automation and accessibility audits.
- Test project-owned behavior, error paths, persistence contracts, cancellation,
  and locator round trips. Do not add tests that only prove Readium, SwiftData,
  CryptoKit, or generated code works.
- Keep EPUB fixtures project-owned, minimal, deterministic, and offline.
- Required milestone validation order:

  1. Narrow tests for the changed behavior.
  2. `make format-check`.
  3. `make lint` with no warnings.
  4. `make test`.
  5. `make project-check` and `make archive-check` when the project/release
     surface changes.

- Run accessibility audits and the relevant simulator matrix for UI milestones.
- Never claim an Xcode, simulator, UI, or archive check passed unless it ran on
  the pinned full Xcode installation.

## Design and Accessibility

- Use the tokens and states in `docs/DESIGN.md`; do not hard-code feature-local
  colors, spacing, or corner radii.
- Support Dynamic Type, VoiceOver labels and ordering, sufficient contrast,
  Reduce Motion, light/dark appearance, portrait, landscape, iPhone, and iPad.
- Speed mode is visual and must not impersonate an accessible speech reader.
  Keep the regular reader and all speed controls accessible.

## Completion

- Contributors do not need Apple credentials or a physical device. Maintainers
  own signed-device, CloudKit, StoreKit sandbox, and App Store validation for
  release-affecting changes.
- Review the final diff for requirements, task lifecycle, errors, accessibility,
  migrations, dead code, scope creep, and unrelated changes.
- Update public documentation when behavior or contributor workflows change.
  Keep maintainer-only operational evidence out of the repository.
- Commit only task-owned, validated files using `<scope>: <summary>`.
