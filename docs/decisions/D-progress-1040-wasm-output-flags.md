# D-progress-1040 — `--wit-out` and `--js-bindings`

**Status:** shipped (W4 follow-up, tracked in #8117 item 5 and #8118 item 2)

## Decision

1. **`--wit-out <path>`** writes the generated WIT to `<path>` (creating its directory)
   instead of beside the component. The WIT is not also written to the default place.
2. **`--js-bindings`** runs `jco transpile` on the finished component into
   `<stem>-js/` (`$JCO`, else `jco` on `PATH`), so a consumer gets runnable JavaScript
   from one command.
3. **Host imports are mapped, not left to the caller.** Every host import becomes a
   `--map lyric:<package>/<interface>@<version>=<target>`: an `npm:<package>` import
   maps to the package itself (resolved from the bindings directory's
   `node_modules`); any other module `m` maps to `../m.js`, a file the caller writes
   beside the component. The second rule is a convention, chosen because the
   bindings directory is a sibling of the component and the alternative (no
   mapping) leaves `jco` generating imports of a WIT interface nothing satisfies.
4. **Scope.** Both flags apply to `--shape component` only (`N0021`); a `;` in the
   `--wit-out` path is rejected because the shape argument the CLI passes the native
   bridge (`component;wit=<path>;js`) separates its options with it. A missing or
   failing `jco` is `N0022`; the component itself is still produced.
5. **Plumbing** rides the existing shape argument, parsed once in `parseShapeSpec`,
   for the same reason as D-progress-1035 (no signature changes across the
   bridge, T0042).
