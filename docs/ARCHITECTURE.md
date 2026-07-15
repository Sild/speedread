# Architecture

## Stack

- Swift 6 with strict concurrency
- SwiftUI application UI; UIKit bridge only for Readium navigator controllers
- SwiftData local metadata persistence
- Readium Swift Toolkit 3.8.0 through Swift Package Manager
- UniformTypeIdentifiers and security-scoped URLs for document intake
- CryptoKit SHA-256 for content identity
- PDFKit and Vision for serial, on-demand local PDF text extraction
- XcodeGen for deterministic project generation

## Components

### Application

Owns dependency construction, SwiftData startup/recovery, scene routing,
external file URLs, app lifecycle, localization, and top-level navigation.

### Library

Owns the adaptive grid/sidebar UI, search and AND filters, book details, tags,
status editing, deletion, and import presentation. It depends on repository and
import interfaces rather than SwiftData or Readium directly.

`LibraryViewModel` loads one unfiltered repository snapshot and derives the
visible books, status facets, and predictive tag facets from that snapshot.
Search, selection, and count updates therefore share one consistent input and
do not require repository or persistence interface changes. Reload intersects
selected tag IDs with the active tag snapshot so a removed tag cannot leave a
hidden stale filter.

The repository exposes only tags referenced by an active membership. Tag edits
tombstone removed memberships and tombstone a tag after its final active
membership disappears; legacy orphan records are filtered immediately even
before a new edit triggers cleanup.

### Import

`ImportCoordinator` is a main-actor observable that serializes each selected
source URL through the following transaction:

1. obtain scoped access and copy to a unique staging URL;
2. stream SHA-256 without loading the whole publication;
3. query duplicate identity;
4. verify the actual EPUB/PDF signature, open with `PublicationService`, and
   collect metadata, cover, and layout;
5. move the staged file to a content-addressed Application Support location;
6. save metadata and file reference in one repository operation;
7. remove staging and uncommitted final files on error.

An existing duplicate is returned unchanged. If its final file is absent, the
incoming staged file repairs it before the existing record is returned.

### Publication

The Readium adapter owns asset retrieval, publication opening, EPUB/PDF
navigator creation, table of contents, preferences, position observation, and
content extraction. It owns the GCDWebServer adapter for the lifetime of PDF
navigators. No feature or persistence module imports Readium types.

The adapter exposes app-owned values:

- `PublicationMetadataSnapshot`
- `PublicationLayout`
- `RegularReaderSession`
- `RegularReaderPreferences`
- `ReaderPositionSnapshot`
- `SpeedContentElement`

### Regular Reader

Owns a publication session and bridges the Readium navigator into SwiftUI. It
debounces location updates, saves immediately on background/dismissal, and
applies supported appearance preferences without treating reflowed pages as
stable identifiers.

The regular-reader container owns the in-book `regular`/`speed` mode state.
Both child surfaces receive the same mode selector contract, while only the
container dismisses back to the library. A mode change flushes the active
locator before constructing or reloading the destination surface.

### Speed Reader

`SpeedContentProviding` returns one bounded content element at a time with its
serialized locator. `SpeedTokenizer` creates grapheme-safe tokens and ORP
indices. `SpeedReaderSession` owns playback state and a cancellable
`ContinuousClock` task. UI state changes happen on `@MainActor`.

For EPUB, the Readium adapter coalesces up to 32 adjacent textual elements into a
100,000-grapheme chunk, preserving paragraph separators and each element's
serialized locator. It retains at most three nearby chunks, splits oversized
extracted elements at a whitespace boundary, and never materializes the whole
publication. Tokenization derives an app-owned locator text context for every
word while preserving the Readium resource and CSS selector. The session
cancels playback on pause, manual navigation, seeking, backgrounding,
dismissal, and deinitialization.

Regular and speed modes persist the same serialized Readium locator. Speed mode
adds the bounded element identity and grapheme-safe token offset; returning to
the regular navigator reloads the active token's exact locator instead of
flushing stale regular-reader state. The adapter then applies a transient
Readium decoration to its text highlight. A malformed optional transition
locator is ignored so the regular reader remains available.

Regular-reader persistence merges navigator snapshots with the last persisted
position. It retains the speed element and token offset while the old and new
locators identify the same EPUB resource and either the same content selector
or the same page progression. It also recognizes Readium's initial navigator
normalization, which changes a backslash resource path to a slash path and
collapses an exact selector to the selector-less resource start. A real resource
or page change still clears the cursor. This prevents the initial location
callback from resetting speed mode while avoiding a stale cursor after genuine
regular-reader navigation.

For PDF, `PDFPageTextExtractor` is a serial actor backed by a separate PDFKit
document. It rejects copy-restricted content, prefers embedded line selections,
and falls back to accurate Vision OCR only for an empty or sparse page. OCR
renders one requested page at a time with a 2048-pixel longest edge. Same-baseline
Vision fragments are assembled into logical lines with character-weighted
confidence before geometry checks. Two-column classification requires repeated,
vertically overlapping column lines; isolated page furniture cannot trigger it.
Geometry, script, table, and confidence gates prevent questionable text from
entering the RSVP stream.

Successful page text and stable page-level failures are encoded beneath
`Derived/<content-hash>/pdf-text-v2/`; rendered page images are never cached.
`PDFSpeedContentProvider` emits stable `pdf-text-v2:<page>:<segment>` identities,
keeps the Readium page locator, segments pages above 100,000 graphemes, and owns
one cancellable task that prefetches the adjacent pages.

## Domain and Persistence

### Core values

- Book, tag, and membership IDs are stable UUIDs.
- `BookStatus`: `new`, `reading`, `done`, `canceled`.
- `LibraryFilter`: normalized query, optional status, required tag-ID set.
- `ReadingPosition`: locator JSON, total progression, optional speed element
  identity and token offset, update timestamp.
- `SpeedReaderSettings`: WPM and adaptive-pause flag.

### Persisted records

`BookRecord` stores stable ID, SHA-256 content hash, title, author display text,
media type, layout, relative file/cover paths, byte count, import/open dates,
progress, locator JSON, speed offset, status, per-field update timestamps, and
an optional future deletion timestamp.

`TagRecord` stores stable ID, canonical name, display name, creation/update
timestamps, and optional deletion timestamp.

`BookTagRecord` stores a stable membership ID, book ID, tag ID, created/update
timestamps, and optional deletion timestamp. Explicit membership records make
future distributed removal unambiguous.

Use repository validation instead of SwiftData unique constraints so the local
schema can later participate in CloudKit-compatible synchronization.

### Interfaces

- `BookRepository`: fetch library snapshots and tags; fetch by ID/hash; import;
  update status/tags; delete.
- `BookFileStore`: staging, atomic placement, existence, repair, deletion, and
  versioned derived-data access.
- `PublicationService`: inspect/open a local publication and create regular or
  speed-reader resources.
- `ReadingProgressStore`: fetch/save positions and mark books opened while
  enforcing status transitions. Reader view models own debouncing and flushes.
- `SpeedContentProviding`: start from a serialized locator and move or seek
  through bounded text elements.

Production implementations are concrete. In-memory implementations exist for
previews and deterministic tests.

## Data Flows

```text
Files / Open With
       |
       v
ImportCoordinator -> BookFileStore -> Application Support
       |                    |
       v                    v
PublicationService     SHA-256 identity
       |
       v
BookRepository / SwiftData -> Library
       |
       +-> Regular Reader --+
       |                    |
       +-> Speed Reader ----+-> ReadingPosition -> BookRepository
```

## Lifecycle and Failure Handling

- Scene state flushes pending reading position and pauses speed playback before
  background execution ends.
- Reader dismissal cancels PDF prefetch, content iteration, and playback,
  flushes position, and releases the Readium session.
- Persistent-store construction yields either a live dependency container or a
  recovery screen with retry; it never calls a process-terminating API.
- Import and deletion serialize file/database changes and compensate on partial
  failure.

## Future iCloud Sync

The MVP persists sync-ready IDs, timestamps, immutable hashes, and tombstones
but contains no CloudKit entitlement or network code.

A future `CKSyncEngine` uses the private database:

- immutable `BookAsset` records contain publication `CKAsset`s keyed by SHA-256;
- book metadata fields merge independently by their update timestamp;
- the newest position timestamp wins, including intentional backward movement;
- tag membership and deletion use tombstones so removals survive offline edits;
- downloaded assets move immediately from CloudKit staging into the local file
  store;
- account loss pauses sync without affecting local reading.

## PDF Storage and Positioning

Original PDFs are stored unchanged as `Books/<sha256>.pdf`. The existing media
type, fixed-layout field, and serialized Readium locator represent PDF books
without a schema migration. A bounded first-page cover is derived at import.
Deletion removes the original file, cover, and every derived extractor version.

The regular-reader facade selects the EPUB or PDF navigator internally. PDF
scrolling is stored separately from the EPUB preference and defaults on. Its
continuous layout uses Readium's largest-page fit so PDFs with a physically
smaller cover retain stable scale. Progress reaches 100% on the final page in
paginated mode and only at the bottom of the final page in scrolling mode;
moving away lowers progression again while the repository's guarded explicit
`done` and `canceled` rules remain unchanged. Token offsets add RSVP precision
but are never interpreted as PDF coordinates.
