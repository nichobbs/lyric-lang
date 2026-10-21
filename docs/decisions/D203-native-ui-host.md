# D203 - The native `lyric-ui` host

**Status:** accepted, implemented for `--target native` on Linux (docs/67 phase G10, #7949); builds on D194 to D200, D162

## Decision

1. **The host is the session protocol's client, in-process.** `Ui.Native.Run` starts an
   `Ui.Host.Instance` with an outbox that queues the JSON the instance sends (a protected `Inbox`,
   because effects deliver from their own threads), applies each patch message to its own mirror of the
   tree, and turns what the user does into `Ui.Protocol.Event`s for `Instance.receive`. Application
   code is therefore the same as for the web and desktop hosts: the same `route(url): Option[Instance]`,
   screens, effects and forms, with only the entry point differing. `examples/ui-customers` runs
   natively through its unchanged packages; its composition below the host moved to `Customers.App`
   (`route`) so three entry points can share it.
2. **Two projects.** `lyric-ui/native/` (`Lyric.Ui.Native.Core`) is host-free and tests on every target:
   `Ui.Native.Theme` (the `runtime/ui.css` tokens, light and dark), `Ui.Native.Client` (decoding server
   messages, applying patches with the reference applier, stale-echo handling by input version, event
   paths by key), `Ui.Native.Layout` (flex-style layout of the widget tree into boxes with absolute
   rectangles, text measured through a `Metrics` the host supplies), `Ui.Native.Interact` (focus order,
   modal hit testing, text editing by code point, grid scroll and viewport requests, click actions).
   `lyric-ui/native/host/` (`Lyric.Ui.Native`) is the painter (`Ui.Native.Paint`, on lyric-draw and
   lyric-text) and the window loop plus a headless harness (`Ui.Native.Run`).
3. **Widgets.** Every kind the customers example uses and the rest of the closed set: columns, rows
   (wrapping, spacers), cards and sections, headings, paragraphs, labels, badges, banners, a spinner,
   fields and field errors, text, number, date and multi-line inputs, checkboxes, selects with a popup,
   buttons in three variants, links (client-side navigation), tables, data grids (header with sorting,
   a clipped scrolling body, viewport requests for rows not yet loaded), dialogs (modal, over a dimmed
   backdrop), and toasts.
4. **Input.** Mouse (click, drag to select, double click for a word, triple click for all, hover, wheel on the
   page and on grids), keyboard (Tab and Shift-Tab
   traversal, Enter and Space to activate, Up and Down between grid rows and select options, Enter in an
   input to submit its form), a caret and selection in text inputs, clipboard through Ctrl or Cmd with A,
   C, X and V, and input-method composition: `lyric-window` decodes `SDL_EVENT_TEXT_EDITING` as
   `Window.TextEditing` and `setTextInputArea` places the candidate window at the focused input; the
   composition is drawn underlined at the caret until the committed text arrives.
5. **High-DPI.** `Draw.setScale` makes a painter take logical pixels and multiply every coordinate, size,
   radius and blur by the display scale, and the host opens its fonts at the scaled size; layout is done
   once in logical units for any display.
6. **Test.** `Ui.Native.Core` has 31 tests. `scripts/ci/ui-native-e2e.sh` builds the example natively and
   drives it headless (`--check`) with scripted window events against golden frames: the list, a link
   click to the edit screen, typing over a selection, clipboard copy and paste, an input-method
   composition, saving, the toast and the return to the list; then runs it in a window on an X server
   (Xvfb, lavapipe) and drives it with real mouse and keyboard events.
7. **Two native-backend defects fixed or worked around, found by this work.** A nullary union case
   nested in a constructor pattern (`case Ok(Back) ->`) was a binding, so it matched any `Ok` no earlier
   arm took; fixed in `llvm_codegen.l` and pinned by `nested_nullary_pattern_native_self_test.l`. Bare
   enum-case patterns resolve bundle-wide, first enum wins (#8421), so `Ui.Core.kindName` and
   `Ui.Forms.fieldViewAt` qualify their cases.

## Not in this slice

- **Accessibility.** AccessKit's C API is not bound, so there is no screen-reader tree and no macOS
  screen-reader smoke test (docs/67's G10 exit criterion names both); the box tree is the structure an
  accessibility tree would be built from. Tracked in the follow-up issue.
- **macOS.** Needs the Cocoa surface of docs/67 G5; nothing in the host is platform specific.
- Soft wrapping and scrolling inside a multi-line input, bidirectional carets, cursor shapes, and a
  Windows build (G9).
- A native build of any program that depends on `Lyric.Ui` links `libwebview` (the desktop kernel's
  `@library`) even when it never opens a webview, because a dependency's packages are lowered in full;
  CI already installs it. Pruning link requirements to reachable externs is a compiler follow-up.
