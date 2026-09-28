# JVM console I/O is UTF-8 regardless of process locale (#7513)

On `--target jvm`, `System.out`/`System.err` encode and `System.in` decodes
through the JVM's platform-default charset unless told otherwise. Under a
C/POSIX locale (`LC_ALL=C`/`LANG=C`, common in containers and CI runners),
that default charset is ASCII, so every non-ASCII byte written through
`println`/`print`/`Std.Console.error` came back as `?`, and every
non-ASCII character read through `readLine()` was mangled. `--target
dotnet` never had this problem — .NET's console writers are UTF-8
unconditionally.

## Fix

- `lyric-compiler/jvm/codegen/06_items.l`: `emitConsoleUtf8Setup`
  (`emitSetUtf8Stream` for `out`/`err`) emits
  `System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.out),
  true, StandardCharsets.UTF_8))` (and the `err`/`setErr` analog) as the
  very first instructions of the synthesized JVM
  `public static void main(String[])` wrapper (`codegenPackageWithSigsSeeded`),
  before the argv-stash bookkeeping and before any user code runs. This is
  the sole runnable entry point per JVM bundle (`hasMain`'s own doc
  comment), so rebinding the two static fields once, there, fixes every
  text-output path with no change to `println`/`print`'s own bytecode
  lowering or to `Std.ConsoleHost`'s codegen: both read the `System.out`/
  `err` static field at the point they run, and `hostConsoleWriteBytes`'s
  raw-byte writes stay on the exact same `PrintStream` instance as the
  text writers, so interleaved text and byte output keep wire order (the
  two already shared one field; this only changes what the field points
  at).
- `lyric-stdlib/std/_kernel_jvm/console_host.l`: `stdinReader` now
  constructs its `InputStreamReader` with an explicit
  `StandardCharsets.UTF_8` argument instead of the platform-default
  constructor, so `hostConsoleRead`/`hostConsoleReadLine` decode stdin as
  UTF-8 regardless of locale too.
- `PrintStream(OutputStream, boolean, Charset)` has existed since JDK 10;
  the project's JVM baseline is 21 (docs/18-jvm-emission.md), so no
  version gate is needed.

## Entry-point coverage audit

Every JVM-runnable entry point goes through `hasMain`'s synthesized
`main` wrapper, so all of them pick up the UTF-8 rebind automatically:

- `lyric run` / `lyric build --target jvm` on a user `func main(): ...` —
  the direct case `emitConsoleUtf8Setup` was added for.
- `lyric test --target jvm` — `Lyric.TestSynth` (`test_synth.l`) rewrites
  a `@test_module` file into a synthesized `func main(): Int` that runs
  each test and prints TAP output; that synthesized `main` is compiled
  through the same `codegenPackageWithSigsSeeded` path, so it gets the
  same wrapper.
- `lyric-lambda`'s `jvm` feature (JVM custom runtime, provided.al2/al2023)
  — its entry point is a consumer-authored `func main(): Int` running the
  Runtime API long-polling loop (see `lyric-lambda/README.md`'s worked
  examples), not a class loaded by an external harness, so it is the same
  `hasMain` case.

One JVM entry-point family does **not** go through this wrapper, and is
called out here rather than silently left uncovered:

- `Jvm.TestEngine` (`lyric-compiler/jvm/test_engine.l`, docs/32
  §"JUnit runner sketch", B126): builds a `LyricTest` JUnit 5 annotation
  class and a test-host `ClassFile` whose methods are stub bodies. The
  actual `LyricTestEngine` (the JUnit 5 `TestEngine` SPI implementation
  that would let an external `java -jar junit-platform-console-standalone
  ...` (or IDE test runner) load and invoke these methods directly,
  without ever calling a synthesized `main`) is explicitly deferred to
  Stage B127+ and does not exist yet — nothing currently runs Lyric test
  methods that way. When B127 ships a real `LyricTestEngine`, its
  JUnit-invoked test methods will need `System.out`/`System.err` rebound
  independently (JUnit's own launcher process owns `main`, not
  Lyric-generated code), most likely once, in a static initializer or
  `TestEngine.discover`/`execute` hook shared by every test class in the
  run, mirroring what `emitConsoleUtf8Setup` does for the ordinary
  `main` path. Tracked in #7686.

## Tests

- `lyric-stdlib/tests/console_locale_c_tests.l` (new): `func main` program
  that `println`s, `print`s, and `Std.Console.error`s the same non-ASCII
  payload (café/😀/中文), then echoes back one `readLine()`.
- `scripts/ci/console-locale-c-test.sh` (new): runs the program above
  under `LC_ALL=C LANG=C`, feeding a non-ASCII stdin line, and byte-diffs
  (`cmp`, never a shell string comparison) the raw stdout and stderr
  against the exact expected UTF-8 bytes. Deliberately does not rely on
  `-Dfile.encoding`/`-Dstdout.encoding` JVM flags — verified to pass with
  neither set. Wired into `ci.yml`'s existing "Std.Process suite on JVM"
  step (no new step — the workflow is near its size ceiling, see
  `scripts/ci/check-workflow-size.sh`).
- `scripts/ci/jsonrpc-content-length-locale-c-test.sh` (new): builds a
  throwaway consumer program against `lyric-jsonrpc` (a local `path`
  dependency) that reads one `JsonRpc.Stdio.ContentLengthTransport`
  message from stdin and echoes it back with the same framing; run under
  `LC_ALL=C LANG=C` with a non-ASCII JSON payload, byte-diffed against the
  expected wire bytes. This is a confirmatory regression test, not a
  bug-for-bug fix target: `ContentLengthTransport`'s send/receive already
  go through byte-level primitives (`Std.Console.writeStdoutBytes`/the raw
  `StdinReader`, hardened for UTF-8 byte-exactness in #7510), so it was
  already locale-independent before this change; the test pins that it
  stays that way now that `System.out`/`err`/`in` are being rebound
  underneath it. Also wired into the same ci.yml step.
- Ran locally (this session, `--target jvm` unless noted): both new
  scripts on dotnet and jvm (all pass);
  `bash scripts/ci/compiler-self-tests-batch.sh` (0 `not ok`);
  `bash scripts/ci/jvm-generics-self-tests-batch.sh` (0 `not ok`);
  `bash scripts/ci/jvm-ecosystem-suites.sh` (includes `lyric-jsonrpc` and
  `lyric-mcp` `--target jvm`); every ci.yml `self-test.sh --target jvm`
  self-test; `bash scripts/audit-axioms.sh` (no drift: `.NET=31, JVM=24`
  unchanged — the two new externs, `JCharset`/`JStandardCharsets`, sit
  inside `console_host.l`'s existing file-level `@axiom`); `bash
  scripts/ci/check-workflow-size.sh` (496166 bytes, under the 500000
  soft ceiling).

## Docs

- `docs/10-stdlib-plan.md`'s `Std.Console` row now documents the JVM
  locale-independence guarantee and what backs it.
- `docs/18-jvm-emission.md` was checked and does not describe the
  synthesized `main` wrapper's console setup at all (it documents type
  mapping, ARC/records/generics/async lowering, and FFI — not console
  I/O), so it needed no edit.

## Out of scope

- `Jvm.TestEngine`'s deferred `LyricTestEngine` (see the entry-point
  audit above) — no runnable entry point exists yet to fix.
- A `lyric-lambda`-specific end-to-end test — its JVM `main` path already
  shares the exact `hasMain` codegen this fix covers, and `lyric-lambda`'s
  own test suite is unrelated to console locale; adding one would be
  redundant with `console_locale_c_tests.l`.
