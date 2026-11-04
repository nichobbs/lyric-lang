# The checker reports an unsolved type argument as the error T0224 (docs/70 phase 3a, #8760)

D339, step two.

- `reportUnsolvedTypeArgs` reports T0224 instead of W0035. Mono keeps its T0224
  as a backstop for call shapes the checker's table does not record.
- `core_tests.l` migrated: the first `Result` of `andThenResult` is annotated.
- Census over every manifest (dotnet and JVM) and the stdlib tests with the
  second-round rule (#8779): the 3 sites in `core_tests.l` were real; `lyric-ui`
  and the other hits were indeterminate calls or a single-file run without
  `LYRIC_LOAD_COMPILER=1`, not source defects.
