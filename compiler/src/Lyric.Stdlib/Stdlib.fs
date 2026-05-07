/// Host-side stdlib shim — methods the emitter targets directly when
/// a Lyric construct can't be expressed in pure Lyric (or whose
/// pure-Lyric form is bootstrap-grade per D035 / D038). Each entry
/// is justified by something the language can't yet express:
///
///   - Null-aware `obj` formatting (`PrintlnAny`, `ToStr`): no Lyric
///     surface for `obj | null` discrimination.
///   - Slice readers (`JsonHost.Get*Slice`): iteration over
///     `JsonElement.ArrayEnumerator` (a nested CLR type) requires
///     extern-type resolution for `+`-separated names, not yet done.
///   - Try/catch wrappers (`FileHost.*`, `TryHost.*`): no try/catch
///     bridging across the FFI boundary yet.
///   - There are no remaining concurrency shims; `LyricTaskScope`,
///     `TaskScopeHost`, and `AmbientSlot` have all been retired.
///
/// Trivial wrappers (`println(string) -> Console.WriteLine(string)`,
/// integer math) have been hoisted out: see
/// `docs/14-native-stdlib-plan.md` §6 P0 for the migration log.
///
/// The kernel target (Decision F) is ≤150 declarations here.
namespace Lyric.Stdlib

open System

// G8 (`docs/23-fsharp-shim-elimination.md` §5): the prior `Console`
// type held `PrintlnAny(obj | null)` and `ToStr(obj | null)` — both
// retired.  Codegen now inlines the `null -> "()" else value.ToString()`
// lowering directly via `emitNullableToStringInline` in
// `compiler/src/Lyric.Emitter/Codegen.fs`.

// G9 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-110): the
// prior `LyricAssertionException` and `Contracts.{Panic, Expect, Assert}`
// were thin wrappers that constructed a custom exception subclass and
// threw it.  Codegen now inlines `newobj System.Exception(string)` +
// `throw` for every `panic` / `expect` / `assert` call site (and for
// `requires:` / `ensures:` runtime checks), so neither type is needed.
// `try { … } catch Bug as b { … }` resolves `Bug` to `System.Exception`
// already, so the user-visible catch behaviour is unchanged.

// `MapHelpers<'K, 'V>` retired (`docs/23-fsharp-shim-elimination.md`).
// All references were superseded when `Std.Collections` migrated to
// `_kernel/collections_host.l` direct externs in `docs/14` P0/4b
// batch 3.  Kept zero live `@externTarget` callers — verified by
// `KernelBoundaryTests.fs`'s outsideCeiling = 0 ratchet plus a
// repo-wide grep.

// `TaskHost` retired (`docs/23-fsharp-shim-elimination.md` G12;
// D-progress-111).  Both members were thin passthroughs to
// `System.Threading.Tasks.Task.Delay(int)` and
// `Task.Delay(int, CancellationToken)`.  `_kernel/task.l` now externs
// those overloads directly; the codegen's arity-based overload
// resolution picks the right one.

// `Lyric.Stdlib.CancelHost` retired (`docs/23-fsharp-shim-elimination.md`
// Phase 1, D-progress-105 follow-up).  Every method was a thin
// passthrough to `System.Threading.Cancellation{Token,TokenSource}`.
// `stdlib/std/_kernel/task.l` now `@externTarget`s those BCL members
// directly — `CancellationToken.None`, `CancellationTokenSource..ctor`,
// `.Token`, `.Cancel`, `.Dispose`, and the matching token methods.

// `Lyric.Stdlib.LyricTaskScope` and `Lyric.Stdlib.TaskScopeHost` retired
// (D-progress-stdlib-expand Group C, D-progress-069).  `Scope` is now a
// native Lyric `protected type` in `stdlib/std/_kernel/task.l` backed by
// a `CancellationTokenSource` + `List[Task]`.  All scope operations
// (`makeScope`, `scopeSpawn`, `awaitAll`, `cancelScope`, `disposeScope`)
// are pure Lyric on top of direct BCL externs.

// `Lyric.Stdlib.UnionEquality` retired (D-progress-stdlib-expand).
// `SameType(obj, obj)` was referenced via a `sameTypeMethod` lazy in
// Codegen.fs but the call site was never reached; union-case equality
// uses `Ceq` directly.  Both the F# type and the lazy are now deleted.

// G7 (`docs/23-fsharp-shim-elimination.md`; D-progress-123): F#
// `StubCounter` and `StubCounterHost` retired.  `stdlib/std/testing_mocking.l`
// (top-level, shadows `_kernel/testing_mocking.l` on .NET) now declares
// `pub protected type StubCounter { … }` in pure Lyric.  No F# types needed.

// `Lyric.Stdlib.AmbientSlot` retired (D-progress-stdlib-expand Group D1).
// `stdlib/std/_kernel/task.l` now declares the singleton slot with
// `@asyncLocal val __ambientSlot` so the emitter synthesises the
// static `AsyncLocal<CancellationToken>` field directly on the
// package's program type — no F# involved.

// `TryHost<'T>` retired (`docs/23-fsharp-shim-elimination.md`).
// Designed as a generic try/catch wrapper for FFI calls but never
// referenced from any `@externTarget` declaration — `Std.File` /
// `Std.Parse` etc. carry their own per-method shims, and the generic
// closure-based form was superseded before it was used.  G10 (FFI
// try/catch) makes the whole concept moot.

/// File I/O host shim.  Each operation catches host exceptions and
/// returns a tuple-shaped pair (`IsValid` flag + value/message) so the
/// Lyric-side caller can decide whether to wrap `Ok` or `Err`.  The
/// pair-of-statics shape is deliberate: Lyric has no out-params and we
/// don't want host exceptions to escape across the FFI boundary.
///
/// The error message is normalised to `<exception type>: <message>` so
/// callers can include it in `IoError(path, message)` without needing
/// the exception object itself.
// `Lyric.Stdlib.JsonHost` retired entirely.  The remaining live
// methods (`Parse`, `EncodeString`, `RenderDoubleSlice`, and the five
// `Get<T>Slice` readers) all migrated out:
//
//   - `Parse`: now resolves directly to
//     `System.Text.Json.JsonDocument.Parse(string, JsonDocumentOptions=default)`
//     via the FFI default-arg emitter, with overload disambiguation
//     by leading-param exact-type match (Emitter.fs `staticArityWithDefaults`).
//   - `EncodeString`: implemented in pure Lyric in `_kernel/json_host.l`,
//     splitting `JsonEncodedText.Encode(string)` (returns struct) and
//     `JsonEncodedText.ToString()` into two externs glued by Lyric.
//   - `RenderDoubleSlice`: replaced by an inline `mkSliceHelperInline`
//     using `toString(items[i])`, now culture-invariant for `Double`
//     / `Float` (Codegen.fs special-cases floating-point in the
//     `toString` builtin to call `Double.ToString(InvariantCulture)`).
//   - `Get<T>Slice` readers: implemented in pure Lyric using direct
//     externs over `JsonElement+ArrayEnumerator` (the nested CLR
//     struct).  The emitter's `findClrType` already handles
//     `+`-separated nested type names via the AppDomain walk; the
//     inout-receiver `Ldarga`/`Ldarg` selection in `emitExternCall`
//     was fixed to honour `inout`-mode value-type receivers so
//     `MoveNext` mutates the enumerator in place.

// G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
// `Lyric.Stdlib.HttpClientHost` retires entirely.  Every member
// migrated to direct-extern primitives + Lyric-level helpers in
// `stdlib/std/_kernel/http_host.l` across G12 (2/N) (everything
// except `ResponseHeader`) and this slice (G12 (4/N) —
// `ResponseHeader` rebuilt over `HttpHeaders.TryGetValues(name,
// out IEnumerable<string>)` + `Linq.Enumerable.ToArray<string>`
// shuttling into a `slice[String]` the Lyric side indexes for the
// first-value-or-empty fallback).

// `Lyric.Stdlib.RandomHost` retired (`docs/23-fsharp-shim-elimination.md`
// Phase 1, D-progress-105 follow-up).  `Std.Random` now externs the
// seeded `System.Random..ctor` directly, and `nextBool` is a one-line
// native Lyric body (`nextIntBelow(rng, 2) != 0`).

// G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
// the F# `Lyric.Stdlib.HttpServerHost` shim retires entirely.
// `stdlib/std/_kernel/http_server.l` declares direct-extern primitives
// for `HttpListener` / `HttpListenerContext` / `HttpListenerRequest` /
// `HttpListenerResponse` / `Stream` / `StreamReader` / `Encoding` and
// composes the user-facing `startListener` / `nextContext` /
// `requestMethod` / `requestBody` / `respondText` / `respondJson` /
// etc. as native Lyric on top of them.

// G10 (`docs/23-fsharp-shim-elimination.md` §5): the F# `FileHost`
// type retires entirely with G10 (2/2) (D-progress-NNN).  The
// bytes-flavoured methods (`ReadBytes*`, `WriteBytes*`) were the
// last survivors after G10 (1/2); they now route through direct
// `System.IO.File.{ReadAllBytes, WriteAllBytes}` externs in
// `stdlib/std/_kernel/file_host.l`, with the `byte[]`/`slice[Byte]`
// to `List[Byte]` shuttle done in pure Lyric inside `Std.File`.

// ── Stdlib expansion shims retired (D-progress-stdlib-expand-01 → P0/4d) ──────
//
// SetHost, FormatHost, and EncodingHost all eliminated:
//
//   FormatHost   — replaced by direct BCL externs in _kernel/format_host.l.
//   EncodingHost — replaced by direct BCL externs in _kernel/encoding_host.l.
//   SetHost      — setToSlice now uses IEnumerable for-loop in set.l (Group B);
//                  SFor emitter extended to handle IEnumerable<T> in Codegen.fs.

// ── JVM class-file emission helpers moved out (Phase 1 Bucket D) ─────────────
//
// `JvmByteBuilder`, `JvmByteHost`, `JvmZipHost`, `JvmConstantPool`, and
// `JvmPoolHost` lived here historically because the F# stdlib was the
// only available place to drop F#-side host code.  They are consumed
// only by the JVM emitter's Lyric source under `compiler/lyric/jvm/`,
// not by stdlib users — so the stdlib bundle no longer carries them.
//
// They now live in `compiler/src/Lyric.Jvm.Hosts/JvmHosts.fs` under the
// `Lyric.Jvm.Hosts` namespace.  See `docs/23-fsharp-shim-elimination.md`
// §4.3 (Bucket D) and D-progress-107 for the migration log.
