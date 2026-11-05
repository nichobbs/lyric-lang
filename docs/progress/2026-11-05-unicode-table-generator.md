# A Lyric generator for Unicode.Data's tables (#8497)

`lyric-unicode/tools/generate` reads the seven Unicode 15.1 Character Database files now vendored and
pinned by SHA-256 in `lyric-unicode/ucd/`, and rewrites the four table lines of
`lyric-unicode/src/unicode_data.l` (D373). It reproduces the ICU 74 tables of D216 byte for byte, so
the tables no longer need ICU, and CI runs it with `--check` in the `unicode` ecosystem-tests entry.
