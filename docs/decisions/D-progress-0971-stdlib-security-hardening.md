# D-progress-971 — Stdlib security hardening; invariant checkers for stdlib types

**Status:** shipped

Second batch of the contract-hardening epic #7221: the stdlib half of the
security band, plus two compiler fixes the batch surfaced.

## Compiler

### Invariant checkers for stdlib sources (#7222)

D-progress-958 synthesizes `__lyric_checked_<Type>` in `pipeExpandAndRewrite`.
The MSIL and JVM bridges' stdlib collection and the native bundled-stdlib
path parse stdlib sources without that stage, so a stdlib type gaining an
`invariant:` (here `Std.Log.LogField`) left user constructions pointing at a
checker that was never declared. All three paths now run
`synthesizeInvariantCheckers` over each stdlib file. Synthesis is idempotent
(a type whose checker already exists is skipped), so a file that reaches it
twice still declares one checker per type. This closes D-progress-958's
"native bundled-stdlib path" exclusion.

### `Bug.message` is never null on `--target jvm`

`b.message` lowered to `Throwable.getMessage()`, which is null for many JDK
exceptions (`ConnectException` among them). The null flowed into a Lyric
`String` and crashed the next method call on it. A null message now falls
back to `toString()` (the exception's class name), the analogue of .NET's
never-null `Exception.Message`. Language reference §8.2 states the
guarantee.

## Stdlib

- **`Std.ProcessArgs` (#7234).** Each process kernel quoted and split
  arguments its own way, so an empty argument, an embedded quote or a
  backslash run reached the child altered. The JVM list path also re-split
  an already-split list. `argvQuote`/`argvJoin`/`argvSplit` now implement the
  CommandLineToArgvW convention once, with `argvSplit(argvJoin(xs)) == xs`.
  The .NET kernel passes the joined string to `ProcessStartInfo.Arguments`.
  The JVM and native kernels split it back, and the JVM list seam passes the
  list straight through.
- **`Std.Path` / `Std.File` (#7246).**
  - `join` does not confine its result, and its documentation now says so.
    The new `joinWithin(base, rel)` returns `Err` for an absolute,
    drive-qualified or `..`-bearing component.
  - Recursive deletes refuse a filesystem root.
  - `listFilesRecursive` does not descend into directory symlinks or
    junctions (`hostIsDirSymlink` on all three kernels) and stops at depth
    256.
- **`Std.Log` (#7244).** A CR/LF in a message forged a new log line
  (CWE-117). Messages now escape line breaks and control characters
  (`\n`, `\r`, `\t`, `\uXXXX`), and `LogField` has the invariant
  `key.length > 0`.
- **HTTP/2 (#7231).**
  - Decoded request headers and trailers are validated per RFC 9113 §8.2:
    field-name and field-value syntax, pseudo-header placement, and
    connection-specific fields.
  - The HPACK-bomb fix (the header-list limit enforced on the decoded size)
    landed on `main` independently in #7265. This branch adds a regression
    test that expands a 5 KB block to about 4 MB and checks it stops at the
    budget.
- **`Std.Http.retry` (#7237).**
  - A host request message can only be sent once, so every attempt after
    the first failed with "already sent" and `backoffMs` was ignored.
    `HttpRequest` now keeps the recipe that built it (method, headers,
    body). `retry` rebuilds the host request per attempt and waits
    `backoffMs` between attempts.
  - Its arguments are bounded by contract (`maxAttempts` 1..100, and
    `backoffMs` non-negative and within `Int`).

## Verification

- `process_args_tests.l` is new, and `path_tests`, `file_tests`,
  `log_tests`, `http_hpack_tests`, `http_h2conn_tests` and
  `http_async_tests` all gained cases. They pass on `--target dotnet` and
  `--target jvm`.
- The `http_async_tests.l` retry case also pins the JVM `Bug.message` fix:
  before it, the case crashed on a null `String`.
