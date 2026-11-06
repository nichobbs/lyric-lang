# D414 - Dictionary word segmentation for Thai, Lao, Khmer and Myanmar (lyric-unicode-dict)

**Status:** shipped (the dictionary-breaking item of #8497; using it from lyric-text and the native lyric-ui
host is #8832)

## Context

UAX #14 and UAX #29 leave a run of Line_Break SA text (Thai, Lao, Khmer, Myanmar and smaller scripts
written without spaces between words) whole and hand its words to a dictionary. `lyric-unicode` does the
rule half: `Unicode.LineBreak` resolves SA to AL, and `Unicode.WordBreak` takes SA letters as ALetter as
CLDR's root rules do (D412). Without a dictionary a Thai paragraph wraps only at spaces, and word movement
steps over a whole run. ICU's dictionaries for the four scripts are 4.3 MB of UTF-8 word lists; most
programs never show these scripts, so the data must not ride along with `lyric-unicode`.

## Decision

1. **A separate, opt-in library.** `lyric-unicode-dict` (`Lyric.Unicode.Dictionary`) depends on
   `lyric-unicode`. A program that wants dictionary breaks depends on it and calls it; nothing else carries
   the data. Loading the lists at run time from files was the third option considered; it adds a
   deployment step and a failure mode for no gain over a library a program chooses to link.
2. **ICU's dictionaries, pinned.** `dict/` holds `thaidict.txt`, `laodict.txt`, `khmerdict.txt` and
   `burmesedict.txt` from ICU 74.2 (identical in ICU 76.1) unchanged, with ICU's LICENSE (the Unicode
   licence, and the BSD terms of the Lao and Burmese lists). `tools/generate` (Lyric) checks each against its
   SHA-256 and writes `Unicode.Dictionary.Data`. Each dictionary has an alphabet (the code points its words
   use, at most 82) and its words sorted by code point. Each code point is written as the ASCII character of
   its rank, so the lists are 1.6 MB of plain ASCII, read the same on every target (native strings are UTF-8,
   the managed ones UTF-16), and are searched by bisection over the chunk strings with no start-up work. CI
   runs the generator with `--check`.
3. **ICU's engines, ported exactly.** `Unicode.Dictionary` ports `dictbe.cpp`'s Thai, Lao, Khmer and Burmese
   engines: `PossibleWord`, maximal matching with three words of look-ahead, resynchronisation over unknown
   text at a plausible word start, never a break before a combining mark, and Thai's PAIYANNOI and MAIYAMOK
   suffixes. The trie matcher's semantics are emulated over the sorted lists, including its 20-candidate
   limit, the longest-prefix count and the final-value stop. The engines run as ICU's `DictionaryCache` runs
   them: on each run of one script's SA characters inside a segment the rules left whole. Runs of SA scripts
   ICU has no dictionary for stay whole, as in ICU.
4. **The API.** `lineBreaksIn` and `wordBoundariesIn` return what `Unicode.LineBreak.breaksIn` and
   `Unicode.WordBreak.boundariesIn` return, with the dictionary's breaks added. `dictionaryBreaksIn` gives
   the breaks inside one segment, and `handles` says whether a character is one the dictionaries segment.
   ICU's CJK dictionary (Han, kana and Hangul in word breaking) is not part of this library.
5. **Conformance against ICU itself.** No Unicode suite covers dictionary breaking, so the reference is ICU
   74.2. `tools/reference` (a Lyric native program calling ICU's `ubrk_*` through `@library("icuuc")`)
   generates 4000 lines of text from the library's own word lists by a fixed pseudo-random sequence: words,
   words cut short, unknown syllables, each script's repetition, elision and punctuation marks, digits,
   spaces, Latin words and the other scripts' words. It records ICU's line and word break iterators' stops in
   `tests/conformance/DictionaryBreakTest.txt`. It refuses any other ICU version, and its `--check` mode
   regenerates the file byte for byte. The conformance runner pins the file by SHA-256 and runs every line on
   dotnet and the JVM (`scripts/ci/unicode-tests.sh`) and native (`scripts/ci/ui-native-e2e.sh`). All 4000
   lines agree, and with the engines disabled 3916 differ.

## Consequences

- Programs opt in per call site today. Making `lyric-text` and the native lyric-ui host accept a segmenter,
  so that wrapping and word movement can use the dictionaries, is #8832.
- Moving to another ICU release means replacing the four files and their checksums, rerunning the
  generator, and rerunning `tools/reference` on that release to re-record the suite.
