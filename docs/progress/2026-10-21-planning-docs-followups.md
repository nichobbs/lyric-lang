# Planning docs follow-ups: stale epics, CLAUDE.md, docs/44 rewrite (2026-10-21)

- Issue tracker: closed #4607 (native backend umbrella; its N2-N9 scope shipped) and #7944
  (docs/67 G5; the compute, triangle and quad golden-image examples pass in CI). The one
  unshipped slice of #4607, the arm64 and macOS native CI legs, is now #8419. Left open on
  purpose because their exit criteria are unmet: #7945, #7941, #8118, #8149. `docs/12` previously
  listed #7945, #7941, #8118 and #8149 as stale; that was wrong and is corrected.
- `CLAUDE.md`: removed the deleted F# projects (`bootstrap/src/Lyric.Cli/`, `Lyric.Emitter/`,
  `bootstrap/tests/`, the `SelfHosted*Bridge.fs` shims, `Manifest.fs`, `MavenShim.fs`); the
  test commands are now `make test-emitter` and `make test-native`; the native work-item count
  is 48 base items plus N8 and N9.
- `docs/44`: sections 1-3 rewritten from the 2026-05 audit prose to the current state, with a
  table of each original headline problem and its outcome. Sections 4 and 5 stay as the audit
  record.
