# D372 - lyric-unicode, and `layoutText` reorders mixed-direction paragraphs itself

**Status:** shipped (#8496, #8410); amends D216 items 1, 2 and 5 (where the algorithms live, and
`layoutText` no longer takes one direction per paragraph) and closes the mixed-direction and UAX #14
items of D199's "Not in this slice"

## Decision

1. **The Unicode tables and algorithms are a library of their own.** `lyric-unicode` (`Lyric.Unicode`)
   holds `Unicode.Data` (the Unicode 15.1 tables of D216 item 2), `Unicode.Bidi` (UAX #9) and
   `Unicode.LineBreak` (UAX #14, as D371 corrected it), unchanged apart from their names; their unit
   tests and Unicode's conformance suites (D371) moved with them (`lyric-unicode/tests/`,
   `lyric-unicode/tests/conformance/`). The packages were `Ui.Native.UnicodeData`, `Ui.Native.Bidi` and
   `Ui.Native.LineBreak` in the native lyric-ui core, which builds on every target, while `lyric-text`
   builds on `--target native` only, so `lyric-text` could not depend on the core; both now depend on
   `lyric-unicode`, which is plain Lyric and builds and tests on every target. `Unicode.Data` is
   imported as `import Unicode.Data as UnicodeData`, so a call reads `UnicodeData.bidiClassOf`.
2. **`Text.layoutText` runs both algorithms on each paragraph.** A paragraph (text between `\n`) becomes
   code points with their byte offsets. When nothing in it can reorder (`Bidi.needsBidi`), its level is 0
   and no bidi work is done; otherwise its level is that of its first strong character (P2, P3) and
   every code point gets its embedding level (`Bidi.resolveLevels`). `LineBreak.breaksIn` gives the break
   opportunities: the text between two of them is a word and the spaces after it, which hang past the
   column edge as before; a required break inside the paragraph (a line separator) starts a new line.
   Words are shaped in runs that change where the fallback font, the embedding level, or the class rule
   L1 may reset (whitespace, separators, isolates, X9-removed characters) changes, so every run has one
   level on its line; each run is shaped by HarfBuzz in its own direction (from reading order, mirrored,
   when the level is odd). After the greedy fill, each line's runs are placed in the order
   `Bidi.lineRuns` gives (L1, L2), and a right to left paragraph is aligned to the right of the column.
   `layoutRun` takes the same path with the direction fixed and no reordering, and keeps its meaning.
   Spaces at the start and end of a line are still not placed, which `Ui.Native.Wrap` relies on.
3. **The old segmentation is gone.** `isCjkCp`, `noBreakBeforeCp`, `noBreakAfterCp`, `isRtlCp`,
   `isLetterCp` and `paragraphIsRtl` were the simplified opportunities and direction guess; UAX #14
   now decides where lines break (a minus sign stays with its digits, `( a` does not break after the
   bracket, the kinsoku rules are complete) and UAX #9 decides the direction.
4. **The existing scene is unchanged, and a mixed-direction scene is added.** The Latin/Arabic/CJK scene
   renders byte-identical to the old layout and its golden. `lyric-text/examples/shape` gains checks that
   only real reordering passes (two Hebrew words in an English line are one reversed run, not two reversed
   words in English order; English words and a number in a Hebrew line; mirrored brackets; a Latin word
   ending an Arabic line; right alignment; each wrapped line reordered by itself), two UAX #14 checks (a
   minus sign and its digits, an ideographic full stop), and a second golden image
   (`golden/bidi-384x224.pgm`, `LYRIC_TEXT_GOLDEN_BIDI`): Hebrew and Arabic with English, a number and
   brackets, and a wrapped mixed paragraph. `LYRIC_TEXT_UPDATE=1` rewrites the goldens. The Linux, macOS
   and Windows text lanes compare both scenes.
   `lyric-draw`'s scene golden changes in one place, for the better: in "Latin, مرحبا, 你好" (a left to
   right paragraph) the comma after the Arabic word is neutral between right to left and left to right
   text, so it takes the paragraph's direction and follows the word on its right; the old layout shaped
   "مرحبا," as one right to left word and drew the comma on its left. 184 pixels move;
   `golden/scene-256x192.rgba` is regenerated.
5. **CI.** `lyric-unicode` is an ecosystem-tests matrix entry (`unicode`: its own suites and the
   conformance suites on dotnet and the JVM); `ui-native-e2e.sh` runs the conformance suites on native.

## Not done, and where it is tracked

- Single-line inputs, caret affinity, word movement, dictionary breaking of Thai, Lao, Khmer and Myanmar,
  Unicode 16, and a Lyric generator for `Unicode.Data`'s tables (#8497).
- `layoutText` breaks a word wider than the column only at its opportunities, as before; breaking it
  between characters as `Ui.Native.Wrap` does is not part of this change.
