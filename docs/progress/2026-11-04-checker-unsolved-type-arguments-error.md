# The checker reports an unsolved type argument as the error T0224 (docs/70 phase 3a, #8760)

D339, step two.

- `reportUnsolvedTypeArgs` reports T0224 instead of W0035. Mono keeps its T0224
  as a backstop for call shapes the checker's table does not record.
- A name, member or index argument with an open type does not make the call
  unsolved (an erased loop variable of a generic body, `lyric-ui`).
- `core_tests.l` migrated: the first `Result` of `andThenResult` is annotated.
- Census over every manifest (dotnet and JVM) and the stdlib tests: 3 sites in
  `core_tests.l` and 3 in `lyric-ui`; the other hits were a single-file run
  without `LYRIC_LOAD_COMPILER=1`, not source defects.
