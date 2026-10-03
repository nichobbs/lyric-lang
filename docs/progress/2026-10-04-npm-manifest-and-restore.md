# NPM dependencies: `[npm]` table and restore (docs/35 W5, slice 1)

`lyric.toml` can declare NPM packages and `lyric restore` installs them
(D-progress-1036).

- `[npm]` / `[npm.options]` parsed and validated in `Lyric.Manifest`, including the
  package-identifier mapping; colliding identifiers are rejected (Q-JS-004).
- `lyric restore` installs into `target/npm/node_modules/` with install scripts off
  (`B0060`) and scaffolds `_extern_npm/` shims it never overwrites (`B0063`).
- Wrongly typed `[wasm]` values are now errors (review suggestion on the `[wasm]` table).
- Tests: manifest parsing and rejections; the restore helpers; an end-to-end restore
  of a local `file:` package through real `npm`, covering scaffold, keep, `B0063` and
  `B0060`.
