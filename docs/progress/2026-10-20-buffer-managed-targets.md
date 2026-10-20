# `buffer[T]` on dotnet and the JVM (docs/67 G2, #7941, D185)

`buffer[T]` is now a built-in type with value semantics on `--target dotnet`
and `--target jvm`.

- Checker: `buffer[T]` resolves like `Task[T]` (reserved type id), with the
  element required to be `Plain` (T0173). Indexing, element writes (T0157),
  `.length`, `for`, the receiver rule (T0174) and the member rule (T0113) are
  checked; a record holding a buffer cannot derive equality or ordering
  (T0159). The array place and copy rules apply unchanged, so a buffer is
  copied when stored into or read out of a writable place.
- Lowering: the array site maps carry buffer sites (length `-1`), and
  `lowerArrays` reads the receiver's `count`: the bounds check
  (`index i out of range for buffer of length n`), `.length`, `for`, and the
  copy. A buffer is a `List[T]` after lowering, copied eagerly; the lazy form
  is #8389.
- `Std.Buffer`: `filled`, `fromSlice`, `view`, `toSlice`, `grow`, `truncate`,
  in Lyric, over two identity members only that package may use. Marked
  `# seed: current` in `lyric.full.toml`.
- Mono: a generic from another package whose signature holds a buffer is
  checked again per specialisation, so its buffer operations are lowered (they
  reached the JVM backend unlowered before).
- Tests: `buffer_self_test.l` (10) and `buffer_panic_self_test.l` (5) on
  dotnet and the JVM, six checker cases in `typechecker_self_test.l`; both new
  files are in the dotnet and JVM CI batches.

Open under #7941: native lowering, `withPointer`/`withMutPointer`, the
verifier model, the lint rule, the lazy managed form (#8389).
