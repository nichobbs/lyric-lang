# `lyric publish --wasm`: NPM tarball for wasm32 builds (docs/35 W4 follow-up)

`lyric publish --wasm [--wasm-file <path>] [-o <dir>] [--package-version <ver>]` packs the built
module or component (with glue, declarations, WIT, jco bindings and `[npm]` dependencies) as
`<name>-<version>.tgz` (D-progress-1045). Tests: `package.json` rendering for both shapes,
with and without bindings and `[npm]` rows, and NPM name sanitising
(`cli_publish_self_test.l`). Open in #8117: cross-package types, records across host
imports, `fetch`-backed `Std.Http`.
