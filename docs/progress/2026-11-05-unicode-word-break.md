# Word boundaries (UAX #29) in lyric-unicode (#8497)

`Unicode.WordBreak` implements the word boundaries of Unicode Text Segmentation for Unicode 16.0, with
`isWordLike`, `nextWordEnd` and `previousWordStart` for an editor's Ctrl+Left and Ctrl+Right. Its
Word_Break table is generated from the pinned `WordBreakProperty.txt`, and Unicode's
`WordBreakTest.txt` passes on dotnet, the JVM and native next to the bidi and line break suites (D412).
