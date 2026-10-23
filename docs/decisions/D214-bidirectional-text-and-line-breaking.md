# D214 - Bidirectional text and UAX #14 line breaking in the native lyric-ui host

**Status:** accepted, implemented for text areas (docs/67 phase G10, #8410); extends D199 (`lyric-text`) and
D204 item 3 (wrapped text areas)

## Decision

1. **The algorithms are plain Lyric over code points, in the host-free core.** `Ui.Native.Bidi` is the Unicode
   Bidirectional Algorithm (UAX #9): the paragraph direction from the first strong character (P2, P3), explicit
   embeddings, overrides and isolates (X1-X10, with isolating run sequences), weak types (W1-W7), paired brackets
   (N0, with canonical equivalents and the NSM rule), neutrals (N1, N2), implicit levels (I1, I2), and per line the
   reset of trailing whitespace (L1) and the reordering of runs (L2). `Ui.Native.LineBreak` is UAX #14 for
   Unicode 15.1: LB2-LB31 over every line break class (kinsoku, numbers by the default pair rules, quotation marks
   by Pi and Pf with LB15a-d, Hangul, regional-indicator pairs, emoji modifiers, hyphens before Hebrew). Both run, and are
   tested, on every target, so `lyric test --manifest lyric-ui/native/lyric.toml` covers dotnet and the JVM and
   the native build of the customers example runs them (`algorithmChecks` in its `--check` mode).
   FriBidi, the library the issue named, is not linked: a native-only dependency could not serve the host-free
   core, and text areas are laid out in Lyric on every target. It, ICU and libunibreak are the test oracles.
2. **The character properties are tables in strings.** `Ui.Native.UnicodeData` holds Bidi_Class, the line break
   class (with East Asian Width F/W/H, Extended_Pictographic-and-unassigned, Pi, Pf and Mn/Mc flags), Bidi_Mirroring_Glyph and
   the paired brackets as sorted fixed-width hex records, generated from ICU 74 (Unicode 15.1), searched by bisection with
   `codeUnitAt`. Nothing is parsed at start-up. A `@pure` package may not hold a `List` in a module-level
   `val`, so the tables are `slice[String]` chunks; one concatenated literal overflowed the type checker's stack
   and the JVM's 64 KB constant limit. Updating the Unicode version means regenerating the four tables from a
   newer ICU in the same record layout.
3. **A paragraph is analysed once, a line is reordered by itself.** `Ui.Native.Wrap.wrapLines` runs UAX #14 over
   each paragraph (text between newlines), cuts lines after the last break opportunity that fits (spaces still hang
   past the edge, a word with no opportunity that fits breaks between characters but never inside a combining
   sequence), and for a paragraph with right to left letters, Arabic digits or direction controls resolves levels
   once and gives each line its runs (`VisualLine.runs`, `rtl`, `visibleTo`, `width`). Text with none of those, the
   usual case, is answered without a table look-up and every line of it is *plain*: one piece from the left edge, and
   the numbers of D204 unchanged (the five existing golden frames are byte-identical).
4. **A line is a list of pieces in visual order.** `Wrap.linePieces` gives each run its place (a right to left
   paragraph is aligned to the right of the box) and its text in reading order without the spaces at its ends: the
   layout of `lyric-text` drops leading and trailing spaces, so a piece's text is drawn from `textX` and the spaces
   are measured by themselves (`spaceAdvance`). The caret, a click, a selection and Left and Right all work on pieces:
   a logical position is drawn at the trailing edge of the character before it (the leading edge of the first character
   of a line), so a position at the boundary of two pieces has one place; `positionAt` picks the nearest;
   `selectionBands` gives one rectangle per piece a selection touches, joined where they touch, and a selected newline
   is a band on the side the paragraph reads towards. Left and Right in a text area step by screen position
   (`Interact.stepVisualCaret`, `Wrap.stepVisual`: among positions drawn at one x the one in the piece the caret is
   in wins, so stepping through a reversed word stays in it; at a line's edge the caret moves on in the text, by one
   in the paragraph's order); Home, End, Up and Down keep their meanings (the edges of the line in the text's order, a
   column in pixels).
5. **`lyric-text` shapes a run in the direction it is given.** `Text.layoutRun(fonts, text, rtl)` (and `measureRun`)
   lays one line of one direction out, setting HarfBuzz's buffer direction instead of guessing it from the script:
   a right to left run is shaped from reading order, so Arabic letters join, its words are placed right to left, and
   its brackets are mirrored by HarfBuzz even when the run has no letter to give the direction (a lone `)` between
   two Latin words of a Hebrew paragraph), which a guessed direction cannot do; a left to right run keeps the order of
   Hebrew inside an override. `Draw.drawTextRun` draws it. `layoutText` is unchanged (a paragraph's direction is its
   first strong character), so the existing text and draw goldens are untouched. The painter draws each piece with
   `drawTextRun(level is odd)`.
6. **A golden frame covers the painted part.** The customers example's `--check` run gains a `bidi` scenario: it replaces
   the notes with a Hebrew word in an English line, a Hebrew line with English, a number and brackets, an Arabic line
   and a long Hebrew paragraph, checks the wrapping, a click at the right edge of the Hebrew line (the start of its text),
   Left and Right across the line's edge, and compares a frame with a selection that crosses pieces
   (`golden/bidi-960x640.rgba`). The text example of `lyric-text` checks `layoutRun` (mirroring, order, widths).

## Validation

The algorithms were checked against independent implementations on generated text.
*UAX #9*: 20000 random strings of 1 to 30 characters (Latin, Hebrew and Arabic letters, digits of both kinds, punctuation,
brackets and their canonical equivalents, combining marks, the explicit controls and the isolates) against ICU 74
and 20000 against FriBidi 1.0.13. The visual order agrees with ICU on all but 2 and with FriBidi on all but 12; where
this implementation differs from one, the other sides with it (ICU on 10 of FriBidi's 12, FriBidi on both of ICU's 2). ICU
does not give a combining mark after a bracket that took the other direction the bracket's type, as UAX #9 N0 says it
must, and resolves the neutrals before an explicit embedding differently; the specification sides with this
implementation. *UAX #14*: 60000 random strings over every class (without the quotation marks, the CJ characters and the
East Asian wide brackets that the oracles treat differently) against libunibreak 5.0.1 and ICU 74. ICU tailors some
rules (a hyphen at the start of a line or after a space does not break; numbers use the regular-expression form of
LB25) and libunibreak lags Unicode 15.1 in places (LB15c; the East Asian Width condition of LB30; it treats CJ as
ID); this implementation follows the specification, and the vectors committed to the tests are the ones on which both
oracles and it agree. Unicode's own `BidiCharacterTest.txt` and `LineBreakTest.txt` are not in the repository and were not
reachable from the build; running them is in the follow-up issue.

## Not done, and where it is tracked

- `Text.layoutText` still takes one direction per paragraph; moving the Unicode tables and the two algorithms to a
  package `lyric-text` can depend on (it builds on `--target native` only, the core on every target) so that
  `layoutText` reorders by itself, the plan is in #8496, and the other items below in #8497 and #8498.
- Single-line inputs (`textInput`, `numberInput`, `dateInput`) are still left to right with a logical caret.
- Caret affinity at a boundary of two pieces (one place per logical position), word movement by Ctrl and Left or Right across
  scripts, dictionary breaking of Thai, Lao, Khmer and Myanmar, and the Unicode 16 rules (LB19 narrowed to
  non-initial and non-final quotes, LB19a, LB28a).
