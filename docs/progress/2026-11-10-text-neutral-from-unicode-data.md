# lyric-text: characters that keep the previous font come from Unicode.Data (2026-11-10)

`isNeutralCp` was a hand-written range list, so most combining marks (Hebrew points, Indic vowel signs,
Thai and Khmer marks, ideographic variation selectors) could be shaped in a run of their own and drawn on a
dotted circle when only a fallback font had them (#8827). It now takes the Mn/Mc flag and the CM, ZWJ, GL,
WJ and ZW line-break classes from `Unicode.Data.lineBreakValueOf`, plus controls, space, U+00A0 and the
variation selectors. The `shape` example checks a mark that only the fallback font has (U+3099) and Hebrew
points stay with their base.
