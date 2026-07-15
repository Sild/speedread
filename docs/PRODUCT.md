# Product Specification

## Goal

FastReader helps people keep a private ebook library and move seamlessly
between comfortable regular reading and visually focused speed reading.

The MVP is TestFlight-ready, offline-first, and supports iPhone and iPad on
iOS/iPadOS 17 or newer.

## Primary Journeys

### Import and open

1. A person selects one or more EPUB or PDF files in FastReader, or chooses
   FastReader from the Files/share-sheet Open With flow.
2. FastReader copies and validates each file inside its sandbox.
3. Successful external imports open immediately in regular reading mode.
4. A byte-identical import opens the existing library item and preserves its
   progress, status, and tags.
5. A failed or protected publication shows a specific error and leaves no
   partial library entry.

### Manage the library

- The default presentation is an adaptive cover grid ordered by most recently
  opened, then most recently imported.
- Typical iPhones show three compact cards per row, wider phones show four when
  space permits, and iPad adds columns adaptively. Accessibility Dynamic Type
  widens cards and reduces the column count before text clips. Horizontal and
  vertical gutters keep neighboring covers and metadata visually independent.
- Cards show cover or a generated placeholder, title, author, integer progress
  percentage, and status. Cover artwork is constrained to its grid cell, and
  progress tracks are inset so neighboring cards never overlap or read as one
  continuous bar.
- Search matches normalized title and author text.
- A filter accepts zero or one status and zero or more tags. Search, status,
  and every selected tag are mandatory AND predicates.
- Status and Tags are stacked filter sections with left-aligned headers above
  their chips. Both sets of options are always visible; a second tap on the
  selected status returns to All, and selected tags remain removable.
- Status counts respect search and selected tags while ignoring the active
  status. Unselected tag counts predict the result of adding that tag to the
  current AND filter; selected tags show the current result count. An
  unavailable unselected tag stays visible but disabled.
- A person can set any status, edit tags, share the original stored EPUB or PDF
  through the system share sheet, and delete a book after confirmation. Sharing
  never includes covers, progress, tags, or derived data. Tag editing is
  transactional: a large sheet groups selected tags above the remaining
  available tags, and Save is enabled only after the selection changes. Cancel
  discards the draft.
- The tag field filters existing names as a person types and offers one explicit
  Create action when no case- or Unicode-equivalent tag exists. Return performs
  the same select-or-create action. Each submission is one tag, so spaces are
  part of the name and commas have no delimiter meaning. A failed Save keeps the
  sheet and draft visible with a retry message.
- Deletion removes the sandbox file, derived cover, versioned PDF text cache,
  tag links, and local metadata.
- Tags with no active book memberships are omitted immediately, including
  orphan records created by older application builds.

### Read normally

- Open at the saved locator or the publication beginning.
- Navigate with Readium pagination or vertical scrolling.
- Open the table of contents and jump to a section.
- Change font family, font size, line height, margins, theme, and reading layout
  when the publication supports those preferences.
- Scrub the bottom progress control and release it to jump to the closest EPUB
  content position or PDF page. The beginning/end endpoints cover the full
  publication, including the bottom of a continuously scrolling PDF.
- Switch to speed reading through the shared bottom mode selector without
  losing the current section. Back always exits the book.

### Read quickly

- Speed mode starts from the closest extractable content at the saved locator.
- The focus word remains anchored by its ORP grapheme at 42% of the reading
  width. Three previous tokens, the active word, and three next tokens share one
  baseline so context stays close enough to scan without vertical eye travel.
- Tap to pause/resume; primary controls use 60-point previous/next targets and
  a 68-point play/pause target. Progress scrubbing and 52-point WPM decrement
  and increment controls remain directly available. Adaptive Pauses is in the
  top-right speed settings menu.
- WPM controls and the shared Regular/Speed selector share one bottom row. The
  selector remains centered at the same position in both modes.
- Returning to regular reading opens the same locator and briefly highlights
  the exact word that was active in speed mode. Back exits the book and returns
  to the library instead of changing reading mode.
- Returning to speed reading restores that exact word after a regular/speed
  round trip or after closing and reopening the book for EPUB and PDF, including
  a PDF word in a later bounded page segment. Regular navigation to a different
  content element replaces the retained speed cursor.
- WPM defaults to 300 and ranges from 100 through 1000 in steps of 25.
- Base duration is `60 / WPM` seconds. Adaptive timing adds 25% for words of at
  least 10 graphemes, 50% after clause punctuation, 100% after sentence-ending
  punctuation, and 150% at paragraph boundaries. The largest applicable pause
  wins rather than stacking multipliers.
- Leaving the view or backgrounding the app pauses playback.

## Progress and Status

- Store progress as a clamped `0...1` total progression and display the nearest
  whole percentage.
- The serialized Readium locator is the canonical cross-mode position. Speed
  mode also stores a content-element identity and token offset. Compatible
  regular-reader saves retain the exact speed locator and cursor while updating
  displayed progression; navigation to another element replaces that anchor.
- A new book begins as `new`. Persisting the first positive progression changes
  `new` to `reading`.
- Reaching an explicit publication-end signal sets progress to `1` and changes
  `reading` to `done`.
- Automatic logic never changes `canceled` or an explicit `done`. All statuses
  remain manually editable.

## EPUB Compatibility

- Support DRM-free EPUB 2 and EPUB 3, including reflowable and fixed-layout
  publications that Readium 3.8.0 can open.
- Regular reading is the baseline capability for every successfully imported
  EPUB.
- Speed reading requires extractable textual content. Disable it with an
  explanation for image-only or unsupported content.
- Apple-specific renderer extensions, FairPlay purchases, ACSM/AZW/ODM, and
  exact Apple Books rendering parity are not supported commitments.

## PDF Compatibility

- Support DRM-free, password-free PDFs that Readium 3.8.0 and PDFKit can open.
- Regular reading uses Readium's native PDF navigator with vertical scrolling
  enabled by default and an independently persisted pagination option.
  Continuous mode fits against the largest page so mixed page boxes do not
  enlarge a small cover independently. Table-of-contents navigation, themes,
  and serialized page locators remain available; PDF typography and margin
  controls are not shown.
- Speed reading uses embedded line text when it is sufficiently complete. For
  image-only or sparse pages, Vision performs accurate OCR entirely on-device
  at a bounded 2048-pixel render size.
- OCR observations sharing a baseline are assembled into logical lines before
  confidence checks. Column detection requires repeated, vertically overlapping
  structure so isolated headings, justified fragments, and page numbers do not
  make ordinary prose ambiguous.
- Speed mode supports Latin and Cyrillic single-column prose and clearly
  separated two-column prose. It pauses before ambiguous columns, table-like
  pages, unsupported scripts, empty text, or OCR below the confidence gates.
- Copy-restricted PDFs remain readable in regular mode but cannot enter speed
  mode. Password entry, annotations, search, manual OCR correction, PDF-to-EPUB
  export, and cloud or LLM reconstruction are not supported.

## Error and Recovery States

- Distinguish unsupported type, protected content, malformed publication,
  inaccessible source, storage failure, metadata failure, missing local file,
  unavailable speed content, and persistent-store failure.
- Preserve the current library on recoverable failures. Never terminate the
  process for a storage or publication error.
- Offer retry when meaningful and direct the person back to the library when a
  publication cannot be opened.

## Privacy and Exclusions

- No account, analytics, advertising, telemetry, or custom network service.
- Book content, OCR, derived text, and reading activity remain on-device.
- Private iCloud sync remains a future milestone, not a hidden partial
  implementation.
- Search inside publication text, bookmarks, highlights, notes, DRM, OPDS,
  text-to-speech, and store purchasing are outside the MVP.
