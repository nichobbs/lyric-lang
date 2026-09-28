# Native codegen: `coerceTo` int narrowing + contained `N0007` diagnostic (#7452)

`lyric run --target native lyric-stdlib/tests/hash_tests.l` failed during
LLVM codegen with an untyped, unhandled-exception panic: `Lyric.LlvmCodegen:
cannot pass a 'i32' where 'i8' is expected (insert an explicit conversion)`.

## Root cause

`Lyric.LlvmCodegen.coerceTo` (`lyric-compiler/lyric/llvm_codegen.l`) already
widened a bare `i32` literal to `i64` at a declared-`Long` boundary, but had
no narrowing path at all: a non-literal integer value (e.g. the result of
arithmetic) flowing into a declared-narrower slot (`Byte`) hit its terminal
`panic`. `hash_tests.l`'s `assertFileDigestMatchesBytes` hits this via
`bytes.add((i * 31 + 7) % 256)` on a `List[Byte]`.

This type-checks on every target because `List[T]`/`Map[K, V]` are `extern
type` aliases over the BCL generics (`lyric-stdlib/std/_kernel/
collections_host.l`) with no Lyric-declared method signatures at all:
`Lyric.TypeChecker`'s `builtinMember` only special-cases `.toArray()`/
`.count` for `List`, so a `.add(...)` call's callee type stays `TyError`,
`maybeUnknownMemberDiag` declines to diagnose it (`symTableIsMemberComplete`
is false for an extern type), and the call's arguments are never checked
against any parameter type at all — not even for arity. MSIL narrows the
mismatch implicitly (the CLR evaluation stack has no sub-`int32` width, so
`List<byte>.Add` accepts the raw `int32` value), and JVM emits `i2b`; LLVM
IR has no such implicit narrowing, so native needs an explicit `trunc`.

## Fix

1. `coerceTo` gained a narrowing branch (`i64`→`i32`, `i64`→`i8`, `i32`→`i8`)
   that emits `NTrunc`, mirroring the `trunc` `.toByte()` already emits
   explicitly.
2. The function's terminal "cannot pass X where Y is expected" panic — the
   one genuinely-incompatible (non-numeric) mismatches still hit — is now a
   real diagnostic instead of an untyped panic: `coerceTo` (and
   `coerceUnlessDiverged`) take an optional `atSpan: Option[Span]`, threaded
   from `lowerExprExpecting` (which has the argument/binop/branch `Expr`'s
   real span) at its five call sites. When present, the panic message embeds
   `error[N0007] line:col: …`, matching the existing `error[T0119] line:col:
   …` shape `Lyric.Emitter.parsePanicSpan` already recovers a real span from.
3. `Lyric.Emitter.emitNativeInProcess`/`emitNativeProject` (`emitter.l`)
   previously called straight into `Lyric.LlvmBridge` with **no**
   `try`/`catch` at all — unlike `emitMsilInProcess`/`emitJvmInProcess`,
   which have wrapped their bridge calls since #6449/#6459 and turn a panic
   into a structured `Diagnostic` via `msilBridgePanicDiagnostic`/
   `jvmBridgePanicDiagnostic`. This was the real reason the panic reached
   the CLI as a raw, unhandled `System.Exception` with a full host stack
   trace: there was no boundary to catch it at. Added the native twin,
   `nativeBridgePanicDiagnostic`, and wrapped both `emitNativeInProcess` and
   `emitNativeProject` in `try { … } catch Bug as b { … }`, exactly mirroring
   the MSIL/JVM pattern. A spanned `N0007` message prints and keeps its
   code; any other uncoded native codegen panic (this closes the gap for
   every native codegen panic, not just `coerceTo`'s) wraps under the same
   `N0007` code with a synthetic point span, matching `T0120`/`J008`.

New diagnostic: **`N0007`** — see `docs/01-language-reference.md`'s
`--target native` section and `book/chapters/appendix-b-quick-reference.md`'s
N-series table.

## Tests

- `lyric-compiler/lyric/llvm_codegen_self_test.l`: "List[Byte].add narrows a
  non-literal Int argument, matching MSIL/JVM (#7452)" — compiles and runs a
  `List[Byte].add((i * 31 + 7) % 256)` loop, asserts the truncated element
  round-trips the expected low-8-bits value.
- `lyric-compiler/lyric/emitter_project_self_test.l`: "emit(target = Native)
  contains a coerceTo type-mismatch Bug as an EmitResult failure, not a
  thrown exception (#7452)" — `xs.add("hello")` against a `List[Int]` (a
  genuinely incompatible, non-numeric mismatch no narrowing can rescue;
  constructible because the type checker performs zero argument validation
  for this extern-generic-method-call shape) asserts `Emitter.emit` never
  throws, and that the returned `EmitResult.diagnostics` carries an `N0007`
  entry whose span points at the real `"hello"` literal (line 8, column 10).

Both verified passing via `make self-test NAME=llvm_codegen` (50/50) and
`make self-test NAME=emitter_project` (97/97).

## Out of scope: `hash_tests.l` still cannot build for `--target native`

Fixing the `coerceTo` narrowing bug was **not** enough to make
`lyric-stdlib/tests/hash_tests.l` itself pass under `--target native`, so it
was **not** wired into `scripts/ci/native-target-smoke-test.sh`. Two
separate, pre-existing, unrelated gaps surfaced once the narrowing panic
stopped masking them:

1. **`Std.Hash` has no native kernel at all.** There is no
   `lyric-stdlib/std/_kernel_native/hash_host.l` (unlike the `_kernel_jvm`
   twin) — every one of `hostSha1Bytes`/`hostSha256Bytes`/`hostSha512Bytes`
   fails to resolve: `cannot resolve call target 'NetSha256.HashData/1' for
   --target native (the callee may be outside the bundled import closure)`,
   confirmed with a minimal `sha256OfBytes(...)` repro.
2. **`Std.Hash.sha512OfFile`'s `try`/`catch` cannot lower on native at all**
   (`lyric-stdlib/std/hash.l`): `Lyric.LlvmCodegen: try/catch is not
   supported for --target native (D-N-003: no unwinding)`, confirmed with a
   minimal `sha512OfFile(...)` repro, independent of the kernel gap above.

Implementing a native `Std.Hash` kernel (SHA-1/256/512 + HMAC, most likely
via the OpenSSL seam `docs/61-https-tls-http-versions.md` already
established for native TLS) and reworking `sha512OfFile`'s streamed-file
path to avoid `try`/`catch` on native (its 64 KiB chunking, `#7284`, still
needs to hold on `--target dotnet`/`--target jvm`) is a substantially
larger, separate feature, tracked in #7684, which also wires `hash_tests.l`
into `scripts/ci/native-target-smoke-test.sh`. The type checker's missing
argument check on `List`/`Map` methods, which let the original
`List[Byte].add(Int)` reach codegen unconverted, is tracked in #7683.
