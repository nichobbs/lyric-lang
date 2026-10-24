# lyric test: preserved line numbers and @cfg-aware --list (#7540)

`Lyric.TestSynth` no longer emits a leading newline before each synthesised
`func __lyric_test_<i>`, so a diagnostic after N `test` items is reported at
its real source line instead of N lines late. `property` items still expand to
multi-line drivers, so lines after a property can drift; that remains open on
#7540.

`lyric test --list` now goes through `TestSynth.listEntriesFor`, which uses
`isItemCfgGatedOut` with the same active/declared feature set the runner
synthesises with, so inactive `@cfg` items are not listed. `listEntries` keeps
its signature and delegates with empty feature sets.

Tests: `test_synth_self_test.l` cases "rewrite preserves line numbers across
earlier tests (#7540)" (seen failing with expected=13 actual=16 before the fix)
and "listEntriesFor honours @cfg (#7540)".

Docs: `docs/01-language-reference.md` (lyric test paragraph) and
`book/chapters/appendix-b-quick-reference.md`.
