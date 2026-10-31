# Pipeline: remove duplicate `files` field in two SourceFile constructions

The release `Publish` run for a8989ce failed in every `Build stage 2` step with
`Lyric.Pipeline: error[T0104] field 'files' is given more than once`. Commit
a8989ce added a trailing `files = ...` to the `SourceFile(...)` constructions in
`specMayRender` and `lowerShowSpec`, which already passed `files` first. Both
trailing duplicates are removed; the remaining `files` argument is unchanged.
