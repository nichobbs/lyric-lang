# Registry, git and single-file enforcement of `[package] targets` (#9031, D602)

`lyric publish` tags packages with `lyric-target-<t>`; restored registry
(nuspec tags) and git (manifest) dependencies are checked with F0055 on
restore, build, test and run; `lyric search --target` filters; single-file
builds with a manifest apply F0054. Contract metadata deliberately does not
carry the field (D602). Language reference, docs/39 and the book updated.
