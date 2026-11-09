# Printer Hub UI style

Status: accepted (EGM review resolved 2026-11-09) · Applies to: the Flutter app (`lib/`) and the OrcaSlicer dock panel (the HTML/CSS in the `PAGE` string of `orca-plugin/printer_hub.py`)

## Goal

Every screen should look like it belongs to the same app, and the Orca panel should look like a compact version of it. This spec changes look and layout only. It changes no behaviour, data or `/hub/*` API, and adds no new buttons or actions.

`lib/ui.dart` already holds the base layer:
- `Palette.dark` and `Palette.light`, plus the accent colour the user picks;
- `C`, the static class that pages read colours from (`C.text`, `C.muted`, `C.danger` and so on);
- `statusStyle(state, online)`, which maps a printer state to a colour and label;
- the shared widgets `Panel`, `Tile`, `StatusPill`, `Hint` and `Heading`.

An audit of `lib/` and the plugin (grep for radii, font sizes, raw colours and state widgets) found these gaps:
- 11 corner radii are in use;
- 10 font sizes, chosen screen by screen;
- loading, empty and error states written by hand on every page;
- in the Orca panel, its own red and orange and its own radii.

The fix is two small static token classes, `R` and `T`, plus one shared `StateView` widget. Static classes match how `C` already works and keep each change a one-word edit. `ThemeExtension`/`TextTheme` would need `Theme.of(context)` at every call site for no gain here.

## Tokens

### Spacing

4-point grid: 4, 8, 12, 16, 24, 32. Existing 10, 14 and 18 paddings round to 8, 12 and 16.

Deliberate exceptions:
- 6, the gap inside pills and chips;
- 96, the list bottom padding under a floating button;
- the Orca panel's 10px card padding.

Page edges use 16. Panels and list rows sit 12 apart (8 in dense lists such as History). A `Panel` has 16 padding, and 12 between its title and its content (14 today).

### Corner radius: `R` (`static const double`)

| Token | Value | Used for |
|---|---|---|
| `R.sm` | 8 | chips, thumbnails, colour swatches, small marks |
| `R.md` | 12 | inputs, hints, inner tiles, images inside a panel |
| `R.lg` | 16 | list tiles (`Tile`), console box, camera frame |
| `R.xl` | 20 | `Panel`, gauge tiles, printer cards |

Dialogs keep 24, set once in `buildTheme`. Pills use 99 (fully round). Chart legend marks may use 3.

How today's radii map to tokens:
- 6 → 8;
- 10 → 8 for chips and swatches, 12 for images;
- 14 → 12;
- 18 → 20.

Input and chip radii change in `buildTheme`: inputs 14 → 12, chips 10 → 8.

### Type scale: `T` (const `TextStyle`, no colour)

Colour is added at the call site, e.g. `T.label.copyWith(color: C.muted)`, because `C` changes at runtime.

| Token | Size / weight | Used for |
|---|---|---|
| `T.caption` | 11 / 400 | helper lines, chart axes, slot labels |
| `T.label` | 12 / 700 | muted labels, pill text, panel titles (uppercase, letter-spacing 1.1) |
| `T.small` | 13 / 400 | hints, secondary text, empty/error messages |
| `T.value` | 16 / 700 | stat values |
| `T.title` | 18 / 800 | card and sheet titles |
| `T.heading` | 20 / 800 | page headings |
| `T.hero` | 26 / 800 | the welcome title, big numbers |

Body text keeps the Material default (14). The review suggested merging `T.title` into `T.heading`. Six screens use 18 for card titles, and 20 crowds them, so `T.title` stays. Folds: 10 → 11, 17 → 18, 22 → 20. Nothing smaller than 11. Gauge and progress-ring numbers keep their size-relative font sizes.

### Colour

The palettes and accent choices don't change.

- **Text:** `C.text` for primary text and `C.muted` for secondary. No other greys.
- **Destructive fill:** `C.dangerFill = #D6304F` with white text, for filled destructive buttons and error snack bars. White on `#FF5470` is only 3.1:1 contrast. `C.danger` stays for icons, borders and dots.
- **Light mode:** status colours get darker wherever they show as text, icons or borders. `C.ink(color)` returns the colour unchanged in dark mode and lerps it 32% toward black in light mode, the same as the theme's `primary`. `statusStyle`, `Hint` and the History job icons use it.
- **Raw `Color(...)`/`Colors.*` only for:**
  - camera overlays (white on a black scrim);
  - filament and accent swatches;
  - printer tint colours;
  - mesh heat-map labels;
  - the white QR-code background;
  - white text on `C.dangerFill`;
  - theme code in `ui.dart`.

**Status mapping** (`statusStyle`, one table for every surface):

| State | App colour | Label | History job icon | Orca card border |
|---|---|---|---|---|
| printing | accent | Printing | in_progress: `C.bed` | default |
| paused | `C.warn` | Paused | — | warn |
| error | `C.danger` | Error | error: `C.danger` | danger |
| complete | `C.bed` | Complete | completed: `C.bed` (was accent) | default |
| cancelled | `C.muted` | Cancelled | cancelled: `C.muted` (was warn) | default |
| ready | `C.text` | Ready | — | default |
| offline | `C.muted` | Connecting | — | default, card dimmed |

On the Blue accent, "printing" and "complete" share a hue. The label and the progress bar tell them apart, so no change is needed.

**Orca panel colours:**
- Colours come from Orca's variables, each with a fallback: `var(--orca-border, #8884)`, `var(--orca-muted, #888)`, `var(--orca-accent, #339cff)`.
- The panel defines `--ph-danger: #FF5470` and `--ph-warn: #F5A524`.
- Under `@media (prefers-color-scheme: light)` these become `#C8243F` and `#9A6200`.

### Motion: `M`

Motion explains change. It doesn't decorate. Every animation is skipped when the OS asks for reduced motion (`M.reduced`).

| Token | Value | Used for |
|---|---|---|
| `M.fast` | 150ms | press feedback, small state changes |
| `M.base` | 260ms | tab switch, colour changes, list state crossfade |
| `M.enter` | 420ms | content entrance (`Reveal`) |
| `M.curve` | easeOutCubic | everything except the printing pulse |

- **Tab switch:** the shown tab fades in and rises 8px. Every tab stays mounted, so data keeps loading in the background. Panels inside the tab replay a stagger (`Reveal`, 45ms apart, capped at 8 items).
- **Entrance:** opacity 0→1 while rising 12px. Used for Home printer cards, History rows, Files rows (replayed per folder) and panels on Overview, Control and Tools. Rows inside a panel don't stagger.
- **Press:** `Tile` scales to 0.98 while held.
- **Status:** `StatusPill` animates its colour. The "printing" dot breathes between 40% and 100% opacity every 1.4s.
- **Numbers:** temperatures, progress and stat values use tabular figures, so digits don't jitter.
- **Pages:** fade-forward transitions on the Mac, the standard swipe on iPhone.
- **Orca panel:** buttons transition background and press to 0.96 over 150ms. No entrance animation, because the panel re-renders on every poll.

## Components

- **Panel:** surface, 1px border, `R.xl`, 16 padding, an optional uppercase `T.label` title with a muted 18px icon.
- **Tile:** surface, 1px border (2px accent when selected), `R.lg`.
- **Buttons:**
  - `FilledButton` for the one main action;
  - `FilledButton.tonal` or `OutlinedButton` for secondary actions;
  - `TextButton` for Cancel and links;
  - `IconButton` for toolbars;
  - destructive confirms use `C.dangerFill`.

  Keep Material's default tap targets (no `shrinkWrap`). Fixed heights are minimums. The Orca panel is exempt.
- **Icons:** Material rounded variants (`*_rounded`). `*_outlined` is allowed for unselected states, such as nav destinations, because there is no outlined-rounded set. Use 18 in titles and hints and 20–24 in toolbars. Icons are `C.muted` unless they show a status.

## Loading, empty and error states

`StateView` (in `ui.dart`) has two constructors. Neither scrolls, so to keep pull-to-refresh working, wrap it in a `ListView`.

- `StateView.empty(icon, text, {action})`: a muted 40px icon above one line of muted `T.small` text, with an optional action widget below.
- `StateView.error(message, {onRetry})`: `Icons.error_outline_rounded` in `C.danger` at 40px, the message in centred `T.small` (up to 3 lines), and a tonal "Retry" button when `onRetry` is set.

Loading keeps the plain centred `CircularProgressIndicator`. Inside a panel, give it a fixed-height box.

Converted sites:

| Site | Becomes |
|---|---|
| History, error | `StateView.error` (keeps its Retry) |
| Files, error | `StateView.error` (keeps its Retry) |
| Files, "No files here" / "No favourite files yet" | `StateView.empty` |
| Console, "No console output yet" | `StateView.empty` |
| Macros, "No macros found" | `StateView.empty` |
| Printer screen, error | `StateView.error` (no retry) |

Unchanged:
- camera.dart's `_msg`, which draws white over the black video area and is styled for that;
- main.dart's `_EmptyState`, the first-run welcome screen.

Actions appear only where a screen already has them.

The Orca panel adds no Retry button, because it already re-polls on a timer. Error text moves from `.warn` to a new `.err` class: normal text colour with a red left marker, like the app's error line.

## Orca panel

The panel is a 340px dock, a compact version of the app.

- **Text:** base 13px, labels 12px, captions and buttons 11–12px, card title 14px bold. Badges go from 10px to 11px.
- **Cards:**
  - 1px border, `border-radius: 12px`, `padding: 10px 12px`, `margin-bottom: 12px`;
  - a 2px left border in danger or warn colour for error and paused printers;
  - `opacity: .6` when offline.
- **Pills and badges:** `border-radius: 99px`.
- **Progress bar:** 6px tall, radius 99.
- **Images:** radius 8.
- **Buttons:** `font-size: 12px; padding: 3px 10px; border-radius: 8px; border: 1px solid var(--orca-border); background: transparent; color: inherit`. Danger buttons use `color: var(--ph-danger)`. The hover state lightens the background.
- **Sections:** separated by a 1px solid border (dashed today), `margin-top: 8px; padding-top: 8px`.

## Verification

- `flutter analyze lib test` and `flutter test` pass.
- `grep -nE 'fontSize: (10|17|22)\b' lib/` finds nothing.
- `grep -n 'e5484d\|f3883b' orca-plugin/printer_hub.py` finds nothing.
- The plugin passes `python3 -c 'import ast'`, and its script passes `node --check`.
- Release as usual: bump `pubspec.yaml` and `kAppVersion`, add a `kWhatsNew` entry, tag, then upload the plugin to the release.

## Not in scope

- new features, actions or navigation;
- new fonts or icon packs;
- changes to the accent choices;
- changes to any `/hub/*` request or response.
