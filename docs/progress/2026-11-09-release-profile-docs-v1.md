# `--release` profile: docs reconciled with the shipped behaviour (#6263, D555)

#6263 was still open although overflow (D163), contract elision (D297, D307)
and the native `-O` default (D-progress-913) had shipped. This entry settles the
issue for v1.0 (exit criterion 5): the profile table is now in docs/01 section
13, the book and appendix B no longer claim optimisation or debug-info
stripping that does not happen, docs/01 section 6 no longer says `--release`
keeps every contract, the docs/05 performance criterion is restated, and the
managed-target optimisation gap is tracked as #8946. No compiler code changed
and no new test was added; the behaviours are covered by the existing
`scripts/ci/release-contracts-e2e.sh` and the D163 self-tests (not re-run in
this change). See D555.

## v1.0 release notes

`docs/release-notes/v1.0.md` is the draft for exit criterion 9 (D548, D549).
`.github/workflows/publish.yml` now uses `docs/release-notes/v<X.Y.Z>.md` or
`v<X.Y>.md` as the draft release body when present (`docs/22` section 5.1.4).
The notes mark what could not be verified (#8927, #8928, #8940 status at the
tag, the lyric-jobs JVM README against closed #5456).
