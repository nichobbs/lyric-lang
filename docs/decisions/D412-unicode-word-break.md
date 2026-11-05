# D412 - Word boundaries (UAX #29) in lyric-unicode

**Status:** shipped (part of #8497: the word movement item's foundation)

## Decision

1. **`Unicode.WordBreak` is UAX #29's word boundaries, Unicode 16.0.** `boundariesIn` applies WB1 to WB999
   over a new Word_Break table in `Unicode.Data` (`wordBreakValueOf`: the value in bits 0-4,
   Extended_Pictographic in bit 5 for WB3c). WB4 is computed once per text: each Extend, Format or ZWJ
   character is folded into the character before it unless that is a newline or the start of the text,
   and the rules look through the folded characters (WB6, WB7, WB7b, WB7c, WB11, WB12 look one further, and
   WB15/WB16 count regional indicators back over them).
2. **The table is generated.** `WordBreakProperty.txt` (16.0.0) joins the pinned UCD files and
   `tools/generate` writes `wordBreakRuns` from it and `emoji-data.txt` (D373).
3. **Words for an editor.** `isWordLike` calls a segment a word when it holds a letter, digit, Katakana or
   ExtendNumLet character (by Word_Break), or an ideograph, Hangul, kana, SA or Aksara character (by
   Line_Break, since UAX #29 gives those no letter value); spaces and punctuation are not words.
   `nextWordEnd` moves to the end of the word the position is in or the next one, `previousWordStart` to
   the start of the word it is in or the one before: the Ctrl+Right and Ctrl+Left of an editor, at the same
   stops in both directions. Scripts written without spaces (Thai, Lao, Khmer, Myanmar) are one segment per
   run of letters until dictionary segmentation exists (#8497).
4. **Conformance.** Unicode's `WordBreakTest.txt` (16.0.0, 1826 lines, pinned by SHA-256) runs with the
   other two suites on dotnet, the JVM and native, and passes.
