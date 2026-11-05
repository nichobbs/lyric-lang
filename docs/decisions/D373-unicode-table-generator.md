# D373 - `Unicode.Data`'s tables are generated in Lyric from pinned UCD files

**Status:** shipped (part of #8497); amends D216 item 2 (how the tables are made and updated)

## Decision

1. **The source of the tables is the Unicode Character Database, vendored.** `lyric-unicode/ucd/` holds the
   seven UCD 15.1.0 files the tables need, unchanged, with the Unicode licence: `extracted/DerivedBidiClass.txt`,
   `LineBreak.txt`, `EastAsianWidth.txt`, `extracted/DerivedGeneralCategory.txt`, `emoji/emoji-data.txt`,
   `BidiMirroring.txt` and `BidiBrackets.txt`. `.gitattributes` keeps their bytes on every checkout.
2. **A Lyric program writes them.** `lyric-unicode/tools/generate` (`Unicode.Generate`) checks each file
   against the SHA-256 it pins with the Unicode version, fills one value per code point (each property's
   `# @missing` defaults first, then its data lines; an unknown value or malformed line is an error that
   names the file and line), and rewrites the four `val ...: slice[String]` lines of `src/unicode_data.l`
   in the existing record layout, leaving the rest of the file alone. `--check` writes nothing and fails
   when the file differs. The class numbers stay those of `Unicode.Bidi` and `Unicode.LineBreak` (ICU's
   order, in which D216's tables were first made), so neither algorithm changes.
3. **It reproduces D216's tables exactly.** From UCD 15.1 the generator writes the same 1200 bidi, 3715
   line break, 428 mirror and 128 bracket records that ICU 74 produced, so the tables are unchanged byte
   for byte, and ICU is no longer needed to update them.
4. **CI keeps them honest.** The `unicode` ecosystem-tests entry runs the generator with `--check` before
   the suites.

## Not done, and where it is tracked

- Moving the tables and the conformance suites to Unicode 16, with the UAX #14 changes that come with it
  (#8497).
