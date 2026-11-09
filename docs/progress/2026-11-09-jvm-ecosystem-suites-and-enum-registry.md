# JVM ecosystem suites: enum type-name collision fixed, six suites wired into CI

Re-ran the JVM erased-generics family and the B'-mode aspect failures against
`main` (`make lyric`, then each library's `lyric test --target jvm`). The
reported bugs are already fixed on `main`: `InProcessJobScheduler` (#5456),
`InProcessSessionStore` (#5451), the `slice[Record]`/`slice[Byte]` element
cases (#5439, #5453), the interface call on a list element (#5444) and the
B'-mode `__LyricBModeCallContext` registration (#4600) all pass, so
lyric-jobs, lyric-session, lyric-auth, lyric-aws-xray and lyric-ws had only
stale README text and no CI coverage.

One real compiler bug turned up: lyric-logging failed four tests on the JVM
with `NoClassDefFoundError: Std/Log/LogLevel`. The JVM type-scoped enum
registry key (`enumty:<Enum>.<Case>`) was bundle-global and first-wins, and
`Jvm.Bridge.importAwareRegistry` skipped any key containing a `.`, so it could
never be re-pointed per file. A package importing `Std.Logging` read
`LogLevel.Info` as the stdlib's `Std.Log.LogLevel`. Fixed in
`lyric-compiler/jvm/codegen/06_items.l` (register the `<owner>/`-qualified
form) and `lyric-compiler/jvm/bridge.l` (let the overlay re-point `enumty:`
keys, and honour selective imports of the enum). Pinned by the
`lyric-compiler/fixtures/enum_type_name_collision` project, run on both targets
by `scripts/ci/test-multi-package-examples.sh`; it fails on the old compiler.

`scripts/ci/jvm-ecosystem-suites.sh` now runs jobs, session, auth, aws-xray,
ws and logging (ws with `--suite`, leaving out the dotnet-only
`Ws.WsDotnetE2eTests`). lyric-otel stays out: its JVM OTLP transport is not
implemented and its transport test binds the dotnet kernel (#8953). The
READMEs of the touched libraries and their rows in the book's "Library
availability matrix" drop the stale "broken" text.
