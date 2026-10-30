# lyric-db parameter-count check, lint rule L008, Windows static-file paths

Closes the remaining open items of #8520 and #8584 and the native follow-up
of #7249.

- `SqlText` stores its placeholder count (`Db.sqlPlaceholderCount`, one more
  than the highest `@p<N>` outside a string literal). `query`/`execute` on
  `NativeConnection` and `NativeTransaction` return `Err` with code
  `PARAM_COUNT_MISMATCH` (`Db.sqlParamsError`) before the driver runs.
- `lyric lint` rule `L008` flags a `sql(...)` / `Db.sql(...)` call whose
  argument is not a string literal or a `+` chain of literals
  (`Lyric.Lint` gained an expression/statement walker, `sqlLintItem`).
- lyric-web static files on `--target native`: separator-aware path helpers
  (`nativePathPrefix`, `nativePathSegments`, `joinNativePath`,
  `staticAppendLexically`) understand `/` and `\`, drive and UNC roots;
  `staticPathWithinRoot` compares case-insensitively with normalised
  separators on Windows; `staticRequestPathAllowed` rejects `\` on every
  target and `:` on Windows. The path logic is pure and unit-tested on Linux
  with `windows = true`.

Not done here: the Windows CI job run of the static-file cases (direct hit,
`..`, junction) and the dotnet/JVM-on-Windows resolvers; see the PR body.
