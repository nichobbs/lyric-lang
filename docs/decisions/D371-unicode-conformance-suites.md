# D371 - Unicode's conformance suites for the native text algorithms; UAX #14 as Unicode 15.1 tests it

**Status:** shipped (#8498); amends D216 item 1 (the rules `Ui.Native.LineBreak` follows)

## Decision

1. **Unicode's own suites are vendored and run on every target.** `BidiCharacterTest.txt` (UAX #9) and
   `LineBreakTest.txt` (UAX #14) of Unicode 15.1.0, the version of `Ui.Native.UnicodeData`, are in
   `lyric-ui/native/tests/unicode/` unchanged, with the Unicode licence (`LICENSE-UNICODE.txt`). The runner
   (`Ui.Native.UnicodeConformance`) pins each by SHA-256 and refuses another revision, finds the files from the
   directory a run starts in (that directory, or `lyric-ui/native/tests/unicode` below it or a parent), and
   needs no network. Every line is run: for the bidi suite the paragraph level, every level after L1 (`x`
   for what X9 removes) and the visual order; for the line break suite every position. `lyric test --manifest
   lyric-ui/native/tests/unicode/lyric.toml` runs them on dotnet and, with `--target jvm`, on the JVM; on
   `--target native`, where `lyric test` does not run manifest suites, the project's `main` runs them
   (`scripts/ci/ui-native-e2e.sh` builds and runs it; `scripts/ci/ui-jvm-suites.sh` gains the JVM run, and
   the core's own suites on the JVM, which D216 described but CI did not run).
2. **`Ui.Native.Bidi` needed no change.** All 91707 lines of `BidiCharacterTest.txt` agree.
3. **`Ui.Native.LineBreak` follows the rules Unicode 15.1 tests.** 52 of 10274 lines differed at first, then
   35 more once those were fixed:
   - *LB28a* (Brahmic orthographic syllables: `AP × (AK | ◌ | AS)`, `(AK | ◌ | AS) × (VF | VI)`,
     `(AK | ◌ | AS) VI × (AK | ◌)`, `(AK | ◌ | AS) × (AK | ◌ | AS) VF`) was missing, although the classes
     AK, AP, AS, VF and VI were already in the table.
   - *LB25* is the regular expression of UAX #14 section 8.2 example 7, which the suite uses:
     `(PR | PO) × (OP | HY)? NU`, `(OP | HY) × NU`, and inside `NU (NU | SY | IS)* (CL | CP)?` no break
     before the next NU, SY, IS, CL or CP, nor before a following PO or PR. The default pair rules joined
     `% (` and `) $` with no digit and `IS NU` anywhere; the tailoring breaks there.
   - *LB13* is `× IS` again and LB15c and LB15d are gone: those two rules are Unicode 16.0 (the 15.1 suite
     gives `SP × IS` by LB13), so D216's "LB15c" was ahead of the tables. A comma after a space never starts
     a line, whatever follows it.
   Two of the random vectors checked against libunibreak and ICU (`H2 IS NU` and `AL IS NU`) are now
   breaks before the digit, as the tailoring and the suite require; they were removed from the vector
   list, whose comment now says the vectors are those the tailoring does not change.

## Not done, and where it is tracked

- The Unicode 16 rules (LB15c, LB15d, LB19 narrowed, LB19a, LB20a, LB28a extended) move in with tables
  generated from Unicode 16 data, and the suites with them (#8497).
- `BidiTest.txt` (the class-sequence suite of UAX #9) is not run; `BidiCharacterTest.txt` covers the
  same rules on real characters.
