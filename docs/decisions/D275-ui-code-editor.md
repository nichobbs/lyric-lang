# D275 - The lyric-ui code editor: a `TextArea` variant

**Status:** shipped on the web host and the desktop webview (docs/65 §13.10, phase U9); the native host shows a plain text area until #8625. Extends D137 and D138.

## Context

lyric-ui has a closed set of semantic widgets (docs/65 §7.1). Editing source,
configuration or other structured text needs more than `TextArea`: a
monospace face, line numbers, highlighting and the keys a programmer expects.
The options were a new widget kind, an escape hatch to a third-party editor
(`Raw`, web only), or a variant of `TextArea`.

## Decision

1. **A variant, not a kind.** `Widgets.codeEditor(value, onInput, opts)` builds
   a `TextArea` with `variant = "code"` and the properties `language`,
   `lineNumbers` and `tabSize`.
   - A new kind would have to be handled by every host and by the plugin
     boundary. Native alone has about twenty places that name `textArea`.
   - A host that draws nothing special shows a working multi-line field with
     the same value, handler and events, so the closed vocabulary still holds.
   - `variant` already exists as a property (`button`, `banner`). It is fixed
     for a node; a screen that switches a field between plain and code gives
     them different keys.
2. **The editor is a textarea under a highlighted copy.** `CodeEditor`
   (`runtime/src/editor.ts`) stacks a real `<textarea>` with transparent text
   over a `<pre>` that holds the same text as coloured spans, with a gutter
   beside them.
   - Selection, the caret, IME composition, undo, drag and drop and the
     platform's accessibility behaviour stay the browser's. A hand-drawn
     editor would make all of them lyric-ui's problem (docs/65 §13.3).
   - The cost is that both layers must lay out identically: one font, one
     line height, no wrapping, a shared scroll position.
3. **Editing keys are pure functions.** `runtime/src/editing.ts` computes what
   Tab, Shift+Tab and Enter do as a replacement of a range of the text plus
   the new selection, and the DOM layer applies it through
   `execCommand("insertText")` so undo keeps working (falling back to
   `setRangeText`).
   - Tab indents to the next tab stop, or every selected line.
   - Shift+Tab outdents.
   - Enter keeps the indentation, adds a level after an opening bracket, and
     between a bracket pair opens an indented blank line.
   - Escape then Tab leaves the field, which avoids a keyboard trap.
   - A read-only editor and an IME composition take no edits.
4. **Highlighting** is a tokenizer per language in `runtime/src/highlight.ts`:
   `lyric` (nested block comments, keywords, types, literals, numbers with
   suffixes and separators, strings) and `json` (keys told from string
   values). Another name is plain text. Tokenizing is lossless, which the
   tests assert. The text is re-tokenized in full on each input; that is for a
   screenful of source, not a megabyte document.
5. **Events.** The editor reports the whole text as an `input` event with the
   same input versions as every text input (docs/65 §9.4), so a stale echo
   does not move the caret. A value from the server that equals the text
   leaves the caret alone.
6. **First paint.** `Ui.Html` renders the editor's wrapper, gutter and
   textarea, unhighlighted; the runtime highlights when it takes over.
7. **Plugins.** `Ui.Plugins.Build.codeEditor(value, message, language)` builds
   the node, and the host keeps the three new properties (`widgetPropNames`).
   Highlighting stays host-side, so a plugin cannot inject markup.
8. **Assets.** The runtime gains three modules (`editor.js`, `editing.js`,
   `highlight.js`) embedded in `host_assets.l` by `embed.mjs` and served beside
   the others.

## Tests

- `lyric-ui/runtime/test/highlight.test.mjs` and `editing.test.mjs` (`node
  --test`): tokens for both languages, losslessness, every editing rule.
- `lyric-ui/runtime/e2e/editor.e2e.mjs` (Chromium): typing and the gutter,
  highlighting, Tab, Shift+Tab, Enter, undo, Escape then Tab, server values and
  the caret, scroll sync, read-only. It needs no application.
- `lyric-ui/tests`: the builder's properties and handlers, the server-side
  markup, and the plugin boundary's properties.

## Not in this slice

The native host's monospace face, gutter, highlighting and editing keys
(#8625); bracket auto-closing, multiple cursors, find and replace, folding
and language servers; highlighting languages beyond `lyric` and `json`.
