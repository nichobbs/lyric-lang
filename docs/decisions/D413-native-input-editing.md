# D413 - Native lyric-ui: bidirectional single-line inputs, caret affinity, word movement

**Status:** shipped (part of #8497); amends D216 item 4 (one place per logical position) and closes the
single-line-input, caret-affinity and word-movement items of D216's "Not done"

## Decision

1. **A single-line input is a text area of one unwrapped line.** `Wrap.singleLine(value, boxWidth, widthOf)`
   gives the one `VisualLine` of a `textInput`, `numberInput` or `dateInput`: never cut, with the paragraph's
   UAX #9 levels and runs, a right to left value against the right edge when it fits. The host's line cache
   (`areaLinesOf`) gives text areas `wrapLines` and inputs `singleLine`, so clicks (`Wrap.placeAt`), Left and
   Right (`Interact.stepVisualCaret`) and the caret rectangle reported to the input method are the same code
   for both. A value with nothing that reorders is a plain line and is painted exactly as before (the six
   existing customers goldens are byte-identical); one that does is painted piece by piece
   (`Paint.paintMixedLine`), with the selection as one band per piece and composed text underlined.
2. **Caret affinity.** `TextEdit.downstream` says which of a position's two places the caret is at when the
   position is the boundary of two pieces: the trailing edge of the character before it (upstream, the only
   place before) or the leading edge of the character after it. `Wrap.offsetInRowAt` draws either;
   `Wrap.placeAt` (a click) picks the nearer place, `Wrap.stepVisualPlace` (Left, Right) treats every place as a
   stop, so Right through `ab אבג cd` now stops after `א` at the right end of the Hebrew word as well as at its
   left end. Every other caret move (typing, Home, End, Up, Down, a word move) is upstream. `offsetInRow`,
   `positionAt` and `stepVisual` keep their meaning as the upstream case.
3. **Word movement.** Ctrl+Left and Ctrl+Right (and Alt, Option on macOS, with Left and Right) call
   `Interact.moveWord`, which goes to the start of the previous word or the end of the next by
   `Unicode.WordBreak` (UAX #29, D412), in every script; in a right to left paragraph Left goes forward in the
   text, as the words read. Shift extends the selection. A double click (`Interact.wordAt`) selects the
   UAX #29 segment under it, so `hello,` selects `hello` and `can't` stays one word. `Interact.caretAt`, which
   only single-line inputs used, is removed in favour of `Wrap.placeAt`.
4. **Tests.** The core tests cover `singleLine`, both places of a boundary position and stepping through them,
   a click's affinity, word movement in both directions and with Shift, and double clicks by UAX #29, on
   dotnet and the JVM. The customers example's `--check` run gains an input scenario: a name with Hebrew and a
   number typed into the name input, Ctrl+Left stopping at the start of each word (Hebrew and digits included),
   Alt+Right, every Right moving the drawn caret right and visiting a boundary position at both its places,
   and a golden frame (`golden/input-bidi-960x640.rgba`); the name is put back, so the frames after it are
   unchanged.

## Not done, and where it is tracked

- Dictionary-based segmentation of Thai, Lao, Khmer and Myanmar for line breaking and word movement (#8497).
- Single-line inputs did not scroll horizontally (`TextEdit.scrollX` was never moved); this is now done, see
  `docs/progress/2026-11-10-native-input-horizontal-scroll.md` (#8813).
