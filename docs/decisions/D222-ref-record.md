# D222 - `ref record`: an explicit marker for records with identity

**Status:** accepted, warning phase implemented (#7955); the error phase follows a seed refresh

Realises the declaration form D157 item 5 left open. Resolves #7955.

## Decision

1. **Spelling.** `ref record Name { ... }`, with the visibility first (`pub ref record`).
   `ref` is a contextual keyword recognised only as an item head directly before
   `record` (like `foreign`, D188); it stays an ordinary identifier everywhere else.
   `RecordDecl` carries `isRef`. `mutable record` was rejected: it names the fields'
   writability, while the property that matters to a reader is that the value is shared.
2. **Meaning.** None beyond D157: a record with a `var` field has identity on every
   backend and a record without one is a value. `ref` states the first case. `ref` on a
   record with no `var` field is accepted and changes nothing (the record stays a value),
   so a type can be marked before its first `var` field lands.
3. **Diagnostic.** A `var` field in a record not marked `ref` is warning **W0031**, which
   names the record and the fix. It becomes an error in a later release, once the
   compiler and the seed-compiled stdlib packages are migrated (below).
4. **Scope.** `exposed record` may not have `var` fields, and an `opaque type` is not a
   record, so neither takes the marker. `Plain`, `.copy()` and `@derive(Equals)` behave
   the same on marked and unmarked records.
5. **Synthesised records.** A protected type lowers to a record with `var` fields; the
   lowering sets `isRef`. `@stubbable` stubs have no `var` field of their own (their
   counter is a `ref record`'s field), so they need nothing.
6. **Migration.** Every record with a `var` field outside the seed-compiled sources is
   marked in this change: ecosystem libraries, examples, tests, compiler self-tests, the
   stdlib's `seed: current` packages and its non-dotnet kernels. The sources the stage-0
   seed release compiles (the compiler's own non-test files and the stdlib packages in
   `lyric.full.toml` without `seed: current`) cannot use syntax the seed does not parse,
   so they keep the plain spelling and draw W0031 until a seed refresh. That refresh then
   migrates them and promotes W0031 to an error in one change.

## Consequences

Contract metadata writes a record that has a `var` field as `pub ref record`, so a restored package
synthesises the marker and a consumer is not warned about it.

The formatter prints `ref record`, `lyric doc` shows it, and every AST pass that rebuilds
a `RecordDecl` carries `isRef`. W0031 is non-fatal, so a seed-compiled source keeping the
plain spelling builds as before.
