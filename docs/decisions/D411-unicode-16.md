# D411 - lyric-unicode moves to Unicode 16.0

**Status:** shipped (part of #8497); supersedes D371 item 3's choice of rules (the Unicode 15.1 rules and
the 15.1 suite's number tailoring) now that the tables are Unicode 16.0

## Decision

1. **Tables and suites are Unicode 16.0.0.** The seven UCD files in `lyric-unicode/ucd/` and the two
   conformance suites in `lyric-unicode/tests/conformance/` are replaced by their 16.0.0 revisions, with the
   pinned version and SHA-256s updated in `tools/generate/generate.l` and `conformance.l`, and the tables are
   regenerated (D373). No property value is new to the generator. The bidi suite keeps its 91707 lines; the
   line break suite has 16672.
2. **`Unicode.Bidi` needed no change.** UAX #9 for Unicode 16 changes no rule, and every line passes.
3. **`Unicode.LineBreak` follows UAX #14 revision 53.**
   - *LB13* is `× CL`, `× CP`, `× EX`, `× SY`, and *LB15c* (`SP ÷ IS NU`) and *LB15d* (`× IS`) are back:
     a decimal mark after a space starts a number, and no other comma or full stop starts a line.
   - *LB19* forbids a break only before a quotation mark that is not initial punctuation (Pi) and after one
     that is not final punctuation (Pf); *LB19a* forbids one on either side of any other quotation mark
     unless East Asian characters (East_Asian_Width F, W or H) are on both sides, so curly quotes around
     ideographs break by their direction and straight quotes still never do.
   - *LB20a*: a hyphen-minus or U+2010 HYPHEN at the start of a word (after the start of the text, a space,
     a mandatory break, ZW, CB or GL) does not break before the letter after it.
   - *LB21a*: after a Hebrew letter and a hyphen (HY, or BA that is not East Asian) there is no break unless
     another Hebrew letter follows.
   - *LB25* is the default number rule of revision 53 (`(PR | PO) (OP IS? NU | NU)`, `(HY | IS) × NU`,
     `NU (SY | IS)* × NU`, and a prefix or suffix after `NU (SY | IS)* (CL | CP)?`); the 16.0 suite tests
     the default rules, so the tailoring of section 8.2 example 7 that D371 followed is no longer used.
   - *LB10*: a combining mark with no base takes U+0041's properties, flags included (not East Asian,
     not a quotation mark), not only its class.
   - Balinese digits are AS since 16.0 (an Aksara-Start of LB28a), which the tables now say.
4. **Nothing drawn changes.** The lyric-text, lyric-draw and native lyric-ui goldens are byte-identical,
   all three suites pass on dotnet, the JVM and native, and the two libunibreak/ICU vectors D371 removed
   (`H2 IS NU`, `AL IS NU`) agree again and are back.
