# D-progress-890 — #6268 closed: manifest-declared `[build] shape` on `--target native` raises `F0043` instead of silent override

**Status:** shipped


**Context.** The shape axis's CLI path already raised the hard `F0043`
("shape invalid for target") for `--target native --shape portable`, but a
manifest's `[build] shape = "portable"` on a native project was silently
upgraded to `"aot"` instead — the old `defaultShapeForTarget` pre-defaulted
`Option[BuildShape]` to `Aot` for `Native` before the manifest's own value
was ever consulted, so `resolveBuildAxesFromManifest` never saw the
manifest's real declaration to check it against.

**Fix.** `BuildSection` gained two new fields, `shapeDeclared`/
`profileDeclared: Bool` (`manifest.l`), set when the `[build]` table's
`shape`/`profile` keys are present in the source TOML — `shape`/`profile`
alone cannot distinguish "the manifest said portable" from "the manifest
said nothing," since both parse to the same default string. `cli_build.l`'s
`defaultShapeForTarget` was replaced by `resolveShapeAxis(cliShape, section,
target)`, called from both `resolveBuildAxes` (CLI-only path) and
`resolveBuildAxesFromManifest` (CLI + manifest path) — a single shared
resolution: an explicit CLI `--shape` wins outright (existing conflict
diagnostics still apply); otherwise a manifest-declared shape
(`shapeDeclared`) is checked against the target the same way a CLI flag
would be, raising `F0043` if it's non-`aot` on `--target native`; only when
NEITHER the CLI nor the manifest declares anything does the native default
(`aot`) apply.

**Verification.** New `cli_build_self_test.l` cases (6) and
`manifest_self_test.l` cases (3, asserting `shapeDeclared`/`profileDeclared`
directly) pin: a manifest-declared `shape = "portable"` on native → `F0043`;
a manifest-declared `shape = "aot"` on native → accepted; no `[build]`
table at all on native → defaults to `aot` unchanged; a CLI `--shape`
conflicting with a manifest value still resolves CLI-first exactly as
before.

**Related:** #6268, `docs/01-language-reference.md` §3.6 (`[build]` table),
`docs/63-build-profiles-and-debugger.md` (the shape axis, Q-BP-003 nearby),
D-progress-887 (the sibling #6263 fix to the same axis, landed in the same
PR).
