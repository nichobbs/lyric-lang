# `[package] targets` and F0053-F0055 (#9030, D601)

`Lyric.Manifest` parses `[package] targets` into `PackageSection.targets`
(F0053 on a bad value). `lyric build`, `lyric test` and `lyric run` refuse a
manifest that excludes the requested `--target` (F0054) and a path or
workspace dependency, transitively, that does (F0055), through
`targetSupportError` in `cli/workspace_builder.l`. Registry and git
dependencies, the nuspec tag, contract metadata and `lyric search` filtering
remain open and are tracked in the follow-up issue. Language reference
(manifest section) and book chapter 20 updated.
