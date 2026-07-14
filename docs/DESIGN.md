# Design System

## Direction

FastReader uses a calm editorial visual language: warm paper-like surfaces,
graphite text, restrained coral/amber focus color, generous whitespace, and
content-led hierarchy. Native controls and interactions take priority over
decorative novelty.

## Tokens

The implemented semantic SwiftUI tokens are:

- surfaces: `canvas` and `raised`;
- content: `primaryText`, `secondaryText`, and `onFocus`;
- accents: `focus` and `progress`;
- spacing: 4, 8, 12, 16, 24, and 32 points;
- radii: 8 points for small controls and 16 points for cards.

Feature-specific presentation uses native materials, shapes, and transitions.
Motion is removed or reduced when Reduce Motion is enabled.

Use system typography for application chrome. Publication typography remains
under Readium preferences. Do not encode meaning by color alone.

## Library

### iPhone

- Navigation stack with Library title, search, and import action.
- An adaptive 92...128-point cover grid produces three columns on typical
  compact iPhones, four on sufficiently wide phones, and 16-point horizontal
  by 24-point vertical gutters.
  Accessibility Dynamic Type widens cards to 160...240 points before text clips.
- Cards show a compact 2:3 cover, title, author, inset progress bar/percentage,
  and status label. Title and author rows reserve a stable two-line/one-line
  metadata area so progress bars align across each grid row. The cover clips
  inside the proposed grid-cell width; the progress inset preserves a visible
  gap between cards.
- Two stacked filter sections sit above the grid. Each uses a left-aligned
  header above a horizontal chip row. Status exposes All, New, Reading, Done,
  and Canceled; Tags always exposes every active tag without a disclosure step.
- Tag count badges use faceted AND semantics; zero-count unselected tags remain
  visible but disabled. If no active tag exists, the Tags section retains its
  header and shows a stable empty placeholder.

### iPad

- `NavigationSplitView` with an All Books sidebar and the complete filter
  controls in the detail view.
- Main adaptive compact cover grid with search and import toolbar actions. It
  adds columns across the available detail width while retaining the same card
  maximum and filter semantics as iPhone.
- Tag editing uses a sheet; status editing and deletion are available from the
  card context menu. Reading uses the detail area.

### States

- Empty: concise value statement plus primary Import EPUB action.
- Importing: a blocking progress indicator while the selected batch is
  processed serially.
- Error: title, plain-language cause, retry/reselect action when meaningful.
- Missing file: retain metadata and show reader retry/back actions; importing
  identical content repairs the missing file.
- No filter results: preserve active filters and show the empty result state.

### Tag Editor

- Present tag selection as a large native sheet with persistent Cancel, Save,
  and one clearly labeled Search or Create field. Do not expose delimiter
  syntax or a comma-separated text buffer.
- With no query, use scannable Selected and Available Tags sections. Rows use a
  tag symbol plus a trailing checkmark, selected VoiceOver trait, and explicit
  selected/not-selected value; an empty library of tags retains a plain empty
  state.
- While typing, show all case-insensitive matches and an explicit
  `Create “Name”` row only when there is no canonical exact match. Keep row
  labels vertically flexible at accessibility text sizes.
- Creation and selection remain draft-only until Save. Save failures use a
  plain-language alert without dismissing the sheet; Cancel never persists a
  newly created draft tag.

## Regular Reader

- Publication content owns the screen. Top/bottom chrome fades after
  interaction and returns on center tap.
- Top chrome: back, title/section, table of contents, appearance.
- Bottom chrome: progression, percentage, and a centered regular/speed mode
  switch. The Regular/Speed selector owns all mode changes and keeps the same
  position in both modes. Top-left Back always returns to the library.
- Keep controls outside unsafe areas and stable when status-bar visibility
  changes.
- Warm light and graphite dark reader themes meet WCAG contrast; system mode
  selects the initial theme without preventing an explicit override.

## Speed Reader

- Use a quiet reader surface with the active word's ORP fixed at 42% of the
  available width, leaving more room for upcoming context.
- Split the active token into prefix, focus grapheme, and suffix so the focus
  grapheme—not the word box—is anchored to the screen center.
- Render the three prior tokens, active word, and three next tokens as one
  non-wrapping baseline. Context uses a 22-point rounded face at lower contrast;
  the active word uses 42 points. Offscreen context clips naturally but never
  moves the focus grapheme.
- The focus grapheme uses the semantic coral/amber accent plus weight, retaining
  meaning under color-vision differences.
- Bottom controls: progression and WPM, 60-point previous/next circles, and a
  68-point play/pause circle. A second row combines 52-point WPM decrement and
  increment controls with the Regular/Speed selector centered independently of
  them. Adaptive Pauses lives in the top-right settings menu. Controls auto-hide
  only while playing and return on tap.
- Switching to regular reading adds a transient coral highlight to the active
  speed word. It communicates continuity without becoming a saved annotation.
- No animated word travel. Token replacement is instantaneous or a subtle
  cross-fade that is disabled by Reduce Motion.

## Accessibility

- Support all Dynamic Type sizes; switch grids and control rows to vertical
  layouts before clipping text.
- Give covers, progress, status, tags, filters, and playback controls concise
  VoiceOver labels, values, hints, and predictable order.
- The RSVP stream is not announced token-by-token. VoiceOver users can operate
  its controls and return to the accessible regular reader.
- Meet contrast in light/dark and Increase Contrast modes.
- Avoid time-limited confirmation UI and retain paused state after interruption.
- Validate portrait/landscape on compact and regular widths, including iPad
  Split View.

## App Icon

Use an original, minimal mark based on a centered focus grapheme/redicle within
an open-page silhouette. Use warm paper, graphite, and focus coral without text,
fine detail, gradients that obscure the mark, or resemblance to Apple Books.

The current asset implements this direction as a bold warm-paper open-book
silhouette on graphite, with a coral center spine representing the active ORP.
Its filled shapes remain legible at Home Screen and Spotlight sizes without
text, thin target lines, or resemblance to Apple Books. The launch screen keeps
its existing mark over the semantic paper surface without release-specific
text.
