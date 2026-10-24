# 2026-10-23 - Bidirectional text and UAX #14 line breaking in native text areas (D216, #8410)

- `Ui.Native.UnicodeData`, `Ui.Native.Bidi` (UAX #9 in full: explicit controls, isolates, brackets, line reordering)
  and `Ui.Native.LineBreak` (UAX #14, Unicode 15.1, LB2-LB31) in the host-free core, tested on dotnet and the JVM
  (`bidi_tests.l`, `linebreak_tests.l`: rule tests plus vectors on which ICU, FriBidi and libunibreak agree) and run on
  native by the customers example.
- `Ui.Native.Wrap` breaks lines at UAX #14 opportunities, resolves bidi per paragraph, aligns right to left paragraphs to
  the right, and gives lines pieces in visual order; caret, click, selection (one band per piece) and Left/Right
  (`Interact.stepVisualCaret`) work on screen positions. Left to right text is unchanged: the five existing golden frames
  are byte-identical.
- `Text.layoutRun` / `measureRun` (lyric-text) and `Draw.drawTextRun` (lyric-draw) shape a run in a given direction;
  the painter draws each piece with it. New `bidi` golden frame and `algorithmChecks` in the customers `--check` run;
  `layoutRun` checks in the lyric-text shape example.
- Docs: D216, docs/67, docs/12, CLAUDE.md, lyric-ui/README.md, book chapter 31.
- Follow-ups: #8496 (`layoutText` reorders by itself, shared Unicode package), #8497 (single-line inputs, caret affinity,
  word movement, Thai breaking, Unicode 16), #8498 (Unicode's own conformance suites). #8410 stays open for #8496.
