# Roadmap

SpeedRead is available on the
[App Store](https://apps.apple.com/app/id6792124935). This roadmap describes
product direction rather than private release operations or account activity.

## Shipped

- DRM-free EPUB 2/3 and password-free PDF import
- regular EPUB/PDF reading with saved Readium locators
- contextual RSVP speed reading with exact regular/speed position handoff
- on-device PDF extraction and Vision OCR
- offline library management with search, status, tags, progress, and sharing
- private iCloud synchronization for Pro libraries
- monthly, annual, and lifetime SpeedRead Pro access
- Dynamic Type, VoiceOver metadata, Reduce Motion, light/dark appearance, and
  portrait/landscape support
- deterministic local validation, fast pull-request CI, and a broader manually
  dispatched release workflow

## Current priorities

### Discovery and onboarding

- improve App Store metadata and screenshot quality
- make first import and the Regular/Speed relationship immediately clear
- add a respectful, event-based App Store rating prompt after demonstrated use
- publish release notes that explain user-visible changes

### Reading quality

- expand EPUB compatibility fixtures without compromising offline behavior
- improve PDF extraction and OCR explanations for unsupported layouts
- refine long-session controls, progress feedback, and restoration
- continue accessibility and performance regression coverage

### Library workflow

- improve large-library organization and bulk operations
- evaluate publication text search, bookmarks, highlights, and notes
- preserve straightforward export and deletion of user-owned files

## Engineering principles

- local-first and usable offline
- no advertising, behavioral analytics, tracking, custom account, or custom
  backend without an explicit product decision
- private CloudKit data remains account-bound
- OCR and derived PDF text remain on-device
- DRM-free user-owned publications only
- deterministic tests and reproducible tooling
- changes to public behavior include focused tests and accessibility review

## Not currently planned

- DRM circumvention
- cloud or LLM document reconstruction
- social feeds or public profiles
- advertising SDKs
- a proprietary content store

Completed implementation details remain discoverable through source, tests, and
Git history. Maintainer-only App Store Connect, signing, device, and account
evidence is intentionally kept outside this public roadmap.
