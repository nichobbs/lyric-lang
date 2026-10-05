# D-progress-1045: `lyric publish --wasm` packs a wasm32 build as an NPM tarball

**Status:** shipped (W4 follow-up, #8117 item 6; docs/35 section 8.1)

## Decision

1. `lyric publish --wasm` packs an existing `--shape module` or `--shape component` build as
   `<name>-<version>.tgz` (the layout `npm publish` accepts: a `package/` root with a
   `package.json`). It does not build, and it does not push: publishing is `npm publish <tgz>`.
2. The wasm file is `bin/<[project] output_assembly, else package name>.wasm`, or `--wasm-file`.
3. The shape comes from the files beside the `.wasm`: a `<stem>.wit` means component, a
   `<stem>.js` with `<stem>.d.ts` means module. Both present, or neither, is an error (a stale
   sidecar must not decide the shape).
4. Module bundles carry the `.wasm`, glue and declarations (`main` is the glue, `types` the
   declarations). Component bundles carry the `.wasm` and WIT, plus the `jco` output in
   `<stem>-js/` when `--js-bindings` produced it (`main`/`types` then point into it); a
   component bundle without bindings is valid for consumers who run `jco` themselves.
5. The NPM name is the package name lowercased with characters outside `a-z 0-9 . - _` turned
   into `-`; a name NPM rejects is an error. `[npm]` rows become `dependencies`, so the
   consumer installs what the `npm:` host imports reach. `description`, `license` and
   `repository` come from `[package]`. `--package-version` and `-o` apply as for NuGet.
6. The tarball is produced with the system `tar`; there is no pure-Lyric tar writer.

## Not covered

Pushing to a registry, signing, and the lock-file checksum (docs/39) stay with NPM tooling.
