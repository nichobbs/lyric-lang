# D381 - An unsolved union-case construction is the error T0224 (docs/70 phase 3a, #8760)

**Status:** shipped. Step two of D353: the warning W0038 becomes an error.

## Context

D353 reported a union-case construction whose type argument nothing fixes as the
warning W0038, and D380 taught the checker the contexts that already fix one.
The CI logs of #8830 (run 42001044091, all 53 jobs) were the census: three sites
remained, all in `lyric-game/platform/src/run.l`.

## Decision

1. The report is the error **T0224**, the code of an unsolved type argument of a
   generic call (D335, D339), with the construction's wording: "cannot infer
   type argument(s) 'E' of 'Ok' from the construction's arguments or its
   expected type; give it an expected type (an annotated binding, a parameter
   or a declared result)". W0038 is retired.
2. `noteCallExpected` reaches the value of a branch of an `if`/`match`/block, so
   the tail of a lambda body that is a `match` (`renderRecording`'s two sites)
   takes the declared result as its expected type.
3. The third site, `val pixels = match drawn { case Ok(_) -> Gpu.readPixels(...); case Err(m) -> Err(error = m) }`,
   was fixed only by the type of a qualified extern call; it is annotated
   (`Result[buffer[Byte], String]`) and no longer depends on it.

Deleting Mono's `ctorFill` and `importedFill` follows (D382).
