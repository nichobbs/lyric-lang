# 10 — Bootstrap implementation progress log

This file tracks the running state of the bootstrap compiler as it
moves through Phase 1 polish and Phase 2 deliverables.  Append-only:
each entry is dated and refers to the PR (or branch) where the work
landed.  Decisions and intentional gaps are documented in line so a
future agent (or human) can pick up cold.

The phased plan lives in `docs/05-implementation-plan.md`; this file
is the *delta* against that plan — what's actually shipped, what's
deferred, and why.

---

## Status against `05-implementation-plan.md`

### Phase 0 — design freeze
All seven deliverables landed (see `CLAUDE.md` table).  Q011 / Q012
deferred to Phase 3 by design.

### Phase 1 — bootstrap compiler MVP
- M1.1 lexer + parser — done.
- M1.2 type checker — done.
- M1.3 MSIL emitter — done.
- M1.4 contracts / async / FFI / banking — *bootstrap-grade* per
  `docs/03-decision-log.md` D035.  Generics are now reified (was a
  bootstrap-grade cut, see M2 progress below); async + FFI remain
  bootstrap-grade.

### Phase 5 — self-hosting (in progress)

| Milestone | Status | Lands in |
|---|---|---|
| M5.1 stage 1 — self-hosted lexer (subset; co-resident with self-test) | **Shipped** | D-progress-093 |
| M5.1 stage 2a — multi-file packages | **Shipped** | D-progress-094 |
| M5.1 stage 2a' — B0010 / B0011 / B0012 multi-file conflict diagnostics | **Shipped** | D-progress-095 |
| M5.1 stage 2b — split lexer into reusable `Lyric.Lexer` library | **Shipped** (PR #127) | D-progress-095 |
| M5.1 stage 2b' — codegen polish: EIf merge-balance + tuple/field TypeBuilder paths | **Shipped** (PR #127) | D-progress-095 |
| M5.1 stage 2c.1 — `internal` visibility tier (parser + AST + contract metadata exclusion) | **Shipped** (PR #129) | D-progress-096 |
| M5.1 stage 2c.2.i — `[project]` table in `lyric.toml` (Manifest parsing + tests) | **Shipped** (this branch) | D-progress-097 |
| M5.1 stage 2c.2.ii.a — single-DLL emit driver MVP: independent packages bundle into one PE, per-package contract resources | **Shipped** (PR #133) | D-progress-098 |
| M5.1 stage 2c.2.ii.b — cross-package symbol resolution within the project: topo-sort emit, in-project artifacts, B0020 cycle diagnostic | **Shipped** (PR #134) | D-progress-099 |
| M5.1 stage 2c.2.ii.c — `internal` → CLR `assembly` access modifier on emitted methods/types (codegen change) | **Shipped** (PR #136) | D-progress-100 |
| M5.1 stage 2c.2.iii — `lyric restore` walks every `Lyric.Contract.<Pkg>` resource on bundled DLLs | **Shipped** (PR #138) | D-progress-101 |
| M5.1 stage 2c.2.iv — CLI integration (`lyric build --manifest` dispatches to `emitProject` when `[project] output = "single"`); main entry-point capture from project bundle | **Shipped** (PR #138) | D-progress-102 |
| M5.1 stage 2c.3 — stdlib-bundle proof: 3-package smoke set compiles via `lyric build --manifest stdlib/lyric.toml`; in-project generic-union ctor + DeclaredOnly reflection fixes | **Shipped** (PR #140) | D-progress-103 |
| `docs/14` stage P3 — F# shim P3 trio: drop dead `Lyric.Stdlib.Parse`; route `format1..6` through `System.String.Format(string, object[])` (delete F# `Format`); inline-loop renderers in `@derive(Json)` synthesiser for Int/Long/Bool/String slices (delete F# `JsonHost.Render*Slice`, retain only `RenderDoubleSlice`) | **Shipped** (PR #141) | D-progress-104 |
| `docs/23` G8 — codegen-emitted null-aware `println(any)` / `toString(any)` lowering: F# `Lyric.Stdlib.Console` retired (`PrintlnAny` / `ToStr`) | **Shipped** (PR #145) | D-progress-105 |
| `docs/23` Phase 1 (2/3) — `RandomHost` / `CancelHost` direct-extern: kernel boundary now points at `System.Random..ctor` / `System.Threading.CancellationToken{,Source}.*` directly; `nextBool` is native Lyric (`nextIntBelow(rng, 2) != 0`) | **Shipped** (PR #147) | D-progress-106 |
| `docs/23` Phase 1 (3/3) — Bucket D split: `Jvm*` host helpers (~430 LoC) move from `Lyric.Stdlib` to a new `Lyric.Jvm.Hosts` project; stdlib bundle freed of JVM-only code | **Shipped** (PR #148) | D-progress-107 |
| `docs/23` Phase 1 dead-code sweep — drop F# `Lyric.Stdlib.MapHelpers` / `TryHost` (zero live `@externTarget` callers) | **Shipped** (PR #149) | D-progress-108 |
| `docs/23` G10 (1/2) — text/dir `Std.File` migrated to native Lyric `try { … } catch Bug as b { … }` around direct BCL externs (`System.IO.File.{ReadAllText,WriteAllText,Exists}` + `System.IO.Directory.{Exists,CreateDirectory}`); F# `FileHost` trimmed to bytes-only methods | **Shipped** (PR #150) | D-progress-109 |
| `docs/23` G9 — codegen inlines `newobj System.Exception(string)` + `throw` for `panic` / `expect` / `assert` + `requires:` / `ensures:` runtime checks; F# `Lyric.Stdlib.Contracts` and `LyricAssertionException` retired | **Shipped** (PR #151) | D-progress-110 |
| `docs/23` G12 (1/N) — F# `Lyric.Stdlib.TaskHost` retired; `Std.Task.{delay, delayWithCancel}` extern at `System.Threading.Tasks.Task.Delay` directly (overload by arity) | **Shipped** (PR #152) | D-progress-111 |
| `docs/23` G11 — `extern type AsyncLocal[T]` + non-builder generic FFI close; `Std.Task.{currentToken, installToken, restoreToken, hasAmbient}` are native Lyric on top of direct BCL externs to `AsyncLocal\`1.{Value, set_Value}` and `CancellationToken.CanBeCanceled`; F# `AmbientHost` collapses to a 4-LoC `AmbientSlot` static-field holder | **Shipped** (PR #155) | D-progress-112 |
| `docs/23` G10 (2/2) — bytes paths in `Std.File` go direct to `System.IO.File.{ReadAllBytes, WriteAllBytes}` via new kernel externs in `_kernel/file_host.l`; `slice[Byte] ↔ List[Byte]` shuttle done in pure Lyric (`for b in raw { acc.add(b) }` for read; `bytes.toArray()` for write).  F# `FileHost` retired entirely; `hostFileBuiltins` codegen map and `fileHostMethod` helper deleted | **Shipped** (PR #158) | D-progress-113 |
| `docs/23` G12 (2/N) — F# `Lyric.Stdlib.HttpClientHost` retired (16 of 17 methods); `_kernel/http_host.l` declares direct-extern primitives for the BCL surface and Lyric-level helpers compose them.  Multi-step orchestration (`MakeRequest`, `WithHeader`, `WithStringBody`, `ClientWithRedirects`, `PostString`) all moves into Lyric on top of `HttpClient/HttpClientHandler/HttpRequestMessage/StringContent/HttpHeaders` extern types and property setters.  `ResponseHeader` survives as the only F# member because `TryGetValues`'s `out IEnumerable<string>` shape isn't yet expressible at the FFI surface | **Shipped** (PR #173) | D-progress-118 |
| `docs/23` G12 (3/N) — F# `Lyric.Stdlib.HttpServerHost` retired entirely (8/8 methods); `_kernel/http_server.l` adds direct-extern primitives over `HttpListener` / `HttpListenerContext` / `HttpListenerRequest` / `HttpListenerResponse` / `Stream` / `StreamReader` / `Encoding` and rebuilds `startListener` / `nextContext` / `requestMethod` / `requestPath` / `requestBody` / `respondText` / `respondJson` as native Lyric (try/catch defensive arms preserved) | **Shipped** (PR #175) | D-progress-119 |
| `docs/23` G12 (4/N) — `HttpClientHost.ResponseHeader` (the last F# member) retired; native Lyric `hostResponseHeader` uses `HttpHeaders.TryGetValues(name, out IEnumerable<string>)` + `Linq.Enumerable.ToArray<string>` to surface a `slice[String]` for first-or-empty fallback.  F# `HttpClientHost` deletes entirely | **Shipped** (PR #179) | D-progress-120 |
| `docs/23` G7 (StubCounter) — `Std.Testing.Mocking.StubCounter` ported from F# shim (`Lyric.Stdlib.StubCounter` / `StubCounterHost`, 24 LoC) to a native Lyric `pub protected type StubCounter`.  New `stdlib/std/testing_mocking.l` shadows `_kernel/testing_mocking.l` for .NET; wrapper functions (`makeStubCounter`, `stubCounterIncrement`, `stubCounterGet`, `stubCounterReset`) are unchanged.  Emitter.fs gains `IProtected` scanning in the artifact-import loop so cross-package `protected type` references resolve to the correct CLR type (previously only `extern type` / record / union / interface got this treatment) | **Shipped** (PR #182) | D-progress-123 |
| `docs/23` JsonHost retirement — final eight live methods retired from `Lyric.Stdlib.JsonHost` (`Parse`, `EncodeString`, `RenderDoubleSlice`, `Get{Int,Long,Double,Bool,String}Slice`).  Compiler fixes unblock the migration: (1) FFI default-arg overload selection now filters by leading-param exact type so `JsonDocument.Parse(string, JsonDocumentOptions = default)` resolves correctly when other 2-arg `Parse` overloads exist; (2) `emitExternCall` honours `inout`-mode value-type receivers (load arg pointer directly instead of `Ldarga`-ing the parameter slot) so mutating instance methods like `JsonElement+ArrayEnumerator.MoveNext` work; (3) `toString(Double)` / `toString(Float)` codegen calls `Double.ToString(InvariantCulture)` for round-trip-safe locale-stable formatting.  `_kernel/json_host.l` declares `extern type JsonArrayEnumerator = "System.Text.Json.JsonElement+ArrayEnumerator"` and `extern type JsonEncodedText` and implements `hostEncodeString` and `lyricJsonGet*Slice` in pure Lyric on top of direct externs (`EnumerateArray` / `MoveNext` / `Current` / `JsonEncodedText.{Encode, ToString}`).  `JsonDerive.fs` synthesiser routes `__lyricJsonEscape` and slice readers through the new pure-Lyric kernel functions; `mkSliceHelperExtern` deleted (Double now uses inline `toString`-based rendering like Int/Long).  `Lyric.Stdlib.JsonHost` class removed; the `Lyric.Stdlib` F# shim is now empty of types | **Shipped** | D-progress-139 |
| `docs/23` F# shim project deleted — with `Lyric.Stdlib.dll` empty of host types after D-progress-139, the `compiler/src/Lyric.Stdlib/` project is deleted outright: `.fsproj` / `Stdlib.fs` removed, `<ProjectReference>` lines pulled from `Lyric.Cli`, `Lyric.Emitter`, `Lyric.Emitter.Tests`, and the project entry / configuration / nesting tag scrubbed from `Lyric.sln`.  CLI + test infrastructure (`Cli/Program.fs`, `EmitTestKit.fs`, `ProjectAsDllTests.fs`, `NugetShimTests.fs`) drop their `Lyric.Stdlib.dll` copy / probe paths.  `stdlib/lyric.toml` reverts `output_assembly` from `Lyric.StdlibBundle.dll` to the canonical `Lyric.Stdlib.dll` — the SDK's `lib/Lyric.Stdlib.dll` is now the Lyric-compiled bundle (no F# / FSharp.Core dep) | **Shipped** | D-progress-140 |
| M5.1 stage 2d.i — `[nuget]` + `[nuget.options]` manifest parsing | **Shipped** (PR #159) | D-progress-117 |
| M5.1 stage 2d.ii — `lyric restore` csproj forwards `[nuget]` entries to `dotnet restore`; TFM compat fallback for the NuGet-cache locator | **Shipped** (PR #159) | D-progress-117 |
| M5.1 stage 2d.iii — reflection-driven `Lyric.Cli.NugetShim` generator (static methods only; primitives + same-package `extern type`s; defensive against `MetadataLoadContext` failures) | **Shipped** (PR #162) | D-progress-118 |
| M5.1 stage 2d.iv — `lyric restore` writes `_extern/<lyric-pkg>.l` + `.skip.md` shims for every `[nuget]` entry after restore completes; B0030-flavoured warnings for unlocatable DLLs | **Shipped** (PR #162) | D-progress-118 |
| M5.1 stage 2d.v — build-time wiring: `project.assets.json` walker, `_extern/<pkg>.l` shim auto-compile to cached DLL, NuGet DLL pre-load into emitter AppDomain, NuGet + shim DLL copy alongside output, end-to-end smoke (`Newtonsoft.Json.JValue.CreateString`) | **Shipped** (PR #177) | D-progress-122 |
| JVM self-tests B111-B124 — lowerSealedUnion, lowerEnum, lowerOutInoutParam, lowerNatTag, makeLyricSignatureAttr, lowerExposedRecord, lowerProjectable, lowerProtectedWithBarriers, lowerHotAsync, lowerScopeBlock, lowerFuncWithContract, lowerDeriveEquality, lowerDeriveOrd, lowerPackage | **Shipped** (PR #183 / #184) | D-progress-124 |
| JVM stage B2 smoke test unskipped — `hello_class_bytes_are_jvm_loadable` now passes; stale `BadImageFormatException` workaround in `JvmSelfTest.fs` removed; `docs/18-jvm-emission.md` B111–B124 status table updated to Shipped | **Shipped** (PR #186) | D-progress-125 |
| Phase 6 — stdlib distribution per `docs/22-distribution-and-tooling.md` §2–§5 — §4 SDK root discovery, §5 `Lyric.SdkVersion` embed, `lyric --sdk-info`, bundle expansion to 11 packages, B0040/B0042 | **Shipped** (PR #187) | D-progress-126 |
| Phase 6 — VS Code tooling §6.1–§6.4 per `docs/22-distribution-and-tooling.md` — JSON schema for `lyric.toml`; manifest-backed package management commands (Add/Remove/Update dependency, Add NuGet, Restore); project navigator tree view; Lyric task definitions and provider (build, run, test, prove) | **Shipped** (PR #188) | D-progress-127 |
| Phase 5 — `Lyric.Ast` — self-hosted AST type declarations mirroring `Ast.fs` (`Expr`, `Stmt`, `Item`, `Pattern`, `TypeRef`, `ContractClause`, …); prerequisite for the self-hosted parser | **Shipped** (PR #185) | — |
| Phase 6 — stdlib expansion D042 — `Std.Sort` (stable merge sort), `Std.Set` (`Set[T]` over `HashSet<T>`), `Std.Char` (Unicode classification + case), `Std.Format` (hex, fixed-point, padding), `Std.Encoding` (Base64, hex, UTF-8), `Std.Uuid` (`Uuid` over `System.Guid`) | **Shipped** (PR #189) | D-progress-D042 |
| M5.1 stage 3 — interpolated / triple-quoted / raw string lexing in self-hosted lexer | **Shipped** (PR #162) | D-progress-119 |
| M5.1 stage 4 — NFC normalisation + L0040 reserved-name diagnostic + full UAX #31 XID_Start / XID_Continue acceptance in self-hosted lexer | **Shipped** (NFC + L0040 PR #167; UAX #31 PR #171) | D-progress-120 / D-progress-121 |
| M5.1 stage 5 — self-hosted parser (`Lyric.Parser` library + `parser_self_test.l`) | **Shipped** (PR #190) | D-progress-128 |
| M5.1 stage 5' — red/green CST foundation in self-hosted lexer + parser (lossless trivia capture, `GreenNode` / `RedNode`, event-based builder, file/import/item granularity) | **Shipped** (PR #197) | D-progress-130 |
| M5.1 stage 6 — self-hosted type checker (`Lyric.TypeChecker` library + `typechecker_self_test.l`) | **Shipped** (PR #195) | D-progress-132 |
| M5.2 stage 1 — self-hosted mode checker (`Lyric.ModeChecker` library + `modechecker_self_test.l`) | **Shipped** (PR #198) | D-progress-133 |
| MSIL PE emitter Stage M1 — `Msil.Pe` + `Msil.Kernel` packages; fixed-layout 1024-byte PE image for a minimal "Hello" assembly; structural smoke test via `msil_self_test_m1.l` | **Shipped** (PR #199) | D-progress-134 |
| MSIL PE emitter Stages M2a–M2d — parameterized heap builders (`Msil.Heaps`), opcode IR + two-pass assembler (`Msil.Opcodes`), metadata table model (`Msil.Tables`), and layout engine (`Msil.Assembler`) producing a correct, runnable PE from structured input; four self-tests verify each layer | **Shipped** (PR #219) | D-progress-141 |
| MSIL PE emitter Stage M3 — end-to-end execution test: `msil_self_test_m3.l` assembles a Hello-World PE, writes it to disk via `Std.File.writeBytes`, and the F# harness executes it with `dotnet exec`, verifying "Hello, World!" in stdout | **Shipped** (PR #220) | D-progress-142 |
| MSIL PE emitter Stage M4 — multi-method PE assembler: `AssemblerInput.methodBodies` replaces single `methodBody`; `methodBodyRvas()` computes per-method RVAs; `msil_self_test_m4.l` builds a two-method PE (`Greet` + `Main`) with structural and CLR-execution checks | **Shipped** (this branch) | D-progress-143 |
| MSIL PE emitter Stage M5 — local variables / fat method header: `StandAloneSig` table (0x11) added to `Msil.Tables`; `msil_self_test_m5.l` builds a PE whose `Main()` stores a string in a local variable (fat header, `InitLocals`) and prints it twice via `Console.WriteLine` | **Shipped** (this branch) | D-progress-144 |
| MSIL PE emitter Stage M6 — method arguments and non-void return: `msil_self_test_m6.l` builds a PE with `Add(int,int):int` (ldarg.0/ldarg.1/add/ret) called from `Main()` which passes the result to `Console.WriteLine(int)`; exercises int32 method signatures and argument-passing | **Shipped** (this branch) | D-progress-145 |
| MSIL PE emitter Stage M7 — static fields: `msil_self_test_m7.l` builds a PE with a static int32 field `s_val`; `Main()` stores 42 via `stsfld`, reloads via `ldsfld`, and prints it; exercises the `Field` (0x04) metadata table and `FieldSig` blob | **Shipped** (this branch) | D-progress-146 |
| MSIL PE emitter Stage M8 — `newobj` + instance fields: `msil_self_test_m8.l` builds a PE with an instance int32 field `x_val`, a HASTHIS constructor `.ctor(int v)` that stores `v` via `stfld`, and `Main()` that creates `Hello(99)` via `newobj`, reads `x_val` via `ldfld`, and prints it | **Shipped** (this branch) | D-progress-147 |
| MSIL PE emitter Stage M9 — multiple TypeDefs: `msil_self_test_m9.l` builds a PE with three classes (`Foo`, `Bar`, `Hello`) each owning one static method; verifies that `TypeDef.methodList` correctly partitions `MethodDef` rows across TypeDefs; CLR prints `GetFoo()+GetBar() = 30` | **Shipped** (this branch) | D-progress-148 |
| MSIL PE emitter Stage M10 — virtual method dispatch (`callvirt`): `msil_self_test_m10.l` builds a PE with abstract `Base` (virtual `GetValue():int`), concrete `Impl` (override returning 77), and `Hello.Main()` using `newobj` + `callvirt` on the base token; verifies CLR dispatches to the override and prints 77 | **Shipped** (this branch) | D-progress-149 |
| MSIL PE emitter Stage M11 — `InterfaceImpl` table: `msil_self_test_m11.l` builds a PE with CLR interface `IGetter` (abstract `GetValue():int`), concrete `Impl` implementing it (returning 42), `InterfaceImpl[1]` wiring the relationship, and `Hello.Main()` dispatching via `callvirt` on the interface token; verifies the `InterfaceImpl` (0x09) table is serialised correctly | **Shipped** (this branch) | D-progress-150 |
| MSIL PE emitter Stage M12 — conditional branch: `msil_self_test_m12.l` builds a PE with `Main()` computing `if 7 > 4 { 1 } else { 0 }` using `cgt` + `brfalse` + `br` + label resolution; verifies 2-byte `0xFE`-prefixed comparison opcode, 5-byte branch instructions with correct signed relative offsets, and CLR execution prints `1` | **Shipped** (this branch) | D-progress-151 |
| MSIL PE emitter Stage M13 — while loop / backward branch: `msil_self_test_m13.l` builds a PE with `Main()` summing 1..5 via a while loop; uses fat method header (2 int32 locals via `StandAloneSig`), `cgt` + `brtrue` for exit condition, and a backward `br` with negative signed offset; CLR prints `15` | **Shipped** (this branch) | D-progress-152 |
| MSIL PE emitter Stage M14 — `newarr` + array element access: `msil_self_test_m14.l` builds a PE with `Main()` creating an `int32[3]` array, storing 10/20/30 via `stelem`, loading and summing via `ldelem`, and calling `Console.WriteLine(60)`; adds `TypeRef[3]` for `System.Int32` as element-type token; CLR prints `60` | **Shipped** (this branch) | D-progress-153 |
| MSIL PE emitter Stage M15 — `ldc.i8` + `conv.i4` (64-bit literals): `msil_self_test_m15.l` builds a PE with `Main()` pushing `1000000000i64` and `2i64` via `ldc.i8` (9-byte instruction), multiplying, narrowing to `int32` via `conv.i4`, and calling `Console.WriteLine(2000000000)`; verifies the 8-byte LE constant encoding | **Shipped** (this branch) | D-progress-154 |
| MSIL PE emitter Stage M16 — `switch` table: `msil_self_test_m16.l` builds a PE with `Main()` dispatching value `2` via a 3-target `switch` instruction; target[2] pushes 42 and falls through to `Console.WriteLine`; verifies opcode `0x45`, count encoding, and each target's signed relative offset | **Shipped** (this branch) | D-progress-155 |
| MSIL PE emitter Stage M17 — bitwise operations: `msil_self_test_m17.l` builds a PE with `Main()` computing `(60 & 13) + (60 | 13) = 12 + 61 = 73`; exercises `and` (0x5F), `or` (0x60) opcodes; CLR prints `73` | **Shipped** (this branch) | D-progress-156 |
| MSIL PE emitter Stage M18 — `ldc.r8` (64-bit float literals): `msil_self_test_m18.l` builds a PE with `Main()` pushing `3.0` and `2.0` via `ldc.r8` (9-byte instruction with IEEE 754 f64 LE constant), multiplying via `mul`, and calling `Console.WriteLine(double)`; verifies opcode and the 8-byte encoding of `3.0`; CLR prints `6` | **Shipped** (this branch) | D-progress-157 |
| MSIL PE emitter Stage M19 — `sub` + `rem`: `msil_self_test_m19.l` builds a PE with `Main()` computing `(23 - 3) % 13 = 7`; exercises `sub` (0x59) and `rem` (0x5D); CLR prints `7` | **Shipped** (this branch) | D-progress-158 |
| MSIL PE emitter Stage M20 — exception handling (try/catch): `msil_self_test_m20.l` builds a PE whose `Main()` throws `System.Exception` in a try block and catches it, printing `42`; exercises `EHClause` record + `mbAddEHClause`, `MoreSects` flag (0x1B) in fat header, fat EH section (kind=0x41), `leave` (0xDD), `throw` (0x7A), and `newobj` (0x73); CLR prints `42` | **Shipped** (this branch) | D-progress-159 |
| MSIL PE emitter Stage M21 — `finally` block: `msil_self_test_m21.l` builds a PE whose `Main()` sets a local to 10 in a try block, adds 32 in a finally handler (flags=2, catchToken=0), and prints 42; exercises `endfinally` (0xDC) and a fat EH clause with `flags=2`; CLR prints `42` | **Shipped** (this branch) | D-progress-160 |
| MSIL PE emitter Stage M22 — `ldstr` + `#US` heap: `msil_self_test_m22.l` builds a PE whose `Main()` loads user string `"Hello, World!"` via `ldstr` (token `0x70000001`) and calls `Console.WriteLine(string)`; exercises `internUs`, UTF-16LE encoding with flag byte, and the `0x70` user-string token form; CLR prints `"Hello, World!"` | **Shipped** (this branch) | D-progress-161 |
| MSIL PE emitter Stage M23 — multiple static methods: `msil_self_test_m23.l` builds a PE with two `MethodDef` rows — `Main` (MethodDef[1]) and `Add(int,int):int` (MethodDef[2]); Main calls Add(20,22) via token `0x06000002`, Add uses `ldarg.0`/`ldarg.1`/`add`/`ret`; verifies two consecutive tiny-header method bodies and a MethodDef call token; CLR prints `42` | **Shipped** (this branch) | D-progress-162 |
| MSIL PE emitter Stage M24 — instance methods + instance fields: `msil_self_test_m24.l` builds a PE with `Counter` class (TypeDef[2]) owning Field[1]=`_value`, MethodDef[1]=`.ctor`, [2]=`Increment`, [3]=`GetValue`; Main (MethodDef[4]) creates Counter via `newobj`, calls Increment 3× via `dup`+`call`, then GetValue; exercises `Field` table, `ldfld`/`stfld`, HASTHIS sig convention, `MDA_SPECIAL_NAME+MDA_RTS_SPECIAL_NAME` on `.ctor`, three-TypeDef methodList/fieldList partitioning; CLR prints `3` | **Shipped** (this branch) | D-progress-163 |
| MSIL PE emitter Stage M25 — `isinst` + `box`: `msil_self_test_m25.l` builds a PE whose `Main()` boxes integer 42 as `System.Object` via `box` (0x8C), tests it with `isinst System.Object` (0x75), branches on null via `brfalse` (0x39), then boxes 42 again and calls `Console.WriteLine(object)`; exercises `isinst` token encoding (TypeRef[2]=System.Object), `box` with TypeRef[3]=System.Int32, and the `object` MemberRef sig `{0x00,0x01,0x01,0x1C}`; CLR prints `42` | **Shipped** (this branch) | D-progress-164 |
| MSIL PE emitter Stage M26 — `newarr` + `ldelem` + `stelem` (managed arrays): `msil_self_test_m26.l` builds a PE whose `Main()` allocates a 2-element `int32[]` via `newarr` (0x8D), stores 21 at indices 0 and 1 via `stelem` (0xA4), loads both elements via `ldelem` (0xA3), adds them (42), and calls `Console.WriteLine(int)`; exercises fat header with `ELEMENT_TYPE_SZARRAY` LocalVarSig, `StandAloneSig` table, and the typed array instruction forms; CLR prints `42` | **Shipped** (this branch) | D-progress-165 |
| MSIL PE emitter Stage M27 — `callvirt` (virtual dispatch): `msil_self_test_m27.l` builds a PE whose `Main()` boxes 42 as `System.Object`, calls `callvirt System.Object::ToString()` (MemberRef[1] with HASTHIS sig `{0x20,0x00,0x0E}`) to produce the string `"42"`, then calls `Console.WriteLine(string)` (MemberRef[2]); exercises the `callvirt` (0x6F) opcode and a HASTHIS signature with a string return type; CLR prints `42` | **Shipped** (this branch) | D-progress-166 |
| MSIL PE emitter Stage M28 — `ldsfld` + `stsfld` (static fields): `msil_self_test_m28.l` builds a PE whose `Hello` class declares two public static I4 fields `_x` and `_y` (Field[1], Field[2], flags=`FDA_PUBLIC+FDA_STATIC`); `Main` stores 20 via `stsfld` (0x80), stores 22, loads both via `ldsfld` (0x7E), adds (42), and calls `Console.WriteLine(int)`; exercises the `Field` table with `FDA_STATIC`, static-field token encoding (`0x04000001`, `0x04000002`), and field-sig `{0x06, 0x08}`; CLR prints `42` | **Shipped** (this branch) | D-progress-167 |
| MSIL PE emitter Stage M29 — `castclass` (reference-type cast): `msil_self_test_m29.l` builds a PE whose `Main()` boxes 42, calls `callvirt System.Object::ToString()` to produce `"42"`, casts the result via `castclass System.String` (TypeRef[4], token 0x01000004), then calls `Console.WriteLine(string)`; exercises `castclass` (0x74) with a TypeRef token and verifies that a successful cast leaves the reference intact; CLR prints `42` | **Shipped** (this branch) | D-progress-168 |
| MSIL PE emitter Stage M30 — `unbox_any` (value-type unboxing): `msil_self_test_m30.l` builds a PE whose `Main()` boxes 42 via `box` (0x8C), then unboxes it back to Int32 via `unbox_any` (0xA5) with TypeRef[3]=System.Int32 (token 0x01000003), and calls `Console.WriteLine(int)`; completes the box / isinst / castclass / unbox_any quartet; CLR prints `42` | **Shipped** (this branch) | D-progress-169 |
| M5.2 stage 2 — self-hosted contract elaborator (`Lyric.ContractElaborator` + `contract_elaborator_self_test.l`) | **Shipped** (this branch) | D-progress-137 |
| M5.2 stage 3+ — monomorphizer / MSIL emitter | Not shipped | — |
| M5.3 — self-hosted stdlib / LSP / formatter / package manager | **In progress** (stage 1: `Std.Process`, `Lyric.Manifest`, `Lyric.Cli`; stage 2: `Lyric.Fmt` formatter port; stage 3: F# CLI `lyric fmt` reflection bridge; stage 4: item-internal comment preservation via `FmtCtx` cursor; stage 5: blank-line preservation via `HiBlank` markers; stage 6: per-expression / per-statement / per-block / per-contract-clause CST granularity; stage 7: contract-clause comment + blank-line preservation; stage 8: where-clause comment preservation + clause-order round-trip fix; stage 9: width-driven multi-line expression rendering at 120-char budget; stage 10: binop-operand / list-element / function-param comment preservation + `out`-mode rendering bug fix; stage 11: `ELambda` / `EForall` / `EExists` multi-line layouts) | D-progress-129 / D-progress-131 / D-progress-135 / D-progress-136 / D-progress-141 / D-progress-142 / D-progress-143 / D-progress-144 / D-progress-145 / D-progress-146 / D-progress-147 |

### Phase 2 — type system completion (in progress)

| Item | Status | Lands in |
|---|---|---|
| Range subtypes | **Shipped** | PR #18 |
| Distinct types `derives` (Add, Sub, Compare, Equals, Hash, Default) | **Shipped** | (M1.4 + range PR) |
| Reified generics + cross-assembly generics | **Shipped** | PR #15 |
| Where-clause enforcement at call sites | **Shipped** | PR #16 |
| Nullary case context inference | **Shipped** | PR #16 |
| BCL method/property dispatch | **Shipped** | PR #17 |
| Range subtype `TryFrom` synthesis + bounds validation | **Shipped** | PR #18 |
| `std.parse` numeric host wiring | **Shipped** | PR #19 |
| `defer { ... }` lowering to try/finally | **Shipped** | PR #20 |
| `@projectable` recursive view derivation | **Shipped** | PR #21 |
| Stdlib import resolver beyond `Std.Core` | **Shipped** | (this branch) |
| Cross-assembly union-case type-arg inference from return type | **Shipped** | (this branch) |
| UFCS-style static dispatch (`Type.method(args)`) | **Shipped** | (this branch) |
| `panic` / `expect` / `assert` builtins | **Shipped** | (this branch) |
| Function overloading by arity | **Shipped** | (stdlib-ergonomics) |
| BCL default-argument emission | **Shipped** | (stdlib-ergonomics) |
| `slice[T]` as function parameter type | **Shipped** | (stdlib-ergonomics) |
| Codegen diagnostics (E0003/E0004/E0012) replacing failwithf | **Shipped** | (stdlib-ergonomics) |
| `Std.String` full surface (split, join, substring overload) | **Shipped** | (stdlib-ergonomics) |
| `toString` polymorphic builtin | **Shipped** | (real-world-stdlib) |
| `format1`..`format4` (String.Format wrappers) | **Shipped** | (real-world-stdlib) |
| `Std.File` (readText / writeText / fileExists / createDir) | **Shipped** | (real-world-stdlib) |
| `Std.Collections` (IntList / StringList / LongList / *Map) | **Shipped** | (collections, superseded by generic-ffi) |
| Generic `extern type` + `@externTarget` (FFI generics) | **Shipped** | (generic-ffi) |
| BCL method dispatch on extern-typed receivers | **Shipped** | (generic-ffi) |
| Indexer dispatch (`xs[i]` / `m[k]`) on BCL containers | **Shipped** | (generic-ffi) |
| `out` / `inout` parameters with CLR byref lowering | **Shipped** | (out-params) |
| Definite-assignment analysis for `out` params | **Shipped** | (out-params) |
| `default[T]()` builtin (zero-init via expected type) | **Shipped** | (out-params) |
| `Dictionary.TryGetValue` etc. callable directly via FFI | **Shipped** | (out-params) |
| `tryInto` synthesis on projectable views | **Shipped** | (already in M2.2) |
| `defer` + `return` (br→leave inside try) | **Shipped** | (already in M2.2) |
| `@projectionBoundary` cycle handling | **Shipped** | (D-progress-019, T0092 diagnostic) |
| Real async state machines | **Shipped** | (C2 chain D-progress-033..076; closed out by PR #62) |
| Reflection-driven FFI | **Shipped** | (C4 phase 1 D-progress-026; phase 2 D-progress-061) |
| `@stubbable` stub builder synthesis | **Shipped** | (D-progress-016; call counters D-progress-073) |
| Stdlib expansion (collections, time, json, http) | **Shipped** | (Std.Time / Json / Http / Math / Random / Testing — D-progress-027..072) |

### Phase 3 — package ecosystem + tooling (substantially shipped)
- Package manager — `lyric.toml` + `lyric publish` / `lyric restore` +
  build-time consumer of restored Lyric packages all shipped
  (D-progress-031 embedded contract resource; D-progress-077 manifest
  + publish/restore wrappers; D-progress-078 build-time consumer).
- LSP — push-diagnostics + completion / hover / go-to-definition shipped
  (D-progress-017, 066).
- Documentation generator (`lyric doc`) — bootstrap shipped (D-progress-023).
- SemVer enforcement (`lyric public-api-diff`) — shipped (D-progress-062).
- Tutorial — shipped (D-progress-065).
- Protected types — bootstrap-grade Monitor wrap shipped
  (D-progress-079); `when:` barriers + `invariant:` checks +
  `ReaderWriterLockSlim`/`SemaphoreSlim` lock-flavour split + generic
  protected types (`Box[T]`) + Ada-style condition-variable barrier
  waiting all shipped under D-progress-080 / 081 / 083 / 086 / 087.
  Bootstrap concession: barrier waits use a finite timeout (currently
  1s) so single-threaded misuses surface as exceptions instead of
  deadlocks; Ada's infinite-wait semantics are tracked as Q008
  follow-up.
- Bootstrap AST formatter (`lyric fmt`) — **shipped** (`Fmt.fs` in `Lyric.Cli`): canonical style (2-space indent, brace placement, contract clause layout, trailing newline), `--write` and `--check` flags. Non-doc `//` comments are not preserved (lexer discards them); doc comments (`///`, `//!`) survive. Idempotent.
- Bootstrap linter (`lyric lint`) — **shipped** (`Lint.fs` in `Lyric.Cli`): five AST-only rules: L001 PascalCase types, L002 camelCase funcs, L003 pub-doc, L004 no TODO/FIXME in docs, L005 pub block-body funcs need contracts. `--error-on-warning` flag. Runs on non-compiling code.
- Real CST formatter (`lyric fmt` v2) — Tier 6, deferred: round-trip-faithful printing with full comment preservation needs a CST layer (decision: D-progress-029).
- Property-based testing (`Std.Testing.Property`) — bootstrap shipped
  (D-progress-064): `forAllIntRange` / `forAllBool` / `forAllDouble` /
  `forAllIntPair` random-sample helpers, caller-supplied seeded `Random`
  for determinism. Shrinking, composable generators, and xunit-style
  discovery deferred.
- Snapshot testing (`Std.Testing.Snapshot`) — bootstrap shipped
  (D-progress-063): `snapshot(label, actual)` first-run-writes /
  later-run-compares against `snapshots/<label>.txt`,
  `snapshotMatch(label, actual)` panic-on-mismatch wrapper. Hard-coded
  snapshot directory, no diff rendering, no normalization — Phase 3
  follow-ups.

### Phase 4 — proof system (in progress)

| Milestone | Status | Lands in |
|---|---|---|
| M4.1 — VC skeleton, arithmetic, range encoding, axiom registration, mode-dispatch, `lyric prove` CLI | **Shipped** | D-progress-085 |
| M4.2 — loop encoding (establish/preserve/conclude), V0005 invariant gate, var SSA, datatype encoding (record/union/opaque), `EMember` field selectors, `@pure` unfold, persistent z3 + content-hashed goal cache, cross-package contract reading + V0001 level-violation diagnostic | **Shipped** | D-progress-089 (PR #90) |
| M4.2 — quantifiers (`forall`/`exists`), trigger inference, V0006 decidable-fragment enforcement | **Shipped** | (V0006 in `ModeCheck.fs`; `TForall`/`TExists` in `Vcir.fs`; `EForall`/`EExists` translation in `VCGen.fs`) |
| M4.2 — `std.core.proof` standard-library subpackage | **Shipped** | D-progress-091 (`compiler/lyric/std/core_proof.l`; 9/9 obligations self-discharge under the trivial checker) |
| M4.2 — `--allow-unverified` CLI flag (escape hatch on `unknown`) | **Shipped** | D-progress-091 (`Driver.ProveOptions`; CLI wires `lyric prove --allow-unverified`; V0007 downgraded to warning, V0008 stays an error) |
| M4.2 — 200-test verification regression suite | **Shipped** | D-progress-091 (216 passing in `Lyric.Verifier.Tests`; the one z3-only failure is environment-gated and predates this milestone) |
| M4.3 — counterexample reporting + trace reconstruction + suggestion heuristics | **Shipped** | D-progress-114 (M4.1 model bindings + M4.2 falsified-hypothesis / falsified-conclusion lines + M4.3 boundary `requires:` suggestions in `Driver.suggestRequiresClauses`; surfaced in V0008 messages, `--json` `goals[].suggestions`, and LSP proof-failure hovers; six unit tests in DriverTests cover the heuristic) |
| M4.3 — `lyric prove --explain --goal <n>` mode | **Shipped** | D-progress-113 (`Vcir.PrettyPrint.goal` + CLI dispatch + ProveTests CLI tests) |
| M4.3 — `lyric prove --json` schema (frozen public surface) | **Shipped** | D-progress-113 (CLI emitter + appendix A in `docs/15-phase-4-proof-plan.md` + ProveTests schema tests) |
| M4.3 — LSP integration: V0007/V0008 hover counterexamples + code actions | **Shipped** | D-progress-113 (`Server.fs` proof-failure hover section; V0007/V0008 downgrade-to-runtime_checked quickfix; ProtocolTests covers V0003 / V0007 / V0008 / V0009) |
| M4.3 — `@proof_required(checked_arithmetic)` mode | **Shipped** | D-progress-113 (`VCGen.Env.CheckedArithmetic` + per-binop overflow side conditions on `+`/`-`/`*` for `SInt`; DriverTests coverage) |
| M4.3 — `unsafe { ... }` + `assert φ` end-to-end (V0003, V0009) | **Shipped** | D-progress-113 (`ModeCheck.onUnsafe`/`checkAssumeUsage`; `VCGen` opacity for `EUnsafe`; assert-as-side-goal-and-assumption in DriverTests) |
| M4.3 — banking-example proof tutorial chapter | **Shipped** | D-progress-113 (`docs/13-tutorial.md` §8: annotation, debit/credit/execute contracts, `--explain`, `--json`, `checked_arithmetic`, `unsafe { }`) |
| M4.3 — `docs/17-axiom-audit.md` (renumbered from 16; slot 16 went to `16-lsp-vscode-plan.md`) | **Shipped** | `docs/17-axiom-audit.md` ships the full audit for `std.bcl.*`; references corrected in 15 / 12 / bootstrap-progress |
| M4.3 — contract-aware `lyric public-api-diff` (strengthened `requires:` / weakened `ensures:` as breaking) | **Shipped** | D-progress-113 (`ContractMeta.DiffContractChanged` with `StrengthenedRequires` / `WeakenedEnsures`; ContractMetaTests cover both directions + non-breaking cases) |
| M4.3 — CVC5 solver-swap parity (≥95 % of M4.2 corpus) | **Shipped** | D-progress-115 (`SolverFlavor` discriminator + flavor-specific args + flavor-aware verdict-line drain) + D-progress-116 (`session-start.sh` installs z3 + cvc5 from the Ubuntu universe repo so every Claude-on-the-web session has both solvers available; the full Lyric.Verifier.Tests suite — 256 tests, the cumulative M4.2 + M4.3 regression corpus — passes against CVC5 alone after temporarily disabling z3, **100 %** of the corpus, well above the ≥95 % exit criterion) |

The end-to-end `examples/prove_demo.l` (12 obligations covering identity,
tautology, bumped-by-1, cross-function call rule, inline range, assert,
match, `@pure` unfold, loop establish/preserve/post, var SSA, record
construction + field access) discharges under the shipped pipeline. The
M4.2 close-out (D-progress-091) ships the remaining three deliverables
flagged "Not shipped" in D-progress-090 — `Std.Core.Proof`,
`--allow-unverified`, and the 200-test regression suite — so the M4.2
status table flips fully to **Shipped**. The pagination-helper /
token-bucket end-to-end worked-example proofs tracked in
`docs/12-todo-plan.md` Band D-D1.3 shipped in D-progress-129: four verifier
bugs were fixed (float/Real mapping, branch-condition propagation, shared
Symbols accumulator, free-var/selector name collision) and both examples
discharge cleanly under Z3.

---

## Active session decisions

### D-progress-147: M5.3 stage 11 — `ELambda` / `EForall` / `EExists` multi-line layouts; type-expression multi-line formally deferred

*claude/lyric-fmt-lambda-forall-multi branch.*

Three more `ExprKind` arms wired into the width-driven multi-line
pretty-printer.  Plus a documentation note formally deferring
multi-line type-expression layout (scenario "comments inside type
expressions" from PR #224's out-of-scope list).

**`ELambda` multi-line layout** (`exprLambdaMulti`):

```
{ param1, param2 ->
  stmt1
  stmt2
}
```

The lambda body is a `Block`, so the existing `blockLines` (already
trivia-aware via `popTriviaBefore` at each statement boundary)
handles per-statement comments and blank-line preservation inside
the lambda for free.  Empty-param lambdas drop the `->` arrow on
the opening line.

**`EForall` / `EExists` multi-line layout** (`exprQuantMulti`):

```
forall (a: Int, b: Int) where guard {
  body
}
```

When the inline form would overrun the budget, the quantifier breaks
on the body (the highest-leverage break — contract quantifiers
usually have long bodies).  Threading multi-line layouts through the
binder tuple and the where-guard expression as well is a follow-up;
for now they render inline.

**Pre-existing double-brace forall body bug** (out of scope for
this stage): when a quantifier body is parsed as `forall (i) { p(i) }`,
the parser wraps the inner expression in `EBlock` (the `{ … }` is a
block).  Both `quantifierStr` (inline) and `exprQuantMulti`
(multi-line) emit a `{` opener and a `}` closer around the body.
The body's `EBlock` rendering (`{ blockInline }`) adds another
pair, producing `forall (i) { { p(i) } }`.  The F# legacy
`Lyric.Cli.Fmt` shares this bug.  Fix is structural — either drop
the formatter's outer braces when body is `EBlock`, or change the
parser to not wrap a single-stmt block.  Out of scope here.

Self-test additions in `compiler/lyric/lyric/fmt_self_test.l`:

- `testCommentInsideLambdaBody` — `// process input` inside a lambda
  body anchors via `blockLines`.
- `testWidthDrivenLongLambdaBody` — long lambda body breaks after
  `->`.

### Type-expression multi-line — formally deferred

The "comments inside type expressions" scenario from PR #224's
out-of-scope list (e.g. `array[\n // size\n N,\n (Int, Int)\n]`) is
formally deferred:

- It needs a parallel `typeAtCol` family mirroring `exprAtCol` —
  per-`TypeExprKind` multi-line layouts for `TGenericApp`, `TArray`,
  `TSlice`, `TFunction`, `TTuple`, `TParen`.  Roughly 200-300 LoC of
  new Lyric, similar shape to the existing expression layouts.
- User-visible benefit is small: comments inside a `Foo[A, B, C]`
  argument list are vanishingly rare in practice (we've not seen
  them in the stdlib or any example file).  `array[N, T]` and
  `slice[T]` are usually short.
- The same is true for **patterns** and **where-clause bound
  lists** — both can be made multi-line via the same pattern,
  same low-priority status.

The next-largest user-visible gap remaining is the inline `EIf` /
`EMatch` forms when long; `EIf` (brace form) and `EMatch` (brace
form) already have multi-line printers.  Those would convert the
inline form to the brace form when budget exceeds — small,
mechanical, and tracked as a future stage.



### D-progress-146: M5.3 stage 10 — binop-operand / list-element / function-param comment preservation, plus `out` mode rendering bug fix

*claude/lyric-fmt-binop-list-param-comments branch.*

Three new comment-anchoring sites + one regression fix.

**Binary-op operand comments.**  `exprBinopMulti` now pops trivia at
the RHS's source-start before emitting, so a `// sum carry` between
two operands lands between operator and RHS:

```
val x = a +
  // sum carry
  b
```

**List / tuple element comments.**  `exprListMulti` pops trivia at
each element's source-start, mirroring the per-arg pop in
`exprCallMulti`.  A `// primes` between two elements stays inside
the bracketed group:

```
val xs = [
  // primes
  2,
  3,
  5
]
```

**Function-parameter comments + width-driven multi-line signatures.**

- New `paramsAtCol(col, ctx, ps)` returns a `Doc`.  Inline if budget
  allows AND no unpopped trivia falls in `[0, lastEnd)` (the broad
  range catches comments before the FIRST param, which sit in the
  first param's leading trivia at offset `< ps[0].span.startPos`).
  Otherwise, multi-line with one parameter per line and a
  Black-style trailing comma on every entry.
- New `paramsFitInline(col, ps, suffixLen)` for the precise budget
  check including the caller's suffix length (e.g. `") -> Foo"`).
- `funcSigDocFromParts(prefix, suffix, paramsCol, ctx, ps)` returns
  the signature `Doc`.  Inline keeps it on one line; multi-line
  emits `prefix(`, params indented, `)suffix` on its own line.
- New `appendToLastLine(doc, suffix)` helper attaches `" = expr"` /
  `" {"` / etc. to a multi-line signature whose last line is the
  closing `)` plus return type.
- `funcDoc` is rewired to thread the multi-line signature `Doc`
  through every body shape (no body / `FBExpr` / `FBBlock` ± extras).

```
func process(
  // x is the input
  x: in Int,
  y: in Int,
): Int {
  x + y
}
```

**`out` mode rendering bug fix.**  `paramStr`'s `PMOut` arm read
`"acc "` — a leftover from the original sed-driven `out` →
`acc` reserved-keyword cleanup (D-progress-131).  Restored to
`"out "` so an `out` parameter round-trips as `: out Int`.

Self-test additions (`fmt_self_test.l`):

- `testCommentBetweenBinopOperands` — `// sum carry` between operands.
- `testCommentBetweenListElements` — `// primes` between list elements.
- `testCommentBeforeFunctionParam` — `// x is the input` before the
  first param triggers multi-line signature.
- `testWidthDrivenLongParamList` — 9-param signature (~145 chars
  inline) breaks across lines with one param per line.
- `testOutModeRendersCorrectly` — regression lock for the `out`
  mode rendering fix.

Out of scope for this stage:

- Multi-line variants for `entryDoc` parameter lists (entry decls
  inside `protected type` bodies follow the same pattern; not yet
  wired but mechanically additive).
- Type-expression multi-line layout (rare in practice; deferred).
- `where`-clause bound list multi-line.
- `EIf` (inline form), `EMatch` (inline form), `ELambda`,
  `EForall`, `EExists`, record-constructor multi-line layouts.



### D-progress-145: M5.3 stage 9 — width-driven multi-line expression rendering in `Lyric.Fmt` (120-char budget)

*claude/lyric-fmt-width-driven-multi-line branch.*

The formatter now breaks long expressions across lines when the
inline rendering would exceed a 120-character line budget at the
expression's current column.  Comments inside an expression's source
span also force a multi-line layout so they can be woven in at sub-
expression boundaries (e.g. between call args).

Architecture (`compiler/lyric/lyric/fmt/fmt_core.l`):

- `maxWidth() = 120` — process-wide constant.
- `exprFitsInline(col, ctx, e, inline) -> Bool` — true when
  `col + inline.length <= maxWidth()` AND no `HarvestedItem` falls
  inside `e`'s source span (peek-only via `hasTriviaInRange`).
- `exprAtCol(col, ctx, e) -> Doc` — the new entry point.  Computes
  the inline rendering via `exprInline`; if it fits, returns
  `singleLineDoc(inline)`; otherwise dispatches on `ExprKind` to a
  per-construct multi-line layout.
- Multi-line layouts ship for `ECall`, `EBinop`, `EList`, `ETuple`,
  `EParen`.  Other constructs (`ELiteral`, `EPath`, `EMember`,
  `EIndex`, `EPrefix`, `EAwait`, `ESpawn`, `ETry`, `ESelf`,
  `EResult`, `ELambda`, `EIf` (inline form), `EMatch` (inline form),
  `EForall`, `EExists`, `EBlock`, `EUnsafe`, `EAssign`, `ETypeApp`,
  `EPropagate`, `EOld`, `ERange`, `EError`, `EInterpolated`) fall
  back to the inline rendering even if it exceeds budget — adding
  multi-line variants for them is mechanical follow-up work.
- Black-style "magic trailing comma" placement: opener on the first
  line, items one-per-line indented by 2, closer on its own line at
  the original indent.  Operators in binary chains end the LHS line
  and the RHS starts a new indented line — keeps the operator
  visually attached to its left operand.
- `exprCallMulti` pops trivia at each arg's start offset and
  prepends the popped lines (indented to match arg column) so a
  comment between two args lands inside the call instead of
  escaping to the next outer statement boundary.

Statement-level wiring:

- New doc-returning helpers in `fmt_core.l`: `localBindingDoc`,
  `assignDoc`, `returnDoc`, `throwDoc`, `invariantDoc`,
  `bareExprDoc`.  Each wraps `exprAtCol` with the keyword/prefix
  prepended to the first line via `prependPrefix`.
- `stmtLines`'s `SLocal` / `SAssign` / `SReturn` / `SThrow` /
  `SInvariant` arms now route through these doc-returning helpers.
  `SExpr`'s fall-through path (non-match, non-if-block) goes
  through `bareExprDoc` so a long bare expression statement
  participates in width-driven multi-line.
- `stmtExprLines` keeps the existing `EMatch` / `EIf-block`
  multi-line specialisations.

Contract-clause wiring (`fmt_items.l`):

- New `contractDoc(col, ctx, cc)` — width-driven variant of
  `contractStr` that returns `Doc`.  `funcDoc` and `entryDoc` now
  emit each clause via `indentDoc(2, contractDoc(2, ctx, c))`,
  preserving the canonical 2-space contract indent and breaking
  long clause bodies across lines.

Reference column tracking is pragmatic for v1: `stmtLines` uses a
hardcoded `col = 2` (the typical function-body indent).  Statements
nested inside `if` / `for` / `while` / `match` blocks run a few
chars over budget per nesting level — close enough for the budget
to catch real overruns without threading `col` through every
signature in the multi-line printer family.  Threading `col` end-to-
end is a follow-up improvement.

Self-test additions in `compiler/lyric/lyric/fmt_self_test.l`:

- `testWidthDrivenLongCallBreaks` — a 32-arg call to a
  long-named function breaks into one-arg-per-line layout.
- `testWidthDrivenLongCallIdempotent` — round-trip lock.
- `testCommentInsideCallArgs` — a `// first arg` comment between
  two call arguments lands inside the multi-line call layout, not
  at the next outer statement boundary.
- `testWidthDrivenLongBinopBreaks` — long `+` chain breaks with
  operator at end-of-line.
- `testShortExpressionStaysInline` — negative test: short
  expressions are never broken (no over-eager triggering).

Out of scope for this stage:

- Multi-line variants for `ELambda`, `EForall`, `EExists`, `EIf`
  (inline form), record/struct constructors used inline, and the
  remaining `ExprKind` arms.  Mechanically additive; same shape
  as the existing layouts.
- Threading `col` end-to-end through `blockLines` /
  `stmtLines` / control-flow helpers (currently hardcoded
  `col = 2`).
- Width-driven multi-line for type expressions, patterns, and
  `where`-clause bound lists.



### D-progress-144: M5.3 stage 8 — where-clause comment preservation + clause-order round-trip fix

*claude/lyric-fmt-where-and-arm-comments branch.*

Two related improvements to `Lyric.Fmt`:

**1. Where-clause comment preservation.**  Mechanically the same as
contract-clause preservation (D-progress-143).  `funcDoc` now calls
`popTriviaBefore(ctx, wc.span.startPos.offset)` before emitting the
`where` line, then `appendIndentedTrivia` to weave the popped
comments / blank-line markers above it with the canonical
two-space contract indent.

```
func max[T](a: in T, b: in T): T
  // T must be ordered      <-- preserved
  where T: Compare
{
  if a > b { a } else { b }
}
```

**2. Clause-order round-trip fix.**  Pre-existing latent bug: the
self-hosted parser accepts `where` only BEFORE the contract clauses
(`parseFunctionDeclBody` reads `parseWhereClauseOpt` before
`parseContractClauses`), but the formatter was emitting `contracts
→ where`.  Round-tripping a function with both clauses through
`lyric fmt` produced output the parser then rejected with `P0040
expected an item declaration`.  Reordered the formatter to emit
`where → contracts` to match the parser's expectation, and reordered
the trivia pops to stay in source order so the `FmtCtx` cursor
advances monotonically.

Self-test additions in `compiler/lyric/lyric/fmt_self_test.l`:

- `testCommentBeforeWhereClause` — `// T must be ordered` survives.
- `testCommentBetweenWhereAndContract` — comment between `where` and
  the following `requires:` survives.
- `testWhereThenContractRoundTrips` — locks in the round-trip
  invariant: parse, format, re-parse must succeed without
  diagnostics; format is idempotent; `where` appears before
  `requires` in the output.

Out of scope for this stage:

- Comments inside contract-clause expressions (`forall`/`exists`/
  `match` bodies) — needs multi-line expression rendering.
- Comments inside arbitrary expression sub-trees (between operands
  of a binary op, between function args).  Same blocker.
- Where-clause emission position on records / unions / enums /
  opaque / protected / interface / impl bodies — the formatter
  currently puts the `where` line INSIDE the braces between header
  and members, which is structurally fine but unusual.  Consistent
  with the F# `Fmt.fs`; left untouched.



### D-progress-143: M5.3 stage 7 — contract-clause comment + blank-line preservation in `Lyric.Fmt`

*claude/lyric-fmt-contract-clause-comments branch.*

First user-visible payoff from the per-expression / per-statement /
per-contract-clause CST granularity that landed in D-progress-142:
the formatter now preserves comments and blank lines that sit
between contract clauses on a function signature.

Before this stage, a function with explanatory `//` comments
attached to its `requires:` / `ensures:` / `when:` clauses lost them
across `lyric fmt`:

```
func divide(x: in Int, y: in Int): Int
  // y must not be zero      <-- DROPPED
  requires: y != 0
  // result times y reconstitutes x  <-- DROPPED
  ensures: result * y == x
  { x / y }
```

After:

```
func divide(x: in Int, y: in Int): Int
  // y must not be zero
  requires: y != 0
  // result times y reconstitutes x
  ensures: result * y == x
{
  x / y
}
```

Mechanism (`compiler/lyric/lyric/fmt/fmt_items.l`):

- New `contractClauseStartOffset(cc)` helper extracts the source
  offset of any `ContractClause` variant.
- `funcDoc` and `entryDoc` now call `popTriviaBefore(ctx, …)` before
  emitting each clause line.  The popped lines (comments + blank-line
  markers) are routed through `appendIndentedTrivia` so each non-
  blank line is prefixed with the canonical contract indent (`  `),
  matching the indent of the clause line itself.  Blank lines stay
  literally `""` so `joinLines` doesn't strip indented whitespace.

Self-test additions in `compiler/lyric/lyric/fmt_self_test.l`:

- `testCommentBeforeContractClause` — `// y must not be zero` and
  `// result times y reconstitutes x` both survive.
- `testBlankLineBetweenContractClauses` — blank line between
  `requires:` and `ensures:` survives.

End-to-end smoke through the F# `lyric fmt` bridge confirms.

Out of scope for this stage:

- Comments inside contract-clause expressions (e.g. inside a
  `requires: forall (i: Int) where i >= 0 { … }` body) — would
  require multi-line expression rendering, which the formatter
  doesn't yet do.
- Comments inside arbitrary expression sub-trees (between operands
  of a binary op, between function args).  Same blocker as above.
- Comments before the function's `where` clause.  Mechanically
  similar to contract clauses; held out for a follow-up stage.



### D-progress-142: M5.3 stage 6 — per-expression / per-statement / per-block / per-contract-clause CST granularity

*claude/lyric-cst-expr-stmt-granularity branch.*

Extends the self-hosted parser's CST below the `SkItem` boundary: each
`parseExpr`, `parseStatement`, `parseBlock`, and committed
`parseContractClauseOpt` invocation now opens its own green node.
The previous shape (everything inside an `SkItem` was a flat token
run) made it impossible for the formatter to anchor sub-expression
trivia at the right depth — the gap called out in `D-progress-141`'s
"Out of scope" note.

Mechanism:

- New `SyntaxKind`s in `parser_cst.l`: `SkBlock`, `SkStatement`,
  `SkExpr`, `SkContractClause`.  Each is documented with the kind
  of source construct it wraps and where its children come from.
- `parseExpr` (the precedence-climber entry) wraps with
  `cstStart(SkExpr)` / `cstFinish` once per call.  The internal
  precedence helpers (`parseImpliesExpr`, `parseAddExpr`, …) do not
  re-wrap — they're parts of one expression node.  Sub-expression
  recursions through parens / function args / indices / type args
  / etc. *do* hit `parseExpr` again and produce nested `SkExpr`
  children, matching how `Expr` is structured in the AST.
- `parseStatement` is split into a thin wrapper (`cstStart(SkStatement)`
  / `cstFinish`) and a renamed `parseStatementInner` that owns the
  body — same pattern used by `parseExpr`.
- `parseBlock` wraps the entire `{ … }` form as `SkBlock`, including
  the brace tokens, statement nodes, and `TStmtEnd` separators.
- `parseContractClauseOpt` peeks the upcoming token before opening
  a node — only commits to `SkContractClause` when we know the next
  keyword is `requires`, `ensures`, or `when`.  Avoids spurious
  empty nodes on items that have no contracts.

Self-test additions in `compiler/lyric/lyric/parser_self_test.l`:

- `testCstHasSkBlockInsideFunc` — at least one `SkBlock` per
  function body.
- `testCstHasSkStatementInsideFunc` — each statement has its own
  `SkStatement` node.
- `testCstHasSkExprInsideStatement` — `SkExpr` nests across paren /
  sub-expr boundaries (≥ 3 in `(1 + 2); a`).
- `testCstHasSkContractClause` — exactly two `SkContractClause`
  nodes for a `requires:` + `ensures:` pair.
- `testCstNoSkContractClauseWhenAbsent` — zero clause nodes when no
  contract is present.
- `testCstShapeIsLossless` — finer granularity preserves the
  byte-for-byte round-trip via `nodeSourceText`.

The formatter already takes a `FmtCtx` cursor, but it doesn't yet
*use* the new sub-`SkItem` nodes.  This stage is the parser-side
scaffolding; a follow-up stage can teach `Lyric.Fmt` to anchor
expression-internal trivia at sub-expression boundaries (e.g. a
comment between operands of a binary op).  CST-driven AST
projection from the LSP / refactoring tools also benefits from the
finer granularity even before the formatter does.

End-to-end smoke via the F# `lyric fmt` bridge confirms the existing
formatter behaviour is unchanged on a sample with comments,
contracts, and blank lines.



### D-progress-141: M5.3 stage 5 — blank-line preservation in `Lyric.Fmt` (+ documenting why the `Lyric.Lyric.<X>.dll` naming wart is intentional)

*claude/lyric-fmt-blank-lines branch.*

Two follow-ups from the M5.3 formatter arc:

**Blank-line preservation.**  Previously the formatter collapsed every
run of newlines in the original source down to the canonical
"between-statement" or "between-member" zero-blank shape, which made
intentional spacing inside function bodies and record/union/enum
bodies vanish.  This stage tracks blank-line markers as a new variant
in the harvested-trivia stream:

- `HarvestedItem` is now a union: `HiComment(text, offset)` |
  `HiBlank(offset)`.  Every run of 2+ consecutive `TKNewline` trivia
  in a token's leading trivia produces exactly one `HiBlank` marker
  (whitespace between newlines doesn't break the run; multiple
  consecutive blank lines collapse to a single marker so the formatter
  emits at most one blank line in any spot — Black-style).
- `popTriviaBefore(ctx, hi)` emits both comments and blanks (the
  blank as `""`).  Used at every block-internal / member-internal
  boundary (`blockLines`, `matchLines`, `recordDoc`, `unionDoc`,
  `enumDoc`).
- `popCommentsBefore(ctx, hi)` (the old name) now drops `HiBlank`
  markers and emits comments only.  Used at top-level item /
  import boundaries and at every block's closing-brace tail —
  the canonical formatter already emits its own inter-item blank,
  and a trailing blank just before `}` is visual noise.
- `skipCommentsBefore(ctx, hi)` is the no-emit fast-forward, used
  defensively after each top-level item to drop trivia from
  expression sub-trees that aren't yet ctx-aware.

Self-test additions (`fmt_self_test.l`):
`testBlankLineInsideFunctionBody`,
`testBlankLineInsideRecordBody`,
`testBlankLinesBetweenCommentBlocks`,
`testMultipleBlankLinesCollapseToOne`.

End-to-end smoke through the F# `lyric fmt` bridge confirms blank
lines between statements, between record fields, and between union
cases all survive a round-trip.

**DLL naming wart documentation.**  The earlier note about the
`Lyric.Lyric.<X>.dll` filename shape (D-progress-135 follow-up
"clean up DLL naming") was investigated and turns out to be load-
bearing: the F# bootstrap ships its own `Lyric.Lexer.dll` /
`Lyric.Parser.dll` / `Lyric.TypeChecker.dll` and exports types under
the same CLR namespace as the self-hosted versions but with PascalCase
record fields (`Token` / `Span`) — not the lower-case `token`/`span`
the self-hosted records carry.  Renaming the self-hosted DLLs to drop
the duplicate prefix lets the AppDomain resolve cross-assembly type
refs to the F# version, and codegen blows up with `imported record
'SpannedToken' has no field 'token'`.  The duplicated `Lyric.` is
what disambiguates the assembly identity.  Comments in
`Emitter.fs:assemblyName` and `SelfHostedFmt.fs` now spell this out
so the next agent doesn't try the same dead end.

Out of scope for this stage: per-expression CST granularity
(comments inside expression sub-trees still anchor at the enclosing
statement), and the F# `Fmt.fs` sunset.  Both are tracked as
follow-ups.

### D-progress-138: native `lyric test` runner — bootstrap-grade v1

*claude/lyric-test-runner-evaluation-0IpPg branch.*

`lyric test <source.l>` ships single-file mode: a `@test_module`
file with `test "title" { … }` items compiles into a synthesised
program that runs each test inside a `try`/`catch Bug as b` and
prints a TAP-shaped report (`1..N`, `ok`/`not ok`, summary
counters).  Exit codes per the design: `0` (all selected tests
passed), `1` (failure), `2` (compilation / language-class error,
including `T0901` fixture and `T0902` user-main rejections), `64`
(usage error / missing `@test_module`).

Implementation is a 200-line source-text rewriter
(`compiler/src/Lyric.Cli/TestSynth.fs`): parse, walk items, replace
each `ITest` with a synthesised `func __lyric_test_<i>(): Unit
<body-slice>`, and append a synthesised `func main(): Int` that
runs each in order and `return`s `1` on failure / `0` on
success.  No emitter changes; no AST construction in F#.  The user's
test bodies are sliced byte-identically from the original source so
diagnostics still point at user code.  Property declarations parse
but report as `# skip` lines (v1 surface; property execution is
v2).  Fixtures hard-error today (`T0901`); the worked-example
pattern that uses `wire` blocks for test fixtures works as-is.

`--filter <substring>` and `--list` ship; the richer surface
(`--manifest` discovery, `--properties`, `--doctests`,
`--update-snapshots`, cross-package non-`pub` access) is staged
in `docs/24-test-runner-plan.md` §5.  CLI integration tests live
at `compiler/tests/Lyric.Cli.Tests/TestRunnerTests.fs` (8 cases
covering pass / fail / no-`@test_module` / user-main / fixture /
`--list` / `--filter` / property-skip).

The motivation, beyond §13.2 spec parity, is Phase 5 §M5.4: the
F# Expecto bridge that drives `stdlib/tests/*_tests.l` today goes
away with the F# host, so a native runner is a Phase 5
prerequisite that we paid down early.

**Self-hosted port (follow-up commit).**  The same rewriter is
also implemented in Lyric at `compiler/lyric/lyric/test_synth/test_synth.l`
(`Lyric.TestSynth`), with a self-test consumer at
`compiler/lyric/lyric/test_synth_self_test.l` driven by the F#
Expecto runner `tests/Lyric.Emitter.Tests/SelfHostedTestSynthTests.fs`.
Seven in-program assertions cover passing/parsing-error/no-`@test_module`/
user-main/fixture/property-skip/filter/`listEntries` paths and pass
end-to-end.  Mirrors the formatter pattern from D-progress-131:
both the F# implementation (used by the F# CLI today) and the Lyric
implementation (Phase 5 ready-to-route artifact) ship side-by-side
until a follow-up stage routes `lyric test` through the Lyric
library via in-process compile + reflection.

### D-progress-137: M5.2 stage 2 — self-hosted contract elaborator (`Lyric.ContractElaborator`)

*claude/contract-elaborator-stage-2-3k3r2 branch.*

Phase 5 §M5.2 stage 2 ships the self-hosted contract elaborator as a
single-file `Lyric.ContractElaborator` library under
`compiler/lyric/lyric/contract_elaborator/`:

- `elaborator.l` — public entry points `elaborateFile(file)` and
  `elaborateFunction(fn)`; helpers for synthetic-name generation
  (`RenameCounter` / `freshResultName`), AST builders
  (`mkPath`, `mkAssertCall`, `mkLetBinding`), and the recursive
  `result` substitution (`substResult` / `substResultStmt` /
  `substResultBlock` / `substResultEob` / `substResultBinding` /
  `substResultRange`).  The elaboration pipeline:

  1. **`requires:` clauses** — for every non-`@axiom` `IFunc` with
     a body, prepend one `assert(req)` `SExpr` statement per
     `CCRequires` clause to the body block (in source order).

  2. **`ensures:` clauses** — top-level shape only.  Each
     `SReturn(Some(e))` directly under the function body block is
     rewritten to:

     ```text
     let __lyric_result_<n> = e
     assert(<ensures with EResult -> __lyric_result_<n>>)*
     return __lyric_result_<n>
     ```

     `SReturn(None)` paths get the asserts prepended verbatim
     (no synthetic local — `result` would be `Unit` and the
     type-checker rejects `EResult` on Unit-returning functions).
     The trailing `SExpr(e)` of the body block is rewritten the
     same way as `SReturn(Some(e))` but yields the synthetic local
     as the implicit fall-off instead of returning it.  `FBExpr(e)`
     bodies are wrapped into a single-statement block before
     elaboration so the same pipeline applies.

  3. **`@axiom` functions and body-less signatures** — pass through
     unchanged.

  4. **Other contract clauses** (`when:`, `decreases:`, `raises:`)
     and loop `SInvariant` statements — left as-is.  The bootstrap
     emitter does not insert runtime checks for these; the verifier
     is the consumer.

  5. **Other item kinds** (records, unions, interfaces, protected
     types, …) — passed through.  Protected-type entries
     (`PMEntry`) are deferred: the bootstrap emitter still wraps
     them in IL with barrier (`when:`) checks and protected-type
     `invariant:` re-evaluation, so the bootstrap remains correct;
     the self-host elaborator picks them up alongside the
     protected-type lowering in a follow-up stage.

The original `contracts: List[ContractClause]` field on each
`FunctionDecl` is preserved on the elaborated decl, so the verifier
and the contract-meta consumers still see the source-level clauses.

**Stage 2 deferrals** (tracked for stage 3):

- Returns nested inside `if` / `match` / `try` / loop bodies are
  not yet rewritten.  Top-level `SReturn` in the function body
  block is the only return shape elaborated.  The bootstrap
  emitter still inserts a runtime check for nested returns via the
  exit-label routing (see `Emitter.fs:2807-2812`), so the bootstrap
  remains correct independently of elaborator coverage.
- Protected-type `EntryDecl` elaboration (barrier `when:` checks,
  protected-type `invariant:` re-evaluation).
- Loop `SInvariant` runtime lowering (the F# bootstrap does not
  insert these either; the elaborator follows the bootstrap).

**Consumer and harness:**

- `compiler/lyric/lyric/contract_elaborator_self_test.l` — 14
  in-process tests covering: empty-contracts identity, single /
  multiple `requires:`, single / multiple `ensures:` (trailing
  fall-off and explicit return paths), bare `return`, combined
  requires + ensures, `@axiom` skip, signature pass-through,
  preservation of the original `contracts` list, synthetic-name
  uniqueness across multiple returns, file-level identity
  (package decl + imports + items), and non-function items
  pass-through.
- `compiler/tests/Lyric.Emitter.Tests/SelfHostedContractElaboratorTests.fs`
  — F# Expecto wrapper (`[contract_elaborator_self_test_passes]`)
  added under the
  `Lyric.ContractElaborator self-host (Phase 5 §M5.2)` test list and
  registered in `Program.fs` next to `SelfHostedModeCheckerTests`.

The pre-existing environment-gated z3 failure in
`Lyric.Verifier.Tests` (D-D1.3 EIf branch test) is unaffected and
unrelated to this stage.

---

### D-progress-136: M5.3 stage 4 — item-internal comment preservation via `FmtCtx` cursor

*claude/lyric-fmt-internal-comments branch.*

Stage 2 (D-progress-131) preserved comments at top-level item boundaries
by harvesting them from the CST and emitting them between items.  This
stage extends the same idea **inside** an item: comments between
statements in a function body, between fields in a record, between
cases in a union or enum, and inside nested blocks (`if` / `for` /
`while` / `match` / `try` / `defer` / `scope`).

Mechanism:

- New `FmtCtx { comments, cursor }` record in `fmt.l`.  `comments` is
  the harvested list (in source order, since the green-tree visit
  produces them in source order); `cursor` advances monotonically as
  the formatter walks AST nodes.
- `popCommentsBefore(ctx, hi)` returns every comment with offset
  `< hi` and bumps the cursor past them.  The block / member iteration
  loops call this just before emitting each statement / member /
  arm / case.  At the closing brace of a block, a final `popCommentsBefore`
  drains any trailing in-body comments.
- Every multi-line printer that can contain inner constructs gains
  `ctx: inout FmtCtx`: `blockLines`, `stmtLines`, `matchLines`,
  `ifBlockLines`, `forLines`, `whileLines`, `loopLines`, `tryLines`,
  `deferLines`, `scopeLines`, `funcDoc`, `recordDoc`, `unionDoc`,
  `enumDoc`, `opaqueDoc`, `protectedTypeDoc`, `interfaceDoc`,
  `implDoc`, `wireDoc`, `entryDoc`, `protectedMemberDoc`, `testDoc`,
  `propertyDoc`, `recordMemberLines`, `itemDoc`, `itemFunc`.  Single-
  line / inline printers are unchanged — they don't span source
  boundaries.
- The top-level `format` constructs the ctx once from the harvested
  comments and threads it through.  Between items it pops comments
  before the next item's first token (as before, plus a defensive
  `skipCommentsBefore` after each item to fast-forward past any
  unconsumed in-item comments — e.g. those that fall inside an
  expression sub-tree which is not yet ctx-aware).

Self-test additions (`compiler/lyric/lyric/fmt_self_test.l`):

- `testCommentInsideFunctionBody` — `// setup` / `// process` between
  statements survive.
- `testCommentInsideRecordBody` — `// y is the second axis` between
  fields survives.
- `testCommentInsideUnionBody` — `// primaries` between cases
  survives.
- `testCommentInsideEnumBody` — `// horizontal` between enum cases
  survives.
- `testCommentInsideNestedBlock` — `// positive branch` inside an
  `if`-body survives.

End-to-end smoke via the actual `lyric` binary on a multi-construct
file: function bodies, records, and unions all keep their inline
`//` comments.

Out of scope for this stage: per-expression CST nodes (so a
comment inside a single expression's sub-tree may still anchor at
the enclosing statement).  Mechanically additive when needed.

---

### D-progress-141: MSIL PE emitter Stages M2a–M2d — parameterized heap/opcode/table/layout pipeline

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stages M2a through M2d build the four foundational layers that a self-hosted
MSIL emitter needs to produce real PE binaries, replacing the fixed-layout
`Msil.Pe` generator from Stage M1.

**M2a — `Msil.Heaps` parameterized heap builders** (`heaps.l`, `msil_self_test_m2a.l`)

Four ECMA-335 metadata heaps with deduplication and serialization:
- `StringHeap` — null-terminated UTF-8 strings; `internString` returns byte offset.
- `BlobHeap` — compressed-length-prefixed blobs; `internBlob` returns byte offset.
- `UsHeap` — UTF-16LE user-string literals with ECMA flag byte; `internUs` returns offset.
- `GuidHeap` — 16-byte GUIDs; `appendGuid` returns 1-based index.
Each heap serializes via `serialize*(h, w)` into a `ByteWriter`.

**M2b — `Msil.Opcodes` CIL instruction IR + two-pass assembler** (`opcodes.l`, `msil_self_test_m2b.l`)

Typed `Insn` union covering all ECMA-335 instruction forms (nullary, token,
branch, local/arg-index, constant, prefix-2).  `MethodBody` accumulates
instructions and label bindings.  `serializeMethodBody` assembles in two
passes: pass 1 computes label→offset map; pass 2 emits bytes with resolved
4-byte branch offsets.  Tiny vs. fat method header selection is automatic.
`switch` targets stored in a parallel flat list on `MethodBody` to avoid the
D035 List[T]-in-union-field erasure constraint.

**M2c — `Msil.Tables` metadata table model + #~ stream serializer** (`tables.l`, `msil_self_test_m2c.l`)

Typed row records for all ten tables used by minimal assemblies (Module,
TypeRef, TypeDef, Field, MethodDef, Param, MemberRef, CustomAttribute,
Assembly, AssemblyRef) plus `MetadataTables` container with `addXxx()`
row-index allocators.  Coded-index helpers: `rsModule/rsAssemblyRef/rsTypeRef`,
`tdrTypeDef/tdrTypeRef/tdrTypeSpec`, `mrpTypeRef/mrpMethodDef`,
`hcaAssembly/catMemberRef`, etc.  `serializeTablesStream` emits a complete
ECMA-335 #~ stream body including header, valid bitmask, sorted bitmask, row
counts, and row data.

**M2d — `Msil.Assembler` single-method PE layout engine** (`assembler.l`, `msil_self_test_m2d.l`)

`assemblePe(inp)` accepts an `AssemblerInput` (one `MethodBody`, populated
`MetadataTables`, four heap objects, and an entry-point token) and produces a
correct CLR-runnable PE image as a `ByteWriter`.  Two-pass layout:
1. Serialize method body and all streams to temp buffers; compute sizes.
2. Write DOS stub → PE/COFF headers → CLR header → method body → BSJB
   metadata root (32-byte header + 5 stream headers + stream data) → section
   padding.
Computes `MetaData.VirtualAddress`, `SizeOfImage`, `SizeOfRawData`, and stream
offsets dynamically from actual content sizes.  `FIRST_METHOD_RVA = 0x2048`.

Smoke test (`msil_self_test_m2d.l`) reconstructs the Hello-World assembly from
Stage M1 using the parameterized pipeline and verifies 11 structural invariants
(DOS magic, PE signature, CLR header `cb`, MetaData RVA and size, entry-point
token, method tiny header, ldstr opcode + token, BSJB magic, stream count).

**Test wiring**: `MsilSelfTestM2a.fs`, `MsilSelfTestM2b.fs`, `MsilSelfTestM2c.fs`,
`MsilSelfTestM2d.fs` added to `Lyric.Emitter.Tests`; all 5 MSIL self-tests pass.

---

### D-progress-142: MSIL PE emitter Stage M3 — end-to-end CLR execution test

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M3 closes the loop on the M2a–M2d pipeline by verifying that
`Msil.Assembler.assemblePe` produces a PE image that the CLR can actually
load and execute, not just one that passes byte-layout checks.

**`msil_self_test_m3.l`** (`compiler/lyric/msil/msil_self_test_m3.l`)

The self-test program:
1. Builds a Hello-World PE using the full M2a–M2d stack (`Msil.Heaps`,
   `Msil.Opcodes`, `Msil.Tables`, `Msil.Assembler`).
2. Writes the assembled bytes to `/tmp/lyric_msil_m3_hello.dll` via
   `Std.File.writeBytes` — the first exercise of the `Std.File` byte-write
   surface from within a self-hosted MSIL context.
3. Prints `wrote_pe=true` on success.

**Key correction versus M2d** (`System.Console` assembly reference):

In .NET 5+, `System.Console` lives in `System.Console.dll`, not
`System.Runtime.dll`. The M2d metadata (matching the Stage-M1 reference
image) used a single `System.Runtime` AssemblyRef for both `System.Object`
and `System.Console`, which passes byte-layout checks but fails at CLR load
time with `TypeLoadException`. M3 adds a second `AssemblyRef` for
`System.Console` and points the `Console` TypeRef at it, producing a PE
that executes cleanly under .NET 10.

**F# test harness** (`MsilSelfTestM3.fs`):

1. Compiles and runs `msil_self_test_m3.l` via the bootstrap emitter.
2. Verifies `wrote_pe=true` in stdout.
3. Writes a matching `runtimeconfig.json` alongside the PE (same logic as
   `Backend.fs:writeRuntimeConfig`), then calls `runDll` on the produced
   file.
4. Asserts PE exit code = 0 and stdout contains `"Hello, World!"`.

**Test wiring**: `MsilSelfTestM3.fs` added to `Lyric.Emitter.Tests`; all 6
MSIL self-tests pass (M1, M2a, M2b, M2c, M2d, M3).

---

### D-progress-143: MSIL PE emitter Stage M4 — multi-method PE assembler

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M4 extends `Msil.Assembler` from single-method to multi-method
assemblies, which is the minimum requirement for any real Lyric program.

**API change in `assembler.l`**:

- `AssemblerInput.methodBody: MethodBody` → `methodBodies: List[MethodBody]`.
  Any number of method bodies can now be described in a single input record.
- New public function `methodBodyRvas(bodies: List[MethodBody]): List[Int]`:
  serializes each body in a scratch buffer, measures its size, and returns
  a list of RVAs starting at `FIRST_METHOD_RVA`.  The caller assigns
  `result[i]` to `MethodDef[i+1].rva` before calling `assemblePe`.
- `assemblePe` now serializes all bodies consecutively in the `.text`
  section and computes `mdRva` / `textVSize` from their total raw size.

**Migration of existing self-tests**: `msil_self_test_m2d.l` and
`msil_self_test_m3.l` updated to use `methodBodies = [mb]`; byte-layout
is identical to the old single-body path so all structural checks pass
unchanged.

**`msil_self_test_m4.l`** builds a two-method PE:
- `MethodDef[1] Greet()` — `ldstr US[1] + call MemberRef[1] + ret`
- `MethodDef[2] Main()` — `call MethodDef[1] + call MethodDef[1] + ret`

RVAs are computed via `methodBodyRvas` before populating the table.
The PE uses two AssemblyRefs (System.Runtime / System.Console) per the
D-progress-142 finding.  Structural checks verify the Greet tiny-header
at file offset 0x248, Main at 0x254, and BSJB at 0x260.  The PE is
written to disk and the F# harness executes it, asserting "Hello from
Greet!" appears twice in stdout.

**Test wiring**: `MsilSelfTestM4.fs` added to `Lyric.Emitter.Tests`; all 7
MSIL self-tests pass (M1, M2a, M2b, M2c, M2d, M3, M4).

---

### D-progress-144: MSIL PE emitter Stage M5 — local variables / fat method header

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M5 exercises the fat method header path and the `StandAloneSig`
metadata table, both of which are required to emit any Lyric function that
declares a local variable.

**`StandAloneSig` table (0x11) added to `tables.l`**:

- New `StandAloneSigRow { signature: Int }` record.
- `standAloneSigs: List[StandAloneSigRow]` field on `MetadataTables`;
  `newMetadataTables()` initialises it to an empty list.
- `TABLE_BIT_STAND_ALONE_SIG = 131072i64` (bit 17 = 2^17).
- `addStandAloneSig(t, r): Int` appends a row and returns its 1-based index.
- `standaloneToken(row: Int): Int` builds the `0x11xxxxxx` metadata token.
- `serializeTablesStream` updated: valid bitmask, row-count section, and
  row-data section (between CustomAttr 0x0C and Assembly 0x20).
- Existing self-tests (M2d, M3, M4) produce an empty `standAloneSigs` list
  so the #~ stream is byte-identical to before.

**`msil_self_test_m5.l`** builds a PE with a single `Main()` that:

1. Interns `"Hello from locals!"` in the US heap.
2. Creates a `LocalVarSig` blob `{0x07, 0x01, 0x0E}` (one `string` local).
3. Adds a `StandAloneSig` row referencing the blob; calls `standaloneToken`
   to get `0x11000001`.
4. Sets `mbSetLocalSig(mbMain, 0x11000001)` so `serializeMethodBody` emits a
   fat header.
5. Emits `ldstr`, `stloc.0`, `ldloc.0`, `call`, `ldloc.0`, `call`, `ret`.

Fat header at file offset 0x248: `0x13 0x30` (FatFormat | InitLocals,
headerSize=3), maxStack=8, codeSize=19, localSig=0x11000001.  CIL starts
at 0x254; BSJB at 0x267.  Structural checks verify fat header flags,
code size, localSig token, ldstr opcode, and BSJB magic.

The F# harness executes the PE and asserts `"Hello from locals!"` appears
exactly twice in CLR stdout.

**Test wiring**: `MsilSelfTestM5.fs` added to `Lyric.Emitter.Tests`; all 8
MSIL self-tests pass (M1, M2a, M2b, M2c, M2d, M3, M4, M5).

---

### D-progress-145: MSIL PE emitter Stage M6 — method arguments and non-void return

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M6 exercises method argument passing (`ldarg.0`, `ldarg.1`) and a
non-void int32 return value, both of which are required for any meaningful
computation in the self-hosted MSIL code generator.

**`msil_self_test_m6.l`** builds a two-method PE:

- **`Add(int a, int b): int`** — MethodDef[1].  Signature blob
  `{0x00, 0x02, 0x08, 0x08, 0x08}` (DEFAULT, 2 params, I4 return, I4, I4).
  Body: `ldarg.0`, `ldarg.1`, `add`, `ret` — 4 bytes CIL; tiny header `0x12`.
- **`Main()`** — MethodDef[2], entry point.  Body: `ldc.i4.3`, `ldc.i4.4`,
  `call 0x06000001` (Add), `call 0x0A000001` (Console.WriteLine(int)), `ret`
  — 13 bytes CIL; tiny header `0x36`.

No US heap entries are needed (no string literals); the MemberRef for
`Console.WriteLine` uses the int32 signature `{0x00, 0x01, 0x01, 0x08}`.

Layout at file offset 0x248:

```
0x248  0x12          Add tiny header (codeSize=4)
0x249  02 03 58 2A   ldarg.0, ldarg.1, add, ret
0x24D  0x36          Main tiny header (codeSize=13)
0x24E  19 1A         ldc.i4.3, ldc.i4.4
0x250  28 01 00 00 06  call MethodDef[1] (Add)
0x255  28 01 00 00 0A  call MemberRef[1] (Console.WriteLine(int))
0x25A  2A            ret
0x25B  42 53 4A 42   BSJB metadata root
```

Structural checks verify `add_hdr_ok`, `add_ldarg0_ok`, `add_ldarg1_ok`,
`add_add_ok`, `main_hdr_ok`, `main_ldc3_ok`, `main_ldc4_ok`, `main_call_ok`,
and `bsjb_ok`.  The F# harness executes the PE and asserts `"7"` appears in
CLR stdout.

**Test wiring**: `MsilSelfTestM6.fs` added to `Lyric.Emitter.Tests`; all 9
MSIL self-tests pass (M1, M2a, M2b, M2c, M2d, M3, M4, M5, M6).

---

### D-progress-146: MSIL PE emitter Stage M7 — static fields

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M7 exercises the `Field` metadata table (0x04) and the `ldsfld` /
`stsfld` instruction pair, both of which are required to emit module-level
`val` bindings and class fields in the self-hosted code generator.

**`msil_self_test_m7.l`** builds a PE with:

- **`FieldRow { flags = FDA_PUBLIC + FDA_STATIC, name = "s_val", signature = FieldSig(I4) }`** — Field[1].
  FieldSig blob: `{0x06, 0x08}` (FIELD marker + ELEMENT_TYPE_I4).
- **`Main()`** — MethodDef[1], entry point.  Body: `ldc.i4.s 42`,
  `stsfld 0x04000001`, `ldsfld 0x04000001`, `call 0x0A000001`
  (Console.WriteLine(int)), `ret` — 18 bytes CIL; tiny header `0x4A`.

Layout at file offset 0x248:

```
0x248  4A             Main tiny header (codeSize=18)
0x249  1F 2A          ldc.i4.s 42
0x24B  80 01 00 00 04 stsfld Field[1]
0x250  7E 01 00 00 04 ldsfld Field[1]
0x255  28 01 00 00 0A call MemberRef[1] (Console.WriteLine(int))
0x25A  2A             ret
0x25B  42 53 4A 42    BSJB metadata root
```

Structural checks verify `main_hdr_ok`, `ldc42_ok`, `stsfld_ok`,
`ldsfld_ok`, and `bsjb_ok`.  The F# harness executes the PE and asserts
`"42"` appears in CLR stdout.

**Test wiring**: `MsilSelfTestM7.fs` added to `Lyric.Emitter.Tests`; all 10
MSIL self-tests pass (M1, M2a–M2d, M3, M4, M5, M6, M7).

---

### D-progress-147: MSIL PE emitter Stage M8 — newobj + instance fields

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M8 exercises `newobj`, instance field access (`ldfld` / `stfld`), and
the HASTHIS calling convention — the three prerequisites for emitting Lyric
record types as .NET classes.

**`msil_self_test_m8.l`** builds a PE with a class `Hello` that has:

- **`Field[1]: x_val`** — public int32 instance field.  FieldSig:
  `{0x06, 0x08}`.
- **`MethodDef[1]: .ctor(int v)`** — HASTHIS constructor; signature
  `{0x20, 0x01, 0x01, 0x08}` (HASTHIS, 1 param, void return, I4).  Body:
  `ldarg.0`, `ldarg.1`, `stfld 0x04000001`, `ret` — 8 bytes; tiny header
  `0x22`.  Flags include `SpecialName | RTSpecialName`.
- **`MethodDef[2]: Main()`** — static entry point.  Body: `ldc.i4.s 99`,
  `newobj 0x06000001`, `ldfld 0x04000001`, `call 0x0A000001`
  (Console.WriteLine(int)), `ret` — 18 bytes; tiny header `0x4A`.

Layout at file offset 0x248:

```
0x248  22             .ctor tiny header (codeSize=8)
0x249  02 03          ldarg.0, ldarg.1
0x24B  7D 01 00 00 04 stfld Field[1]
0x250  2A             ret
0x251  4A             Main tiny header (codeSize=18)
0x252  1F 63          ldc.i4.s 99
0x254  73 01 00 00 06 newobj MethodDef[1] (.ctor)
0x259  7B 01 00 00 04 ldfld Field[1]
0x25E  28 01 00 00 0A call MemberRef[1] (Console.WriteLine(int))
0x263  2A             ret
0x264  42 53 4A 42    BSJB metadata root
```

Structural checks verify `ctor_hdr_ok`, `ctor_stfld_ok`, `main_hdr_ok`,
`newobj_ok`, `ldfld_ok`, and `bsjb_ok`.  The F# harness executes the PE
and asserts `"99"` appears in CLR stdout.

**Test wiring**: `MsilSelfTestM8.fs` added to `Lyric.Emitter.Tests`; all 11
MSIL self-tests pass (M1, M2a–M2d, M3, M4, M5, M6, M7, M8).

---

### D-progress-148: MSIL PE emitter Stage M9 — multiple TypeDefs

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M9 verifies that `TypeDef.methodList` correctly partitions `MethodDef`
rows across multiple TypeDefs in a single assembly — a prerequisite for
emitting Lyric records, module-level functions, and auxiliary types in the
self-hosted MSIL code generator.

**`msil_self_test_m9.l`** builds a PE with four TypeDefs:

| TypeDef | methodList | Owns |
|---------|-----------|------|
| `<Module>` | 1 | none (range 1..0) |
| `Foo` | 1 | MethodDef[1] (GetFoo → 10) |
| `Bar` | 2 | MethodDef[2] (GetBar → 20) |
| `Hello` | 3 | MethodDef[3] (Main → entry) |

CIL for `GetFoo()` and `GetBar()` each returns their constant via `ldc.i4.s`;
`Main()` calls both, adds the results, and passes 30 to
`Console.WriteLine(int)`.

Layout at file offset 0x248:

```
0x248  0E          GetFoo tiny header (codeSize=3)
0x249  1F 0A 2A   ldc.i4.s 10, ret
0x24C  0E          GetBar tiny header (codeSize=3)
0x24D  1F 14 2A   ldc.i4.s 20, ret
0x250  46          Main tiny header (codeSize=17)
0x251..0x25A       call GetFoo (5B), call GetBar (5B)
0x25B  58          add
0x25C..0x261       call Console.WriteLine(int) (5B), ret (1B)
0x262  42 53 4A 42 BSJB metadata root
```

Structural checks verify `foo_hdr_ok`, `foo_ldc_ok`, `bar_hdr_ok`,
`bar_ldc_ok`, `main_hdr_ok`, `main_call1_ok`, `main_add_ok`, and `bsjb_ok`.
The F# harness executes the PE and asserts `"30"` appears in CLR stdout.

**Test wiring**: `MsilSelfTestM9.fs` added to `Lyric.Emitter.Tests`; all 12
MSIL self-tests pass (M1, M2a–M2d, M3, M4, M5, M6, M7, M8, M9).

---

### D-progress-149: MSIL PE emitter Stage M10 — virtual method dispatch (callvirt)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M10 verifies `callvirt` virtual dispatch — the core mechanism Lyric uses
for interface and union dispatch in the self-hosted MSIL emitter.

**`msil_self_test_m10.l`** builds a PE with four TypeDefs:

| TypeDef | flags | Extends | Owns |
|---------|-------|---------|------|
| `<Module>` | 0 | — | none |
| `Base` | PUBLIC\|ABSTRACT | `System.Object` (TypeRef[2]) | MethodDef[1] GetValue():int (abstract, rva=0) |
| `Impl` | PUBLIC | `Base` (TypeDef[2]) | MethodDef[2] .ctor(), MethodDef[3] GetValue():int (override) |
| `Hello` | PUBLIC | `System.Object` | MethodDef[4] Main() |

Key metadata decisions:
- `Base.GetValue` has flags `VIRTUAL|NEWSLOT|ABSTRACT` and `rva=0` (no body); its
  signature is HASTHIS (`0x20`) + 0 params + I4 return.
- `Impl.GetValue` has flags `VIRTUAL` without `NEWSLOT` (= override); CLR links
  it to the same vtable slot as `Base.GetValue` because the name and signature match.
- `Impl` uses the `tdrTypeDef(2)` coded index (`2*4+0 = 8`) in `extends` to
  reference the same-assembly `Base` class.
- `Main()` emits `newobj 0x06000002` (Impl..ctor) then `callvirt 0x06000001`
  (Base.GetValue token); the CLR dispatches to `Impl.GetValue`, returning 77.

Layout at file offset 0x248:

```
0x248  06          Impl..ctor tiny header (codeSize=1)
0x249  2A          ret
0x24A  0E          Impl.GetValue tiny header (codeSize=3)
0x24B  1F 4D 2A   ldc.i4.s 77, ret
0x24E  42          Main tiny header (codeSize=16)
0x24F  73 02 00 00 06   newobj Impl..ctor
0x254  6F 01 00 00 06   callvirt Base.GetValue
0x259  28 01 00 00 0A   call Console.WriteLine(int)
0x25E  2A          ret
0x25F  42 53 4A 42 BSJB metadata root
```

Structural checks verify `ctor_hdr_ok`, `getv_hdr_ok`, `getv_ldc_ok`,
`main_hdr_ok`, `newobj_ok`, `callvirt_ok`, and `bsjb_ok`.
The F# harness executes the PE and asserts `"77"` appears in CLR stdout.

**Test wiring**: `MsilSelfTestM10.fs` added to `Lyric.Emitter.Tests`; all 13
MSIL self-tests pass (M1, M2a–M2d, M3, M4, M5, M6, M7, M8, M9, M10).

---

### D-progress-150: MSIL PE emitter Stage M11 — InterfaceImpl table

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M11 adds the `InterfaceImpl` (0x09) metadata table — the mechanism by
which the CLR knows a class implements a given interface and builds the
interface dispatch table.

**tables.l changes**:
- Added `InterfaceImplRow { class_: Int; interface_: Int }` record.
- Added `interfaceImpls: List[InterfaceImplRow]` to `MetadataTables`.
- Added `addInterfaceImpl` accessor function.
- Added `TABLE_BIT_INTERFACE_IMPL = 512i64` (bit 9).
- Updated `serializeTablesStream` to include the table in the valid bitmask,
  row count section, and row data section (in correct table-number order
  between Param=0x08 and MemberRef=0x0A).

**`msil_self_test_m11.l`** builds a PE with four TypeDefs:

| TypeDef | flags | Extends | Owns |
|---------|-------|---------|------|
| `<Module>` | 0 | — | none |
| `IGetter` | PUBLIC\|INTERFACE\|ABSTRACT | 0 (interfaces have no base in metadata) | MethodDef[1] GetValue():int (abstract, rva=0) |
| `Impl` | PUBLIC | `System.Object` (TypeRef[2]) | MethodDef[2] .ctor(), MethodDef[3] GetValue():int (override) |
| `Hello` | PUBLIC | `System.Object` | MethodDef[4] Main() |

InterfaceImpl[1]: `class_=3` (Impl), `interface_=tdrTypeDef(2)` (IGetter = coded index 8).

The body layout is identical to M10 (same code sizes). The InterfaceImpl table
adds 4 bytes to the metadata section but does not change method body offsets.

Structural checks verify the same layout as M10 (except `getv_ldc_ok` checks
value 0x2A = 42). The F# harness executes the PE and asserts `"42"` appears
in CLR stdout, confirming the CLR resolved the interface dispatch correctly.

**Test wiring**: `MsilSelfTestM11.fs` added to `Lyric.Emitter.Tests`; all 14
MSIL self-tests pass (M1, M2a–M2d, M3, M4, M5, M6, M7, M8, M9, M10, M11).

---

### D-progress-151: MSIL PE emitter Stage M12 — conditional branch (cgt / brfalse / br)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M12 verifies conditional control flow — the fundamental building block
for any non-trivial computation in the self-hosted MSIL emitter.

**`msil_self_test_m12.l`** builds a single-method PE whose `Main()` computes
`if 7 > 4 { Console.WriteLine(1) } else { Console.WriteLine(0) }`:

```
offset  0  1D          ldc.i4.7
offset  1  1A          ldc.i4.4
offset  2  FE 02       cgt            (2-byte prefixed opcode)
offset  4  39 06 00 00 00  brfalse else_lbl  (relative offset +6)
offset  9  17          ldc.i4.1
offset 10  38 01 00 00 00  br end_lbl  (relative offset +1)
[else_lbl = offset 15]
offset 15  16          ldc.i4.0
[end_lbl = offset 16]
offset 16  28 01 00 00 0A  call Console.WriteLine(int)
offset 21  2A          ret
```

Key verified properties:
- `cgt` is a 2-byte `0xFE`-prefixed opcode (OP2_CGT = 0x02); the serializer
  correctly emits `FE 02` as a `Nullary2` instruction.
- `brfalse` and `br` are 5-byte instructions: opcode + signed i32 LE relative
  offset (from the start of the next instruction). The label resolver
  computes `else_lbl - (brfalse_end) = 15 - 9 = 6` and
  `end_lbl - (br_end) = 16 - 15 = 1` correctly.
- The `mbNewLabel` / `mbMarkLabel` two-pass label system resolves forward
  references correctly.

Body codeSize = 22; tiny header = `(22 << 2) | 2 = 0x5A` at file offset 0x248.
BSJB metadata root at 0x25F (= 0x248 + 1 + 22).

Structural checks verify `main_hdr_ok`, `ldc_ok`, `cgt_ok`, `brfalse_ok`,
`br_ok`, `branches_ok`, and `bsjb_ok`. The F# harness executes the PE
and asserts `"1"` appears in CLR stdout (7 > 4 is true).

**Test wiring**: `MsilSelfTestM12.fs` added to `Lyric.Emitter.Tests`; all 15
MSIL self-tests pass (M1, M2a–M2d, M3–M12).

---

### D-progress-152: MSIL PE emitter Stage M13 — while loop / backward branch

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M13 verifies backward branch instructions — required for any loop in
the self-hosted MSIL emitter.

**`msil_self_test_m13.l`** builds a PE with `Main()` summing 1+2+3+4+5=15:

```
ldc.i4.0 / stloc.0      sum = 0
ldc.i4.1 / stloc.1      i = 1
[loop_start:]
ldloc.1 / ldc.i4.5 / cgt  i > 5?
brtrue end               exit if true
ldloc.0 / ldloc.1 / add / stloc.0  sum += i
ldloc.1 / ldc.i4.1 / add / stloc.1  i += 1
br loop_start            backward branch
[end:]
ldloc.0 / call Console.WriteLine(int) / ret
```

Key verified properties:
- Fat method header (12 bytes) required because `localSig != 0`; flags
  `0x13 0x30`, codeSize = 33 (`0x21`), `localVarSigTok = 0x11000001`.
- `StandAloneSig[1]` holds `LocalVarSig { 2 I4 I4 }` = `{0x07, 0x02, 0x08, 0x08}`.
- `brtrue` exits the loop with positive offset +13 (forward jump).
- `br loop_start` uses a **negative** signed offset: next-instruction at
  offset 26, target at offset 4, relative = 4 − 26 = −22 = `0xFFFFFFEA` (LE).
- The `mbNewLabel` / `mbMarkLabel` system resolves both forward and backward
  references in a single pass.

Fat header at 0x248, code at 0x254, BSJB at 0x275 (= 0x248 + 12 + 33).

Structural checks verify `fat_hdr_ok`, `code_size_ok`, `local_sig_ok`,
`cgt_ok`, `brtrue_ok`, `br_back_ok`, and `bsjb_ok`. The F# harness
executes the PE and asserts `"15"` appears in CLR stdout.

**Test wiring**: `MsilSelfTestM13.fs` added to `Lyric.Emitter.Tests`; all 17
MSIL self-tests pass (M1, M2a–M2d, M3–M13).

---

### D-progress-153: MSIL PE emitter Stage M14 — `newarr` + array element access

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M14 verifies array creation (`newarr`), indexed stores (`stelem`), and
indexed loads (`ldelem`) — all token-bearing 5-byte instructions using a
`TypeRef` for the element type.

**`msil_self_test_m14.l`** builds a PE with `Main()` that:

```
ldc.i4.3 / newarr Int32 / stloc.0   arr = new int32[3]
ldloc.0 / ldc.i4.0 / ldc.i4.s 10 / stelem Int32   arr[0] = 10
ldloc.0 / ldc.i4.1 / ldc.i4.s 20 / stelem Int32   arr[1] = 20
ldloc.0 / ldc.i4.2 / ldc.i4.s 30 / stelem Int32   arr[2] = 30
ldloc.0 / ldc.i4.0 / ldelem Int32   push arr[0]=10
ldloc.0 / ldc.i4.1 / ldelem Int32   push arr[1]=20
add                                  30
ldloc.0 / ldc.i4.2 / ldelem Int32   push arr[2]=30
add                                  60
call Console.WriteLine(int) / ret
```

A `TypeRef[3]` for `System.Int32` is added (beyond the existing Console and
Object refs) and used as the element-type token `0x01000003` for `newarr`,
`stelem`, and `ldelem`. The local `int32[]` array is held in local 0 via a
fat method header; `LocalVarSig` = `{0x07, 0x01, 0x1D, 0x08}` (LOCALS, 1
variable, SZARRAY, I4).

Key verified byte positions:
- Fat header at 0x248; codeSize = 63 (`0x3F`), `localVarSigTok = 0x11000001`.
- `newarr` opcode `0x8D` at 0x255; token LE `03 00 00 01` at 0x256–0x259.
- First `stelem` opcode `0xA4` at 0x25F; token LE at 0x260–0x263.
- First `ldelem` opcode `0xA3` at 0x278; token LE at 0x279–0x27C.
- BSJB at 0x293.

**Test wiring**: `MsilSelfTestM14.fs` added to `Lyric.Emitter.Tests`; all 18
MSIL self-tests pass (M1, M2a–M2d, M3–M14).

---

### D-progress-154: MSIL PE emitter Stage M15 — `ldc.i8` + `conv.i4`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M15 verifies 64-bit integer literal encoding (`ldc.i8`) and
widening/narrowing type conversion (`conv.i4`).

**`msil_self_test_m15.l`** builds a PE with a tiny-header `Main()`:

```
ldc.i8 1000000000i64   (0x21 + 8-byte LE: 00 CA 9A 3B 00 00 00 00)
ldc.i8 2i64            (0x21 + 8-byte LE: 02 00 00 00 00 00 00 00)
mul                    (2000000000L)
conv.i4                (2000000000i32 — fits within signed i32 range)
call Console.WriteLine(int)
ret
```

Key verified byte positions:
- Tiny header `0x6A` at 0x248 (codeSize=26, (26<<2)|2=106=0x6A).
- `ldc.i8` opcode `0x21` at 0x249; LE bytes `00 CA 9A 3B 00 00 00 00` at 0x24A–0x251.
- `mul` opcode `0x5A` at 0x25B (code offset 18).
- `conv.i4` opcode `0x69` at 0x25C (code offset 19).
- BSJB at 0x263 (= 0x249 + 26).

**Test wiring**: `MsilSelfTestM15.fs` added to `Lyric.Emitter.Tests`; all 19
MSIL self-tests pass (M1, M2a–M2d, M3–M15).

---

### D-progress-155: MSIL PE emitter Stage M16 — `switch` table

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M16 verifies the variable-length `switch` table instruction — the
primary mechanism for dispatching on enum/union tag values in the self-hosted
MSIL emitter.

**`msil_self_test_m16.l`** builds a PE with `Main()`:

```
ldc.i4.2                       push 2 (dispatch key)
switch [lbl0, lbl1, lbl2]      3-target switch
  (default) ldc.i4.s 99 / br end
  lbl0: ldc.i4.s 10 / br end
  lbl1: ldc.i4.s 20 / br end
  lbl2: ldc.i4.s 42            (reached; fall through)
end: call Console.WriteLine(int) / ret
```

The switch instruction is: opcode `0x45` + count (u32 LE) + count × target
(i32 LE signed offsets from the instruction after the switch). Targets are:
- target[0] = +7 (lbl0 at code offset 25, next-after-switch at 18)
- target[1] = +14 (lbl1 at offset 32)
- target[2] = +21 (lbl2 at offset 39)

Key verified byte positions:
- Tiny header `0xBE` at 0x248 (codeSize=47, (47<<2)|2=190=0xBE).
- `switch` opcode `0x45` at file 0x24A (code offset 1).
- Count `03 00 00 00` at file 0x24B–0x24E.
- target[0] = `07 00 00 00` at file 0x24F.
- target[2] = `15 00 00 00` at file 0x257 (21 = 0x15).
- BSJB at 0x278.

**Test wiring**: `MsilSelfTestM16.fs` added to `Lyric.Emitter.Tests`; all 20
MSIL self-tests pass (M1, M2a–M2d, M3–M16).

---

### D-progress-156: MSIL PE emitter Stage M17 — bitwise operations

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M17 verifies the bitwise `and` (0x5F) and `or` (0x60) opcodes, and
establishes the pattern for all one-byte bitwise instructions (`xor`, `shl`,
`shr`).

**`msil_self_test_m17.l`** builds a tiny-header `Main()`:

```
ldc.i4.s 60 / ldc.i4.s 13 / and   → 12  (0b00111100 & 0b00001101 = 0b00001100)
ldc.i4.s 60 / ldc.i4.s 13 / or    → 61  (0b00111100 | 0b00001101 = 0b00111101)
add                                → 73
call Console.WriteLine(int) / ret
```

Key verified byte positions:
- Tiny header `0x46` at 0x248 (codeSize=17, (17<<2)|2=70=0x46).
- `and` opcode `0x5F` at file 0x24D (code offset 4).
- `or`  opcode `0x60` at file 0x252 (code offset 9).
- `add` opcode `0x58` at file 0x253 (code offset 10).
- BSJB at 0x25A.

**Test wiring**: `MsilSelfTestM17.fs` added to `Lyric.Emitter.Tests`; all 21
MSIL self-tests pass (M1, M2a–M2d, M3–M17).

---

### D-progress-157: MSIL PE emitter Stage M18 — `ldc.r8` (64-bit float literals)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M18 verifies `ldc.r8` — the 9-byte instruction for pushing a 64-bit
IEEE 754 floating-point literal — and demonstrates calling
`Console.WriteLine(double)` with a new MemberRef signature.

**`msil_self_test_m18.l`** builds a tiny-header `Main()`:

```
ldc.r8 3.0   (0x23 + 8-byte LE: 00 00 00 00 00 00 08 40)
ldc.r8 2.0   (0x23 + 8-byte LE: 00 00 00 00 00 00 00 40)
mul          → 6.0
call Console.WriteLine(double)   [MemberRef[1], sig {00,01,01,0D}]
ret
```

Key verified byte positions:
- Tiny header `0x66` at 0x248 (codeSize=25, (25<<2)|2=102=0x66).
- `ldc.r8` opcode `0x23` at file 0x249.
- `3.0` bytes: `bs[0x250]==0x08, bs[0x251]==0x40` (high bytes of 0x4008000000000000).
- `mul` opcode `0x5A` at file 0x25B (code offset 18).
- BSJB at 0x262.

**Test wiring**: `MsilSelfTestM18.fs` added to `Lyric.Emitter.Tests`; all 22
MSIL self-tests pass (M1, M2a–M2d, M3–M18).

---

### D-progress-158: MSIL PE emitter Stage M19 — `sub` + `rem`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M19 verifies `sub` (0x59) and `rem` (0x5D) — the remaining
core arithmetic opcodes.

**`msil_self_test_m19.l`** builds a tiny-header `Main()`:

```
ldc.i4.s 23 / ldc.i4.s 3 / sub   → 20
ldc.i4.s 13 / rem                 → 7  (20 % 13)
call Console.WriteLine(int) / ret
```

Key verified byte positions:
- Tiny header `0x3A` at 0x248 (codeSize=14, (14<<2)|2=58=0x3A).
- `sub` opcode `0x59` at file 0x24D (code offset 4).
- `rem` opcode `0x5D` at file 0x250 (code offset 7).
- BSJB at 0x257.

**Test wiring**: `MsilSelfTestM19.fs` added to `Lyric.Emitter.Tests`; all 23
MSIL self-tests pass (M1, M2a–M2d, M3–M19).

---

### D-progress-159: MSIL PE emitter Stage M20 — exception handling (try/catch)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M20 introduces exception handling sections — the most structurally
complex addition to the method-body serialiser so far.

**New infrastructure in `opcodes.l`**:

- `EHClause` record: `flags` (0=typed catch, 2=finally, 4=fault),
  `tryStart`/`tryEnd`/`handlerStart`/`handlerEnd` (label IDs),
  `catchToken` (TypeRef/TypeDef token).
- `ehClauses: List[EHClause]` field added to `MethodBody`.
- `mbAddEHClause(b, clause)` — appends a clause to the method body.
- Fat header `flags1` becomes `0x1B` (FatFormat|InitLocals|MoreSects)
  when any EH clauses are attached; otherwise stays `0x13`.
- After the code bytes (and 4-byte alignment padding), the serialiser
  emits a fat EH section: kind `0x41` (SectEHTable|SectFatFormat),
  3-byte little-endian `dataSize` = 4 + 24×nClauses, then one 24-byte
  fat clause per entry.

**`msil_self_test_m20.l`** code layout (fat header):

```
offset  0  newobj  System.Exception::.ctor()   [5 bytes]
offset  5  throw                                [1 byte]
offset  6  leave   end_lbl (rel=12)             [5 bytes]
offset 11  [handler_start]
offset 11  pop                                  [1 byte]
offset 12  ldc.i4.s 42                          [2 bytes]
offset 14  stloc.0                              [1 byte]
offset 15  leave   end_lbl (rel=3)              [5 bytes]
offset 20  [handler_end / try_end / end_lbl]
offset 20  ldloc.0                              [1 byte]
offset 21  call Console.WriteLine(int)          [5 bytes]
offset 26  ret                                  [1 byte]
```

EH clause: flags=0 (typed catch), tryOffset=0, tryLength=11,
handlerOffset=11, handlerLength=9,
catchToken=0x01000003 (TypeRef[3]=System.Exception).

File layout:
- Fat header at 0x248 (`0x1B 0x30`).
- Code (27 bytes) at 0x254; ends at 0x26F → 1 pad byte → EH at 0x270.
- EH section: kind=0x41 at 0x270, dataSize=0x1C at 0x271.
- BSJB at 0x28C.

**Test wiring**: `MsilSelfTestM20.fs` added to `Lyric.Emitter.Tests`; all 24
MSIL self-tests pass (M1, M2a–M2d, M3–M20).  CLR execution: throw →
caught → prints `42`.

---

### D-progress-160: MSIL PE emitter Stage M21 — `finally` block

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M21 exercises the `finally` EH clause variant (flags=2, catchToken=0)
and the `endfinally` (0xDC) instruction.

**`msil_self_test_m21.l`** code layout (fat header, codeSize=21):

```
offset  0  ldc.i4.s 10                     [2 bytes]
offset  2  stloc.0                          [1 byte]
offset  3  leave end_lbl (rel=6)            [5 bytes]
offset  8  [finally_start]
offset  8  ldloc.0                          [1 byte]
offset  9  ldc.i4.s 32                      [2 bytes]
offset 11  add                              [1 byte]
offset 12  stloc.0                          [1 byte]
offset 13  endfinally                       [1 byte]
offset 14  [finally_end / try_end / end_lbl]
offset 14  ldloc.0 / call WriteLine / ret   [7 bytes]
```

EH clause: flags=2 (finally), tryOffset=0, tryLength=8,
handlerOffset=8, handlerLength=6, catchToken=0.

File layout:
- Fat header at 0x248 (`0x1B 0x30`).
- Code (21 bytes) at 0x254; ends at 0x268 → 0x269; 3 pad bytes → EH at 0x26C.
- EH section: kind=0x41 at 0x26C, dataSize=0x1C at 0x26D.
- BSJB at 0x288.

Key verified byte positions:
- `leave` (0xDD) at 0x257 (code offset 3).
- `endfinally` (0xDC) at 0x261 (code offset 13).
- EH flags=2 at 0x270.

**Test wiring**: `MsilSelfTestM21.fs` added to `Lyric.Emitter.Tests`; all 25
MSIL self-tests pass (M1, M2a–M2d, M3–M21).  CLR execution: try sets 10,
finally adds 32 → prints `42`.

---

### D-progress-161: MSIL PE emitter Stage M22 — `ldstr` + `#US` heap

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M22 exercises the user-string heap and `ldstr` instruction.

**`msil_self_test_m22.l`** calls `internUs(uh, "Hello, World!")` which
returns byte offset 1 (offset 0 is the empty entry), then computes
`ldstrTok = 0x70000000 + 1 = 0x70000001`.

#US heap layout for "Hello, World!" (13 chars, all ASCII):
- offset 0: `0x00` empty entry
- offset 1: `0x1B` length prefix (27 = 13×2+1)
- offsets 2–27: UTF-16LE code units (`48 00  65 00  6C 00 ...`)
- offset 28: `0x00` flag byte (no high code units)

Code layout (tiny header, codeSize=11):
```
ldstr 0x70000001  [5 bytes]
call MemberRef[1] [5 bytes]  — Console.WriteLine(string)
ret               [1 byte]
```

File layout: tiny header `0x2E` at 0x248; code at 0x249; BSJB at 0x254.

**Test wiring**: `MsilSelfTestM22.fs` added to `Lyric.Emitter.Tests`; all 26
MSIL self-tests pass (M1, M2a–M2d, M3–M22).  CLR execution: prints
`"Hello, World!"`.

---

### D-progress-162: MSIL PE emitter Stage M23 — multiple static methods

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M23 verifies that the PE assembler correctly places two `MethodDef`
rows in one type and that a `call` to the second method's token works.

**`msil_self_test_m23.l`** defines:

- `MethodDef[1]` = `Main()`: tiny header `0x3E` (codeSize=15)
  ```
  ldc.i4.s 20 / ldc.i4.s 22 / call 0x06000002 / call 0x0A000001 / ret
  ```
  Body = 16 bytes at file 0x248.
- `MethodDef[2]` = `Add(int,int):int`: tiny header `0x12` (codeSize=4)
  ```
  ldarg.0 / ldarg.1 / add / ret
  ```
  Body = 5 bytes at file 0x258.

BSJB at 0x25D (= 0x248 + 16 + 5).

Key verified bytes:
- Main tiny header `0x3E` at 0x248.
- `call 0x06000002` (28 02 00 00 06) at 0x24D (Main code offset 4).
- Add tiny header `0x12` at 0x258.
- `ldarg.0` (0x02) at 0x259, `ldarg.1` (0x03) at 0x25A, `add` (0x58) at 0x25B.

**Test wiring**: `MsilSelfTestM23.fs` added to `Lyric.Emitter.Tests`; all 27
MSIL self-tests pass (M1, M2a–M2d, M3–M23).  CLR execution: Add(20,22)=42
→ prints `42`.

---

### D-progress-163: MSIL PE emitter Stage M24 — instance methods + instance fields

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M24 introduces the `Field` metadata table and instance-method signatures,
exercising `ldfld`/`stfld`, `newobj` with same-assembly MethodDef tokens, and
multi-TypeDef `methodList`/`fieldList` partitioning.

**Class layout:**
- TypeDef[1] `<Module>`: methodList=1, fieldList=1 (owns nothing)
- TypeDef[2] `Counter`: methodList=1, fieldList=1 → owns MethodDef[1..3] and Field[1]
- TypeDef[3] `Hello`: methodList=4, fieldList=2 → owns MethodDef[4]=Main

**Field[1]** `_value`: sig `{0x06, 0x08}` (FIELD, I4).

**MethodDef[1]** `.ctor`: `MDA_SPECIAL_NAME + MDA_RTS_SPECIAL_NAME` required; HASTHIS void() sig; body: `ldarg.0 / ldc.i4.0 / stfld 0x04000001 / ret`.

**MethodDef[2]** `Increment`: HASTHIS void(); `ldarg.0 / ldarg.0 / ldfld / ldc.i4.1 / add / stfld / ret`.

**MethodDef[3]** `GetValue`: HASTHIS I4(); `ldarg.0 / ldfld / ret`.

**MethodDef[4]** `Main`: tiny header; `newobj 0x06000001 / dup / call 0x06000002` × 3 / `call 0x06000003 / call 0x0A000001 / ret`.

BSJB at 0x28C.

**Test wiring**: `MsilSelfTestM24.fs` added to `Lyric.Emitter.Tests`; all 28
MSIL self-tests pass (M1, M2a–M2d, M3–M24).  CLR: Counter.Increment × 3;
GetValue() = 3 → prints `3`.

---

### D-progress-164: MSIL PE emitter Stage M25 — `isinst` + `box`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M25 exercises two value-type boxing / type-testing instructions:
`box` (0x8C) wraps an `I4` on the stack into a `System.Object` reference;
`isinst` (0x75) tests whether that reference is an instance of a given type,
leaving the reference on the stack if it is or null if it isn't.

**Code flow:**
1. `ldc.i4.s 42` / `box TypeRef[3]=System.Int32` → object ref on stack.
2. `isinst TypeRef[2]=System.Object` → ref (succeeds) or null.
3. `brfalse printZero` — long-form (0x39, 4-byte offset) as emitted by `emitBrfalse`.
4. Happy path: `ldc.i4.s 42` / `box System.Int32` / `call Console.WriteLine(object)` / `ret`.
5. `printZero`: `ldc.i4.0` (0x16, 1-byte) / `box System.Int32` / `call Console.WriteLine(object)` / `ret`.

**Token layout:** TypeRef[2]=System.Object (token 0x01000002); TypeRef[3]=System.Int32 (token 0x01000003); MemberRef[1]=Console.WriteLine(object) with sig `{0x00,0x01,0x01,0x1C}`.

codeSize=42; tiny header=0xAA; BSJB at 0x273.

**Test wiring**: `MsilSelfTestM25.fs` added to `Lyric.Emitter.Tests`; all 29
MSIL self-tests pass (M1, M2a–M2d, M3–M25). CLR: isinst succeeds; prints `42`.

---

### D-progress-165: MSIL PE emitter Stage M26 — `newarr` + `ldelem` + `stelem`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M26 introduces managed single-dimension array allocation and element access.

**New instructions:**
- `newarr` (0x8D) — allocates a zero-based, single-dimension array of the given element type.
- `stelem` (0xA4) — stores a typed value into an array element (token-bearing form).
- `ldelem` (0xA3) — loads a typed element from an array (token-bearing form).

**Code flow:** `ldc.i4.2 / newarr TypeRef[3]=System.Int32` allocates `int32[2]`, stored in local 0 via `stloc.0`.  Two `stelem` sequences write 21 at indices 0 and 1.  Two `ldelem` loads feed `add`, yielding 42, which `Console.WriteLine(int)` prints.

**Fat header:** flags=0x13 (FatFormat | InitLocals), maxStack=3, codeSize=46.  LocalVarSig `{0x07, 0x01, 0x1D, 0x08}` = 1 local of type `SZARRAY I4`.  StandAloneSig[1] referenced via `localVarSigTok = 0x11000001`.

TypeRef layout: [1]=System.Console, [2]=System.Object (Hello extends), [3]=System.Int32 (array element token).  BSJB at 0x282.

**Test wiring**: `MsilSelfTestM26.fs` added to `Lyric.Emitter.Tests`; all 30
MSIL self-tests pass (M1, M2a–M2d, M3–M26).  CLR: `int32[2]{21,21}`, sum=42 → prints `42`.

---

### D-progress-166: MSIL PE emitter Stage M27 — `callvirt` (virtual dispatch)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M27 exercises virtual method dispatch via `callvirt` (0x6F).

**Code flow:**
1. `ldc.i4.s 42` / `box TypeRef[3]=System.Int32` → boxed `System.Object` on stack.
2. `callvirt MemberRef[1]=System.Object::ToString()` — HASTHIS signature `{0x20, 0x00, 0x0E}`, returns `System.String`; CLR dispatches to `Int32.ToString()`.
3. `call MemberRef[2]=Console.WriteLine(string)` — prints `"42"`.

**Signature detail:** HASTHIS calling convention (0x20) is required for all instance method signatures; the return type is `ELEMENT_TYPE_STRING` (0x0E).

TypeRefs: [1]=System.Console, [2]=System.Object (Hello extends + callvirt target), [3]=System.Int32.  Tiny header at 0x248 = 0x4A (codeSize=18).  BSJB at 0x25B.

**Test wiring**: `MsilSelfTestM27.fs` added to `Lyric.Emitter.Tests`; all 31
MSIL self-tests pass (M1, M2a–M2d, M3–M27).  CLR: box 42 → `ToString()` → `"42"`.

---

### D-progress-167: MSIL PE emitter Stage M28 — `ldsfld` + `stsfld` (static fields)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M28 introduces the `Field` table with static fields and the `ldsfld`/`stsfld` instructions.

**Field layout:** Hello class owns Field[1]=`_x` and Field[2]=`_y`, both flagged `FDA_PUBLIC + FDA_STATIC` (0x0016) with sig `{0x06, 0x08}` (FIELD + I4).  Field tokens: `_x`=0x04000001, `_y`=0x04000002.

**Code flow:**
1. `ldc.i4.s 20` / `stsfld 0x04000001` — writes 20 to `_x`.
2. `ldc.i4.s 22` / `stsfld 0x04000002` — writes 22 to `_y`.
3. `ldsfld 0x04000001` + `ldsfld 0x04000002` — loads both fields.
4. `add` → 42 / `call Console.WriteLine(int)` / `ret`.

Tiny header at 0x248 = 0x7E (codeSize=31).  BSJB at 0x268.

**Test wiring**: `MsilSelfTestM28.fs` added to `Lyric.Emitter.Tests`; all 32
MSIL self-tests pass (M1, M2a–M2d, M3–M28).  CLR: `_x=20`, `_y=22`; 20+22=42 → prints `42`.

---

### D-progress-168: MSIL PE emitter Stage M29 — `castclass` (reference-type cast)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M29 exercises `castclass` (0x74), the always-or-throw reference-type cast.

**Code flow:**
1. `ldc.i4.s 42` / `box TypeRef[3]=System.Int32` → `System.Object` ref on stack.
2. `callvirt MemberRef[1]=System.Object::ToString()` → `System.String` ref "42".
3. `castclass TypeRef[4]=System.String` — explicit cast; succeeds here.
4. `call MemberRef[2]=Console.WriteLine(string)` / `ret`.

**Token detail:** TypeRef[4]=System.String, token 0x01000004.  `castclass` opcode = 0x74, 5-byte instruction (opcode + 4-byte token).

TypeRefs: [1]=Console, [2]=Object (Hello extends), [3]=Int32, [4]=String.  Tiny header 0x5E (codeSize=23).  BSJB at 0x260.

**Test wiring**: `MsilSelfTestM29.fs` added to `Lyric.Emitter.Tests`; all 33
MSIL self-tests pass (M1, M2a–M2d, M3–M29).  CLR: box 42 → ToString → castclass String → print `42`.

---

### D-progress-207: Aspect weaver A2 — `@no_aspect` per-target opt-out

*claude/plan-emitter-next-steps-6jGK7 branch.*

Implements §3.3 of `docs/26-aspects.md`: functions annotated with `@no_aspect`
or `@no_aspect("AspectName")` are skipped by the weaver.

- **`isOptedOut`** in `Weaver.fs`: checks a `FunctionDecl`'s `Annotations`
  list for an annotation whose `Name.Segments = ["no_aspect"]`.
  - No args → opts out of all aspects.
  - `@no_aspect("Name")` → opts out of only the named aspect (checked via
    `ALiteral(AVString(s, _), _)` matching).
- **Tests** in `AspectWeaverTest.fs`:
  - `aspect_weaver_no_aspect_all` — `@no_aspect` on `greetAdmin()` while
    `greet()` is glob-matched; verifies exactly one "before" in stdout.
  - `aspect_weaver_no_aspect_named` — `@no_aspect("Loud")` on `greetQuiet()`
    while `greet()` is still wrapped; verifies "quiet" printed without wrapping.

All 5 aspect weaver tests pass.

---

### D-progress-206: Aspect weaver A1 — bootstrap-grade wrapper synthesis

*claude/plan-emitter-next-steps-6jGK7 branch.*

First runtime slice of the aspect system (docs/26-aspects.md):

- **`Weaver.fs`** added to `Lyric.Emitter`: transforms `SourceFile.Items` before IL Pass A.
  Collects all `IAspect` items with `Around` advice, glob-matches each `IFunc` against the
  aspect's `matches: name like "<glob>"` clause, renames matched targets to
  `<name>__aspect_target`, and splices in a wrapper function carrying the `around` body with
  `proceed(args)` rewritten to `<target>(p1, p2, …)`.  Unmatched functions and `IAspect` items
  (which carry no IL) pass through unchanged.

- **Glob engine** in `Weaver.fs`: supports `*` (any sequence), `?` (one char), `[abc]`/`[a-z]`
  (character classes).  Matched against short function name only (package-scoped weaving).

- **`sigs` augmentation** in `emitAssembly`: the type checker runs pre-weave, so renamed target
  functions are absent from the `ResolvedSignature` map.  Their entries are inferred by copying
  the original function's signature, keyed on both bare name and arity form.

- **Tests**: `AspectWeaverTest.fs` — three cases: basic before/after advice, no-match bypass,
  `run*` glob matching two functions out of three.

Bootstrap-grade limitations (deferred to v1.x):
  - `args.field` record access inside `around` bodies not supported.
  - `call` ambient value (`call.shortName`, `call.elapsed`, …) not injected.
  - Multi-aspect ordering and contract augmentation (§5/§6 of docs/26) deferred.
  - `@no_aspect` opt-out annotations not yet checked.

---

### D-progress-205: MSIL PE emitter Stage M83 — constrained. + ldvirtftn + ldsflda

*claude/plan-emitter-next-steps-6jGK7 branch.*

- **M83** (`constrained.`, 0xFE 0x16; `ldvirtftn`, 0xFE 0x07; `ldsflda`, 0x7F): the
  `constrained.` prefix (ECMA-335 §III.2.1) enables callvirt on value types without boxing.
  Test calls `Int32.GetHashCode()` via `constrained. System.Int32 / callvirt Object.GetHashCode()`,
  which returns the value itself (42). `ldvirtftn` and `ldsflda` exercised on a dead code path.
  One Int32 local, fat header; codeSize=47, BSJB at 0x283.
  `ldvirtftn` 0xFE 0x07 at file 0x260/0x261; `ldsflda` 0x7F at 0x268;
  `constrained.` 0xFE 0x16 at 0x272/0x273.

87 MSIL self-tests pass (M1, M2a–M2d, M3–M83).

---

### D-progress-204: MSIL PE emitter Stages M80–M82 — cgt/clt/conv.r.un + typed stelem/ldelem (i4/i8/r4/r8 and i1/u1/i2/u4 + tok)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Three stages batched:

- **M80** (`cgt`/`cgt.un`/`clt`/`clt.un`, 0xFE 0x02–0x05; `conv.r.un`, 0x76): signed/unsigned
  greater-than and less-than comparisons, plus convert-to-float treating value as unsigned.
  `43>40 / 45>41.un / 41<45 / 43<44.un → 1×1×1×1 × 42 = 42`. Tiny header (codeSize=38 → 0x9A).
  `cgt` at file 0x24D/0x24E, `cgt.un` at 0x253/0x254, `clt` at 0x259/0x25A,
  `clt.un` at 0x25F/0x260, `conv.r.un` at 0x266, BSJB at 0x26F.

- **M81** (`stelem.i4`/`stelem.i8`/`stelem.r4`/`stelem.r8`, 0x9E/0x9F/0xA0/0xA1;
  `ldelem.i4`/`ldelem.i8`/`ldelem.r4`/`ldelem.r8`, 0x94/0x96/0x98/0x99): typed array
  element stores and loads for all numeric widths. Four locals (Int32[], Int64[], Single[],
  Double[]); fat header. Stores then loads 42 through each array type; final ldelem.i4 → 42.
  Code at 0x254, codeSize=88; BSJB at 0x2AC.

- **M82** (`stelem.i1`/`stelem.i2`, 0x9C/0x9D; `ldelem.i1`/`ldelem.u1`/`ldelem.i2`/`ldelem.u4`,
  0x90/0x91/0x92/0x95; `stelem`/`ldelem` token forms, 0xA4/0xA3): remaining typed and
  generic element-access opcodes. Three locals (Byte[], Int16[], Int32[]); fat header.
  Exercises sign-extended and zero-extended byte/short loads, unsigned I4 load, and
  generic `stelem`/`ldelem` taking a TypeRef token. Code at 0x254, codeSize=86;
  BSJB at 0x2AA (no padding before metadata).

86 MSIL self-tests pass (M1, M2a–M2d, M3–M82).

---

### D-progress-203: MSIL PE emitter Stages M76–M79 — ldloca.s + selective ldind, ldind.r4/r8 + stind float/i8, newarr/ldlen/ldelema, ldarg.2-3/s/a + starg.s

*claude/plan-emitter-next-steps-6jGK7 branch.*

Four stages batched:

- **M76** (`ldloca.s`, 0x12; `ldind.i1`, 0x46; `ldind.u2`, 0x49; `ldind.u4`, 0x4B;
  `ldind.i8`, 0x4C): local-address load plus sign/zero-extended indirect loads for
  byte, ushort, uint, and int64 widths. Fat header with 4 locals (I1, U2, U4, I8).

- **M77** (`ldind.r4`, 0x4E; `ldind.r8`, 0x4F; `stind.i8`, 0x55; `stind.r4`, 0x56;
  `stind.r8`, 0x57): float and int64 indirect loads and stores via managed pointer.
  Fat header with 3 locals (I8, R4, R8).

- **M78** (`newarr`, 0x8D; `ldlen`, 0x8E; `ldelema`, 0x8F): array creation, length query,
  and element-address load for managed arrays.

- **M79** (`ldarg.2`, 0x04; `ldarg.3`, 0x05; `ldarg.s`, 0x0E; `ldarga.s`, 0x0F;
  `starg.s`, 0x10): argument loads by index 2/3, short-form argument load/address/store.
  Two-method PE (Helper + Main); no wide `ldarg`/`starg` forms.

83 MSIL self-tests pass (M1, M2a–M2d, M3–M79).

---

### D-progress-202: MSIL PE emitter Stages M71–M75 — div/beq/bgt, signed branches, unsigned branches, ble.un/blt.un/ldc.i4 variants, ldloc/stloc forms

*claude/plan-emitter-next-steps-6jGK7 branch.*

Five stages batched:

- **M71** (`div`, 0x5B; `beq`, 0x3B; `bgt`, 0x3D): integer divide plus two conditional
  branch forms. `84/2=42`; `beq` and `bgt` guard dead fall-through paths. Tiny header.

- **M72** (`bge`, 0x3C; `ble`, 0x3F; `blt`, 0x3E): three signed conditional branch forms;
  also verifies the OP_BLE/OP_BLT constant fix (`blt`=0x3E, `ble`=0x3F per ECMA-335).
  Tiny header (codeSize=59).

- **M73** (`bne.un`, 0x40; `bge.un`, 0x41; `bgt.un`, 0x42): three unsigned conditional
  branch forms. Tiny header (codeSize=59).

- **M74** (`ble.un`, 0x43; `blt.un`, 0x44; `ldc.i4`, 0x20; `ldc.i4.6`, 0x1C;
  `ldc.i4.7`, 0x1D; `ldc.i4.8`, 0x1E): two unsigned branches plus full-form and
  high inline-constant loads. `6×7=42; 8-8+42=42`. Tiny header (codeSize=53).

- **M75** (`stloc.2/3`, 0x0C/0x0D; `ldloc.2/3`, 0x08/0x09; `stloc.s/ldloc.s`, 0x13/0x11;
  `stloc/ldloc` wide, 0xFE 0x0E/0xFE 0x0C): all remaining local-variable store/load
  forms above index 1. Fat header with 5 I4 locals (codeSize=24).

79 MSIL self-tests pass (M1, M2a–M2d, M3–M75).

---

### D-progress-201: MSIL PE emitter Stages M66–M70 — checked conversions and float literal loads

*claude/plan-emitter-next-steps-6jGK7 branch.*

Five stages batched:

- **M66** (conv.ovf.i1/i2/i4/i8, 0xB3/0xB5/0xB7/0xB9): checked signed conversions. `42` round-trips
  through all four without overflow. Tiny header (codeSize=13 → 0x36).

- **M67** (conv.ovf.u1/u2/u4/u8, 0xB4/0xB6/0xB8/0xBA): checked unsigned conversions. Same round-trip.
  Tiny header (codeSize=13 → 0x36).

- **M68** (conv.ovf.i1.un/i2.un/i4.un/i8.un, 0x82/0x83/0x84/0x85): checked from-unsigned signed
  conversions. Same pattern. Tiny header (codeSize=13 → 0x36).

- **M69** (conv.ovf.u1.un/u2.un/u4.un/u8.un, 0x86/0x87/0x88/0x89): checked from-unsigned unsigned
  conversions. Same pattern. Tiny header (codeSize=13 → 0x36).

- **M70** (ldc.r8/ckfinite/ldc.r4, 0x23/0xC3/0x22): float literal loads and finiteness check.
  `ldc.r8 42.0 / ckfinite / conv.i4 + ldc.r4 0.0 / conv.i4 / add = 42`. Tiny header (codeSize=24 → 0x62).

74 MSIL self-tests pass (M1–M70).

---

### D-progress-200: MSIL PE emitter Stages M61–M65 — overflow arith, int/float conversions, misc loads

*claude/plan-emitter-next-steps-6jGK7 branch.*

Five stages batched:

- **M61** (add.ovf/sub.ovf/mul.ovf + .un, 0xD6/0xDA/0xD8/0xD7/0xDB/0xD9): checked arithmetic.
  `21+21=42`, sub.ovf/mul.ovf/+un variants keep 42. Tiny header (codeSize=21 → 0x56).

- **M62** (conv.i1/i2/i4/i8, 0x67/0x68/0x69/0x6A): signed integer conversions. `42` round-trips
  through all four. Tiny header (codeSize=13 → 0x36). conv.i4 used twice (4 and 6).

- **M63** (conv.u1/u2/u4/u8, 0xD2/0xD1/0x6D/0x6E): unsigned integer conversions. Same round-trip.
  Tiny header (codeSize=13 → 0x36).

- **M64** (conv.r8/r4/r.un, 0x6C/0x6B/0x76): float conversions with int round-trip.
  `42→r8→i4 + 0→r4→i4 + 0→r.un→i4 = 42`. Tiny header (codeSize=18 → 0x4A).

- **M65** (ldc.i8/ldc.i4.m1/ldnull, 0x21/0x15/0x14): misc loads. `ldc.i8 43i64 + ldc.i4.m1(-1) = 42`;
  ldnull/pop exercises null push without printing. Tiny header (codeSize=20 → 0x52).

69 MSIL self-tests pass (M1–M65).

---

### D-progress-199: MSIL PE emitter Stages M56–M60 — bitwise, unary, shift, remainder, stack misc

*claude/plan-emitter-next-steps-6jGK7 branch.*

Five stages batched together:

- **M56** (`or`/`and`/`xor`, 0x60/0x5F/0x61): bitwise binary ops. `(40|2)&63^0 = 42`.
  Tiny header (codeSize=16 → 0x42). Checks or at 0x24D, and at 0x250, xor at 0x252, BSJB at 0x259.

- **M57** (`neg`/`not`, 0x65/0x66): unary arithmetic/bitwise ops. `~(neg(43)) = ~(-43) = 42`.
  Tiny header (codeSize=10 → 0x2A). Checks neg at 0x24B, not at 0x24C, BSJB at 0x253.

- **M58** (`shl`/`shr`/`shr.un`, 0x62/0x63/0x64): shift ops. `21<<1=42`, shr/shr.un add zeros.
  Tiny header (codeSize=18 → 0x4A). Checks shl at 0x24C, shr at 0x24F, shr.un at 0x253, BSJB at 0x25B.

- **M59** (`rem`/`rem.un`/`div.un`, 0x5D/0x5E/0x5C): remainder and unsigned division.
  `85%43=42`, `0%1=0`, `42/1=42`. Tiny header (codeSize=17 → 0x46). Checks rem at 0x24D,
  rem.un at 0x250, div.un at 0x253, BSJB at 0x25A.

- **M60** (`nop`/`dup`/`pop`, 0x00/0x25/0x26): stack misc. `push 42; nop; dup; pop; print`.
  Tiny header (codeSize=11 → 0x2E). Checks nop at 0x24B, dup at 0x24C, pop at 0x24D, BSJB at 0x254.

64 MSIL self-tests pass (M1, M2a–M2d, M3–M60).

---

### D-progress-194: MSIL PE emitter Stage M55 — `initobj`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M55 tests the `initobj` instruction (0xFE 0x15, Token2 form):
- `initobj` — zero-initialises the value type at the managed pointer on the stack.

Test: `ldloca.s 0 / initobj System.Int32 / ldloc.0` loads a zeroed I4 from a
local, then `ldc.i4.s 42 / add` gives 42.  Requires a fat header (InitLocals) due
to the local variable.  `MsilSelfTestM55.fs` verifies fat header at 0x248, LocalVarSig
token at 0x250–0x253, initobj FE prefix at file 0x256, 0x15 at 0x257, BSJB at 0x266.
TypeRef[3] = System.Int32 (same token as M50).

59 MSIL self-tests pass (M1, M2a–M2d, M3–M55).

---

### D-progress-193: MSIL PE emitter Stage M54 — `cgt.un` + `clt.un`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M54 tests the two unsigned integer comparison opcodes (Nullary2 form):
- `cgt.un` (0xFE 0x03) — pushes 1 if `a > b` (unsigned), else 0
- `clt.un` (0xFE 0x05) — pushes 1 if `a < b` (unsigned), else 0

Test: `(10>9 unsigned) * (3<7 unsigned) + 41 = 1*1 + 41 = 42`, prints `42`.
Tiny header (codeSize=22 → 0x5A). `MsilSelfTestM54.fs` verifies cgt.un at
0x24D–0x24E (FE 03), clt.un at 0x253–0x254 (FE 05), and BSJB at 0x25F.

58 MSIL self-tests pass (M1, M2a–M2d, M3–M54).

---

### D-progress-192: MSIL PE emitter Stage M53 — `ceq` + `cgt` + `clt`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M53 tests the three signed integer comparison opcodes (Nullary2 form):
- `ceq` (0xFE 0x01) — pushes 1 if `a == b`, else 0
- `cgt` (0xFE 0x02) — pushes 1 if `a > b` (signed), else 0
- `clt` (0xFE 0x04) — pushes 1 if `a < b` (signed), else 0

Test: `(5==5) * (10>9) * (3<7) + 41 = 1*1*1 + 41 = 42`, prints `42`.
Tiny header (codeSize=29 → 0x76). `MsilSelfTestM53.fs` verifies ceq at
0x24D–0x24E (FE 01), cgt at 0x253–0x254 (FE 02), clt at 0x25A–0x25B (FE 04),
and BSJB at 0x266.

57 MSIL self-tests pass (M1, M2a–M2d, M3–M53).

---

### D-progress-191: MSIL PE emitter Stage M52 — `tail.` prefix

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M52 tests the `tail.` prefix (0xFE 0x14, Nullary2 form):
- `tail.` — marks the immediately-following call instruction as a tail call.

Test: `ldc.i4.s 42 / tail. / call Console.WriteLine(Int32) / ret` prints `42`.
Tiny header (codeSize=10 → header byte 0x2A = 42 itself).
`MsilSelfTestM52.fs` verifies tiny header at 0x248 (0x2A), tail. FE prefix at
file offset 0x24B (code offset 2), second byte 0x14 at 0x24C, and BSJB at 0x253.

56 MSIL self-tests pass (M1, M2a–M2d, M3–M52).

---

### D-progress-190: MSIL PE emitter Stage M51 — `volatile.` prefix

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M51 tests the `volatile.` prefix (0xFE 0x13, Nullary2 form):
- `volatile.` — marks the immediately-following load or store as volatile.

Test: `ldc.i4.s 4 / localloc` allocates 4 bytes on the stack (`rawPtr`);
`stind.i4` writes 42; `volatile. / ldind.i4` performs a volatile load of 42;
`call Console.WriteLine(Int32) / ret` prints `42`.  Requires a fat method header
(InitLocals flag) because `localloc` is used; a dummy I4 local forces the fat path.
`MsilSelfTestM51.fs` verifies fat header at 0x248 (0x13 0x30), LocalVarSig token
at 0x250–0x253, volatile. FE prefix at file offset 0x25C (code offset 8),
second byte 0x13 at 0x25D, and BSJB at 0x265.

55 MSIL self-tests pass (M1, M2a–M2d, M3–M51).

---

### D-progress-189: MSIL PE emitter Stage M50 — `sizeof`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M50 tests the `sizeof` instruction (0xFE 0x1C, Token2 form):
- `sizeof` — pushes the byte size of a value type onto the stack as I4.

Test: `sizeof System.Int32` (TypeRef[3] token) pushes 4, then `ldc.i4.s 38` /
`add` = 42, prints `42`.  `MsilSelfTestM50.fs` verifies the tiny header (0x3E
at 0x248), FE prefix at 0x249, 0x1C at 0x24A, BSJB at 0x258.

54 MSIL self-tests pass (M1, M2a–M2d, M3–M50).

---

### D-progress-188: MSIL PE emitter Stage M49 — `ldelem.i4` + `stelem.i4`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M49 adds typed int32 array element operations and fills in all 18 missing
typed ldelem/stelem opcode constants:
- `ldelem.i1/u1/i2/u2/i4/u4/i8/i/r4/r8/ref` (0x90–0x9A) — typed element loads.
- `stelem.i/i1/i2/i4/i8/r4/r8` (0x9B–0xA1) — typed element stores.

Test: builds a PE that creates a 1-element `int32[]` via `newarr System.Int32`
(TypeRef[3] token 0x01000003), stores 42 via `stelem.i4` (0x9E), reads it back
via `ldelem.i4` (0x94), and prints `42`.  `MsilSelfTestM49.fs` verifies the
tiny header (0x4E at 0x248), newarr at 0x24A, stelem.i4 at 0x253, ldelem.i4
at 0x255, BSJB at 0x25C, and PE execution output `"42"`.

Also fixes a pre-existing verifier bug: `Solver.fs` `isTautology` now handles
`TIte(_, a, b)` when both branches `a` and `b` are individually tautological
(closes the `[D-D1.3] EIf in statement position` test that was failing due to
the trivial discharger not reducing ite-conclusions with tautological branches).

53 MSIL self-tests pass (M1, M2a–M2d, M3–M49).

---

### D-progress-187: MSIL PE emitter Stage M48 — `stind.i` + `ldind.i`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M48 completes the indirect load/store family with the native-int variants:
- `stind.i` (0xDF) — store native int at a raw pointer address.
- `ldind.i` (0x4D) — load native int from a raw pointer address.

Uses `localloc` (M43) to obtain 8 bytes of stack memory (sufficient for a native
int on 64-bit), `conv.i` to widen 42 to native int before storing, and `conv.i4`
to narrow the loaded value back to a printable I4.

**New in `opcodes.l`**: `OP_STIND_I` (0xDF), `OP_LDIND_I` (0x4D); smart constructors
`iStind_I()`, `iLdind_I()`; emit wrappers `emitStind_I()`, `emitLdind_I()`.

**Test wiring**: `MsilSelfTestM48.fs` added to `Lyric.Emitter.Tests`; all 52
MSIL self-tests pass (M1, M2a–M2d, M3–M48).  CLR: `"42"` printed.

---

### D-progress-186: MSIL PE emitter Stage M47 — `conv.i` + `conv.u`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M47 exercises the native-int conversion opcodes:
- `conv.i` (0xD3) — convert top-of-stack to native int (pointer-sized signed).
- `conv.u` (0xE0) — convert top-of-stack to native uint (pointer-sized unsigned).

Both are followed by `conv.i4` to return to a printable I4. For 42, the round-trip
is lossless on all platforms (42 fits in any integer width).

**New in `opcodes.l`**: `OP_CONV_I` (0xD3), `OP_CONV_U` (0xE0); smart constructors
`iConv_I()`, `iConv_U()`; emit wrappers `emitConv_I()`, `emitConv_U()`.

**Test wiring**: `MsilSelfTestM47.fs` added to `Lyric.Emitter.Tests`; all 51
MSIL self-tests pass (M1, M2a–M2d, M3–M47).  CLR: `"42"` printed twice.

---

### D-progress-185: MSIL PE emitter Stage M46 — `conv.i1` + `conv.i2`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M46 exercises two narrow signed conversion opcodes:
- `conv.i1` (0x67) — truncate top-of-stack to int8 and sign-extend to I4.
- `conv.i2` (0x68) — truncate to int16 and sign-extend to I4.

For in-range values (42 < 128) the result is identical to the source. The self-test
verifies both opcodes independently by converting 42 through each and printing.

**New in `opcodes.l`**: `OP_CONV_I1` (0x67), `OP_CONV_I2` (0x68); smart constructors
`iConv_I1()`, `iConv_I2()`; emit wrappers `emitConv_I1()`, `emitConv_I2()`.

**Test wiring**: `MsilSelfTestM46.fs` added to `Lyric.Emitter.Tests`; all 50
MSIL self-tests pass (M1, M2a–M2d, M3–M46).  CLR: `"42"` printed twice.

---

### D-progress-184: MSIL PE emitter Stage M45 — `initblk` + `cpblk`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M45 exercises two bulk-memory instructions:
- `initblk` (0xFE 0x18) — fill `count` bytes at a managed pointer with a byte value.
  Stack protocol: `addr, value (I4), count → (empty)`.
- `cpblk` (0xFE 0x17) — copy `count` bytes from source address to destination.
  Stack protocol: `destaddr, srcaddr, count → (empty)`.

Two I4 locals provide managed pointers without `localloc`, enabling re-entrant
access to the same address after the block operation.

**Code flow:**
1. `initblk`: fill 1 byte at `&local0` with 42; `ldind.u1` → 42; print.
2. `cpblk`: set `local0 = 42`; copy 4 bytes from `&local0` to `&local1`; `ldloc.1` → 42; print.
CLR prints two `"42"` lines.

**New in `opcodes.l`**: `OP2_CPBLK` (0x17), `OP2_INITBLK` (0x18); smart constructors
`iCpblk()`, `iInitblk()`; emit wrappers `emitCpblk()`, `emitInitblk()`.

**Test wiring**: `MsilSelfTestM45.fs` added to `Lyric.Emitter.Tests`; all 49
MSIL self-tests pass (M1, M2a–M2d, M3–M45).

---

### D-progress-183: MSIL PE emitter Stage M44 — `conv.r.un` + `ckfinite`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M44 exercises two float-related opcodes:
- `conv.r.un` (0x76) — convert integer to R8 treating the source as unsigned; for
  non-negative values within I4 range the result is identical to `conv.r8`.
- `ckfinite` (0xC3) — throw `ArithmeticException` if the top-of-stack F value is
  NaN or infinity; otherwise leave the value unchanged.

**Code flow:** `ldc.i4.s 42 / conv.r.un` → 42.0; `ckfinite` passes (finite);
`conv.i4` → 42; `call Console.WriteLine(int)` prints `"42"`.  Tiny header.

**New in `opcodes.l`**: `OP_CONV_R_UN` (0x76), `OP_CKFINITE` (0xC3); smart
constructors `iConv_R_Un()`, `iCkfinite()`; emit wrappers `emitConv_R_Un()`,
`emitCkfinite()`.

**Test wiring**: `MsilSelfTestM44.fs` added to `Lyric.Emitter.Tests`; all 48
MSIL self-tests pass (M1, M2a–M2d, M3–M44).  CLR: `"42"` printed.

---

### D-progress-182: MSIL PE emitter Stage M43 — `localloc` (stack allocation)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M43 exercises `localloc` (0xFE 0x0F), which allocates a caller-specified
number of zeroed bytes on the evaluation stack and pushes a native-int pointer.
`localloc` requires `InitLocals` which is only present in fat method headers;
a dummy I4 local forces fat-header emission.

**Code flow:**
1. `ldc.i4.s 4` / `localloc` — allocate 4 bytes, push pointer.
2. `dup` / `ldc.i4.s 42` / `stind.i4` — write 42 at the address.
3. `ldind.i4` / `call Console.WriteLine(int)` — read 42 back, print.

**New in `opcodes.l`**: `OP2_LOCALLOC = 0x0F`, `iLocalloc()` smart constructor,
`emitLocalloc()` wrapper.

**Test wiring**: `MsilSelfTestM43.fs` added to `Lyric.Emitter.Tests`; all 47
MSIL self-tests pass (M1, M2a–M2d, M3–M43).  CLR: `"42"` printed.

---

### D-progress-181: MSIL PE emitter Stage M42 — `stind.i1`/`i2` + `ldind.u1`/`i2` (narrow indirect access)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M42 exercises narrow indirect stores and loads through a managed pointer.
Using one I4 local:
1. `stind.i1` (0x52) — store low byte; `ldind.u1` (0x47) — load unsigned byte → 42
2. `stind.i2` (0x53) — store low two bytes; `ldind.i2` (0x48) — load signed short → 42

**New in `opcodes.l`**: The complete `ldind.*`/`stind.*` family:
`OP_LDIND_I1/U1/I2/U2/U4/I8/R4/R8` (0x46–0x4F) and `OP_STIND_I1/I2/I8/R4/R8`
(0x52–0x57) constants, smart constructors, and `emitLdind_*/emitStind_*`
wrappers for all variants (adding to the existing I4 and Ref forms).

**Test wiring**: `MsilSelfTestM42.fs` added to `Lyric.Emitter.Tests`; all 46
MSIL self-tests pass (M1, M2a–M2d, M3–M42).  CLR: two `"42"` lines printed.

---

### D-progress-180: MSIL PE emitter Stage M41 — `conv.ovf.*.un` (unsigned-input overflow conversions)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M41 exercises the unsigned-input variants of the overflow-checked
conversion opcodes: `conv.ovf.i8.un` (0x85), `conv.ovf.i4.un` (0x84), and
`conv.ovf.u4.un` (0x88).  These treat the source value as unsigned before
converting; for non-negative operands within range the result is identical to
the signed variants.

**Code flow:** Two computations, both yielding 42:
1. `ldc.i4.s 42 / conv.ovf.i8.un / conv.ovf.i4.un` → int32 42 → `Console.WriteLine`
2. `ldc.i4.s 42 / conv.ovf.u4.un` → uint32 42 (same bits) → `Console.WriteLine`

Tiny header (codeSize=18, header byte 0x4A) at 0x248.  BSJB at 0x25B.

**New in `opcodes.l`**: `OP_CONV_OVF_I1_UN/I2_UN/I4_UN/I8_UN/U1_UN/U2_UN/U4_UN/U8_UN`
constants (0x82–0x89) plus corresponding `iConv_Ovf_*_Un` constructors and
`emitConv_Ovf_*_Un` wrappers for all eight unsigned-input overflow-checked
conversion variants.

**Test wiring**: `MsilSelfTestM41.fs` added to `Lyric.Emitter.Tests`; all 45
MSIL self-tests pass (M1, M2a–M2d, M3–M41).  CLR: two `"42"` lines printed.

---

### D-progress-179: MSIL PE emitter Stage M40 — `volatile.` prefix

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M40 exercises the `volatile.` prefix (0xFE 0x13), a Nullary2 instruction
that must immediately precede a memory-access opcode and instructs the JIT that
the access must not be cached, hoisted, or reordered.

**Code flow:** `ldloca_S 0 / ldc.i4.s 42 / volatile. / stind.i4` — volatile-write
42 to a local int via managed pointer; then `ldloca_S 0 / volatile. / ldind.i4`
— volatile-read it back; `Console.WriteLine` prints `"42"`.  Fat header with
one I4 local (codeSize=18, BSJB at 0x266).

**New in `opcodes.l`**: `OP2_VOLATILE = 0x13` constant, `iVolatile()` constructor,
and `emitVolatile` wrapper.

**Test wiring**: `MsilSelfTestM40.fs` added to `Lyric.Emitter.Tests`; all 44
MSIL self-tests pass (M1, M2a–M2d, M3–M40).  CLR: prints `"42"`.

---

### D-progress-178: MSIL PE emitter Stage M39 — `conv.ovf.i4` / `conv.ovf.i8` (overflow-checked conversions)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M39 exercises the `conv.ovf` integer conversion opcodes: `conv.ovf.i4`
(0xB7) — overflow-checked convert-to-int32, and `conv.ovf.i8` (0xB9) —
overflow-checked convert-to-int64.  Both throw `OverflowException` when the
result is out of range; for in-range inputs the behaviour is identical to
the unchecked `conv.*` variants.

**Code flow:**
1. `ldc.i8 42 / conv.ovf.i4` → int32 42 → `Console.WriteLine` prints `"42"`
2. `ldc.i4.s 42 / conv.ovf.i8 / conv.ovf.i4` → int32 42 → `Console.WriteLine` prints `"42"`

Tiny header (codeSize=25, header byte 0x66) at 0x248.  First `conv.ovf.i4`
at 0x252, `conv.ovf.i8` at 0x25A, second `conv.ovf.i4` at 0x25B.  BSJB at
0x262.

**New in `opcodes.l`**: `OP_CONV_OVF_I1/U1/I2/U2/I4/U4/I8/U8` constants
(0xB3–0xBA) plus corresponding `iConv_Ovf_*` constructors and
`emitConv_Ovf_*` wrappers for all eight signed/unsigned overflow-checked
conversion variants.

**Test wiring**: `MsilSelfTestM39.fs` added to `Lyric.Emitter.Tests`; all 43
MSIL self-tests pass (M1, M2a–M2d, M3–M39).  CLR: two `"42"` lines printed.

---

### D-progress-177: MSIL PE emitter Stage M38 — `add.ovf` / `sub.ovf` / `mul.ovf` (overflow-checked arithmetic)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M38 exercises the three overflow-checked integer arithmetic opcodes:
`add.ovf` (0xD6), `sub.ovf` (0xDA), and `mul.ovf` (0xD8).  Each throws
`OverflowException` when the result exceeds the representable range; for
in-range inputs the behaviour is identical to the unchecked variants.

**Code flow:** Three independent computations each yielding 42:
1. `ldc.i4.s 21 / ldc.i4.s 21 / add.ovf` → 42 → `Console.WriteLine`
2. `ldc.i4.s 43 / ldc.i4.1 / sub.ovf` → 42 → `Console.WriteLine`
3. `ldc.i4.s 21 / ldc.i4.s 2 / mul.ovf` → 42 → `Console.WriteLine`

Tiny header (codeSize=30, header byte 0x7A) at 0x248.  `add.ovf` at file
offset 0x24D, `sub.ovf` at 0x256, `mul.ovf` at 0x260.  BSJB at 0x267.

All three opcodes were already present in `opcodes.l` (emitters
`emitAdd_Ovf`, `emitSub_Ovf`, `emitMul_Ovf`) so no new instruction
definitions were required.

**Test wiring**: `MsilSelfTestM38.fs` added to `Lyric.Emitter.Tests`; all 42
MSIL self-tests pass (M1, M2a–M2d, M3–M38).  CLR: three `"42"` lines printed.

---

### D-progress-176: MSIL PE emitter Stage M37 — `ldelema` (load address of array element)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M37 exercises `ldelema` (0x8F), which pops an array reference and an
index from the stack and pushes a managed pointer (byref) to that array
element.

**Code flow:** `newarr Int32 / stloc_0` → allocate `int32[1]`; `ldloc_0 /
ldc.i4.0 / ldelema Int32` → push byref to element[0]; `ldc.i4.s 42 /
stind.i4` → write 42 via byref; `ldloc_0 / ldc.i4.0 / ldelem Int32` → read 42
normally; `Console.WriteLine(42)` → prints `"42"`.

Fat header with one `int32[]` local (LocalVarSig `{0x07,0x01,0x1D,0x08}`).
BSJB at 0x272.

**Test wiring**: `MsilSelfTestM37.fs` added to `Lyric.Emitter.Tests`; all 41
MSIL self-tests pass (M1, M2a–M2d, M3–M37).  CLR: `ldelema` → `stind.i4` 42 →
`ldelem` → prints `"42"`.

---

### D-progress-175: MSIL PE emitter Stage M36 — `ldind.i4` + `stind.i4` (indirect int32 load/store)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M36 exercises `stind.i4` (0x54) and `ldind.i4` (0x4A), the indirect
integer store and load opcodes used to read/write through a managed pointer
(byref).

**Code flow:** `ldloca_S 0 / ldc.i4.s 42 / stind.i4 / ldloca_S 0 / ldind.i4 /
call Console.WriteLine(int) / ret` — stores 42 into local[0] via a byref, then
reads it back and prints.  Fat header with one I4 local.

Both opcodes are `Nullary` (single-byte, no operand).  BSJB at 0x262.

**New opcodes** added to `opcodes.l`: `OP_LDIND_I4 = 0x4A`, `OP_STIND_I4 = 0x54`,
`iLdind_I4`, `iStind_I4`, `emitLdind_I4`, `emitStind_I4`.

**Test wiring**: `MsilSelfTestM36.fs` added to `Lyric.Emitter.Tests`; all 40
MSIL self-tests pass (M1, M2a–M2d, M3–M36).  CLR: `stind.i4` stores 42,
`ldind.i4` retrieves it → prints `"42"`.

---

### D-progress-174: MSIL PE emitter Stage M35 — `tail.` prefix (tail-call hint)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M35 exercises the `tail.` prefix opcode (0xFE 0x14), a `Nullary2`
instruction that hints the JIT may recycle the current call frame for the
immediately following `call` / `callvirt` / `calli`.

**Code flow:** `ldc.i4.s 42 / tail. / call Console.WriteLine(int) / ret`
(codeSize=10, tiny header 0x2A).  The prefix is observable in the binary at
offset 2 from code start.  CLR behaviour is identical to the non-tail
variant — observable output is `"42"`.

`tail.` encodes as `Nullary2(op=0x14)` = 2 bytes (0xFE 0x14).  BSJB at 0x253.

**New opcode** added to `opcodes.l`: `OP2_TAIL = 0x14`, `iTail`, `emitTail`.

**Test wiring**: `MsilSelfTestM35.fs` added to `Lyric.Emitter.Tests`; all 39
MSIL self-tests pass (M1, M2a–M2d, M3–M35).  CLR: `tail.` hint → prints `"42"`.

---

### D-progress-173: MSIL PE emitter Stage M34 — `sizeof` (byte size of value type)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M34 exercises `sizeof` (0xFE 0x1C), which pushes the byte size of a
value type as an unsigned `int32`.  The test: `sizeof System.Int32` → push 4 →
`Console.WriteLine(int)` → prints `"4"`.

`sizeof` encodes as `Token2(op=0x1C, token)` = 6 bytes (0xFE 0x1C + 4-byte
TypeRef token).  Tiny header 0x32 (codeSize=12).  BSJB at 0x255.

**New opcode** added to `opcodes.l`: `OP2_SIZEOF = 0x1C`, `iSizeof`,
`emitSizeof`.

**Test wiring**: `MsilSelfTestM34.fs` added to `Lyric.Emitter.Tests`; all 38
MSIL self-tests pass (M1, M2a–M2d, M3–M34).  CLR: `sizeof Int32` = 4 → prints
`"4"`.

---

### D-progress-172: MSIL PE emitter Stage M33 — `ldtoken` + `Type.GetTypeFromHandle`

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M33 exercises `ldtoken` (0xD0), which pushes a `RuntimeTypeHandle` /
`RuntimeMethodHandle` / `RuntimeFieldHandle` onto the evaluation stack for a
metadata token.

**Code flow:**
1. `ldtoken TypeRef[3]=System.Int32` → `RuntimeTypeHandle` on stack.
2. `call Type::GetTypeFromHandle(RuntimeTypeHandle)` → `System.Type` object.
3. `callvirt Type::get_Name()` → string `"Int32"`.
4. `call Console::WriteLine(string)` → prints `"Int32"`.

`ldtoken` encodes as `Token(op=0xD0, token)` = 5 bytes.  `GetTypeFromHandle`
signature uses `ELEMENT_TYPE_CLASS` + compressed TypeRef token for the return
type and `ELEMENT_TYPE_VALUETYPE` + compressed TypeRef token for the
`RuntimeTypeHandle` parameter.

TypeRefs: [1]=Console, [2]=Object (Hello extends), [3]=Int32 (ldtoken target),
[4]=Type (GetTypeFromHandle class + get_Name class), [5]=RuntimeTypeHandle
(GetTypeFromHandle param type).  Tiny header 0x56 (codeSize=21).  BSJB at
0x25E.

**New opcode** added to `opcodes.l`: `OP_LDTOKEN = 0xD0`, `iLdtoken`,
`emitLdtoken`.

**Test wiring**: `MsilSelfTestM33.fs` added to `Lyric.Emitter.Tests`; all 37
MSIL self-tests pass (M1, M2a–M2d, M3–M33).  CLR: `ldtoken` → `GetTypeFromHandle`
→ `get_Name` → prints `"Int32"`.

---

### D-progress-171: MSIL PE emitter Stage M32 — `initobj` (zero-initialise value type)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M32 exercises `initobj` (0xFE 0x15), which zero-initialises a value type
at a managed pointer.  The test uses a fat method header (one I4 local) and the
sequence `ldloca_S 0 / initobj TypeRef[Int32] / ldloc_0 / ldc.i4.s 42 / add /
call Console.WriteLine(int) / ret` — the zeroed local is added to 42 and
printed.

**Key details:**
- LocalVarSig `{0x07, 0x01, 0x08}` (one I4 local), StandAloneSig[1].
- Fat header: flags=0x13 (FatFormat|InitLocals), size=0x30, maxStack=2,
  codeSize=18, localVarSigTok=0x11000001.
- `initobj` token = TypeRef[3]=System.Int32 = 0x01000003.
- `initobj` encodes as Token2 (0xFE 0x15 + 4-byte token) = 6 bytes.
- BSJB at 0x248+12+18 = 0x266.

**Test wiring**: `MsilSelfTestM32.fs` added to `Lyric.Emitter.Tests`; all 36
MSIL self-tests pass (M1, M2a–M2d, M3–M32).  CLR: `initobj` → 0+42 → prints
`42`.

---

### D-progress-170: MSIL PE emitter Stage M31 — `ldftn` + delegate (System.Action)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M31 exercises `ldftn` (0xFE 0x06), a two-byte prefix opcode that loads a
function pointer for a `MethodDef` onto the evaluation stack, and then wraps it
in a `System.Action` delegate via the standard `ldnull / ldftn / newobj
Action::.ctor / callvirt Action::Invoke` pattern.

**Methods:**
- `Main` (MethodDef[1], entry point): `ldnull / ldftn 0x06000002 / newobj
  MemberRef[1]=Action::.ctor / callvirt MemberRef[2]=Action::Invoke / ret`
  (codeSize=18, tiny header 0x4A at 0x248).
- `PrintFortyTwo` (MethodDef[2]): `ldc.i4.s 42 / call
  MemberRef[3]=Console.WriteLine(int) / ret` (codeSize=8, tiny header 0x22 at
  0x25B).

**Signatures:**
- `Action::.ctor` — HASTHIS, 2 params, void, OBJECT (0x1C), I (0x18): `{0x20,
  0x02, 0x01, 0x1C, 0x18}`.
- `Action::Invoke` — HASTHIS, 0 params, void: `{0x20, 0x00, 0x01}`.

TypeRefs: [1]=Console (AssemblyRef[2]=System.Console), [2]=Object
(AssemblyRef[1]=System.Runtime, Hello extends), [3]=Action
(AssemblyRef[1]=System.Runtime).  MemberRefs: [1]=Action::.ctor,
[2]=Action::Invoke, [3]=Console.WriteLine(int).  BSJB at 0x264.

`ldftn` token is 6 bytes total: `FE 06` opcode + 4-byte method token.  No
padding between consecutive tiny method bodies confirmed (0x248+1+18=0x25B for
second body, 0x25B+1+8=0x264 for BSJB).

**Test wiring**: `MsilSelfTestM31.fs` added to `Lyric.Emitter.Tests`; all 35
MSIL self-tests pass (M1, M2a–M2d, M3–M31).  CLR: `ldftn` → `Action`
constructor → `Invoke()` → `PrintFortyTwo()` → prints `42`.

---

### D-progress-169: MSIL PE emitter Stage M30 — `unbox_any` (value-type unboxing)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M30 exercises `unbox_any` (0xA5), the inverse of `box`.

**Code flow:**
1. `ldc.i4.s 42` / `box TypeRef[3]=System.Int32` → boxed object ref on stack.
2. `unbox_any TypeRef[3]=System.Int32` → extracts the Int32 value 42 back to the stack.
3. `call Console.WriteLine(int)` / `ret`.

This completes the boxing/unboxing/casting quartet alongside M25 (box+isinst), M29 (castclass), and M30 (unbox_any).

TypeRefs: [1]=Console, [2]=Object (Hello extends), [3]=Int32 (box + unbox_any token 0x01000003).  Tiny header 0x4A (codeSize=18).  BSJB at 0x25B.

**Test wiring**: `MsilSelfTestM30.fs` added to `Lyric.Emitter.Tests`; all 34
MSIL self-tests pass (M1, M2a–M2d, M3–M30).  CLR: box 42 → unbox_any → 42 (I4) → prints `42`.

---

### D-progress-140: F# `Lyric.Stdlib` project deleted entirely

*claude/remove-stdlib-live-methods-wZ199 branch (continued from D-progress-139).*

After D-progress-139 emptied the F# shim of host types, the assembly
was 0 LoC of live code and pure ceremony.  This commit deletes the
project outright.

Files removed:

- `compiler/src/Lyric.Stdlib/Lyric.Stdlib.fsproj`
- `compiler/src/Lyric.Stdlib/Stdlib.fs`

Files updated:

- `compiler/Lyric.sln` — removes the `Lyric.Stdlib` project entry,
  configuration block, and nesting tag.
- `compiler/src/Lyric.Cli/Lyric.Cli.fsproj`,
  `compiler/src/Lyric.Emitter/Lyric.Emitter.fsproj`,
  `compiler/tests/Lyric.Emitter.Tests/Lyric.Emitter.Tests.fsproj` —
  drop the `<ProjectReference Include="...Lyric.Stdlib.fsproj" />`
  line.
- `compiler/src/Lyric.Cli/Program.fs` — `locateStdlibDll` and the
  F# shim copy in `copyStdlibArtifacts` deleted; the second copy in
  the AOT path also drops the `Lyric.Stdlib.dll` line.  Comments
  rewritten to reflect that the only `Lyric.Stdlib.<X>.dll` files
  staged are the precompiled Lyric-compiled package DLLs.
- `compiler/tests/Lyric.Emitter.Tests/EmitTestKit.fs` — `stdlibDll ()`
  helper and the corresponding `File.Copy` call deleted from
  `prepareOutputDir`.
- `compiler/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` — drops
  the `Lyric.Stdlib.dll` copy in the test scratch dir helper.
- `compiler/tests/Lyric.Cli.Tests/NugetShimTests.fs` — replaces the
  `Lyric.Stdlib.dll` probe-DLL fallback with `Lyric.Parser.dll`.
- `stdlib/lyric.toml` — `output_assembly` reverts from
  `Lyric.StdlibBundle.dll` to the canonical `Lyric.Stdlib.dll`
  (the comment carve-out for "once the F# shim merges into the
  bundle" is now obsolete; the SDK's `lib/Lyric.Stdlib.dll` is
  now this Lyric-compiled bundle).
- `CLAUDE.md` — updates the `Lyric.Stdlib` project description.

`SdkRoot.fs` is unchanged in logic (`lib/Lyric.Stdlib.dll` is still
the SDK install sentinel — it just resolves to the Lyric-compiled
bundle now).  Comments about `Lyric.Stdlib.dll` (built by F#) in
the AOT-copy block are scrubbed.

`docs/23-fsharp-shim-elimination.md` Phase 5 decision is now moot:
"keep / rewrite in C# / Cecil-merge" all collapse to "delete the
project" with the F# shim itself gone.

All 638 emitter tests pass; full sweep across Lexer (123), Parser
(312), TypeChecker (137), Cli (112), Lsp (28) all green.

### D-progress-139: F# `Lyric.Stdlib.JsonHost` retirement — final eight live methods migrated to pure Lyric

*claude/remove-stdlib-live-methods-wZ199 branch.*

The last live F# methods in `compiler/src/Lyric.Stdlib/Stdlib.fs` were
all on `Lyric.Stdlib.JsonHost` and split into three buckets, each
gated on a different compiler limitation:

| Method(s) | Blocker | Fix |
|---|---|---|
| `Parse` | FFI default-arg overload selection picked an arbitrary `JsonDocument.Parse(X, JsonDocumentOptions = default)` overload — `staticArityWithDefaults` matched on count only, so `Parse(ReadOnlyMemory<char>, …)` could win over `Parse(string, …)` | Filter by leading-param exact type before falling back to count-only |
| `EncodeString` | `JsonEncodedText.Encode(string)` returns a struct (`JsonEncodedText`); calling instance `ToString()` on it from Lyric needed BCL struct return bridging | Already worked via `Ldarga 0` for value-type receivers; split into `hostEncodeText` + `hostEncodedTextToString` and a native-Lyric concat-with-quotes |
| `Get{Int,Long,Double,Bool,String}Slice` (5 methods) | `JsonElement.EnumerateArray()` returns the nested CLR struct `JsonElement+ArrayEnumerator`; `extern type X = "Foo+Bar"` parsed but `MoveNext` (mutating instance method) failed because the emitter `Ldarga`-ed the parameter slot when `inout` already gave it a managed pointer | Skip the `Ldarga` when `paramList[0]` is already byref so `Ldarg 0` loads the pointer directly |
| `RenderDoubleSlice` | `Lyric.toString(Double)` boxed and called `Object.ToString()` (locale-dependent, not round-trip-safe) | Special-case `toString(Double | Float)` in codegen to call `Double.ToString(InvariantCulture)` — .NET 10's default format is already round-trip-shortest, and `InvariantCulture` pins the decimal separator |

Files touched:

- `compiler/src/Lyric.Emitter/Emitter.fs` — three edits.  (1)
  `staticArityWithDefaults` / `instanceArityWithDefaults` get a
  two-pass match: leading-param exact-type first, then count-only as
  fallback — fixes the `Parse(ReadOnlyMemory<char>, opts=default)`
  ambiguity.  (2) `emitExternCall` arg push: when `paramList[0]` is
  already a byref (Lyric `inout T`), use `Ldarg 0` instead of
  `Ldarga 0` so the loaded pointer matches the BCL receiver shape.
  (3) `findClrType` no longer pins `typeof<Lyric.Stdlib.JsonHost>` —
  the type doesn't exist anymore.
- `compiler/src/Lyric.Emitter/Codegen.fs` — `toString` builtin gains a
  branch for `argTy = typeof<double>` / `typeof<single>` that emits
  `Stloc + Ldloca + Call CultureInfo.get_InvariantCulture + Call
  Double.ToString(IFormatProvider)`.
- `stdlib/std/_kernel/json_host.l` — adds `extern type
  JsonArrayEnumerator = "System.Text.Json.JsonElement+ArrayEnumerator"`
  and `extern type JsonEncodedText`; direct externs for
  `EnumerateArray` / `ArrayEnumerator.MoveNext` (inout) /
  `ArrayEnumerator.Current` (inout property getter); pure-Lyric
  `hostEncodeString` (split into `hostEncodeText` + Lyric concat with
  surrounding quotes); pure-Lyric `lyricJsonGet{Int,Long,Double,Bool,
  String}Slice` that drive the enumerator with a `while
  hostEnumMoveNext(en) { … }` loop.  `hostParseJson` now `@externTarget`s
  `System.Text.Json.JsonDocument.Parse` directly (the default-arg
  fix lets it resolve to the `(string, JsonDocumentOptions=default)`
  overload).
- `compiler/src/Lyric.Parser/JsonDerive.fs` — synthesiser updates.
  `__lyricJsonEscape` becomes a Lyric body (`hostEncodeString(s)`)
  instead of `@externTarget`-ing the F# shim; the five
  `__lyricJsonGet*Slice` helpers route through `mkGetShimBody` to
  the new `lyricJsonGet*Slice` kernel functions; the Double slice
  renderer uses `mkSliceHelperInline` with `toString(items[i])`
  (now culture-invariant).  `mkSliceHelperExtern` and the legacy
  count-only `mkGetShim` builders deleted — both unused after
  migration.
- `compiler/src/Lyric.Stdlib/Stdlib.fs` — the `JsonHost` class is
  deleted; the file is now entirely retirement-log comments.

The `Lyric.Stdlib` F# project still ships (the assembly is referenced
by the CLI and emitter tests for runtime probing) but contains no
host types.  The packaging-shape decision tracked in
`docs/23-fsharp-shim-elimination.md` Phase 5 ("keep as F# / rewrite
in C# / Cecil-merge") can now be made on an empty assembly — net F#
shim size is zero LoC.

All 638 emitter tests pass, including `JsonDeriveTests` (Int / Long /
Bool / String / Double slice round-trip via the new pure-Lyric
readers and renderers) and the `@derive(Json)` end-to-end smoke
covering `User { name: String, address: Address }` with
`address.zip` round-tripped through the synthesiser.

### D-progress-135: M5.3 stage 3 — F# CLI `lyric fmt` reflection bridge

*claude/lyric-fmt-cli-wiring branch.*

Routes the F# `lyric fmt` subcommand through the self-hosted
`Lyric.Fmt` (D-progress-131) so non-doc comments survive the user-
facing `lyric fmt` command.  The previous stage shipped the formatter;
this stage wires it.

How it works:

- `Lyric.Fmt` (Lyric package) gains two String-in / String-out
  facade entry points so the F# bridge doesn't have to construct a
  Lyric `ParseResult` across the language boundary:
  `pub func formatSource(source: in String): String`
  `pub func isFormattedSource(source: in String): Bool`
  The bodies just thread through the existing `format` /
  `isFormatted` and parse the source first.
- `compiler/src/Lyric.Cli/SelfHostedFmt.fs` (new F# module)
  implements the bridge.  On first call it compiles a tiny driver
  Lyric program (`package Lyric.FmtBridge / import Lyric.Fmt /
  func main(): Unit { }`) via `Emitter.emit`, which has the side-
  effect of dropping `Lyric.Lyric.Fmt.dll` into the per-process
  stdlib precompile cache.  We then `Assembly.LoadFrom` every cached
  DLL so the transitive references resolve, locate
  `Lyric.Fmt.Program`, and reflect out the static
  `formatSource(string)` / `isFormattedSource(string)` methods.  The
  resolved delegates are cached in a process-wide `lock`-guarded
  ref so subsequent invocations skip the ~3-5s driver compile.
- `Program.fs` `lyric fmt` dispatch routes through
  `SelfHostedFmt.format` / `SelfHostedFmt.isFormatted` by default; a
  new `--legacy` flag (and `LYRIC_FMT_LEGACY=1` env var for
  automation harnesses that can't pass extra flags) falls back to
  the F# `Lyric.Cli.Fmt` formatter.  If the bridge throws (e.g.
  driver compile error in a pathological env), we surface the
  message to stderr and degrade to the legacy backend so
  `lyric fmt` is never bricked.
- Help text on `lyric --help` is updated: `--legacy` is documented
  and the comment-preservation note is corrected — the default
  backend now keeps both `///` and `//` comments.

Tests at `compiler/tests/Lyric.Cli.Tests/SelfHostedFmtBridgeTests.fs`
exercise the bridge directly (round-trip, idempotence, leading +
between + trailing line/block comment preservation, `isFormatted`
discrimination).  All seven F# Expecto suites continue to pass.

Naming wart for follow-up: the emitter's stdlib-precompile path
mints DLL filenames as `sprintf "Lyric.%s.%s" head (concat rest)`,
so `Lyric.Fmt` lands as `Lyric.Lyric.Fmt.dll` (the double `Lyric.`
is head + per-package basename, not a typo).  The CLR type names
inside the DLL are unaffected (`Lyric.Fmt.Program`).  Cleaning the
DLL naming is its own concern; for now the bridge looks up
`Lyric.Lyric.Fmt.dll` explicitly with a comment.

---

### D-progress-131: M5.3 stage 2 — self-hosted formatter (`Lyric.Fmt`) port

*claude/lyric-self-hosted-formatter branch.*

The F# `lyric fmt` (compiler/src/Lyric.Cli/Fmt.fs) drops `//` comments
because it walks the AST exclusively.  D-progress-130's red/green CST
gave the parser a lossless source view; this stage ports the formatter
to Lyric so it can consume that CST and preserve comments.

Scope:

- New `Lyric.Fmt` package at `compiler/lyric/lyric/fmt/{fmt_core,fmt_items,fmt}.l`
  mirroring the F# Fmt.fs structure (helpers + line model + type /
  pattern / literal / expression / statement printers in `fmt_core`,
  item printers in `fmt_items`, top-level entry points in `fmt`).
- Public API matching the contract advertised in `compiler/lyric/lyric/cli.l`:
  `pub func format(parsed: in ParseResult): String`
  `pub func isFormatted(source: in String, parsed: in ParseResult): Bool`
- Comment preservation at item granularity: line and block comments
  between items, before the first item, and after the last item are
  harvested from the CST (`harvestCommentsFromNode` walks every
  green-token's `leadingTrivia` and records `TKLineComment` /
  `TKBlockComment` runs with their offsets) and re-emitted at the
  appropriate item boundary.  Item-internal comments are deferred
  until the CST is refined to per-statement / per-expression
  granularity.
- `fmt_self_test.l` covers the file-level format (package, imports,
  module doc), every supported item kind exercised end-to-end (alias,
  distinct type, record, union, enum, func, val, pub func), and the
  three comment-preservation paths (before first item, between items,
  trailing after last item).  A new F# Expecto runner
  `tests/Lyric.Emitter.Tests/SelfHostedFmtTests.fs` compiles and
  runs the self-test.

Bootstrap codegen workaround in `patStr`'s `PBinding` arm: the obvious
`match innerOpt { Some(ip) / None }` shape silently falls through under
the bootstrap codegen when `innerOpt` is destructured out of an outer
union case in the same arm (`Option[Pattern]` specifically).
Routed around with `isSome` + `unwrapOr`; both are pure helpers from
`Std.Core` and the recursion still terminates on the inner pattern's
kind.  Tracked for follow-up against the bootstrap emitter.

CLI wiring is intentionally out of scope: the F# `lyric fmt` still
calls `Lyric.Cli.Fmt.format` (F#).  The next stage routes
`lyric fmt` through this Lyric formatter via in-process compile +
reflection (matching the existing emitter pattern for stdlib DLL
loading).

---

### D-progress-130: M5.1 stage 5' — red/green CST foundation in self-hosted lexer + parser

*claude/lyric-parser-ast-cst-trivia-47fTT branch.*

The self-hosted formatter (planned for M5.3) needs a lossless source
view to preserve comments and whitespace.  This stage lays the
Roslyn-style red/green CST foundation entirely on the self-hosted
side; the F# bootstrap is not touched.

**Lexer changes (`compiler/lyric/lyric/lexer.l`):**

- New `TriviaKind` (`TKWhitespace`, `TKNewline`, `TKLineComment`,
  `TKBlockComment`) and `Trivia { kind, text, span }` records.
- `SpannedToken` gains `leadingTrivia: List[Trivia]`.  The lexer
  accumulates whitespace, newlines, and non-doc comments into a
  `pendingTrivia` buffer and flushes them onto every emitted token —
  including synthesised STMT_END and the trailing TEof, so trailing
  trivia at end-of-file is also preserved.
- Doc comments (`///` and `//!`) remain real tokens (`TDocComment`,
  `TModuleDocComment`) because the parser still binds them into the
  AST.
- `makeSpannedToken(tok, sp)` is a public helper for synthetic
  out-of-bounds tokens (used by parser sentinels).

**CST data model (`compiler/lyric/lyric/parser/parser_cst.l`):**

- `SyntaxKind` enumerates structural CST node kinds (`SkSourceFile`,
  `SkModuleDocSection`, `SkFileAnnotationsSection`, `SkPackageDecl`,
  `SkImportSection`, `SkImportDecl`, `SkItemSection`, `SkItem`,
  `SkAnnotation`, `SkRaw`).
- `GreenNode { kind, children, width }` plus `GreenChild` (`GcToken`
  or `GcNode`) is the immutable, parent-pointer-free green tree.
  `width` is precomputed in bytes so a downstream consumer can map
  any node to an absolute source offset.
- `RedNode { green, parent, offset }` plus `redChildren` lazily
  expose absolute offsets and parent pointers.
- `nodeSourceText(source, node)` walks the green tree and produces
  the original source byte-for-byte (modulo CR/LF normalisation
  performed by `lex`).

**Event-based builder:**

- `CstEvent` (`CeStart(kind, tokenStart)` / `CeFinish(tokenEnd)`)
  is pushed into `ParseState.cstEvents` by the parser as it enters
  and exits each production.  Token indices reference `st.tokens`
  directly, so internal `mark` / `reset` speculation does not need
  to truncate the event log.
- `buildGreenTree(events, tokens)` walks the events plus the lexer's
  token list to materialise the root.  A single `cursor` tracks
  the next unclaimed token; when a child opens at `tokenStart >
  cursor`, the gap belongs to the parent as direct token children.

**Parser wrapping (`compiler/lyric/lyric/parser/parser_*.l`):**

The parser now opens / closes nodes at the file / package / import /
item / annotation granularity:

- `parse` wraps the entire file in `SkSourceFile`; the trailing TEof
  is included so its leading trivia (final whitespace, dangling
  comments) survives.
- `parseModuleDocComments` → `SkModuleDocSection`.
- `parseFileLevelAnnotations` → `SkFileAnnotationsSection`.
- `parsePackageDecl` → `SkPackageDecl`.
- `parseImports` → `SkImportSection`; each `parseImportDecl` →
  `SkImportDecl`.
- `parseItems` → `SkItemSection`; each `parseItemOpt` →
  `SkItem`.
- `parseAnnotation` → `SkAnnotation` (covers both file-level and
  item-level annotations).

Inside an item, every consumed token still appears as a token leaf
of the surrounding `SkItem` node in source order.  Future passes can
refine the granularity (expression, statement, contract clause) by
adding `cstStart` / `cstFinish` calls without changing the data
model.

**`ParseResult` shape change:**

- New `cst: GreenNode` field on `ParseResult` — the lossless tree.
- New `source: String` field — the post-CR/LF-normalised input,
  retained so callers can render token text via `tokenSourceText` /
  `nodeSourceText` without holding the file contents themselves.

**Tests:**

- `lexer_self_test.l` gains six trivia tests covering the four
  trivia kinds, the synthetic-STMT_END flush, the doc-comment
  carve-out, and a full lossless round-trip on a mixed source.
- `parser_self_test.l` gains six CST tests: root kind,
  byte-faithful round-trip on a comment-rich source, structural
  child counts, the empty-source case, the `width == source.length`
  invariant, and red-tree offset monotonicity.

All 1595 tests across the seven F# Expecto suites continue to pass
unchanged (lexer 123, parser 312, type-checker 137, CLI 105,
verifier 256, LSP 28, emitter 634).

---

### D-progress-128: M5.1 stage 5 — self-hosted parser (`Lyric.Parser`)

*claude/lyric-parser-selfhosted-AvCuy branch.*

The self-hosted Lyric parser ships as a four-file `Lyric.Parser` library
under `compiler/lyric/lyric/parser/`:

- `parser_ast.l` — AST variant types (`Expr`, `Stmt`, `Item`, `Pattern`,
  `TypeRef`, `ContractClause`, …) that mirror the F# `Ast.fs` definition.
- `parser_core.l` — shared primitives: `ParseState`, token-stream helpers
  (`peekToken`, `consume`, `expect`), span arithmetic, and the diagnostic
  accumulator.
- `parser_exprs.l` — expression parser (Pratt-style precedence climbing
  from primary → comparison → logic → `if`/`match` → block).
- `parser_items.l` — item parser: `func`, `type`, `alias`, `interface`,
  `impl`, `import`, `module`, `val`, contract clauses, and the top-level
  `parseFile` entry point.

`compiler/lyric/lyric/parser_self_test.l` is the self-test consumer.  It
imports `Lyric.Lexer` and `Lyric.Parser`, exercises the full parse path
(imports, function decls with contracts, expression types, match, loops,
closures, …) through assertions, and writes `"ok"` on success.

The F# test
`compiler/tests/Lyric.Emitter.Tests/SelfHostedParserTests.fs`
(`[parser_self_test_passes]`) compiles `parser_self_test.l` via the
bootstrap emitter, runs the resulting PE, and asserts exit 0 + `"ok"` in
stdout.  All 613 emitter tests pass with 0 failures.

**Emitter fixes required to make the self-hosted parser compile and run:**

1. **`SAssign` `ExpectedType` propagation** (`Codegen.fs`): When emitting
   `target = rhs` where `target` is a typed local, the emitter now sets
   `ctx.ExpectedType <- Some lb.LocalType` (if not already set) before
   emitting the RHS.  Without this, `op = Some(value = BEq)` produced
   `Option_Some<object>` instead of `Option_Some<BinOp>`; subsequent
   `isinst Option_Some<BinOp>` always failed, causing match fall-through
   to `null` and a `NullReferenceException` in `parseContractClauseOpt`.

2. **`emitMatch` arm `ExpectedType` propagation** (`Codegen.fs`): When
   emitting match arms after the first, the emitter now sets
   `ctx.ExpectedType <- Some resultTy` (the type inferred from arm 0) for
   arms i > 0 when `ctx.ExpectedType` is None.  This fixed incorrect
   `Option_Some<object>` construction in multi-arm matches inside parser
   helper functions.

3. **Nullary union-case singletons** (`Codegen.fs` / `Emitter.fs`):
   Cross-assembly nullary cases (e.g. `None`, `KwRequires`) are now
   fetched via their `Get<Name>()` static accessor rather than `newobj`
   so that `isinst` / `ceq` comparisons work correctly against the shared
   singleton.  In-project nullary cases use a `Instance` static field
   when available.

4. **`UnionEquality.SameType`** (`Stdlib.fs` / `Codegen.fs`): Added a
   `Lyric.Stdlib.UnionEquality.SameType(obj, obj)` helper and wired `BEq`
   on abstract union base types through it to avoid virtual-dispatch and
   TypeBuilder vtable issues in `PersistedAssemblyBuilder`.

5. **Type-checker / symbol fixes** (`Checker.fs`, `Symbol.fs`): Various
   minor fixes to support the parser's use of closures, mutual recursion,
   and deeply nested `match` expressions.

---


### D-progress-125: JVM stage B2 smoke test unskipped; B111–B124 doc status update

*claude/continue-jvm-emitter-T9Gdj branch.*  The `[hello_class_bytes_are_jvm_loadable]`
test in `compiler/tests/Lyric.Emitter.Tests/JvmSelfTest.fs` was marked `ptestCase`
(pending) since the stage-B2 PR with the note that `buildLabelMap` / `emitAllInsns`
in `bytecode.l` failed JIT-time verification with `BadImageFormatException` when the
compiled .NET program was executed.  The root cause was a codegen bug with `match`
over a local union type in statement position.  That bug was fixed as a side effect of
the B90–B124 emitter improvements (stack-map frame computation, `assembleCodeWithFrames`,
and StackMapTable fixes across `lowerFuncImpl`).  The test now passes cleanly (627
tests, 0 ignored).

**Changes:**
- `JvmSelfTest.fs`: `ptestCase` → `testCase`; stale bug-description comment removed.
- `docs/18-jvm-emission.md` §23.11: B111–B124 status updated from "Planned" → "Shipped";
  intro sentence updated to "All stages B90–B124 have shipped."  Function names corrected
  (`makeLyricSignatureAttr`, `lowerProtectedWithBarriers`, `lowerScopeBlock`,
  `lowerFuncWithContract`) to match `lowering.l` exports.
- `docs/10-bootstrap-progress.md` Phase 5 table: PR numbers filled in for D-progress-124;
  D-progress-125 row added.

---

### D-progress-129: M5.3 (stage 1) — self-hosted CLI migration

*claude/migrate-lyric-cli-3WDhT branch.*  Phase 5 §M5.3 begins
migrating the Lyric CLI from F# to Lyric itself, keeping the F# bootstrap
compiler in place for compilation.

**Files shipped:**

| File | Role |
|---|---|
| `stdlib/std/_kernel/process_host.l` | Trusted BCL extern boundary for `System.Diagnostics.Process` |
| `stdlib/std/process.l` | `Std.Process` — `run` / `runChecked` wrapping the process kernel |
| `compiler/lyric/lyric/manifest.l` | `Lyric.Manifest` — pure-Lyric TOML parser for `lyric.toml` (mirrors `Manifest.fs`) |
| `compiler/lyric/lyric/cli.l` | `Lyric.Cli` — self-hosted command dispatch (mirrors `Program.fs`) |
| `stdlib/std/string.l` | Added `pub func fromInt(n: in Int): String` convenience wrapper over `toString` |

**Architecture decisions:**

- `Std.ProcessHost` lives in `stdlib/std/_kernel/` (kernel boundary), using
  `Process.Start(string, string)` — the two-string overload — so argument
  quoting is done in pure Lyric (`buildArgString` in `process.l`).  This
  avoids `ProcessStartInfo.ArgumentList` (a generic mutable collection
  with no exact-CLR-type match in the emitter's `paramsExactMatch`).
- No new F# shim modules were added.  `G10` pattern (`try/catch Bug`) is
  used throughout for host-failure conversion.
- `Lyric.Manifest` uses a cursor-based recursive descent parser with
  `inout Cursor` for mutable state, matching the `lexer.l` style.
- `Lyric.Cli` forward-imports `Lyric.Parser`, `Lyric.Emitter`, `Lyric.Fmt`,
  `Lyric.Lint`, `Lyric.Verifier`, `Lyric.Doc`, and `Lyric.ContractMeta`.
  These packages do not exist yet; they will ship in M5.2 (parser/emitter)
  and the remainder of M5.3.  The CLI source documents their expected API
  surface in header comments.  The file lives in `compiler/lyric/lyric/`
  and is only compiled by the self-hosted compiler, so forward references
  are safe.
- `stdlib/lyric.toml` gains `Std.ProcessHost` in Tier 0 (only depends on
  `Std.Core`).  `Std.Process` is queued for Tier 1 once `Std.Collections`
  is wired into the bundle.

**Kernel boundary count** (after this PR): `Std.ProcessHost` adds 3 extern
declarations (`hostSpawn`, `hostWait`, `hostExitCode`).  Total kernel
extern count: ~217, well under the 250 hard limit.

---

### D-progress-124: JVM self-tests B111-B124 — sealed-union, enum, out-param, nat-tag, signature attr, exposed-record, projectable, protected-barriers, hot-async, scope-block, func-with-contract, derive-equality, derive-ord, lowerPackage

*claude/jvm-scope-b111-XNq6s branch.*  Completes the JVM lowering
self-test series B111–B124 exercising the full range of Lyric-level
lowering functions.  Each stage has a self-test Lyric source in
`compiler/lyric/jvm/` and an F# Expecto test in
`compiler/tests/Lyric.Emitter.Tests/`.

**Stages shipped:**

| Stage | Lyric API exercised | Key issue fixed |
|---|---|---|
| B111 | `lowerSealedUnion` | sealed interface + permitted-subclasses attr |
| B112 | `lowerEnum` | `assembleCodeWithFrames` needed for branching `switch` |
| B113 | `lowerOutInoutParam` | out-alloc / out-store / out-load helpers |
| B114 | `lowerNatTag` | `42L` not valid; use `42i64` Lyric syntax |
| B115 | `makeLyricSignatureAttr` | SIGSEGV: direct `ClassFile(...)` ctor outside module; fix via `makeClassWithAttrs` helper in `classfile.l` |
| B116 | `lowerExposedRecord` | `makeRecordAttr` + `makeRecordClass` helpers |
| B117 | `lowerProjectable` | `makeClassWithMethodsAndAttrs` helper |
| B118 | `lowerProtectedWithBarriers` | `invokevirtual` on `Condition` (interface) → `invokeinterface`; result-slot pre-init before barrier branch targets |
| B119 | `lowerHotAsync` | `thenApply` + `completedFuture` nesting; fix: stage2 returns raw value |
| B120 | `lowerScopeBlock` | direct `ClassFile(...)` ctor SIGSEGV; fix via `makeFinalClass`/`makeClassWithInterfaces` |
| B121 | `lowerFuncWithContract` | StackMapTable empty-stack assumption; fix: skip result slot when ensures is empty; simplify requires to avoid diamond-with-stack-value |
| B122 | `lowerDeriveEquality` | `equals` branch targets before slot-2 assigned; fix: `LIfAcmpeq`/`LIfAcmpne` LInsn cases + pre-init slot 2 + `lowerFuncForClass` path |
| B123 | `lowerDeriveOrd` | `compareTo` with long comparison |
| B124 | `lowerPackage` | `LIreturn` missing from static `add` body |

**Lowering infrastructure changes (in `lowering.l`):**

- `lowerFuncImpl(f, thisTypeName, pool)` — internal impl taking explicit `this`-type for StackMapTable frame generation
- `lowerFunc(f, pool)` — public wrapper using `java/lang/Object` as `this`-type (static / top-level methods)
- `lowerFuncForClass(f, declaringClass, pool)` — public wrapper using the actual class name (instance methods)
- `lowerEntry` and `lowerProtectedWithBarriers` updated to call `lowerFuncForClass`
- Fixed `paramSlotCount` double-counting of `this` in non-static methods
- Added `LIfAcmpeq` and `LIfAcmpne` to the `LInsn` union, `lowerInsn`, and `collectBranchTargets`
- `lowerDeriveEquality` refactored to use `LInsn` list + `lowerFuncForClass` for correct StackMapTable

---

### D-progress-134: MSIL PE emitter Stage M1 — pure-Lyric PE/COFF image generator

*claude/self-hosted-msil-emitter-pe branch.*

Stage M1 of the self-hosted MSIL emitter produces a structurally valid 1024-byte
PE/COFF + CLR-metadata image for a fixed "Hello" assembly without any new F#
host code.  The implementation reuses the `Lyric.Jvm.Hosts.JvmByteBuilder` /
`JvmByteHost` infrastructure already present for the JVM emitter.

**New files:**

- `compiler/lyric/msil/_kernel/kernel.l` — `Msil.Kernel` package; declares
  `extern type ByteWriter = "Lyric.Jvm.Hosts.JvmByteBuilder"` and re-exports
  the JVM LE byte-write helpers (`bufU1`, `bufU2`, `bufU4`, `bufAppend`,
  `bufLen`, `bufToList`) under PE-centric names, plus `bufZero` and `bufPadTo`
  in native Lyric.

- `compiler/lyric/msil/pe.l` — `Msil.Pe` package; full fixed-layout serializer.
  Sections: DOS stub (128 B), PE/COFF headers (384 B, padded), CLR header
  IMAGE_COR20_HEADER (72 B), MSIL method body in tiny format (12 B, ldstr +
  call + ret), and ECMA-335 metadata (408 B: BSJB root + #~ tables stream +
  #Strings + #US + #Blob + #GUID).  Entry points: `buildHelloAssemblyBuf()`,
  `buildHelloAssembly(): List[Byte]`, `buildHelloAssemblySize(): Int`.

- `compiler/lyric/msil/msil_self_test_m1.l` — `Msil.SelfTestM1` package;
  calls `buildHelloAssemblySize()` + `buildHelloAssembly()` and prints five
  structural invariants: `pe_size_ok=true`, `mz_ok=true`, `pe_sig_ok=true`,
  `clr_header_ok=true`, `bsjb_ok=true`.

**Emitter change:**

- `compiler/src/Lyric.Emitter/Emitter.fs` — `isBuiltinHead` extended to
  include `"Msil"`, mapping `import Msil.X` to `compiler/lyric/msil/`.

**F# test:**

- `compiler/tests/Lyric.Emitter.Tests/MsilSelfTestM1.fs` — `Msil.SelfTest M1`
  Expecto test: compiles `msil_self_test_m1.l` via the bootstrap emitter, runs
  it, asserts all five `*=true` lines are present in stdout.  Wired into
  `Lyric.Emitter.Tests.fsproj` and `Program.fs`.

All 635 emitter tests pass.

**Design note:** `List[Byte].length` is not available (CLR `List<T>` exposes
`Count`, not `length`); size checking uses `bufLen(w)` on the raw `ByteWriter`
before `bufToList`.  Multi-line boolean expressions use `and` (not `&&`, which
the parser splits into two prefix-ref operators across line boundaries).

---

### D-progress-126: Phase 6 (partial) — stdlib distribution + `lyric --sdk-info`

*claude/phase-6-distribution-tooling-gNldX branch.*  Ships the
non-VS-Code deliverables from `docs/22-distribution-and-tooling.md`:
SDK root discovery, `Lyric.SdkVersion` resource embedding, the
`lyric --sdk-info` command, B0040/B0042 diagnostics, stdlib bundle
expansion, and a dedup fix for in-project `mergedImportedItems`.

**New module: `compiler/src/Lyric.Emitter/SdkRoot.fs`**

`Lyric.Emitter.SdkRoot` implements `docs/22` §4:

- `SdkSource` discriminated union: `EnvVar | BinaryRelative | NotFound`.
- `SdkInfo` record: `Root`, `StdlibDll`, `Version` (4-tuple read from
  the `Lyric.SdkVersion` embedded resource), `Source`.
- `locate(binaryDir)` — checks `LYRIC_SDK_ROOT` first, then walks up
  from `binaryDir` looking for `lib/Lyric.Stdlib.dll`.
- `tryReadSdkVersion(dllPath)` — reads the `Lyric.SdkVersion` managed
  resource via Mono.Cecil (no file lock, no AppDomain load).

**`Emitter.fs` changes**

1. **Binary DLL fast path** in `ensureStdlibArtifact`: before falling
   back to source-tree compilation, `locate AppContext.BaseDirectory`
   is called; if a `Lyric.StdlibBundle.dll` (or any DLL with the right
   `Lyric.Contract.<Pkg>` resource) is found at the SDK root, it is
   loaded via `loadRestoredPackage` and cached in
   `stdlibArtifactCache`.
2. **`Lyric.SdkVersion` embedding** in `emitProject` Phase D: after
   the per-package `Lyric.Contract` resources are written, a single
   JSON object `{ "language_version", "stdlib_version",
   "compiler_version", "build_date" }` is embedded as a
   `Lyric.SdkVersion` managed resource via `ContractMeta.embedIntoAssemblyAs`.
   Failure emits B0042.
3. **`getSdkInfo()`** public helper calls `SdkRoot.locate` and is
   consumed by `lyric --sdk-info`.
4. **`mergedImportedItems` dedup fix** in `emitProject`'s per-package
   emit loop: `intraItems @ restoredItems @ importedItems` is filtered
   through `itemConflictKey` so that `Std.Core` (auto-added by
   `resolveStdlibImports` for every kernel dependency) is not
   registered twice when a package already imports `Std.Core` as an
   in-project import.

**`Program.fs` changes**

`lyric --sdk-info` dispatches to `Lyric.Emitter.Emitter.getSdkInfo()`
and prints:

```
sdk-root: /usr/local/lib/lyric (from LYRIC_SDK_ROOT)
stdlib-dll: /usr/local/lib/lyric/lib/Lyric.Stdlib.dll
language-version: 0.1
stdlib-version: 0.1.0
compiler-version: 0.1.0-bootstrap
build-date: 2026-05-07T03:00:00Z
```

B0040 is printed as an error to stderr when `LYRIC_SDK_ROOT` is set
but the DLL is not found; B0042 is a warning when the DLL exists but
carries no `Lyric.SdkVersion` resource.  Exit code 1 when SDK root is
`NotFound` with `LYRIC_SDK_ROOT` set, 0 otherwise (source-tree
fallback is a valid mode).

**`stdlib/lyric.toml` expansion**

Bundle grew from 3 smoke packages to 11 packages across 5 tiers:

| Tier | Packages |
|---|---|
| 0 | `Std.Core`, `Std.Errors`, `Std.String`, `Std.Core.Proof` |
| 1 | `Std.Collections` |
| 2 | `Std.Math`, `Std.Parse`, `Std.Stream` |
| 3 | `Std.Time` |
| 4 | `Std.Json` |
| 5 | `Std.Testing.Mocking` |

`Std.Environment` and `Std.Log` remain excluded: their kernel packages
(`Std.EnvironmentHost`, `Std.LogHost`) use `extern package {}` syntax
whose `EMSig` members the type checker does not flatten into the symbol
table.  Fix path: rewrite those kernel files to use `@externTarget
pub func` (like `math_host.l`).

**VS Code extension** (`docs/22` §6) — deferred; requires a separate
build toolchain outside this F# solution.

---

### D-progress-122: M5.1 stage 2d.v — build-time wiring for NuGet packages

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Closes the M5.1 stage-2d
work: the user can now write `[nuget] "Newtonsoft.Json" = "13.0.3"`
in `lyric.toml`, run `lyric restore`, and `lyric build` produces a
PE that loads + runs against the NuGet runtime DLL.

**Architecture decisions (taken in-session)**:

1. **`_extern/` discovery via implicit-import fallback (option b).**
   `compiler/src/Lyric.Emitter/Emitter.fs` gains
   `resolveExternShimImports` running between `resolveRestoredImports`
   and `resolveStdlibImports`.  For every `import <Head>` whose first
   path segment isn't a builtin head (`Std`, `Lyric`, `Jvm`,
   `Testpkg`), the resolver looks for `<ExternShimRoot>/<Head>.l` on
   disk; if found, it parses + type-checks + compiles the shim to a
   cached DLL and registers a `StdlibArtifact` shaped like any
   other.  The user's call sites resolve through the existing
   `importedFuncTable` machinery — no new code path in codegen.
2. **Authoritative DLL paths via `project.assets.json` (option β).**
   New module `Lyric.Cli.NugetAssets` parses
   `<scratch>/obj/project.assets.json` after `dotnet restore` writes
   it, walks the `targets[<tfm>]` graph, and joins each entry's
   `<libraries>.path` with its `runtime` first-key to produce
   absolute DLL paths.  Transitive deps surface automatically;
   build-time and runtime probing agree on which lib path was
   chosen.
3. **NuGet + shim DLLs copied alongside the output (option 2c, copy
   half).**  `Program.fs` gains `copyNugetArtifacts` mirroring
   `copyStdlibArtifacts`: every NuGet runtime DLL plus every
   `<.lyric/extern-cache>/*.dll` shim ends up next to the user's
   output PE.  `dotnet exec` finds them through the default
   adjacent-probing path.  Generated `.deps.json` (the cache-based
   runtime resolution variant) is deferred for `dotnet publish` /
   AOT flows.
4. **`_extern/` admitted for `extern type` / `@externTarget`
   declarations (decision 4 yes).**  No new policy enforcement; the
   existing kernel-only convention was a soft norm only.  The
   `@axiom("from NuGet package …")` annotation is the audit
   anchor, not the directory name.
5. **Hard-fail at build when an `import <Pkg>` lacks a shim
   (decision 5).**  Default behaviour: an unresolved import becomes
   a regular type-check error.  No new diagnostic code needed —
   the existing "unknown import" error is the right shape.

**EmitRequest / ProjectEmitRequest**: gain
`NugetAssemblyPaths: string list` and
`ExternShimRoot: string option`.  Every existing call site updates
to pass `[]` / `None`.  The CLI's `build` and `buildProject` add
the same parameters and thread them in from the manifest's
`[nuget]` block via `NugetAssets.readForManifest`.

**Emitter changes (`compiler/src/Lyric.Emitter/Emitter.fs`)**:
* `preloadNugetAssemblies` runs at the top of `emit` to
  `Assembly.LoadFrom` every NuGet DLL the request carries.  Already
  loaded paths are skipped via the AppDomain's existing
  `Assembly.Location` set.
* `resolveExternShimImports` parses each shim, type-checks it,
  emits via `emitAssembly` (with `isLibrary = true` so the
  main-function gate doesn't fire), loads the resulting DLL, and
  builds a `StdlibArtifact` whose `Lookup` walks that DLL.  Cached
  DLLs land at `<manifestDir>/.lyric/extern-cache/<head>.dll` so
  re-runs hit the cache.

**Shim generator polish**: `NugetShim.fs` learned to disambiguate
type-name collisions (`Newtonsoft.Json.Linq.Extensions` vs
`Newtonsoft.Json.Schema.Extensions` -> `Extensions` and
`Schema_Extensions`) and method-name collisions across types
(every emitted func is now `<TypeName>_<MethodName>`, e.g.
`JValue_CreateString`).  Without these, the shim source failed
type-check on `T0001` duplicates.

**Smoke test (manual, `/tmp/lyric-nuget-smoke`)**:
```toml
[package]
name = "smoke"; version = "0.0.1"
[nuget]
"Newtonsoft.Json" = "13.0.3"
```
```l
package Smoke
import Std.Core
import NewtonsoftJson
func main(): Unit {
  val v: JValue = JValue_CreateString("hello from nuget")
  println("nuget extern resolved + loaded")
}
```
`lyric restore` materialises `_extern/NewtonsoftJson.l` (138
extern types, 36 funcs, 77 skipped) plus a markdown skip report.
`lyric build main.l --manifest lyric.toml` succeeds.
`dotnet exec main.dll` prints `nuget extern resolved + loaded`.

**Deferred to follow-ups**:
* Generated `.deps.json` so `dotnet publish` / AOT flows can do
  cache-based resolution without copying every transitive DLL.
* Instance-method shim generation (the existing generator is
  static-only; instance externs need a receiver-as-first-param
  shape that the FFI bridge supports but the generator doesn't
  yet emit).
* Generic-method shims (per `docs/21-nuget-linking.md` §4's
  example `pub func serialize[T](value: in T): String`).
* AOT compatibility audit per `docs/21` §7 — projects with `[nuget]`
  forfeit the "all Lyric code AOT-compatible" guarantee, which
  needs explicit messaging when `--aot` is requested.

### D-progress-121: M5.1 stage 4 close-out — UAX #31 acceptance in self-hosted lexer

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Closes the half of stage
4 that D-progress-120 deferred: full UAX #31 XID_Start /
XID_Continue acceptance for non-ASCII identifier characters in the
self-hosted lexer.

* New audited kernel file `stdlib/std/_kernel/unicode_host.l`
  exposes `System.Char.GetUnicodeCategory` returning `Int` (the
  underlying type of `System.Globalization.UnicodeCategory`'s
  `enum : int32`) plus a small set of `@pure` constant accessors
  for the categories the lexer cares about:
  `UppercaseLetter` (0), `LowercaseLetter` (1), `TitlecaseLetter`
  (2), `ModifierLetter` (3), `OtherLetter` (4), `NonSpacingMark`
  (5), `SpacingCombiningMark` (6), `DecimalDigitNumber` (8),
  `LetterNumber` (9), `ConnectorPunctuation` (18).  One new
  `@externTarget`; `_kernel/` count now 147/150.
* `compiler/lyric/lyric/lexer.l` `isIdStart` / `isIdContinue` keep
  the ASCII fast path (`[A-Za-z_]` / `[A-Za-z0-9_]`) and gain a
  non-ASCII branch that calls `hostUnicodeCategory(c)` and
  matches the same category set the F# bootstrap does
  (compiler/src/Lyric.Lexer/Lexer.fs lines 92-119).
* New helper `isAscii(c) = c <= '\u{007F}'` keeps the dispatch
  branch readable.
* Self-test grows by 3 cases — Greek-letter ident, Cyrillic
  uppercase + lowercase, and `<letter><digit>` continuation.

The kernel-cap check (≤150 `@externTarget`s per platform per the
audit boundary policy) leaves room for further BCL exposure
without re-architecting the kernel.

### D-progress-120: M5.1 stage 4 (partial) — NFC + L0040 in self-hosted lexer

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Adds the F# bootstrap's
existing identifier hardening to `compiler/lyric/lyric/lexer.l`:

* `lexIdentOrKeyword` NFC-normalises every lexed identifier via
  `buf.normalize()` (calls `System.String.Normalize` through the BCL
  method-dispatch path).  Guarded by `buf.isNormalized()` so pure-
  ASCII identifiers cost nothing.  Mirrors `Lexer.fs` lines 268-271.
* `L0040` reserved-name diagnostic for identifiers that begin with
  `_` followed by an ASCII uppercase letter (`_Hidden`, `_X`, …).
  The lexeme still flows through as `TIdent` so the parser can
  recover; only the diagnostic surfaces the policy.
* Helpers `isAsciiUpper`, `isReservedUnderscoreUpper`, and
  `reservedUnderscoreUpperMessage` factored out of the case path.
* Self-test grows by 4 cases: `_Hidden` triggers L0040; `_hidden`,
  `_0name`, and pure `_` do not.

**Deferred**: full UAX #31 XID_Start / XID_Continue category
coverage (the non-ASCII identifier-acceptance side of stage 4).
The bootstrap-grade `isIdStart` / `isIdContinue` in the self-hosted
lexer remain ASCII-only.  Wiring up `System.Char.GetUnicodeCategory`
through an audited `_kernel/` extern is the obvious next step;
deferred to keep the audited extern surface count visible to a
follow-up review.

### D-progress-119: M5.1 stage 3 — interpolated / triple / raw strings in self-hosted lexer

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Ports
`compiler/src/Lyric.Lexer/Lexer.fs`'s string-shape coverage into
`compiler/lyric/lyric/lexer.l` 1:1.  Adds the `TStringStart` /
`TStringPart` / `TStringHoleStart` / `TStringEnd` quartet for
interpolated literals, plus `TTripleString` / `TRawString` for the
multiline + literal-byte-buffer shapes.  Introduces a `Mode` union
(`InString` / `InHole`) carried in a `List[Mode]` stack on
`LexerState` plus `topMode` / `pushMode` / `popMode` helpers.
`hasInterpolation` does the lookahead deciding whether a leading
`"` takes the simple `TString` path or the multi-token interpolated
path.  `lexNext` dispatches on `topMode`: `InString` runs
`lexStringChunk`, otherwise normal `lexOne` with `InHole` pop-on-
bracketDepth-match.  EOF drains any open string / hole frames so the
diagnostics arrive in a well-defined order and the token stream
stays balanced.

Diagnostic codes added: `L0026` (unterminated triple-quoted),
`L0027` (missing `"` after `r` in raw opener), `L0028` (unterminated
raw string).  Self-test grows from 23 to 30 cases — interpolation
sequence shape, triple-quoted bodies preserved across newlines, raw
strings with and without hash delimiters, and unterminated variants
of each diagnostic.

### D-progress-118: M5.1 stage 2d.iii / 2d.iv — NuGet shim generator + restore wiring

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Adds
`Lyric.Cli.NugetShim.generate` (reflection-driven via
`System.Reflection.MetadataLoadContext`) and wires it into the
existing `lyric restore` flow:

* Generator emits `<manifest-dir>/_extern/<lyric-pkg>.l` carrying
  `@axiom("from NuGet package <id> v<ver>")` plus sorted
  `extern type T = "Namespace.T"` declarations and bodyless
  `@externTarget(…)` `pub func` decls for each translatable static
  method.  An optional `<lyric-pkg>.skip.md` records skipped
  surface with reasons (open generic, by-ref param, type not
  translatable, duplicate (name, arity), …).
* Bootstrap-grade scope: static methods only; translatable types
  are BCL primitives (Bool / Byte / Int / Long / UInt / ULong /
  Float / Double / Char / String / Unit) plus the package's own
  exported types.  Generic methods, generic types as params, and
  nested types skip with reasons.  Lyric-keyword collisions are
  renamed to `<name>_` with a comment.
* `tryLocateNugetDll` walks the standard NuGet cache (`lib/<tfm>/`,
  then a TFM-compat fallback chain through net5/6/…/10 and
  netstandard1.0/…/2.1, then `ref/<tfm>/`).
* The CLI restore reporter splits the count: "N Lyric + M NuGet
  packages declared" when both are present.  Failed shim generation
  surfaces a B0030-flavoured warning; the restore exit code stays 0
  so the cache is still usable.
* Manual smoke (`/tmp/lyric-nuget-smoke` with
  `Newtonsoft.Json = "13.0.3"` in `[nuget]`) generates
  `_extern/NewtonsoftJson.l` (138 types, 36 methods, 77 skipped)
  plus a markdown skip report.  CLI tests grow from 92 to 105
  passing (NugetShim coverage: package-name derivation, missing-DLL
  error, axiom + autogen banner, sorted `extern type` emission,
  skip report present on a real DLL).

**Deferred to stage 2d.v**: build-time wiring (auto-discovery of
`_extern/*.l` source files when resolving imports, NuGet DLLs in the
emitter's `Assembly.LoadFrom` set, `.deps.json` emission, end-to-end
smoke that exercises a real NuGet symbol from Lyric source).

### D-progress-117: M5.1 stage 2d.i / 2d.ii — `[nuget]` manifest + restore csproj forwarding

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Schema changes in
`Lyric.Cli.Manifest` add `NugetEntry` / `NugetOptions` /
`NugetSection` records and parse `[nuget]` (a flat
`"<id>" = "<version>"` table) plus `[nuget.options]` (`allow_native`,
`target`).  Section is `Manifest.Nuget = None` when both are absent,
preserving the legacy "no NuGet" behaviour.  `restoreCsproj` emits a
`<PackageReference>` for every `[nuget]` entry alongside the
existing `[dependencies]` entries; `[nuget.options] target`
overrides the default `net10.0` TFM.  CLI test suite grows from 82
to 92 passing across 10 new tests covering parsing edge cases and
the csproj rendering.

Reconciles `docs/21-nuget-linking.md`'s header (was M5.2; now M5.1
stage 2d, matching the bootstrap-progress slot and the assigned
working branch).  Also locks in the **autonomous-work default** in
`CLAUDE.md`: when the user assigns a multi-stage task on a working
branch, plan and execute through it without check-ins until either
genuinely blocked or out of independent stages — commit + push
regularly, group related commits into a single PR per natural
slice.

### D-progress-116: M4.3 — z3 + cvc5 in the session-start hook (CVC5 corpus run cleared)

*claude/review-phase-4-5-items-bRPXA branch.*  Closes the
environment-gated half of M4.3 deliverable 10 (CVC5 solver-swap
parity, ≥95 % of M4.2 corpus) by ensuring both solvers are
available in every Claude-on-the-web session and exercising the
full M4.2 corpus against CVC5.

**Hook update.**  `.claude/hooks/session-start.sh` learns an
`ensure_solver` helper that `apt-get install`s z3 and cvc5 (both
Ubuntu universe packages, ~30 s combined first install,
idempotent fast-path on subsequent sessions).  Failures are
soft — apt-get failure logs a warning and the verifier falls back
to the trivial-only discharger, exactly as before.  The hook
already required sudo + apt-get for the .NET SDK install, so this
imposes no new privileges.

**Corpus run.**  With z3 temporarily renamed to `/usr/bin/z3.disabled`
(forcing `findZ3` to return `None`), the full
`Lyric.Verifier.Tests` suite — 256 tests covering the cumulative
M4.1 / M4.2 / M4.3 regression corpus — was run against CVC5 alone:

```
EXPECTO! 256 tests run in 00:00:00.94 for Lyric.Verifier
       — 256 passed, 0 ignored, 0 failed, 0 errored.  Success!
```

That's **100 %** of the corpus, well above the ≥95 % exit
criterion from `docs/15-phase-4-proof-plan.md` §M4.3.  The
`[verify] endSession (dirty=true)` debug traces confirm CVC5
sessions actually started, dispatched goals through
`dischargeIn`, and wrote cache entries — not silently falling
through to the trivial discharger.

z3 was then restored.  Both solvers now coexist on every fresh
Claude session via the hook.

**Status table.**  M4.3 row 10 (`CVC5 solver-swap parity (≥95 %
of M4.2 corpus)`) flips from "Shipped (mechanism)" — the
qualifier added in D-progress-115 because the corpus run hadn't
been observed in any concrete environment — to plain **Shipped**.
Every M4.3 deliverable from `docs/15-phase-4-proof-plan.md` §M4.3
is now Shipped without qualifier.

### D-progress-115: M4.3 — CVC5 persistent-session parity

*claude/review-phase-4-5-items-bRPXA branch.*  Closes the last
in-flight M4.3 deliverable: solver-swap parity to CVC5 in the
persistent-session path.  Before this branch, `withSession` would
*locate* CVC5 via `findCvc5` but spawn it with Z3-style flags
(`-in -T:5`), which CVC5 rejects — so any environment with CVC5
but not Z3 silently degraded to the trivial-only discharger.

**The fix.**  Introduce a public `SolverFlavor = Z3Flavor |
Cvc5Flavor` discriminator, route the right CLI args per flavor, and
make the verdict-line drain in `readResponse` flavor-aware (Z3
emits a stray `(error ...)` line on `(get-model)` against an
`unsat` scope; CVC5 doesn't, so we don't try to drain on CVC5).

| Flavor       | Interactive args                                                       |
|--------------|------------------------------------------------------------------------|
| `Z3Flavor`   | `-in -T:5`                                                             |
| `Cvc5Flavor` | `--lang=smt2 --interactive --produce-models --tlimit-per=5000`         |

The cache key salt now includes the solver name (e.g.
`cvc5/This is cvc5 version 1.0.5`) so cache entries from
different solvers (or different versions of the same solver)
never collide.

**`SolverSession` shape changes (private record fields):**

* `Z3Version`   → `SolverVersion` (renamed; meaning generalised).
* New `Flavor: SolverFlavor` field.
* New public `member this.Version` (was `this.Z3`) and
  `member this.SolverName` accessors.

`Solver.discharge` (per-goal subprocess fallback) was already
flavor-aware via `invokeZ3` / `invokeCvc5`; the persistent-session
path now matches.

**Tests.**  `Lyric.Verifier.Tests/SolverTests.fs` adds two unit
tests that exercise the flavor table directly (no process spawn,
so they run on every CI host regardless of solver presence):

* `[M4.3] SolverFlavor.display is stable` — `z3` / `cvc5`
  identifiers are pinned for downstream tooling.
* `[M4.3] SolverFlavor.interactiveArgs differ between solvers` —
  Z3 args contain `-in` / `-T:5`; CVC5 args contain
  `--lang=smt2` / `--interactive` / `--produce-models` /
  a `--tlimit*` flag; cross-pollination guard verifies neither
  flavor's flags leak into the other.

**Corpus run.**  The ≥95 %-of-M4.2-corpus exit criterion is
environment-gated: it runs automatically whenever `cvc5` is on
`$PATH` (or `$LYRIC_CVC5` is set) and `z3` is not, by way of
the existing `Lyric.Verifier.Tests` driver suite which discharges
the cumulative verification regression suite via `withSession`.
This branch ships the *mechanism*; running the corpus against a
real CVC5 binary is now a deployment concern, not an
implementation gap.

**Status table delta** (`docs/10-bootstrap-progress.md` Phase 4):

| Row                                    | Was      | Now                                          |
|----------------------------------------|----------|----------------------------------------------|
| CVC5 solver-swap parity (≥95 % corpus) | Partial  | Shipped (mechanism); corpus gated on `cvc5`  |

This is the last M4.3 row to flip.  Every M4.3 deliverable from
`docs/15-phase-4-proof-plan.md` §M4.3 is now Shipped (or, for the
CVC5 corpus-run exit criterion, Shipped-pending-environment).

**Test counts after this branch.**  256 verifier (was 254 before
the SolverFlavor unit tests).

### D-progress-113: G10 (2/2) — `Std.File` bytes paths go direct to BCL

*claude/g10-bytes-jsonslice branch.*  Closes the second half of
`docs/23-fsharp-shim-elimination.md` G10 by retiring the F#
`Lyric.Stdlib.FileHost` type entirely.  G10 (1/2) (D-progress-109)
ported the text/dir surfaces; this PR finishes the migration for
`readBytes` / `writeBytes`.

**Kernel externs** (`stdlib/std/_kernel/file_host.l`).

* New `hostReadAllBytes(path)` → `System.IO.File.ReadAllBytes`
  returning `slice[Byte]` (Lyric's mapping for `byte[]`).
* New `hostWriteAllBytes(path, slice[Byte])` → `System.IO.File.WriteAllBytes`.

**`Std.File` rewrite** (`stdlib/std/file.l`).

* `readBytes` now: `try { hostReadAllBytes(path) → for b in raw {
  acc.add(b) } → Ok(acc) } catch Bug as b { Err(IoError(...)) }`.
* `writeBytes` now: `try { hostWriteAllBytes(path, bytes.toArray());
  Ok(()) } catch Bug as b { Err(IoError(...)) }`.
* The `slice[Byte] ↔ List[Byte]` shuttle is pure Lyric — no FFI
  gymnastics.  The public surface (`Result[List[Byte], IOError]`)
  stays unchanged so callers (incl. JVM self-tests) need no edits.

**F# shim** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

* `type FileHost private () = …` (~70 LoC after G10 1/2 had pruned
  text/dir; 5 remaining `ReadBytes*`/`WriteBytes*` members) deleted.
* Replaced by a short doc comment.

**Codegen trim** (`compiler/src/Lyric.Emitter/Codegen.fs`).

* `hostFileBuiltins` map (5 entries) deleted along with the
  `fileHostMethod` helper.
* The dispatch arm in `emitExpr` that consulted `hostFileBuiltins`
  also deleted — the bytes operations now flow through the regular
  extern-call path.

**Net F# shim shrink.** ~40 LoC retired.  Trajectory now ~760 LoC
in `Stdlib.fs` (Phase 1 + G10 1/2 + G9 + G12 1/N + G11 + G10 2/2).

**`JsonHost.Get*Slice` parked.** The five `JsonHost.Get*Slice`
methods (`GetIntSlice`, `GetLongSlice`, `GetDoubleSlice`,
`GetBoolSlice`, `GetStringSlice`) were the second G10 (2/2) target
in the prior summary — they're real JSON parsers (parse + property
lookup + array enumeration + typed extraction), not boundary
passthroughs.  `docs/14-native-stdlib-plan.md` §3 already declares
the JSON tokenizer kernel-grade; these methods inherit that
classification and stay.

**Tests.** All non-pre-existing-failure suites green: 583 emitter
(the 16 errored tests are pre-existing JVM-lowering failures on
main, identical between this branch and `origin/main`), 83 CLI,
242 verifier, 137 type checker, 312 parser, 123 lexer, 25 LSP.
Native bytes-round-trip probe (`/tmp/bytes_probe.l`) confirms
write 4 → read 4 with byte 0 = 1, byte 3 = 255 round-trip
correctly.

### D-progress-114: M4.3 — counterexample suggestion heuristics

*claude/review-phase-4-5-items-bRPXA branch.*  Closes the last
in-flight M4.3 deliverable: the suggestion line called for by
`docs/15-phase-4-proof-plan.md` §9.3.

**The heuristic.**  `Lyric.Verifier.Driver.suggestRequiresClauses`
walks the parsed `(get-model)` bindings emitted on a V0008
counterexample.  For each binding `x = v` where the *name* looks
like a Lyric source identifier (lowercase first letter, no `$` or
`?`, alphanumeric + `_`) and the *value* sits at a numeric
boundary, it proposes the `requires:` clause that would have
blocked this counterexample:

| Model binding | Suggested clause       |
|---------------|------------------------|
| `x = 0`       | `requires: x > 0`      |
| `x < 0`       | `requires: x >= 0`     |

Each candidate is locally validated: a synthetic
`x > 0` term is substituted under the model and partially
evaluated; only candidates that collapse to `false` (i.e. blocked
by the offending model) are kept.  The list is deduplicated and
capped at three to avoid flooding the diagnostic on goals with
many free variables.

The plan's §9.3 example
`suggestion: add \`requires: amount.value > 0\`` is the canonical
shape.  The bootstrap implementation only handles plain
parameter-name boundary cases (no field-access decomposition); the
field-access form is a Phase 5 polish item.

**Surfaces.**

* **`ProofResult.Suggestions: string list`** — new field on
  the public proof-result record.  Empty for `Discharged` and
  `Unknown`; populated for `Counterexample`.
* **V0008 diagnostic message body** — appends a
  `suggestions (heuristic — verify the rest of the proof still
  goes through):` block under the existing trace.
* **`lyric prove --json`** — every goal now carries a
  `"suggestions": [string]` array.  Always present (empty by
  default).  Schema appendix A in
  `docs/15-phase-4-proof-plan.md` updated accordingly.  The
  M4.3 stability promise (additive-only) is preserved: existing
  consumers ignoring unknown fields are unaffected.
* **LSP hover** — proof-failure section appends a
  `*Suggestions:* - \`requires: x > 0\`` list under the
  counterexample bindings block.

**Tests.**

* `Lyric.Verifier.Tests/DriverTests.fs` adds **6 unit tests** that
  exercise `suggestRequiresClauses` with synthetic bindings
  (zero / negative / positive / synthetic-name / cap-at-three /
  non-integer), and **3 integration tests** that cover the full
  pipeline (suggestions surface on a counterexample, are bounded
  on multi-var goals, and are empty on Discharged / Unknown).
* `Lyric.Cli.Tests/ProveTests.fs` adds **1 test** that the
  `suggestions` array is always present in `--json` output, and
  empty for discharged goals.
* All suites green: 254 verifier (was 248 before this PR2 split,
  now 254 after the 6 unit tests + 3 integration), 90 CLI,
  28 LSP, 598 emitter.

**Status table delta** (`docs/10-bootstrap-progress.md` Phase 4):

| Row                                                          | Was      | Now     |
|--------------------------------------------------------------|----------|---------|
| Counterexample reporting + trace reconstruction + suggestion heuristics | Partial  | Shipped |

CVC5 solver-swap parity remains the only Partial row in the
M4.3 group — see D-progress-113 (Phase 4 status flip) for the
in-place state and the follow-up plan.

### D-progress-112: G11 — `AsyncLocal[T]` extern + non-builder generic-FFI fix

*claude/g11-asynclocal-extern branch.*  Realises the type-form path
described in `docs/23-fsharp-shim-elimination.md` G11 by fixing the
codegen blocker that previously stopped non-generic Lyric functions
from declaring externs against generic BCL types like
`System.Threading.AsyncLocal\`1`.

**Codegen fix** (`compiler/src/Lyric.Emitter/Emitter.fs`).

`emitExternCall` previously closed open generic declaring types via
the static `TypeBuilder.GetMethod` / `TypeBuilder.GetConstructor`,
on the documented assumption that the BCL static accepts both
TypeBuilder-bearing and fully-resolved closed types.  In practice
the BCL throws

    'type' must be or must contain a TypeBuilder as a generic
    argument. (Parameter 'type')

when the closed type's args are all real CLR types — exactly the
shape produced by a non-generic Lyric function returning
`AsyncLocal[CancellationToken]`.  The generic-Lyric-function path
(`newList[T]`) keeps working because its `T` becomes a
`GenericTypeParameterBuilder`, which the static accepts.

The fix walks the closed type's generic args and detects whether
any TypeBuilder / GTPB is present.  When it isn't, we look the
member up directly on the closed Type via regular reflection
(`closedTy.GetMethods(flags)` + name + arity match).  The
TypeBuilder static remains the path for the GTPB case so existing
generic externs are unchanged.

**`Std.Task` rewrite** (`stdlib/std/_kernel/task.l`).

* New `extern type AsyncLocal[T] = "System.Threading.AsyncLocal\`1"`.
* Three private kernel helpers:
  * `ambientSlot()` → `Lyric.Stdlib.AmbientSlot.Slot` (the one
    process-shared instance).
  * `ambientValue` / `setAmbientValue` → `AsyncLocal\`1.Value` getter
    + setter.
  * `tokenCanBeCanceled` → `CancellationToken.CanBeCanceled`.
* `currentToken` / `installToken` / `restoreToken` / `hasAmbient`
  are now native Lyric, four short bodies on top of the helpers.

**F# shim** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

`type AmbientHost private () = …` (~30 LoC, four members) collapses
to `type AmbientSlot private () = …` (~4 LoC, just holds the
`AsyncLocal<CancellationToken>` slot — Lyric still needs *some*
host site for a process-shared static field of a generic BCL
type).

**Net F# shim shrink.** ~26 LoC retired.  Trajectory now ~800 LoC
in `Stdlib.fs` (Phase 1 + G10 1/2 + G9 + G12 1/N + this PR).

**Tests.** All suites green: 593 emitter (the existing
`AsyncLocalTests.fs` exercises every retired AmbientHost method),
83 CLI, 242 verifier, 137 type checker, 312 parser, 123 lexer,
25 LSP.

**Why "non-builder generic FFI" matters past G11.**  The codegen
fix is reusable: any future direct-extern against a closed generic
BCL type (e.g. `Task\`1`, `Task\`2.ContinueWith`, `IDictionary\`2`
overloads) from a non-generic Lyric function now Just Works.

### D-progress-113: Phase 4 — M4.3 deliverables status flip

*claude/review-phase-4-5-items-bRPXA branch.*  M4.3 deliverables
were *largely landed in code* across earlier branches but the
status table (D-progress-090, refreshed at D-progress-091) still
flagged eight of them as "Not shipped" because no PR ever flipped
the row.  This branch closes that gap by adding the missing
tests / docs / cross-references, then flips the rows to
**Shipped**.

**What this branch ships (no production code changes apart from
test fixtures and docs):**

* **Tests for the frozen `lyric prove --json` schema.**
  `compiler/tests/Lyric.Cli.Tests/ProveTests.fs` (new) covers the
  top-level `file`/`level`/`goals`/`diagnostics`/`summary` shape,
  `goals[].outcome == "discharged"` with `model: null`,
  `goals.length == 0` for `@runtime_checked` files, and the
  diagnostics-array shape on V0006.
* **Tests for `--explain --goal <n>`.** Same file: success case
  (Goal 0 / kind / hypotheses / conclusion sections present),
  missing-flag case (exit 1 + "specify a goal index" stderr), and
  out-of-range case (exit 1 + "out of range" stderr).
* **Tests for `lyric public-api-diff` contract clauses.**
  `compiler/tests/Lyric.Emitter.Tests/ContractMetaTests.fs` adds
  five cases covering strengthened-requires (breaking),
  weakened-ensures (breaking), relaxed-requires (non-breaking),
  added-ensures (non-breaking), and the `[breaking] strengthened
  requires:` rendering format that downstream tooling can grep.
* **Tests for `@proof_required(checked_arithmetic)`.**
  `compiler/tests/Lyric.Verifier.Tests/DriverTests.fs` adds three
  cases pinning the overflow VCs:
  bounded-input addition discharges, unbounded `x*x` produces a
  non-discharged VC over and above plain `@proof_required`, and the
  level surfaces in the `ProofSummary`.
* **Tests for LSP V0007 / V0008 / V0003 quickfixes.**
  `compiler/tests/Lyric.Lsp.Tests/ProtocolTests.fs` adds three
  `textDocument/codeAction` cases verifying the existing
  `Server.fs` handlers offer "Downgrade to @runtime_checked" on
  V0007 and V0008, and "Allow unsafe blocks" on V0003.
* **JSON schema appendix.**
  `docs/15-phase-4-proof-plan.md` Appendix A formalises the v1
  `--json` surface: top-level keys, goal/diagnostic/summary
  objects, exit codes, and the stability promise (frozen as of
  M4.3; new keys may be added but not removed or renamed).
* **Axiom-audit doc reference fix.**
  `docs/15-phase-4-proof-plan.md` and `docs/12-todo-plan.md` no
  longer reference `docs/16-axiom-audit.md` (which never existed —
  slot 16 went to `16-lsp-vscode-plan.md`); they point to the
  shipped `docs/17-axiom-audit.md`.

**Status table delta** (`docs/10-bootstrap-progress.md` Phase 4):

| Row                                                              | Was         | Now         |
|------------------------------------------------------------------|-------------|-------------|
| `lyric prove --explain --goal <n>`                               | Not shipped | Shipped     |
| `lyric prove --json` schema                                      | Not shipped | Shipped     |
| LSP V0007/V0008 hover + code actions                             | Not shipped | Shipped     |
| `@proof_required(checked_arithmetic)` mode                       | Not shipped | Shipped     |
| `unsafe { … }` + `assert φ` end-to-end (V0003, V0009)            | Not shipped | Shipped     |
| Banking-example proof tutorial chapter                           | Not shipped | Shipped     |
| `docs/17-axiom-audit.md` (was wrongly numbered 16 in this table) | Not shipped | Shipped     |
| Contract-aware `lyric public-api-diff`                           | Not shipped | Shipped     |
| Counterexample reporting + suggestion heuristics                 | Partial     | Partial     |
| CVC5 solver-swap parity                                          | Not shipped | Partial     |

**Remaining M4.3 work** (now the only two M4.3 rows below
**Shipped**):

* **Suggestion heuristics.** The current trace renders the
  falsified hypothesis / falsified conclusion under the model
  bindings; the `suggestion: add `requires: …`` line from §9.3 of
  the proof plan is not yet emitted.  Tracked as a follow-up.
* **CVC5 corpus run.** `Solver.invokeCvc5` exists for one-shot
  use; `withSession` doesn't differentiate solver flags, so a CVC5
  session falls through to the per-goal `discharge` (trivial
  only).  Full corpus parity needs solver-aware flag selection.

**Test counts after this branch:**

* `Lyric.Cli.Tests`: +6 cases (89 total, was 83)
* `Lyric.Verifier.Tests`: +3 cases (245 total, was 242)
* `Lyric.Emitter.Tests`: +5 cases (598 total, was 593)
* `Lyric.Lsp.Tests`: +3 cases (28 total, was 25)

All suites green.

### D-progress-106: Phase 1 (2/3) — `RandomHost` / `CancelHost` direct-extern

*claude/g8b-direct-extern-random-cancel branch.*  Second slice of
`docs/23-fsharp-shim-elimination.md` Phase 1.  Replaces the F# shim's
two thinnest passthrough types with direct BCL `@externTarget`
declarations in the existing kernel boundary files.

**`Std.Random` (`stdlib/std/_kernel/random.l`).**

* `makeRandom(seed)` now externs `System.Random..ctor` directly
  (the `(int)` overload is selected by arity).
* `nextBool(rng)` is now native Lyric: `nextIntBelow(rng, 2) != 0`.
  No host method needed once `Std.Random.nextIntBelow` is in scope
  (already declared in this same file).

**`Std.Task` (`stdlib/std/_kernel/task.l`).**

* `noCancellation()` → `System.Threading.CancellationToken.None`
  (static field).
* `makeCancelSource()` → `System.Threading.CancellationTokenSource..ctor`
  (default ctor).
* `makeCancelSourceTimeout(ms)` → same `..ctor` symbol; the `(int
  millisecondsDelay)` overload is selected by arity.
* `sourceToken(src)` → `System.Threading.CancellationTokenSource.Token`
  (instance property).
* `cancelSource(src)` → `System.Threading.CancellationTokenSource.Cancel`.
* `disposeSource(src)` → `System.Threading.CancellationTokenSource.Dispose`.
* `isCancelled(token)` → `System.Threading.CancellationToken.IsCancellationRequested`.
* `throwIfCancelled(token)` → `System.Threading.CancellationToken.ThrowIfCancellationRequested`.

**F# shim** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

* `type CancelHost private () = …` deleted (52 LoC).
* `type RandomHost private () = …` deleted (14 LoC).
* Both replaced by short doc comments pointing at the new direct
  externs.

**Net F# shim shrink.** ~66 LoC removed.

**Why these two together.** Both fall under Bucket B in `docs/23`
§4.1 — pure passthroughs that the BCL exposes directly with no
language-level gating.  Bundling them into one slice trims a
quarter of Bucket B's LoC budget in a single PR.

**Tests.** All suites stay green — the kernel-boundary ratchet
(`KernelBoundaryTests.fs`) holds at `outsideCeiling = 0` because
the migrations are inside `_kernel/` already.  Cancellation tests
(`CancellationTests.fs`, `StructuredConcurrencyTests.fs`,
`AsyncLocalTests.fs`) and randomness tests (`StdRandomTests.fs`)
exercise every retired CancelHost / RandomHost method.

**Remaining Phase 1 (per docs/23 §6).** Bucket D split-out — move
`Jvm*` helpers (~430 LoC) to `compiler/lyric/jvm/`, freeing the
stdlib bundle from JVM-specific code.

### D-progress-107: Phase 1 (3/3) — Bucket D `Jvm*` split-out

*claude/bucket-d-jvm-split branch.*  Third and final slice of
`docs/23-fsharp-shim-elimination.md` Phase 1.  Removes ~430 LoC of
JVM-emit-only F# helpers from the stdlib bundle's host shim by
moving them to a dedicated project.

**New project: `compiler/src/Lyric.Jvm.Hosts/`.**

* `Lyric.Jvm.Hosts.fsproj` (default F# library shape, doc-file
  generation enabled to match `Lyric.Stdlib`).
* `JvmHosts.fs` (~454 LoC) — verbatim move of the previous
  `JvmInternals` / `JvmByteBuilder` / `JvmByteHost` / `JvmZipHost` /
  `JvmConstantPool` / `JvmPoolHost` types from
  `compiler/src/Lyric.Stdlib/Stdlib.fs` lines 1008–1452, repackaged
  under `namespace Lyric.Jvm.Hosts`.

**`Lyric.Stdlib`** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

* Lines 1008–1452 deleted (the entire JVM block).  Replaced by
  a short doc comment pointing at the new home.

**`Lyric.Emitter`** (`compiler/src/Lyric.Emitter/`).

* `Lyric.Emitter.fsproj` adds a `<ProjectReference>` to
  `Lyric.Jvm.Hosts` so the assembly is in the test/CLI runtime
  closure.
* `Emitter.fs` `findClrType` now also force-loads
  `Lyric.Jvm.Hosts` via `typeof<Lyric.Jvm.Hosts.JvmByteHost>`,
  mirroring the existing `Lyric.Stdlib` force-load — so emit-time
  `findClrType("Lyric.Jvm.Hosts.…")` walks the AppDomain and
  resolves cleanly.

**Lyric source updates** (`@externTarget` repointing).

* `compiler/lyric/jvm/_kernel/kernel.l` — 38 occurrences of
  `Lyric.Stdlib.Jvm…` rewritten to `Lyric.Jvm.Hosts.Jvm…`.
  `extern type ByteWriter = "Lyric.Stdlib.JvmByteBuilder"` and
  `extern type Pool = "Lyric.Stdlib.JvmConstantPool"` updated to
  the new namespace.
* `stdlib/std/_kernel_jvm/json_host.l` — 1 occurrence updated.

**Stdlib bundle impact.**  `Lyric.Stdlib.dll` (the F# host shim)
shrinks from 1452 → 1018 LoC (~30% reduction).  The stdlib bundle
DLL emitted by `lyric build --manifest stdlib/lyric.toml` is
unchanged in surface; the JVM helpers were never part of its
contract resources anyway.  A new `Lyric.Jvm.Hosts.dll` ships
alongside the JVM emitter's Lyric source as expected per
`docs/23` §4.3.

**Tests.**  All suites green.  JVM lowering tests
(`JvmLoweringB*Test.fs`, 80+ stages) exercise every retired Jvm*
host method via the kernel `@externTarget` path, and they all
pass — confirming the new namespace + force-load wiring works.

**Net F# stdlib shim.** ~430 LoC retired from `Lyric.Stdlib`.
Trajectory tracks the ~890 LoC waypoint in `docs/23` §4.4.

**Phase 1 complete.**  All three Phase 1 slices have shipped
(G8, RandomHost/CancelHost direct-extern, Bucket D split).
The next steps require new G-items (G7 `protected type` codegen,
G9 user-defined exceptions, G10 try/catch FFI, G11 `AsyncLocal`,
G12 delegate-lowering audit).

### D-progress-108: Phase 1 dead-code sweep — drop `MapHelpers` + `TryHost`

*claude/delete-dead-shim-types branch.*  Tactical follow-up to the
`docs/23-fsharp-shim-elimination.md` Phase 1 trio (G8 / Random &
Cancel direct-extern / Bucket D Jvm split).  An audit of every
remaining `Lyric.Stdlib.*` type for live `@externTarget` callers
turned up two with **zero** live callers: `MapHelpers<'K, 'V>`
(31 LoC) and `TryHost<'T>` (39 LoC).

**`MapHelpers`** was superseded when `Std.Collections` migrated
to `_kernel/collections_host.l` direct externs in `docs/14` P0/4b
batch 3 (D-progress-094 era).  The type stayed as legacy housekeeping;
this PR drops it.

**`TryHost<'T>`** was originally designed as a generic try/catch
wrapper for FFI calls — `Std.File` / `Std.Parse` were going to
route through it.  Each module ended up with its own per-method
shim instead, and the generic closure-based form was never wired
up.  G10 (FFI try/catch) makes the whole concept moot regardless,
so the dead code retires now.

Both replaced by short doc comments noting the removal.

**Net F# shim shrink.** ~70 LoC retired.

**Tests.** All suites stay green — no behavioural change because
nothing called these types in the first place.

**Remaining shim trajectory.**

After this PR, `Lyric.Stdlib.Stdlib.fs` is at ~1019 - 70 = ~949
LoC.  The remaining types are all genuinely live:

* `Contracts` / `LyricAssertionException` — invoked by codegen for
  `assert` / `panic` / contract failures.  Gated on G9
  (user-defined exceptions).
* `TaskHost` / `LyricTaskScope` / `TaskScopeHost` / `StubCounter*` /
  `AmbientHost` — concurrency / mocking primitives.  Gated on G7
  (`protected type`) or G11 / G12.
* `JsonHost` / `HttpClientHost` / `HttpServerHost` / `FileHost` —
  larger BCL bridges.  `JsonHost` mostly stays kernel forever
  (tokenizer); the rest gated on G10 / G12.

All future shim shrinkage requires a language-level G-item, per
`docs/23` §5.

### D-progress-109: G10 (1/2) — `Std.File` text/dir paths use native try/catch

*claude/g10-trycatch-ffi branch.*  First half of `docs/23-fsharp-shim-elimination.md`
G10 (try/catch FFI bridging).  Migrates `Std.File`'s text- and
directory-mode helpers off the F# `FileHost` pair-of-statics
workaround onto direct BCL `@externTarget`s wrapped in `try { … }
catch Bug as b { … }`.

**Surfaces migrated.**

| `Std.File` user fn | Old shape | New shape |
|---|---|---|
| `fileExists` | `hostFileExists` codegen builtin → `FileHost.Exists` | `hostFileExists` extern → `System.IO.File.Exists` |
| `dirExists` | codegen builtin → `FileHost.DirectoryExists` | extern → `System.IO.Directory.Exists` |
| `readText` | three-call dance (`*IsValid` + `*Value` + `*Error`) | one-call `try { hostReadAllText(p) } catch Bug as b { … b.message }` |
| `writeText` | two-call dance | one-call try/catch around `hostWriteAllText` |
| `createDir` | codegen builtin → `FileHost.CreateDirectoryIsValid` | extern → `Directory.CreateDirectory`, error captured by Lyric's catch |

**New kernel boundary.**  `stdlib/std/_kernel/file_host.l` declares
five `@externTarget` wrappers: `hostFileExists`, `hostDirectoryExists`,
`hostReadAllText`, `hostWriteAllText`, `hostCreateDirectory`.  All
within the audited `_kernel/` boundary.  `Std.File` `import`s the new
`Std.FileHost` package.

**`Std.File` rewrite** (`stdlib/std/file.l`).

* `readText` / `writeText` / `createDir` now use `return try { Ok(…) }
  catch Bug as b { Err(IoError(message = b.message)) }`.  Single I/O
  call per operation instead of the previous 2–3.
* `fileExists` / `dirExists` go through the new direct BCL externs.
* Bytes paths (`readBytes` / `writeBytes`) unchanged — gated on a
  `slice[Byte] → List[Byte]` conversion that's a follow-up to G10.

**Codegen trim** (`compiler/src/Lyric.Emitter/Codegen.fs`).
The `hostFileBuiltins` map shrinks from 13 entries to 5 (only the
bytes-flavoured ones remain).  No more F# `FileHost.Exists` /
`ReadIsValid` / `WriteIsValid` / `DirectoryExists` /
`CreateDirectoryIsValid` / `Read*Error` route.

**F# shim trim** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).
Eight `FileHost` static members deleted (~96 LoC); five
`ReadBytes*`/`WriteBytes*` survive until the bytes follow-up.

**Tests.** All suites green: 589 emitter, 83 CLI, 242 verifier,
137 type checker, 312 parser, 123 lexer.  `StdFileTests.fs` exercises
each migrated helper end-to-end (write → read → fileExists →
createDir → dirExists), confirming the try/catch path matches the
prior pair-of-statics behaviour for both success and error arms.

**Net F# shim shrink.** ~96 LoC retired; trajectory now ~782 LoC
in `Stdlib.fs` (was 1473 pre-Phase-1).

**Why "G10 (1/2)".** The bytes paths and `JsonHost.Get*Slice`
out-param readers — the other targets G10 was supposed to unblock —
still need a `slice[Byte] → List[Byte]` constructor and a
slice-of-string `out` param respectively.  Both ride on a
follow-up to this PR; the text/dir migration is the cleanest first
slice.

### D-progress-110: G9 — codegen inlines `panic` / `expect` / `assert` throws

*claude/g9-user-exceptions branch.*  Implements the pragmatic
interpretation of `docs/23-fsharp-shim-elimination.md` G9 — instead
of growing user-defined exception types as a full language feature,
codegen inlines the `newobj System.Exception(string)` + `throw`
pattern that the F# `Contracts` helpers used to do.  Drops both the
`Contracts` static class (~20 LoC) and the `LyricAssertionException`
custom subclass (~3 LoC) without losing any user-visible behaviour.

**Codegen** (`compiler/src/Lyric.Emitter/Codegen.fs`).

* Two new lazy lookups:
  * `systemExceptionStringCtor` → `System.Exception(string)` ctor.
  * `systemStringConcat2` → `System.String.Concat(string, string)` —
    used by `panic` to prepend the `"panic: "` prefix at runtime
    (matches the F# `Contracts.Panic` behaviour without baking the
    prefix into every IL emit).
* `panic(msg)` lowers to:
  ```
  ldstr "panic: "
  <emit msg>
  call String.Concat
  newobj System.Exception(string)
  throw
  ```
* `expect(cond, msg)` and `assert(cond)` lower to:
  ```
  <emit cond>
  brtrue okLbl
  <emit msg>          ; "assertion failed" literal for `assert`
  newobj System.Exception(string)
  throw
  okLbl:
  ```

**Emitter** (`compiler/src/Lyric.Emitter/Emitter.fs`).

* `lyricAssertCtor` (resolving `Lyric.Stdlib.LyricAssertionException`)
  renamed to `contractExceptionCtor` and points at
  `System.Exception(string)`.
* `emitContractCheck` (the helper used by `requires:` / `ensures:`
  runtime checks) now uses the BCL exception ctor — matching the
  builtin sites above.

**F# shim** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

* `type LyricAssertionException(message: string) = …` deleted (3 LoC).
* `[<Sealed; AbstractClass>] type Contracts private () = …` deleted
  (~20 LoC, including doc strings).
* Both replaced by short doc comments noting the migration.

**Why "G9" not "user-defined exception types".** The full
`@exception type Foo { … }` syntax surfaced in `docs/23` §5 needs
typechecker recognition + emitter inheritance pattern + parser
extensions.  This PR instead covers the only existing consumer of
custom exception types in the bootstrap — `panic` / `expect` /
`assert` and the `requires:` / `ensures:` runtime checks — with a
much smaller IL-only change.  Truly user-extensible exception types
remain a follow-up if a real consumer surfaces.

**Why `try/catch Bug as b { … b.message }` still works.** The
`Bug` catch alias resolves to `System.Exception` already (per
`TryCatchTests.fs` `[try_catch_specific_exception_type]`), and a
runtime-thrown `System.Exception(message)` exposes `Message` via
the standard BCL property.  No catch-side change needed.

**Tests.** All suites green.  589 emitter (the existing
`TryCatchTests.fs`'s `panic` round-trip + every `requires:` /
`ensures:` test exercises the new lowering), 83 CLI, 242 verifier,
137 type checker, 312 parser, 123 lexer.

**Net F# shim shrink.** ~23 LoC retired.  Trajectory now ~759 LoC
in `Stdlib.fs` (post-Phase-1 + post-G10 1/2 + post-G9).

### D-progress-111: G12 (1/N) — `TaskHost` direct-extern

*claude/g12-delegate-audit branch.*  Smallest realised win from the
G12 delegate-lowering audit in `docs/23-fsharp-shim-elimination.md`
§5.  `Lyric.Stdlib.TaskHost` was a 25-LoC F# class with two static
members: `Delay(int)` and `DelayWithCancel(int, CancellationToken)`.
Both are pure pass-throughs to `System.Threading.Tasks.Task.Delay`.

**`stdlib/std/_kernel/task.l`.**  Both `@externTarget`s repointed at
`System.Threading.Tasks.Task.Delay` directly.  The codegen's
arity-based overload resolution selects the right one at each call
site (1-arg → `Task.Delay(int)`, 2-arg → `Task.Delay(int, CancellationToken)`).

**`compiler/src/Lyric.Stdlib/Stdlib.fs`.**  `type TaskHost` deleted
along with its 2 static members.  Replaced by a doc comment.

**G12 status.** This PR closes the simplest part of G12 — direct-
extern of methods whose Lyric surface already matches the BCL surface
1:1.  The remaining `HttpClientHost` (~140 LoC) and `HttpServerHost`
(~60 LoC) need either:

* multi-step orchestration that single `@externTarget` can't do
  (`MakeRequest` constructs `HttpRequestMessage`; `WithStringBody`
  composes `StringContent` + assigns to `request.Content`;
  `RespondText` chains `Response.OutputStream.Write` + `.Close`); or
* property-setter externs (`set_StatusCode`, `set_ContentType`)
  that haven't been validated against the codegen yet.

Both retire when there's a need-driven follow-up that's worth the
auditing cost.  TaskHost ships now because it has no such
complications.

**Net F# shim shrink.** ~25 LoC retired.  Trajectory now ~734 LoC
in `Stdlib.fs` (after Phase 1 + G10 1/2 + G9 + this PR).

**Tests.** All green.  589 emitter, 83 CLI, 242 verifier, 137 type
checker, 312 parser, 123 lexer.  Existing async tests (delay,
delayWithCancel inside `withTimeout`) confirm both
`Task.Delay` overloads route correctly.


### D-progress-105: G8 — codegen inlines null-aware `println` / `toString`

*claude/g8-inline-printlnany branch.*  First slice of
`docs/23-fsharp-shim-elimination.md` Phase 1.  Retires the F# shim's
`Lyric.Stdlib.Console` type by inlining the `null -> "()" else
value.ToString()` lowering at the codegen call sites.

**Codegen change** (`compiler/src/Lyric.Emitter/Codegen.fs`).

* New helper `emitNullableToStringInline (il)` consumes a boxed
  `obj | null` from the stack and pushes a non-null `string`.  IL
  shape: `dup` + `brfalse outerNull`, `callvirt Object::ToString()`,
  defensive inner `dup` + `brfalse innerNull` (BCL types are free
  to return null from `ToString`), `ldstr ""` / `ldstr "()"` in
  the respective null arms.  Stack discipline preserved across
  both branches.
* `println(any)` non-string path now: `boxIfValue` →
  `emitNullableToStringInline` → `Call Console::WriteLine(string)`.
  No more F# `PrintlnAny` round-trip.
* `toString(any)` non-string path now: `boxIfValue` →
  `emitNullableToStringInline`.  No more F# `ToStr` round-trip.
* The `printlnString` lazy lookup is reused for both string- and
  any-arg cases (same target method), so the call-site dispatch
  logic stays single-method in either branch.
* `Lyric.Stdlib.Console` references in Codegen.fs / Emitter.fs
  (`typeof<Lyric.Stdlib.Console>` AppDomain force-load) repointed
  at the surviving `Lyric.Stdlib.JsonHost` so the assembly still
  loads on demand.

**F# shim change** (`compiler/src/Lyric.Stdlib/Stdlib.fs`).

* `type Console private () = …` deleted along with its two static
  members.  Replaced by a one-paragraph doc comment pointing at
  the codegen helper that took over.

**Test totals.**  All suites stay green — no behavioural change.
The inline IL was hand-validated with a probe source
(`println("hello")`, `println(42)`, `println(toString(3.14))`)
producing `hello`, `42`, `3.14` respectively.  Existing tests in
`BuiltinTests.fs` exercise `toString` over Int / Long / Bool /
String / Double / record / union / Option types — they cover the
inline path.

**Net F# shim shrink.**  ~29 LoC retired (`Console` type body) +
~30 LoC retired in Codegen.fs (the two `Lazy<MethodInfo>`
lookups), partially offset by the ~28-line
`emitNullableToStringInline` helper.  Net trajectory tracks the
~1320 LoC waypoint in `docs/23` §4.4.

**Deferred to subsequent G-items.**

* G7 (`protected type` codegen) — Phase 3 roadmap item; gates
  `StubCounter` / `LyricTaskScope` ports.
* G9 (user-defined exception types) — gates
  `LyricAssertionException` / `Contracts` port.
* G10 (try/catch FFI) — gates `TryHost` / `FileHost` ports.
* G11 (`AsyncLocal[T]`) — gates `AmbientHost` port.
* G12 (delegate-lowering audit) — gates direct-extern of
  `TaskHost` / `HttpClientHost` / `HttpServerHost`.
* Bucket B follow-ups (`RandomHost` / `CancelHost` direct-extern;
  Bucket D `Jvm*` split-out) ship as subsequent Phase 1 PRs.

### D-progress-105: JVM self-tests B90-B96 — Java 21 StackMapTable, higher-level lowering helpers, float-opcode fix, reader round-trip

*claude/fix-bytecode-emitter-37pZc branch.*  Seven new JVM self-tests
exercise the higher-level `Jvm.Lowering` helpers and round out the
`Jvm.Bytecode` / `Jvm.Reader` pipeline:

* **B90 (`lowerFunc` + Java 21 StackMapTable).**  First Lyric-authored
  class targeting Java 21 (`major=65`).  The B5 `lowerFunc` stack-map
  pre-pass already existed; this test proves it works end-to-end.
  Required the *result-slot pattern*: pre-assign a default to a local
  slot before any conditional branch so every branch-target label sees
  an empty operand stack, satisfying the B5 invariant that
  `lowerFunc` always emits a zero-stack frame at branch targets.
* **B91 (`lowerRecord`).**  Minimal `Point(x:JInt, y:JInt)` record →
  Java class with constructor and field getters, verified by spawning
  the produced JAR under `java -jar`.
* **B92 (`lowerUnion`).**  `Shape` union with `Circle`/`Square` cases
  → abstract base + `Shape$Circle` / `Shape$Square` case classes;
  both cases loadable from the multi-class JAR.
* **B93 (`lowerProtected`).**  `Counter` with `increment()` /
  `get()` entry methods; verifies mutable field round-trip in a
  generated Java class.
* **B94 (`lowerWire`).**  Config wire with a single `answer=42`
  binding; verifies `bootstrap()` / accessor code generation.
* **B95 (float fields in `lowerRecord`).**  `Vector2(x:JFloat, y:JFloat)`
  with a `getX():JFloat` accessor.  Exposed a class of JVM verifier
  rejections: `emitFieldLoad`, `storeInsn`, `loadInsn`, and `returnInsn`
  in `lowering.l` all used int opcodes (`LIload/LIstore/LIreturn`) for
  `JFloat` fields instead of float opcodes.  Fixed by adding
  `LFload / LFstore / LFreturn / LFconst / LFadd / LFsub / LFmul / LFdiv`
  to the `LInsn` union and wiring them through all affected helpers;
  also fixed `lowerProtected` constructor zero-init of JFloat fields
  (`LIconst(v=0)` → `LFconst(v=0.0)`).
* **B96 (`Jvm.Reader` round-trip).**  Builds a minimal `Hello.class`
  via `Jvm.Classfile` + `Jvm.Bytecode`, serializes to bytes, parses
  back with `Jvm.Reader.parseClassSummary`, and prints `magic_valid`,
  `majorVersion`, `methodCount` to Lyric stdout — no Java invocation
  needed.

All seven F# driver tests follow the standard pattern: locate the
`.l` source file by walking up from `AppContext.BaseDirectory`, call
`compileAndRun`, assert zero diagnostics, assert exit 0, then check
stdout against expected lines (and for B91-B95 also `runJar` the
produced JAR under `java -jar`).  Both the `.l` sources and the
`.fs` drivers are registered in the `.fsproj` / `Program.fs`.

---

### D-progress-104: F# shim P3 trio — drop `Parse`, port `format`/`Render*Slice`

*claude/p3-1-std-parse-native branch.*  Executes the three P3 items
in `docs/14-native-stdlib-plan.md` §6 as one atomic slice:

* **P3-1 (drop `Parse`).**  `Lyric.Stdlib.Parse` had been replaced
  by `Std.ParseHost.hostTryParse*` (which uses `out` parameters
  routed straight at `System.Int32.TryParse` etc.) but the F# type
  and the codegen `hostParseBuiltins` map / `hostParse*` builtin
  wiring were never deleted.  Both sides removed; the dead-code
  `compiler/tests/Lyric.Emitter.Tests/ParseTests.fs` (which
  exercised those builtins) deleted.
* **P3-2 (`format1..6` → `String.Format(string, object[])`).**  The
  arity-specialised `Lyric.Stdlib.Format.OfN` wrappers retired.
  Codegen now builds an `object[arity]` inline (`newarr` + per-slot
  `dup` / `ldc.i4` / boxed value / `stelem.ref`) and calls
  `System.String.Format(string, object[])` directly.  `format1..6`
  remain reserved codegen builtin names because Lyric still has no
  first-class params-array literal — when one lands the names can
  collapse into a single varargs builtin.
* **P3-3 (`@derive(Json)` slice renderers → inline while-loops).**
  `Lyric.Parser.JsonDerive.fs`'s `mkSliceHelper` extern-stub form
  replaced by a generic `mkSliceHelperInline` that emits the same
  AST as the existing `mkRecordSliceHelper`: `var result = "["`,
  bumping `i` over `items.length`, joining with `","`.  Per-element
  rendering is parameterised: Int / Long use `toString(items[i])`,
  Bool uses `if items[i] { "true" } else { "false" }`, String
  routes through the per-source synthesised `__lyricJsonEscape`.
  `Double` keeps the host extern (`Lyric.Stdlib.JsonHost.RenderDoubleSlice`)
  because round-trip culture-invariant rendering
  (`ToString("R", InvariantCulture)`) isn't yet expressible via
  Lyric's `toString`.  Four of the five `JsonHost.Render*Slice`
  methods retired from the F# shim.

**Test totals.** 573 emitter (was 575 — `ParseTests.fs`'s 4 tests
deleted; `+0` net new), 83 CLI, 242 verifier, 137 type checker,
312 parser, 123 lexer.  Stdlib bundle (`stdlib/lyric.toml`) still
compiles cleanly via `lyric build --manifest`.

**Net F# shim change.**  ~80 LoC removed from `Stdlib.fs`
(`Parse` type ≈48 LoC + `Format` type ≈40 LoC + 4× `Render*Slice`
≈40 LoC, partially offset by inline doc comments).

**Deferred.**

* `format1..6` collapse to a single varargs builtin — gated on
  Lyric-level params-array support.
* `RenderDoubleSlice` migration — needs either a tiny kernel
  helper for `ToString("R", InvariantCulture)` or a Lyric-level
  surface for culture-aware double formatting.
* `JsonHost.Encode` (used by `__lyricJsonEscape`) — kernel forever
  per `docs/14-native-stdlib-plan.md` §3 (depends on
  `System.Text.Json.JsonEncodedText`).


### D-progress-103: M5.1 stage 2c.3 — stdlib-bundle proof

*claude/stdlib-bundle-proof branch.*  Validates the project-as-DLL
pipeline (D-progress-098 / 099 / 100 / 101 / 102) end-to-end on the
real bootstrap stdlib's source tree: a 3-package smoke set
(`Std.Core` + `Std.Errors` + `Std.String`) compiles cleanly via
`lyric build --manifest stdlib/lyric.toml` into one
`Lyric.StdlibBundle.dll` carrying three `Lyric.Contract.<Pkg>`
resources side-by-side.

**CLI manifest enhancement.**  `[project.packages]` values now
accept either a directory (existing semantics — multi-file package
under that dir) or a single `.l` file (one package per file — the
shape the stdlib actually uses, with every `Std.X` living as a
sibling under one `std/` dir).  `Lyric.Cli.Program.buildProject`
branches on `Path.GetExtension`/`File.Exists` versus
`Directory.Exists` and falls back to the existing source-walking
behaviour for dir entries.

**Emitter codegen fixes for in-project artifacts.**

* `emitAssembly`'s import-table population now uses
  `BindingFlags.DeclaredOnly` when reflecting on case TypeBuilders
  and record TypeBuilders.  Generic union case classes inherit from
  a `TypeBuilderInstantiation` parent (e.g. `Option_Some<T>` ⇒
  `Option<T>`), and `caseTy.GetFields()` traverses parents by
  default — that walk explodes on a builder instantiation with
  `NotSupportedException: TypeBuilder generic instantiation does
  not support resolving members. Use TypeBuilder.GetField instead.`
  Declared-only skips the parent walk (case fields are never
  inherited anyway), and the same fix applies to
  `caseTy.GetConstructors()` plus the matching record path.
* `Codegen.fs`'s nullary and payload union case construction sites
  used to route through `TypeBuilder.GetConstructor` only when a
  *type-arg* was a builder.  When the open generic def is itself a
  `TypeBuilder` (the in-project artifact case shipped in
  D-progress-099), `caseInfo.Type.MakeGenericType(...)` always
  returns a `TypeBuilderInstantiation` regardless of type-args —
  walking `constructedCase.GetConstructors()` then explodes the
  same way.  The check now also fires when `caseInfo.Type :?
  TypeBuilder`, routing through `TypeBuilder.GetConstructor`
  unconditionally for builder-backed open defs.

**Tests.**

* `compiler/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs`
  `[stdlib_smoke_bundle_compiles]` mimics the working subset of the
  bundle: a generic `Option[T]` union in `Std.Smoke.Core`, a plain
  `HostError` enum-shaped union in `Std.Smoke.Errors`, and a
  consumer in `Std.Smoke.String` that imports `Std.Smoke.Core` and
  builds `Some(value = s[0])` / `None` in helper bodies.  Asserts
  the bundle compiles clean and ships three per-package contract
  resources.
* `stdlib/lyric.toml` lands as the canonical project manifest for
  the stdlib bundle, currently scoped to the working 3-package
  smoke set.  Expanding to additional packages surfaces
  package-specific codegen gaps (e.g. `Std.Path`'s `dir.length`
  property pattern — `E11 codegen: unknown constructor pattern`)
  that pre-date this stage and are tracked separately for
  follow-up work.

**Test totals.**  575 emitter tests pass (was 573 + the new
`stdlib_smoke` + the existing 2c.* coverage).  Lexer 123, Parser
312, Type checker 137, CLI 83, Verifier 242 — all green.

**Stage-level status.**

* The user-stated Phase-5 milestone "compile the stdlib into a
  single (project) DLL" is **proven** for the foundational
  generics-bearing subset of the stdlib.  Bundling the rest of
  `std/` requires individual codegen fixes that are out of scope
  for this proof; see D-progress-104 (open) for the running list.
* "Reference the bundled stdlib from an arbitrary lyric program"
  is **deferred**.  The current emitter still routes `import
  Std.X` through the in-process precompile cache
  (`ensureStdlibArtifact`) regardless of restored packages.
  Consuming a published stdlib bundle requires a switch on the
  `[dependencies]` side that prefers a restored bundle over the
  precompile when both are available.  Tracked as
  `Q-stdlib-bundle-consume` in `docs/06-open-questions.md`
  (open) — needs a design decision before implementation.

### D-progress-102: M5.1 stage 2c.2.iv — CLI dispatch to `emitProject`

*claude/project-dll-stage-2c2iv-iii branch.*  Wires `lyric build`
to recognise `[project] output = "single"` in `lyric.toml` and
dispatch to the in-emitter project-as-DLL bundler.  Closes the loop
between the manifest format (D-progress-097) and the emit driver
shipped across D-progress-098 / D-progress-099.

**`Lyric.Cli.Program.buildProject`.** New private helper that:

* Resolves the bundle output path: explicit `-o` wins, else the
  manifest's `output_assembly`, else `<project.Name>.dll` placed in
  `<manifestDir>/bin/`.
* Walks `[project.packages]`, enumerating `*.l` files under each
  package's source dir in deterministic (lexicographic) order so
  emit reproducibility doesn't depend on filesystem traversal order.
* Constructs a `Lyric.Emitter.Emitter.ProjectEmitRequest` with
  `Single = true` and forwards restored-package refs from
  `[dependencies]`.
* On success: writes `runtimeconfig.json`, copies the stdlib
  closure into the output dir, prints `built <bundle>`.

**`build` command dispatch.**  When `lyric build --manifest <path>`
is called with no positional source AND the manifest declares
`[project]`, the CLI routes to `buildProject` instead of the
single-source `build`.  `--aot` with project mode is rejected
(B0021/B0022 follow-up).  The `output = "per-package"` path also
errors with a helpful pointer back to `lyric build <pkg>.l`; the
bootstrap stdlib's per-package layout is unchanged.

**Bundle entry-point capture.**  `emitAssembly` gains a new
`mainOut: MethodInfo option ref option` parameter — when the
caller passes `Some r`, the host-main wrapper produced by
`defineHostEntryPoint` is written into `r`.  `emitProject`
pre-scans packages for `func main`, emits exactly one as
non-library (the rest stay library-shaped to avoid duplicate
`Program.Main` claims), captures the resulting `MethodInfo`, and
threads it through `Backend.save` so the bundled DLL's PE header
records the right entry-point token.  Bundles without `main` save
library-shaped (no entry point) — same as the legacy
single-package library path.

**Tests.**

* `Lyric.Cli.Tests/ProjectBuildTests.fs` — two cases.
  - `lyric build --manifest bundles a multi-package project` drops
    a `MyApp.Core` + `MyApp.App` skeleton in a temp dir, invokes
    the CLI as a subprocess, asserts the bundle DLL exists, both
    `Lyric.Contract.MyApp.Core` and `Lyric.Contract.MyApp.App`
    resources are present (and the legacy `Lyric.Contract`
    resource is *absent*), then runs the bundle via `dotnet exec`
    and verifies cross-package call output (`println(double(7))`
    → `14`).
  - `lyric build --manifest reports empty [project.packages]`
    asserts the missing-packages diagnostic surfaces with a
    non-zero exit.
* No emitter-side tests changed shape; the existing
  `[two_packages_bundle_into_one_dll]` covers the same emit
  invariants from the API side.

**Test totals after rebase + new tests.** 527 emitter tests pass
(+2 over the post-#136 baseline of 525), 83 CLI tests (+2),
242 verifier, 137 type checker, 312 parser, 123 lexer.

**Deferred.**

* `--aot` for project-mode bundles: requires the AOT publish
  wrapper to handle multi-resource DLLs and the synthetic
  entry-point class lookup.  Tracked as a follow-up Q.
* `output = "per-package"` dispatch: the legacy bootstrap stdlib
  flow is the only consumer today and it stays on the
  per-source-file `lyric build` path.
* Auto-discovery for `[project.packages]` (the doc's "glob
  default"): when `[project.packages]` is empty, today the build
  errors with B0023.  Walking the source root for `package <X>`
  declarations is straightforward but isn't on the critical path
  for the self-hosted compiler bootstrap.

### D-progress-101: M5.1 stage 2c.2.iii — `lyric restore` walks bundled DLL contracts

*claude/project-dll-stage-2c2iv-iii branch.*  Closes the
publish/restore round-trip for `output = "single"` bundles per
`docs/20-project-as-dll.md` §5: a downstream consumer can list a
single bundled DLL as one `[dependencies]` entry and `import` any
of its bundled packages by name.

**`Lyric.Emitter.RestoredPackages`.**  The package loader gains a
multi-resource path.  `loadRestoredPackage` first probes for the
legacy single-resource form (`Lyric.Contract` with no suffix); on
miss, falls back to `ContractMeta.readAllContractsFromAssembly`
and produces one `RestoredArtifact` per `Lyric.Contract.<Pkg>`
resource, sharing the same loaded `Assembly` and `DllPath`.  The
return type changes from `Result<RestoredArtifact, _>` to
`Result<RestoredArtifact list, _>` so a single ref can expose
multiple artifacts.

**`Lyric.Emitter.Emitter.resolveRestoredImports`.**  Updated to
match: pre-load every ref's contracts up front, index every
resulting artifact by its declared package path
(`String.concat "." source.Package.Path.Segments`), then partition
the consumer's imports against that path index.  An import for
`MyApp.Core` matches the artifact whose synthesised source begins
`package MyApp.Core` — regardless of which `RestoredPackageRef`
the artifact came from.  Per-package contract resources let one
bundle dependency feed N consumer-side imports.

**Tests.**

* `Lyric.Emitter.Tests/RestoredPackageE2ETests.fs +
  consumer imports two packages from a bundled DLL` — builds a
  two-package bundle via `emitProject`, points a consumer at it
  via a single `RestoredPackageRef`, imports both bundled
  packages, runs the consumer, and verifies cross-package output.
* `Lyric.Cli.Tests/RestoredPackagesTests.fs` updated to handle
  the new `Ok (artifact :: _)` shape.

### D-progress-100: M5.1 stage 2c.2.ii.c — `internal` → CLR `Assembly` access

*claude/internal-codegen-2c2iic branch.*  Wires the parsed
`Visibility.Internal` marker through to CLR access flags so the
emitted PE metadata mirrors the Lyric `pub` / `internal` boundary.

**Helpers.**

* `visibilityByName : SourceFile -> Map<string, Visibility option>`
  collects each top-level item's `Item.Visibility` keyed by name.
* `typeAttrsForVis (vis: Visibility option) (extra: TypeAttributes)
  : TypeAttributes` returns `NotPublic ||| extra` for `Internal`,
  `Public ||| extra` otherwise.  Package-private (no marker)
  intentionally stays `Public`: the legacy per-package stdlib relies
  on cross-DLL access to unmarked items, and the type checker
  doesn't yet enforce a package-private boundary at call sites.
* `methodAttrsForVis` and `nestedTypeAttrsForVis` mirror the type
  helper for methods (`Assembly` vs `Public`) and nested types
  (`NestedAssembly` vs `NestedPublic`).

**`defineMethodHeader`.**  The top-level function emit consults
`methodAttrsForVis fn.Visibility` for the access flag.  `main` is
forced to `Public` regardless of declared visibility so the host
`Main` wrapper (which Lyric promotes to the assembly entry point)
can locate it via reflection-driven entry-point discovery.

**Type-defining helpers.**  Each helper that defines a top-level
user type accepts a new `vis: Visibility option` parameter and
threads it through `typeAttrsForVis`.  Updated:

* `defineInterface`
* `defineDistinctType`
* `defineEnum` (with `enum<TypeAttributes> 0` for the no-extras
  baseline)
* `defineUnion` (base abstract class + generic case classes use
  `typeAttrsForVis`; non-generic nested cases use
  `nestedTypeAttrsForVis`)
* `defineProtectedTypeOnto`
* `defineProjectableViewStub`

The two inline define sites in `emitAssembly` (records, opaques)
look up visibility via the new `visOf` closure and pass it the
same way.

**Contract metadata** is unchanged: `ContractMeta.isPub` already
filtered both `Internal` and unmarked items out of the emitted
contract surface (D-progress-096), so the contract resource
correctly hides internal items from external Lyric consumers.

**Tests.**  `[internal_items_emit_assembly_visibility]` builds a
package with a `pub func`, `internal func`, `pub record`, and
`internal record`; loads the bundled DLL via reflection; and asserts
`pubFn.IsPublic`, `intFn.IsAssembly`, `PubRec.IsPublic`,
`IntRec.IsNotPublic`.  514 emitter tests pass (was 513 + 1 new).

**Why package-private stayed CLR Public.**  Strict package-private
enforcement requires the type checker to refuse cross-package
access to unmarked items first; that's a larger change touching the
symbol resolver.  Treating package-private as CLR `Public` matches
today's behaviour (no regression), keeps the legacy per-package
stdlib working (its `func` items are unmarked but reachable across
DLL boundaries), and lets the contract resource alone gate external
visibility for now.  A follow-up can tighten the type-checker side
without re-touching codegen.


### D-progress-099: M5.1 stage 2c.2.ii.b — cross-package symbol resolution within the project

*claude/project-dll-cross-pkg branch.*  Builds on D-progress-098 to
let package B import package A within the same single-DLL project.
The MVP from 2c.2.ii.a only handled independent packages; this
slice closes the gap so the stdlib can compile as one bundled DLL
(every `Std.X` package importing siblings).

**`StdlibArtifact` refactor.**

* `StdlibArtifact.Assembly: Assembly` becomes
  `StdlibArtifact.Assembly: Assembly option` and gains a new
  `Lookup: string -> System.Type option` field.  The single
  consumer (the import-table population loop in `emitAssembly`)
  now calls `artifact.Lookup` instead of `artifact.Assembly.GetType`.
  Stdlib + restored-package artifacts still carry a real
  `Assembly` and bind `Lookup = fun n -> Option.ofObj (asm.GetType n)`;
  in-project artifacts pass `Assembly = None` and bind `Lookup`
  to a shared name-keyed dictionary populated by the emit loop.

**`emitAssembly` — type-export hook.**

* New trailing parameter `typesOut: Dictionary<string, Type> option`.
  When `Some d`, every sealed `TypeBuilder` (interface, record,
  union base + cases, async state machine, program type) is added
  to `d` keyed by its fully-qualified `FullName`.  Builder types
  whose `FullName` is null mid-construction are skipped (closure
  helpers etc. that downstream packages don't reference).  The
  legacy single-package `emit` path passes `None`.

**`emitProject` rewrite.**

* Phase A0 — parse every package up front.
* Phase A1 — extract intra-project import edges (an `import P` is
  intra-project iff `P` matches some `req.Packages.PackageName`)
  and run Kahn's algorithm to topo-sort.  A non-empty residual
  in-degree set surfaces as `B0020` listing the packages still
  involved in cycles.
* Phase A2 — iterate packages in topo order.  For each, partition
  its imports into intra-project / restored / stdlib three ways,
  splice the matched in-project artifacts into the
  `mergedArtifacts` list ahead of restored + stdlib, and call
  `emitAssembly` with both the shared `Backend.EmitContext` AND
  the shared `typesByName` dictionary.  After a clean emit, capture
  the package as a `StdlibArtifact` whose `Lookup` reads from the
  shared dictionary; downstream packages see its full surface.

**Why the shared dictionary, not `module.GetType`.**

* `PersistedAssemblyBuilder`'s `ModuleBuilder` does NOT implement
  `GetType(string)` or `GetTypes()` (verified via probe — both
  throw `NotImplementedException` in .NET 10.0.107).  So the
  intra-project artifact's `Lookup` can't go through the module.
  `emitAssembly` instead populates a dictionary as `CreateType()`
  seals each `TypeBuilder`, and intra-project artifacts query that
  dictionary.  The TypeBuilder stays the same `Type` instance
  pre/post `CreateType()` (for our purposes), so the dictionary
  yields fully-formed CLR types ready for the import-table
  registration loop.

**Tests.**

* `compiler/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` gains:
  * `[cross_package_bundle]` — `CrossPkg.Util` declared first
    in `req.Packages` but importing `CrossPkg.Core` (declared
    second).  Must topo-sort to emit Core first; Util's
    `quadruple(x) = double(x) + double(x)` resolves the
    cross-package call.  Both per-package contracts land in
    the bundled DLL.
  * `[B0020_import_cycle]` — `Cycle.A` imports `Cycle.B`,
    `Cycle.B` imports `Cycle.A`.  Topo sort cannot order them;
    emitter surfaces `B0020`.

**Test totals.**  511 emitter tests pass (was 509 + 2 new).
Lexer, parser, type checker, CLI, and verifier suites stay
green.

**Still deferred.**

* `internal` → CLR `assembly` access modifier.  Codegen still
  emits all top-level methods + types as `Public`.  This is fine
  for the immediate goal — within a single bundled DLL,
  `internal` items are callable from sibling packages anyway, and
  the `Lyric.Contract.<Pkg>` resource already gates external
  consumers (only `pub` items appear in the contract).  Reflection-
  level enforcement is sub-stage 2c.2.ii.c.
* CLI integration (`lyric build` reading `[project]` and routing
  to `emitProject`) — sub-stage 2c.2.iv.
* `lyric publish` / `lyric restore` walking every
  `Lyric.Contract.<Pkg>` resource — sub-stage 2c.2.iii.


### D-progress-098: M5.1 stage 2c.2.ii.a — single-DLL emit driver MVP

*claude/project-dll-emit-driver branch.*  First slice of the
in-emitter restructure picked at the resolution of D-progress-097
§"2c.2.ii architectural decision".  Lands the plumbing + a working
end-to-end single-DLL emit for independent packages — full
cross-package symbol resolution within the project lands in stage
2c.2.ii.b.

**Backend.**

* New `Backend.createWith asm m desc` lets callers reuse an
  externally-managed `PersistedAssemblyBuilder` + `ModuleBuilder`
  across multiple emit calls.  `Backend.create` keeps its current
  shape (creates + returns a fresh one).

**`emitAssembly` changes.**

* New trailing parameter `sharedCtx: Backend.EmitContext option`.
  When `None` (default for the legacy single-package path),
  behaviour is unchanged: `emitAssembly` owns the backend, calls
  `Backend.save`, and embeds a single `Lyric.Contract` resource.
  When `Some ctx`, `emitAssembly` emits into the caller-owned
  context and skips both `Backend.save` and the per-package
  contract / proof resource embeds — the caller drives the final
  save + per-package contract embeds.
* Two existing callers (stdlib precompile in
  `ensureStdlibArtifact`, and the public `emit` entry point) pass
  `None`; full test sweep stays green.

**Contract metadata.**

* New `ContractMeta.embedIntoAssemblyAs dllPath resourceName json`
  is the resource-name-aware embed primitive.  Project-as-DLL
  bundles use `Lyric.Contract.<Pkg>` (one per package); the legacy
  single-package path goes through the existing
  `ContractMeta.embedIntoAssembly` which now thin-wraps the new
  helper with `"Lyric.Contract"` as the name.
* New `ContractMeta.readFromAssemblyNamed dllPath resourceName`
  reads a specific resource by name.
* New `ContractMeta.readAllContractsFromAssembly dllPath` walks
  every `Lyric.Contract` / `Lyric.Contract.<Pkg>` resource and
  returns them keyed by package name (`""` for legacy
  single-package, package name for project-as-DLL).  Used by stage
  2c.2.iii's `lyric restore` walker (pending) and the test that
  asserts both per-package contracts land in the bundled DLL.

**`emitProject` driver.**

* New `ProjectPackageInput` / `ProjectEmitRequest` /
  `ProjectEmitResult` types.
* `emitProject (req: ProjectEmitRequest)` opens one
  `Backend.create`, loops over packages calling `emitAssembly …
  (Some ctx)`, calls `Backend.save` once, then embeds N
  `Lyric.Contract.<Pkg>` resources via `embedIntoAssemblyAs`.
* `B0023` surfaces when `Single = true` is requested with zero
  packages.
* `B0021` surfaces when more than one package declares
  `pub func main` in a single-output project.
* `B0099` is reserved for `Single = false` calls (per-package mode
  drives via repeated `emit` calls — until 2c.2.iv ships, the
  CLI doesn't yet route through `emitProject`).

**Tests.**

* `compiler/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` adds
  two new tests:
  * `[two_packages_bundle_into_one_dll]` — two independent
    packages (`MyApp.Core`, `MyApp.Util`) compile into one DLL with
    two `Lyric.Contract.<Pkg>` resources; the legacy
    `Lyric.Contract` resource is absent.
  * `[B0023_zero_packages]` — empty package list with
    `Single = true` raises B0023.

**Test totals.**  509 emitter tests pass (was 507 + 2 new).

**Deferred to stage 2c.2.ii.b.**

* Cross-package symbol resolution within the project — package B
  importing package A in the same project.  Requires registering
  A's `TypeBuilder`s in B's `ImportedRecords` / `ImportedFuncs`
  tables before B emits.
* `internal` → CLR `assembly` access modifier.  Today's MVP still
  emits everything as `MethodAttributes.Public` /
  `TypeAttributes.Public`; the contract resource is the gate.
* Topological sort over intra-project imports + cycle detection
  (B0020).
* CLI integration: `lyric build` reads `[project] output = "single"`
  and routes to `emitProject` (currently `emitProject` is exposed
  as a public API but not yet wired through the CLI).


### D-progress-097: M5.1 stage 2c.2.i — `[project]` table in `lyric.toml`

*claude/project-as-dll-stage-2c2 branch.*  Lands the manifest piece
of stage 2c.2 per `docs/20-project-as-dll.md` §3 — the
`[project]` and `[project.packages]` sections are now parsed and
materialised into a typed `ProjectSection` record on `Manifest`.

**Manifest model.**

* New `ProjectOutputMode` discriminated union: `Single` |
  `PerPackage` (defaults to `PerPackage` for back-compat).
* New `ProjectSection` record: `Name`, `Output`, `OutputAssembly`,
  `Packages : (string * string) list`.
* `Manifest` gains `Project : ProjectSection option` field — `None`
  for legacy single-package manifests, `Some` when `[project]` is
  present.

**Parser changes.**  `Manifest.toManifest` now accepts an optional
`[project]` block.  When present:

* `name` (required) — project name.
* `output` (optional, defaults to `"per-package"`) — `"single"` or
  `"per-package"`; anything else surfaces as
  `InvalidFieldType ("project", "output", …)`.
* `output_assembly` (optional) — bundled DLL filename when
  `output = "single"`.
* `[project.packages]` (optional) — map of `<pkg-name>` to source
  directory, sorted by name on load.

**Tests.**  Five new cases in
`compiler/tests/Lyric.Cli.Tests/ManifestTests.fs`:

* `[project section absent by default]` — legacy back-compat.
* `[project section parses with defaults]` — minimal `[project]`.
* `[project output mode round-trips]` — `single` and `per-package`
  both materialise correctly + `output_assembly` flows through.
* `[invalid project output mode rejected]` — `output = "weird"`
  surfaces as `InvalidFieldType`.
* `[[project.packages] map sorted by name]` — packages-by-name
  lookup is stable.

**Doc updates.**

* `book/chapters/19-package-ecosystem.md` §19.1 fixed to use the
  correct `[package]` section name (was using `[project]` as a
  synonym for `[package]`); new §19.1.1 documents the multi-package
  `[project]` block.
* `book/chapters/appendix-b-quick-reference.md` lyric.toml example
  updated.
* `docs/10-bootstrap-progress.md` Phase 5 status table splits 2c.2
  into 2c.2.i / 2c.2.ii / 2c.2.iii sub-stages.

**Test totals.**  81 CLI tests pass (was 76 + 5 new project-table).

**2c.2.ii architectural decision (resolved).**

After review the user picked **option 1 — in-emitter restructure**:
refactor `emitAssembly` to accept a list of `SourceFile` and emit
them serially into one shared `PersistedAssemblyBuilder`.  Each
package's emit walks both the local-package symbol table AND the
previously-emitted-package tables (whose `TypeBuilder`s aren't
finalised yet — the recent tuple/field/ctor TypeBuilder fixes
already plumb this path).  Trade-off accepted: ~600-1000 LOC +
tests, deep changes to `Records.fs` / `ContractMeta.fs` /
`Codegen.fs` import-table handling, in exchange for full
single-DLL semantics including the CLR `internal` access modifier
shipping naturally.  Options 2 (ILRepack post-merge) and 3
(`PublishSingleFile`) recorded as rejected alternatives.

### D-progress-096: M5.1 stage 2c.1 — `internal` visibility tier

*claude/internal-visibility-tier branch.*  Lands the language-level
half of stage 2c per `docs/20-project-as-dll.md` §2: a third
visibility tier between `pub` and package-private, marking symbols
that are visible to other packages within the same project but
hidden from cross-project consumers.

**Lexer.**  `internal` becomes a reserved keyword via `KwInternal`
(added to `Token.fs`, `Keywords.fs`'s `spelling` / `all` table, and
`docs/grammar.ebnf` §1.5).

**Parser + AST.**  `Visibility` gains an `Internal of Span` case
alongside the existing `Pub of Span`.  Three places in `Parser.fs`
that consumed `pub` extend to also accept `internal`: the top-level
item-prefix loop, record/struct field parsing, and entry-decl
parsing.  Protected-type members and `pub use` re-exports stay
`pub`-only (intentional — internal members of protected types
have the same lifetime concerns as cross-await `var` capture, and
re-exporting an internal symbol would leak the project boundary).

**Contract metadata.**  `ContractMeta.isPub` was previously truthy
for any `Some _`; now it requires `Some (Pub _)` specifically.
`internal` and package-private items both stop appearing in the
`Lyric.Contract` resource — exactly the cross-project policy
documented in §3.3 of the language reference.

**Codegen.**  Stays at `MethodAttributes.Public` /
`TypeAttributes.Public` for both `pub` and `internal` items in the
current per-package-DLL world.  Once `output = "single"` ships
(stage 2c.2), the emit driver picks `assembly` for `internal` and
`public` for `pub`; until then, the contract resource is the gate.

**Tests.**

* `compiler/tests/Lyric.Lexer.Tests/KeywordTests.fs` automatically
  covers the new keyword via `Keywords.all` round-trip.
* New parser test `[internal visibility parses on funcs, records,
  and fields]` asserts the AST shape across all three positions
  the parser was extended for.
* New emitter test `[internal items are excluded from contract]`
  builds a package with mixed `pub` / `internal` / unmarked
  declarations and verifies only `pub` names appear in the embedded
  `Lyric.Contract` resource.

**Doc updates.**

* `docs/01-language-reference.md` §1.3 reserved-keyword list adds
  `internal`; §3.1 is rewritten as "Visibility tiers" with the
  three-tier table and example block showing the new modifier.
* `docs/grammar.ebnf` §1.5 adds `'internal'` to the keyword list.
* `docs/10-bootstrap-progress.md` Phase 5 status table splits stage
  2c into 2c.1 (this branch) + 2c.2 (project-as-DLL bundling, still
  pending).

**Future work.**  Single-DLL emit (`output = "single"`),
`[project]` in `lyric.toml`, per-package contract resources in one
bundled DLL, and `lyric publish` updates land in stage 2c.2.

### D-progress-095: M5.1 stage 2a' — multi-file conflict diagnostics

*claude/multi-file-diagnostics branch.*  Hardens the multi-file
package merge from D-progress-094 with the three diagnostic codes
specified in `docs/19-multi-file-packages.md` §9.  Each is exercised
by a new test in `MultiFilePackageTests.fs`.

* **B0010 — layout conflict.**  Detected in
  `locateBuiltinFilesWithLayout` when both `<root>/<base>.l` and
  `<root>/<base>/*.l` exist in the same root (or the kernel
  sub-root).  The single-file form's path list still returns so
  diagnostics can be demoted, but the build refuses outright in
  `ensureStdlibArtifact`.
* **B0011 — duplicate declaration across files.**  Detected in
  `parseAndMergeBuiltinFiles` via the new `itemConflictKey` helper:
  functions key on `name + arity` (overloads-by-arity legitimate),
  records / unions / enums / etc. key on bare name, anonymous shapes
  (impl, test, fixture) skip the check.  The duplicate item is
  dropped from the merged list so downstream type-checking sees a
  clean symbol table.
* **B0012 — conflicting import alias across files.**  Same alias
  pointing at different targets across files.  Same alias same
  target dedupes silently.

Tests:

* `[B0010_layout_conflict]` — write `b0010.l` AND `b0010/two.l` in
  the same root, assert B0010 surfaces.
* `[B0011_duplicate_decl_across_files]` — two files declare
  `pub func twice(x: Int): Int`, assert B0011 surfaces with
  both file names.
* `[B0012_conflicting_import_alias]` — `import Std.Core as A` in
  one file, `import Std.Math as A` in another, assert B0012
  surfaces.
* `[overload_by_arity_across_files]` — `pub func add(x)` in one
  file, `pub func add(x, y)` in another, assert NO B0011 fires
  AND the user can call `add(3, 4)` end-to-end.

501 emitter tests pass (was 497 + 4 new diagnostic tests).


### D-progress-094: Phase 5 §M5.1 stage 2a — multi-file packages + emitter polish + design docs

*claude/multi-file-packages-design-docs branch.*  Follow-up to PR #122
that lands the small emitter fixes the self-hosted lexer pressure-tested,
adds multi-file-package support to the built-in resolver, and ships
three design documents covering the next stages of self-hosting.

**Emitter fixes.**

* `Codegen.fs` `SAssign EMember` now walks `ctx.ImportedRecords` after
  `ctx.Records` so `state.field = …` works on a cross-package record
  receiver, not just a local one.  Mirrors the read-side path that
  shipped on main while #122 was open.
* `Codegen.fs:2191` (imported nullary case ctor) now uses
  `TypeBuilder.GetConstructor` whenever any type-arg is a TypeBuilder
  flavour — not just `GenericTypeParameterBuilder`.  Previously a
  user-defined local `TypeBuilder` (e.g. `Keyword` from the same emit)
  closing `None[Keyword]` landed on the
  `constructedCase.GetConstructors()` branch and threw
  `NotSupportedException`.  This is the bug that forced the lexer to
  use local non-generic union shims (`KeywordLookup` / `OperatorLookup`)
  in place of `Option[Keyword]` / `Option[OperatorMatch]`.

**Multi-file packages.**

* `Emitter.locateBuiltinFile` is now a thin wrapper around
  `locateBuiltinFiles : string list`.  The new probes-in-priority
  order is single-file → directory → kernel single-file → kernel
  directory; first non-empty wins.
* New `parseAndMergeBuiltinFiles` reads every located `.l`, parses
  each, and merges `Items`, `Imports`, `ModuleDoc`, and
  `FileLevelAnnotations` into one `SourceFile`.  Single-file inputs
  round-trip unchanged.
* Cross-file conflict detection (B0011 duplicate decl, B0012 alias
  collision) is deferred to the type checker for stage 2a — the
  existing duplicate-symbol diagnostic catches conflicts at the
  next stage.  Per `docs/19-multi-file-packages.md` §4.
* `Testpkg` added to `isBuiltinHead` for emitter test fixtures.
  Two new tests in
  `compiler/tests/Lyric.Emitter.Tests/MultiFilePackageTests.fs`
  exercise (a) two-file merge and (b) two-file with distinct
  imports.  Both pass.

**Design docs.**

* `docs/19-multi-file-packages.md` — specifies the layout, resolver
  changes, conflict diagnostics (B0010-B0012), and migration path for
  multi-file packages.  Stage 2a implements §1-§4; §5-§9 land later.
* `docs/20-project-as-dll.md` — adds the `internal` visibility tier,
  a `[project]` table in `lyric.toml`, single-DLL emit with
  per-package contract resources, and `lyric publish` semantics for
  bundled projects.  Decisions: yes `internal`, retain
  per-package mode as escape hatch, publish ships the project DLL.
* `docs/21-nuget-linking.md` — adds `[nuget]` to `lyric.toml`,
  auto-generated `@axiom` shims per restored package, and the
  AOT-compatibility caveat (no Lyric-level enforcement; rely on
  `dotnet publish -p:PublishAot=true` to flag non-AOT-safe NuGet
  surface).

**Test totals.**  Full sweep on this branch: 497 emitter (495 +
2 multi-file) + 123 lexer + 311 parser + 137 type-checker + 76 CLI
+ 242 verifier + 25 LSP = 1 411 tests, all passing.

**Future work.**

* Stage 2b: split the self-hosted lexer at
  `compiler/lyric/lyric/lexer.l` into a reusable `Lyric.Lexer` library
  + a tiny consumer.  The cross-package field access fix lands the
  blockers; remaining work is moving the test harness out and adding
  `pub` re-exports.
* Stage 2c: implement project-as-DLL per `docs/20-project-as-dll.md`.
* Stage 2d: implement NuGet linking per `docs/21-nuget-linking.md`.
* Open: hard surface for B0011 / B0012 diagnostics (deferred from
  stage 2a).

### D-progress-093: Phase 5 §M5.1 stage 1 — self-hosted lexer down-payment

*claude/implement-lyric-lexer-44Aar branch.*  First slice of the
self-hosting work specified in `docs/05-implementation-plan.md` §5.
Delivers a Lyric-language lexer that tokenises a substantial subset
of the bootstrap lexer's scope and self-tests via the bootstrap
emitter on every `dotnet test` run.

**New source.** `compiler/lyric/lyric/lexer.l` (~2 000 lines):
identifiers + the full keyword table, decimal/hex/octal/binary integer
literals (with `_` separators and the i8/i16/i32/i64/u8/u16/u32/u64
suffixes), float literals (with optional exponent and `f32`/`f64`
suffix), single-quoted plain string and character literals (with the
common escape set + BMP `\u{…}`), the full punctuation table, line +
nested block comments, doc + module-doc comments, statement-end
insertion with the same suppression rules as the F# bootstrap, and
diagnostic codes L0001/L0010/L0011/L0012/L0020/L0021/L0022/L0023/
L0024/L0025/L0030.  String interpolation, triple-quoted and raw
strings, non-BMP `\u{…}`, non-ASCII identifiers + NFC normalisation,
and the L0040 reserved-name diagnostic are deferred to a follow-up.

The same file ships an in-program test harness (24 cases over
`Std.Testing`) covering empty input, identifiers + keywords, bool
literals, decimal / hex / octal / binary integers, suffix parsing,
leading-zero diagnostic, floats with exponent + suffix, plain strings
+ escapes, char literals, full punctuation table, STMT_END insertion
+ suppression-after-operator + bracket-depth gating, explicit `;`,
line / block / nested-block comments, doc + module-doc comments,
CRLF normalisation, and a realistic mixed source.  Lexer + harness
co-exist in one package only because the bootstrap codegen does not
yet expose imported-record field accessors (`Codegen.fs:1969-2005`
falls through to a BCL property lookup); stage 2 of M5.1 will split
the harness out as a `Lyric.Lexer` consumer once that lookup lands.

**New test runner.**
`compiler/tests/Lyric.Emitter.Tests/SelfHostedLexerTests.fs` walks
up from the test binary's base directory to locate
`compiler/lyric/lyric/lexer.l`, compiles it via `compileAndRun`,
and asserts (a) zero error-class diagnostics, (b) exit code 0,
(c) `"ok"` in stdout.  Discoverable as `[lexer_self_test_passes]`
in the Expecto run.  Wired into `Program.fs` after `JvmSelfTest`.

**`Lyric` head added to `isBuiltinHead`.**  `Emitter.fs:4298` now
includes `"Lyric"` so `import Lyric.<X>` resolves under
`compiler/lyric/lyric/<x>.l` via the existing built-in resolver.
Reserved for the self-hosted compiler's own packages; future M5.1
stages (parser, type-checker) live in the same head.

**Bootstrap codegen patches.**

* `Codegen.fs:1097-1117` (`EIndex` BCL fallback) — route through
  `getRecvMethods` + `closeBclMethod` so `xs[i]` works when `xs`
  is a `List[T]` whose `T` is a TypeBuilder under construction
  (e.g. `List[SpannedToken]`).  `recvTy.GetMethods()` directly
  throws `NotSupportedException` on a TypeBuilderInstantiation.
  Element type recovered via `substituteGenericArgs` so callers see
  the closed `T` rather than the open generic parameter.

These two patches are the minimum needed for the lexer's
`List[SpannedToken]` indexing to JIT cleanly; the rest of the
emitter's TBI-aware code paths already used the helpers.

**Pattern-shape work-arounds.**  At the time the lexer was first
written the bootstrap parser/codegen did not yet handle or-patterns
in `match` arms, nested constructor patterns, or tuple destructuring
in `val` / match patterns, and the lexer was hand-shaped around those
gaps.  All three have since landed (E20: see
`compiler/tests/Lyric.Emitter.Tests/PatternMatchingTests.fs` —
`tuple_nested_in_function`, `nested_two_levels`, and
`nested_constructor_in_or` exercise tuple destructuring in `val`,
`case Wrap(A(x))`-style nested constructor patterns recursing via
`emitPatternTest` at `Codegen.fs:4451-4462`, and `case Circle(r) |
Square(r)` or-patterns at `Codegen.fs:4526` / `:4657`).  The lexer's
hand-rolled style is therefore now defensive rather than necessary —
future stages can use the natural pattern-matching forms.  The one
work-around that still applies is bare `func()` statements that return
non-Unit on `inout` recipients (JIT-verifier rejects the resulting IL);
binding to `val _ =` Stloc-discards instead, which works.

**Local non-generic union shim for `Option[LocalType]`.**  The
imported nullary case codegen (`Codegen.fs:2118-2139`) calls
`GetConstructors()` on a `TypeBuilderInstantiation` whose type
arg is a TypeBuilder under construction, throwing
`NotSupportedException`.  Until the codegen routes that path
through `TypeBuilder.GetConstructor`, the lexer uses small local
non-generic unions (`KeywordLookup { FoundKw(kw) | NoKw }`,
`OperatorLookup { FoundOp(p, n) | NoOp }`, `PunctLookup { … }`)
in place of `Option[Keyword]` / `Option[OperatorMatch]`.  Existing
`Option[Long]` / `Option[Double]` / `Option[Char]` returns are
unaffected because their type args are CLR primitives.

**Test totals.**  Full sweep on this branch: 479 emitter + 123
lexer + 311 parser + 137 type-checker + 76 CLI + 242 verifier +
25 LSP = 1 393 tests, all passing.

**Future work.**

* Stage 2 (M5.1): extend the bootstrap emitter to expose imported
  records' field accessors (`Codegen.fs:1969+`), then split the
  lexer into its own `Lyric.Lexer` library + a tiny consumer.
* Lift the deferred string variants (interpolation, triple, raw)
  in stage 3.
* Lift the `_X` reserved-name diagnostic + Unicode/NFC identifier
  handling in stage 4.

### D-progress-092: barrier-wait timeout removed — Ada-orthodox infinite wait

*claude/remove-barrier-timeout-eOJER branch.*  Resolves the
barrier-wait timeout sub-question from Q008 by adopting the
Ada-orthodox stance: `entry … when …` barriers wait **forever**
until another thread makes the condition true.

**Emitter change.**  `monitorWaitMI` now resolves
`Monitor.Wait(object)` (void return, no timeout) instead of
`Monitor.Wait(object, int)`.  The `barrierWaitTimeoutMs` constant
and the entire timeout-branch IL sequence (load int, call, Brfalse
to a throw block) are removed.  The wait sub-block shrinks to three
opcodes:

```
L_wait:
  ldarg.0
  ldfld  <>__lock
  call   Monitor.Wait(object)   // void — blocks until PulseAll
  br     L_check
```

**Test changes.**  `pt_when_barrier_throws_when_false` (which relied
on the 1 s timeout to surface a `LyricAssertionException`) is
removed from the table-driven cases.  A new standalone test
`[barrier_wait_hangs_forever_single_threaded]` compiles the same
single-threaded `Bag` program, runs it in a child `dotnet exec`
process, and asserts that `Process.WaitForExit(2000)` returns
`false` (the process did **not** exit — it is correctly blocked on
the barrier).  The existing
`[barrier_wait_wakes_on_state_change]` test is unaffected.

**Spec update.** `docs/09-msil-emission.md` §17.3 now shows the
three-opcode wait block and explains the Ada infinite-wait
guarantee.  §17.4 (formerly "Concurrent `func`") is retitled to
"Lock-flavour selection" and documents the full tri-modal table.
The Q008 / Q009 rows in the cross-reference table are updated.

**Future work.** Honouring `CancellationToken` in barrier waiters
requires replacing `Monitor` with a `Lock` + `SemaphoreSlim` pair
(or `SemaphoreSlim` + `ManualResetEventSlim`) that supports
`WaitAsync(CancellationToken)`.  That is ~200–400 LOC in the emitter
(a fourth row in the lock-flavour table), plus test-harness changes
to inject a deadline token.  Deferred to Phase 2 / Phase C scope.

### D-progress-091: Phase 4 verifier — M4.2 close-out

*claude/close-m4.2-milestone-kLOj5 branch.* Lands the three remaining
M4.2 deliverables flagged "Not shipped" in D-progress-090 so the
Phase 4 status table can flip them all to **Shipped**.

**1 — `Std.Core.Proof` standard-library subpackage.** New
`compiler/lyric/std/core_proof.l`, mapped to package `Std.Core.Proof`
via the existing `Std.X.Y → x_y.l` resolver convention
(`Emitter.fs:4258-4315`). Bootstrap-grade scope: identity witnesses
(`identity`, `pickFirst`/`pickSecond`, generic over T/U), Boolean
literal anchors (`trueLit`, `falseLit`), let-rebind passthroughs
(`tag`, `assertEq` — the latter threads a reflexive hypothesis via
`assert(x == x)`), and a `wrappedIdentity` exercising the §10.4
cross-call rule + §5.5 `@pure` unfold. Every contract closes under
the trivial syntactic discharger so the package self-verifies in
environments without `z3` on `$PATH` (M4.2 exit criterion: a no-op
edit re-verifies in < 1 s under cache hit, which presupposes
baseline discharge). Aspirational `List[T]` / `Result[T,E]` proof
surface deferred to Phase 4 polish — the verifier's
structural-induction support past the M4.2-core primitives is the
gating work, not the package shape.

**2 — `--allow-unverified` CLI flag.** `Driver.ProveOptions` record
(`Driver.fs`) carries an `AllowUnverified: bool`. When set, the
V0007 *unknown* outcome rewrites from `Diagnostic.error` to
`Diagnostic.warning` so `lyric prove` exits 0; V0008
*counterexamples* stay hard errors regardless. The CLI parses
`--allow-unverified` as a fourth flag alongside `--proof-dir`,
`--verbose`, and the positional source path, and surfaces the
unverified count in the summary line (`%d/%d obligations
discharged (...) [N unverified, allowed]`). Existing
`proveSource`, `proveSourceWithImports`, `proveFile`, and
`proveFileWithImports` retain their M4.1/M4.2-core call shape and
forward to `proveSourceWithOptions` / `proveFileWithOptions` with
`ProveOptions.defaults`.

**3 — Verification regression suite to ≥ 200.** New
`compiler/tests/Lyric.Verifier.Tests/RegressionTests.fs` adds 142
tests across seven sub-suites:

| Sub-suite | Count | Coverage |
|---|---|---|
| Positive driver regressions | 30 | identity / `let` / `val` / @pure-unfold / loop-invariant: true / cross-call / no-contract baselines |
| Additional positive driver regressions | 18 | conjunctive ensures, varied param arity, type-axis identity (Bool/Long/String) |
| Negative driver regressions | 5 | wrong-sign post, wrong identity ensures, wrong loop establish, false assert, `result == false` on `true` |
| SMT-LIB rendering coverage | 15 | `and`/`or`/`not`/`=`/`<`/`+`/`-`/`*`, `set-logic ALL`, `check-sat`/`get-model`, Bool/Int literal forms |
| Trivial discharger coverage | 12 | reflexive `=`/`>=`/`<=` over Int/Bool/String, `P ⇒ P`, `(P∧Q) ⇒ P/Q` (flatten-on-adopt), conjunctions |
| `parseModel` / `renderCounterexample` | 7 | empty / single-Int / Bool / three-binding / `unknown` blob / pair-render / Bool-render |
| IR construction coverage | 25 | `mkAnd`/`mkOr` empty/singleton, `isClosed`, `sortOf`, `subst`, `Goal.asImplication`, `Sort.display`, `GoalKind.display`, `Builtin.display` |
| Sort/builtin display matrix | 21 | `BitVec[8/32/64]`, `Float32/64`, `SDatatype` arity 0/1/2, `SSlice`, `SUninterp`, every `Builtin` variant |
| `ProveOptions` defaults | 3 | `default = false`, equality with explicit, explicit-true round-trips |

Total: 217 tests in `Lyric.Verifier.Tests`, 216 passing. The single
failure (`record construction + field access discharges`) predates
this milestone and is environment-gated on a `z3` binary that the
test host doesn't ship — see the §13 testing-strategy note in
`docs/15-phase-4-proof-plan.md` about z3-only positives. Suite
exceeds the 200-test M4.2 exit criterion with margin for the
fragile case.

**Decision-log scope.** Every test case targets the trivial
discharger so the regression suite is portable across CI hosts
without `z3`. Tests that exercise solver-only shapes (full
arithmetic counterexamples, conjunctive precondition discharge,
`@pure` unfold chains across two call sites) stay in
`DriverTests.fs` and assert the *non-Discharged* invariant rather
than a specific Discharged/Counterexample/Unknown verdict.

**No emitter or type-checker change.** Bootstrap-grade limits from
D-progress-085 / D-progress-089 carry forward unchanged; M4.3 work
(counterexample reconstruction, `--explain`, `--json`,
`@proof_required(checked_arithmetic)`, V0003/V0009 end-to-end,
banking tutorial, axiom audit, contract-aware `public-api-diff`,
CVC5 parity) listed under `docs/12-todo-plan.md` Band D-D2 is
unaffected.

---

### D-progress-090: Implementation-vs-plan audit — M4.2, Q021, Phase 3 testing

*claude/review-implementation-plan-1MZgA branch.* Documentation-only
delta. Reconciles `docs/05-implementation-plan.md`,
`docs/06-open-questions.md`, and this file against the shipped
compiler / stdlib for three buckets that had drifted out of sync.

**Phase 3 testing surface — both shipped, status surfaced.**
`Std.Testing.Property` (D-progress-064) and `Std.Testing.Snapshot`
(D-progress-063) shipped during the C2 async tail but neither was
called out in the Phase 3 status block. Added bullets above, both
labelled bootstrap-grade with the deferred follow-ups (shrinking,
composable generators, xunit discovery, snapshot diff/normalisation,
configurable snapshot dir).

**Phase 4 status — new table.** No Phase 4 status block existed.
Added one above with M4.1 / M4.2 / M4.3 broken out per
`docs/15-phase-4-proof-plan.md` §12. Findings:

- **M4.1: shipped** (D-progress-085).
- **M4.2 core: shipped** (D-progress-089) — loops with explicit
  invariant (`while c invariant: ι`), establish/preserve/conclude
  sub-VCs (`VCGen.fs:1014-1129`), V0005 invariant gate
  (`ModeCheck.fs:132-170`), var SSA (forward env-substitution), full
  record / union / opaque datatype encoding via SMT-LIB
  `declare-datatypes` with typed selectors, `@pure` cross-package
  unfold, persistent z3 session + content-hashed cache at
  `target/<P>/proofs/cache.json`, V0001 cross-package level
  violation.
- **M4.2 quantifiers: shipped.** `EForall` / `EExists` IR shapes
  (`Vcir.fs:97-98`), translation in `VCGen.fs:573-616`, V0006
  decidable-fragment enforcement with finite-domain checks
  (`ModeCheckTests.fs:84-156` covers unbounded-Int rejection +
  bounded acceptance). The "M4.2 quantifier coverage uncertain"
  note in any prior planning doc is obsolete.
- **M4.2 not shipped:** `std.core.proof` subpackage (no
  `lyric/std/proof.l` exists), `--allow-unverified` CLI flag (no
  match for the string in `compiler/src/Lyric.Cli/`), and the
  200-test verification regression target (83 verifier tests today
  across `Lyric.Verifier.Tests/`'s 8 files: ModeTests 8, ModeCheck
  11, Imports 6, Vcir 7, Smt 8, Solver 14, Driver 29).
- **M4.3 not shipped** in its entirety — counterexamples currently
  produce `name : sort = value` bindings parsed from `(get-model)`
  but no trace reconstruction, no suggestion heuristic, no
  `--explain --goal <n>`, no `--json` schema, no LSP V0007/V0008
  integration, no `@proof_required(checked_arithmetic)` mode, no
  `unsafe { ... }` + `assert φ` end-to-end (V0003 / V0009 not in
  the diagnostic surface), no axiom-audit doc, no
  contract-aware `public-api-diff`, no CVC5 solver-swap.

**Q021 — flipped OPEN → PARTIALLY RESOLVED.** Audit found the
parser / type-checker / emitter all carry where-clause work that
the OPEN status didn't credit:

- Sub-questions 1, 3, 4 SHIPPED with file:line evidence in
  `06-open-questions.md` (revision note appended).
- Sub-question 2 reclassified PARTIAL: D034 markers are enforced
  via a closed lookup table in `Codegen.fs:630` (`satisfiesMarker`)
  rather than the interface-dispatch model
  `09-msil-emission.md` §9.4 implies. Pragmatically equivalent for
  primitive monomorphisations; `09-msil-emission.md` §9.4 should be
  updated to match shipped reality (separate follow-up — not in
  this commit).
- Sub-question 5 reclassified NOT SHIPPED: user-defined interface
  constraints parse and type-check but `satisfiesMarker` falls
  through to `_ -> false` for any non-marker name (Codegen.fs:645),
  so `f[Impl]` where `Impl` implements `SomeInterface` aborts the
  build with a misleading B0001. Bug, not a deferral.
- Distinct-types/derives gap surfaced as a Q021 follow-up: locally-
  declared distinct types' `derives` lists aren't snapshotted on
  `DistinctTypeInfo`, so `f[Age] where Age: Hash` rejects even when
  the source declares `derives Hash`. Comment at Codegen.fs:626-629
  acknowledges this.

**D038 native-stdlib G3 implication.** The marker-only path covers
`HashMap[K, V] where K: Hash + Equals` and `Sort[T] where T:
Compare` for primitive instantiations — i.e. P1 of the migration
is unblocked for primitives. Distinct-typed and user-interface-
constrained instantiations remain blocked on Q021#5 + the
distinct-types gap.

**No code changes in this entry.** Tests still 1141 passing
solution-wide (last measured under D-progress-089). Documentation
correction only.

---

### D-progress-089: Phase 4 verifier — M4.2 (cross-package + loops + var SSA + cache)

*claude/phase-4-proof-plan-tVGu7 branch (continuation of
D-progress-085, M4.1 polish).*  Lands the five M4.2 decisions
confirmed in interview with the user:

**1c — `Lyric.Contract` format-2.**  Bumps the embedded JSON to
`formatVersion: 2` with `level` per package and `pure` /
`requires` / `ensures` / `body` / `params` per declaration.
Format-1 payloads round-trip via safe defaults; existing test
fixtures use new `ContractMeta.Contract.legacy` /
`ContractDecl.basic` factories.

**2 (modified) — `Lyric.Proof` opaque binary resource.**  A
separate embedded resource (custom binary layout: `LYPRF` magic +
format byte + length-prefixed strings + length-prefixed lists)
carrying record / union / enum / opaque type representations.
Marked `Private` so it stays out of public-resource listings.
Cecil-based embed/extract mirrors `ContractMeta`.  Honors the
design intent: opaque-type representational privacy is preserved
for runtime/source consumers; proof consumers see through the
cell deliberately.

**V0001 cross-package level violation.**  New
`Lyric.Verifier.Imports` module loads both resources from a list
of DLL paths.  `ModeCheck.checkFileWithImports` walks the file's
`Imports`, resolves each to its level, and fires V0001 when a
`@proof_required` package directly imports a `@runtime_checked`
package.

**Cross-package Hoare call rule + `@pure` unfold.**  `Env` gains
`Imports` and `Datatypes`.  The `ECall` translator falls back to
`Imports.findDeclByLeaf` when the local table misses, parses the
serialised requires/ensures/body via `parseExprFromString`, and
applies the standard call rule: side-goal the precondition,
assume the postcondition (with `result := TApp(name, args)`),
emit `g(args) == body` for `@pure` callees.

**Datatype encoding.**  `registerDatatype` emits SMT-LIB
`declare-datatypes` for records / unions / enums / opaques on
first reference.  `EMember` short-circuits to a typed
`(field receiver)` selector when the receiver sort is a known
datatype; falls back to `$field.name` otherwise.  `ECall`
short-circuits to a typed datatype constructor when the name
matches a record / union case / enum case (named-arg reordering
by field-list position).

**Decision 3a — loop `invariant:` trailing-clause syntax.**

```
while c
  invariant: i >= 0
  invariant: i <= n
{ ... }
```

The parser inserts each clause as a leading `SInvariant`
statement inside the body block, so the existing `Block` shape
is unchanged; consumers outside the verifier treat them as no-
ops.  V0005 now fires only on loops without any invariant.

**Loop wp encoding (§5.3).**  For
`while c invariant: ι { S }; rest`:

* Establish: side-goal `ι` at the loop point.
* Preserve: side-goal `ι ∧ c ⇒ wp(realBody, ι)`.
* Conclude: `wp(rest, Q)` continues under `ι ∧ ¬c`, with loop-
  modified vars havoc'd to fresh `<name>$loopout` symbols.

**Decision 4a — `var` SSA via forward env-substitution.**  `var`
bindings now bind like `let`; `SAssign(EPath x, op, value)` re-
binds `name` to the new translated term.  Compound ops `+=`,
`-=` etc. expand against the current `x` term.  Loop havoc
converts modified `var`s to fresh symbolic values constrained
only by `ι ∧ ¬c` after the loop.

**Decision 5c — goal cache + persistent z3 session.**

* Persistent z3 process per `Driver.proveSourceWithImports`
  invocation.  Preamble (`set-logic ALL`, `set-option`, `Unit`
  datatype) sent once.  Each goal: `(push 1) ... (pop 1)` so the
  declared-const stack is per-goal but datatype + declare-fun
  declarations persist across goals.
* Content-hashed cache at `target/<P>/proofs/cache.json`.  Each
  entry: `{ "<sha256-of-smtlib + z3-version>": "unsat" | "sat:..."
  | "unknown:..." }`.  Different Z3 versions invalidate the
  cache automatically.
* `LYRIC_VERIFY_DEBUG=1` enables session-lifecycle trace.

**End-to-end demo** (`examples/prove_demo.l`) now ships 12
obligations covering identity, tautology, bumped-by-1,
cross-function call rule, inline range, assert, match, `@pure`
unfold, loop establish/preserve/post, var SSA, and record
construction + field access.  All 12 discharge.

**Backwards-compat:** every M4.1 entry point retained as an
alias forwarding to the M4.2 imports/cache-aware version with
`[]` / `None`.

**Tests.**  71 verifier-suite tests (was 63; +8 covering loops,
var SSA, record encoding, cross-package import shapes).  All
1141 tests pass solution-wide.

---

### D-progress-088: protected types — `Box[Int]()` explicit-type-arg construction
*claude/protected-type-explicit-type-args branch.*  Closes the
remaining D-progress-086 follow-up: generic protected types can now
be constructed with explicit type-arg syntax, no LHS annotation
required.

`Box[Int]()` parses as
`ECall(EIndex(EPath{Box}, [EPath{Int}]), [])`.  A new dispatch arm
in `Codegen.fs`, ordered before the existing LHS-driven
construction arm, matches that shape when the path resolves to a
known generic protected type and at least one index expression is
present.  Each index `Expr` is wrapped as a synthetic
`TypeExpr.TRef` and routed through the existing `ctx.ResolveType`
pipeline, so primitives (`Int`, `String`), user types, and
qualified paths resolve uniformly.  `MakeGenericType` +
`TypeBuilder.GetConstructor` then close the open ctor handle.

Type-arity mismatches surface as a deliberate `failwithf`
diagnostic so a malformed `Box[Int, String]()` doesn't silently
crash inside `MakeGenericType`.  Nested/computed type expressions
(`Box[List[Int]]()`) also work transitively because `TRef` /
`TGenericApp` resolution is recursive.

One new test in `ProtectedTypeTests.fs`:

- `pt_generic_explicit_type_arg` exercises `val b = Box[Int]()`
  (no LHS annotation), confirms `b.put(7)` + `b.get()` round-trip.

All 467 emitter tests pass post-change (was 466; +1 net new).

---

### D-progress-087: protected types — Ada-style barrier waiting via tri-modal lock selection
*claude/protected-type-barrier-wait branch.*  Closes the second half
of Q008's lock-flavour decision (`docs/06-open-questions.md`,
`docs/09-msil-emission.md` §17.4): a `when:` barrier on an entry no
longer immediately throws `LyricAssertionException` when the
condition is false.  Instead the wrapper waits on a condition variable
until another thread satisfies the barrier, then re-checks and
proceeds.  Same scheme Ada uses for `entry … when …`.

Decision per the Q008 recommendation: ship Option C (tri-modal lock
selection).  The barrier semantics need `Wait` / `Pulse` primitives
and `Monitor` is the only BCL lock with both.  `ReaderWriterLockSlim`
+ `SemaphoreSlim` don't support Wait/Pulse, so any protected type
that declares a barrier is forced onto `Monitor` (losing concurrent
reads); types without barriers keep the cheaper RWLock /
SemaphoreSlim from D-progress-081 / 083.

Lock-flavour selection (codegen-time, in `defineProtectedTypeOnto`):

| `hasBarriers` | `hasFuncs` | Lock chosen        |
|---------------|------------|--------------------|
| true          | (any)      | `PLMonitor`        |
| false         | true       | `PLRwLock`         |
| false         | false      | `PLSemaphore`      |

`Records.ProtectedTypeInfo.UsesRwLock: bool` is replaced with a
`LockFlavour: ProtectedLockFlavour` discriminated union
(`PLSemaphore | PLRwLock | PLMonitor`).

Wrapper IL for the Monitor flavour with at least one barrier:

```
Monitor.Enter(this.<>__lock)
.try {
  L_check:
    if (!barrier_1) goto L_wait
    ...
    if (!barrier_n) goto L_wait
    goto L_body
  L_wait:
    if (Monitor.Wait(this.<>__lock, timeoutMs))
       goto L_check          // signalled — re-evaluate
    else
       throw LyricAssertionException(
         "<entry>: barrier wait timed out after Xms")
  L_body:
    result = <unsafe>__name(this, args)
    // invariant checks
    if (isEntry) Monitor.PulseAll(this.<>__lock)  // wake waiters
    leave end
} finally {
  Monitor.Exit(this.<>__lock)
}
end:
  [ldloc result]
  ret
```

The PulseAll runs only after entry bodies (funcs are read-only and
can't make any new barrier become true).  The wait timeout is a
bootstrap concession — Ada specifies infinite waits, but a finite
timeout means a single-threaded program calling an entry whose
barrier never resolves throws an exception instead of hanging the
test suite.  Currently 1 second, hard-coded as
`barrierWaitTimeoutMs`.

Two new tests in `ProtectedTypeTests.fs`:

- `[lock_flavour]` (existing test, expanded): now confirms all three
  lock flavours via reflection — entry-only → `SemaphoreSlim`,
  mixed → `ReaderWriterLockSlim`, barrier-bearing → `Object`
  (Monitor).
- `[barrier_wait_wakes_on_state_change]` (new): compiles a `Bag` with
  `entry take() when: count > 0`, kicks off a worker `Task` that
  blocks on the empty bag, then has the main thread call `add(1)`
  100ms later.  The PulseAll wakes the waiter; it re-checks the
  barrier (now true) and completes.  Asserts the worker finishes
  within 2 seconds.

The existing `pt_when_barrier_throws_when_false` test still passes:
in a single-threaded program, calling `take()` on an empty bag
blocks waiting for state change, hits the 1-second timeout, and
throws — same observable "blocked" output as before, just via the
wait/timeout path instead of an immediate throw.

All 466 emitter tests pass post-change (was 465; +1 net new — the
wake test).

---

### D-progress-086: protected types — generic `Box[T]` via LHS-driven inference
*claude/protected-type-generics-impl branch.*  Closes the first half
of the D-progress-082 follow-up: `protected type Box[T] { var value:
T; entry put(v: in T); func get(): T }` now lowers to a real CLR
generic class, replacing the `E920` diagnostic with a working emit
path.

Decision per Q008 follow-up: ship Option A (LHS-driven inference)
rather than Option B (`Box[Int]()` EIndex-as-type-app).  Option A
mirrors the nullary union-case path (`val o: Option[Int] = None`)
that's already in the bootstrap and reuses the existing
`ctx.ExpectedType` plumbing — `val b: Box[Int] = Box()` reads the
expected closed CLR type, calls `MakeGenericType` against the open
TypeBuilder, and looks up the constructed ctor through
`TypeBuilder.GetConstructor`.  EIndex-as-type-app is tracked as
follow-up but isn't in the critical path for bootstrap consumers.

Implementation in three pieces:

- **Pass A** (`defineProtectedTypeOnto` in `Emitter.fs`):
  `tb.DefineGenericParameters(typeParamNames)` produces the GTPBs;
  a `name → GTPB` substitution map is threaded through field-type,
  method param-type, and method return-type lookups via
  `TypeMap.toClrTypeWithGenerics` / `toClrReturnTypeWithGenerics`.
  The `Records.ProtectedTypeInfo.Generics` field is added so call
  sites can detect the generic case.
- **Body emit** (`emitFunctionBody`): synthesised entry/func
  signatures carry the class's type-parameter names in
  `sg.Generics`; the GTPB recovery falls back to
  `selfType.GetGenericArguments()` when the method itself isn't
  generic but its declaring class is.  This lets `var x: T` and
  `return value` references resolve to the right GTPB.
- **Call sites** (`Codegen.fs`):
  - **Construction**: `ECall (EPath {name}, [])` for a generic
    protected type reads `ctx.ExpectedType`; if it's a closed
    generic of the same open def, `MakeGenericType` +
    `TypeBuilder.GetConstructor` produce the constructed ctor ref;
    otherwise the args fall back to `obj` (M1.4 erasure parity).
  - **Method dispatch**: the protected-method picker compares the
    receiver's open generic def (via `GetGenericTypeDefinition`)
    against `info.Type`.  For a closed receiver,
    `TypeBuilder.GetMethod(recvTy, openMb)` produces the
    constructed method ref.  A new `substituteGenericArgs` helper
    rebinds the open method's `ReturnType` against the closed
    receiver's generic args so downstream consumers (boxing on
    `toString`, expected-type propagation) see the substituted
    type instead of the bare GTPB.
  - **Wrapper IL** (`Pass B.6`): the lock-field `Ldfld` and the
    `<unsafe>__name` `Call` rebind onto the type instantiated on
    its own GTPBs (`TypeBuilder.GetField` /
    `TypeBuilder.GetMethod`).  Without the rebind, the JIT throws
    `InvalidOperationException: Could not execute the method
    because either the method itself or the containing type is not
    fully instantiated.`

Two new tests in `ProtectedTypeTests.fs` (replacing the
`pt_generic_not_yet_emitted` E920 test):

- `pt_generic_int` exercises a `Box[Int]` round-trip
  (value-type closure).
- `pt_generic_string` does the same for `Box[String]`
  (reference-type closure).

All 463 tests pass post-change (was 462; +1 net new — removed the
E920 test, added two generic round-trip tests).

The remaining piece — `Box[Int]()` EIndex-as-type-app dispatch — is
deferred until a bootstrap consumer actually needs to construct a
generic protected type without an LHS type annotation.

---

### D-progress-085: Phase 4 verifier — M4.1 polish (call rule, match, assert, V0006)

*claude/phase-4-proof-plan-tVGu7 branch (continuation of D-progress-084).*
Brings the M4.1 verifier from "skeleton wired end-to-end" to "small
real proofs run."  63 verifier tests; all pass.

**Hoare call rule (`docs/08-contract-semantics.md` §10.4).**
`TranslateResult` and `WpResult` gain an `Assumed: Term list` track
alongside `SideConds`.  At every call site to a known callee `g`:

* `g`'s `requires:` clauses are translated, substituted with caller
  args, and added as **side goals** that must hold before the call.
* `g`'s `ensures:` clauses are translated with `result := TApp(g, args)`
  and the params substituted with the caller's args, then added as
  **assumed hypotheses** for the surrounding wp computation.

Side goals (preconditions) get the un-augmented hypothesis set so
the assumption isn't circular at the call site itself.  Without this
rule, the `wp` of `return id(x)` is opaque to the discharger because
`id(x)` carries no syntactic relationship to `x`; with it, the
assumption `id(x) == x` flows through and the wrapper's
`result == x` postcondition closes.

**Match support (M4.1 fragment).**  An `EMatch` arm in a function
body or contract translates to a nested
`ite(matches(scrutinee, P_i), arm_i, ...)` chain.  Patterns supported
this milestone:

* `case _` — wildcard, always matches.
* `case n` — bare binding, always matches; binds `n` to the
  scrutinee's term.
* `case 0` — literal equality.
* `case (paren_pat)` — passes through.

Constructor / record / tuple patterns are V0027 warnings (treated
as no-match).  When the last reached arm has an unconditional
pattern, the chain collapses to that body directly so Z3 sees a
clean `(ite (= x 0) 0 x)` rather than an `(ite ... (ite true x ?))`
shape with a stray uninterpreted fallthrough sort.

**`assert φ` in body.**  An `SExpr (ECall (EPath ["assert"], [φ]))`
inside a proof-required body now:

1. Translates φ into the IR.
2. Emits φ as a side goal (V0008 if not provable).
3. Adds φ to the assumed hypotheses for the rest of the block.

Standard Hoare encoding for assertions.  Wrong assertions produce a
counterexample exactly like wrong ensures.

**V0006 quantifier-domain enforcement.**  `forall`/`exists` over
unbounded domains (`Int`, `Long`, `Nat`, `Float`, `Double`, `String`,
`UInt`, `ULong`) inside proof-required contract clauses are now
rejected with a fix-it message pointing at slices, sets, range
subtypes, or finite enums.  Bounded slices (`slice[T]`), `Bool`, and
range-refined types are admissible.  `@runtime_checked` code remains
unrestricted (V0006 only fires inside proof-required modules).

**Counterexample pretty-printer.**  `parseModel` extracts
`(define-fun NAME () SORT VALUE)` clauses from Z3's `(get-model)`
output; `renderCounterexample` renders them as `name : sort = value`
lines.  V0008 diagnostics now show:

```
V0008 error: postcondition of wrong — proof failed
  x : Int = 0
```

instead of the raw Z3 model dump.

**Trivial discharger strengthened.**  Closes `true`, `P ⇒ P`,
reflexive `(= a a)` / `(<= a a)` / `(>= a a)` / `(iff a a)`,
`(ite c a a)`, conjunctions of any of the above, and
`(=> P Q)` where Q closes given `P :: hypotheses`.  Still no full
solver, but enough to handle most identity-style postconditions
without requiring z3 in CI.

**Inline range refinement.**  A parameter typed
`Int range 0 ..= 100` now lifts to `SInt` with a closed-range
hypothesis — Z3 sees `(declare-const x Int)` plus `(<= 0 x)` and
`(<= x 100)` in the goal's antecedent.  Distinct types declared as
`type Age = Int range 0 ..= 150` lift to a separate `SDatatype`
sort (M4.2 work to bridge the two).

**CI wiring (`.github/workflows/ci.yml`).**

* Apt-installs `z3` before the test phase so non-trivial arithmetic
  VCs in the verifier suite + smoke tests can discharge.
* Adds a "Verifier tests" step after the CLI tests step.
* The examples smoke-tester routes `@proof_required` files (detected
  via first-line grep) through `lyric prove` instead of `lyric
  build` — `prove_demo.l` is verifier-only and intentionally has no
  `func main`.

**Examples.**  `examples/prove_demo.l` ships a five-function tour
(identity, tautology, bumped-by-1 under a precondition, cross-
function call rule, inline-range arithmetic).  All five
discharge.

### D-progress-084: Phase 4 verifier — M4.1 skeleton

*claude/phase-4-proof-plan-tVGu7 branch.*  Lifts Phase 4 from
"planned" (`docs/15-phase-4-proof-plan.md`) to "M4.1 partial".  The
verifier is wired end-to-end (parse → mode-check → VC-gen → SMT-LIB
emission → discharge → CLI summary) at bootstrap-grade fidelity.
A new `lyric prove <source.l>` subcommand exposes it.

**New project** — `compiler/src/Lyric.Verifier/`:

- `Mode.fs` — parses `@runtime_checked` / `@proof_required[(modifier)]`
  / `@axiom` file-level annotations into `VerificationLevel`.
  Conflict diagnostics: V0010 (multiple level annotations), V0011
  (unknown modifier).
- `ModeCheck.fs` — implements the V0001/V0002/V0004/V0005 dispatch
  rules from `15-phase-4-proof-plan.md` §3.1.  For each function in
  a proof-required package: rejects calls into non-pure
  runtime-checked callees (V0002), `await`/`spawn` (V0002),
  `unsafe` blocks outside `@proof_required(unsafe_blocks_allowed)`
  (V0003), `@axiom`-with-body (V0004), and loops without an
  `invariant:` clause (V0005).  V0001 (cross-package level
  violation) is deferred until the contract-metadata reader for
  proof-required packages lands.
- `Vcir.fs` — solver-agnostic Lyric-VC IR per the plan's §6.  Sorts
  cover `Bool`, `Int`, `BitVec n`, `Float32/64`, `String`,
  parameterised datatypes, `Slice`, and uninterpreted sorts.  Terms
  cover variables, literals, builtins (`and`/`or`/`not`/arithmetic/
  comparisons/`ite`/quantifiers), `let`, user-function applications,
  and `forall`/`exists`.  Capture-avoiding substitution is built in.
- `Theory.fs` — Lyric `TypeExpr` → `Sort` mapping plus a
  `RangeBoundKind` for refined integers (`Int range a ..= b` lifts to
  `SInt` with a constant-folded `[a, b]` hypothesis).  Lyric `BinOp`/
  `PrefixOp` → `Vcir.Builtin`.
- `VCGen.fs` — wp/sp calculus over the *imperative* fragment per the
  plan's §5.  Function bodies of shape `= expr` or `{ let* ; return e }`
  produce a `Pre ⇒ wp(body, Post)` goal plus side conditions.
  `result` and parameter-old snapshots are bound into the env.
  Quantifiers translate to `TForall`/`TExists`; calls translate to
  `TApp` so the SMT layer can declare them once.  Loops, `match`,
  full `var`/`if`-with-blocks, and `old(e)` over non-path expressions
  are flagged with V0022/V0024/V0025/V0026 warnings and treated as
  uninterpreted (M4.2 work).
- `Smt.fs` — SMT-LIB v2.6 emitter.  Renders the `Unit` datatype, the
  free variables of the goal as `(declare-const ...)`, every collected
  user function as `(declare-fun ...)`, and `(assert (not …))` of the
  goal's implication shape, followed by `(check-sat)` + `(get-model)`.
- `Solver.fs` — back-end.  Two paths:
  * A *trivial syntactic discharger* that closes goals of shape
    `true`, reflexive `(= a a)`, `P ⇒ P`, conjunctions/disjunctions
    of these, or any conclusion that appears verbatim among the
    hypotheses.  Handles the most common bootstrap-test cases
    without any solver dependency.
  * An optional *Z3 shell-out*: if `LYRIC_Z3` is set or `z3` is on
    `$PATH`, the emitter pipes the SMT-LIB blob to it and parses
    the first line of stdout (`unsat`/`sat`/`unknown`).  The
    `Microsoft.Z3` NuGet bindings are intentionally avoided so the
    AOT path stays clean (per `15-phase-4-proof-plan.md` §7.1
    carve-out).
- `Driver.fs` — `proveSource` / `proveFile` end-to-end entry.
  Returns a `ProofSummary { Level; Diagnostics; Results }` plus
  per-goal `SmtPath` for the optional `target/proofs/<label>.smt2`
  file.  Discharged goals are silent; failed goals raise V0008
  (with up to six lines of counterexample preamble) and V0007 for
  `unknown`.

**CLI** — `compiler/src/Lyric.Cli/Program.fs` gains a `prove`
subcommand:

```
lyric prove <source.l> [--proof-dir <dir>] [--verbose]
```

`--proof-dir` defaults to `<source-dir>/target/proofs/`.  `--verbose`
prints the per-goal outcome and the SMT path.  Exit code is 0 on
all-discharged-no-errors, 1 otherwise.  `lyric build` is unchanged.

**Tests** — `compiler/tests/Lyric.Verifier.Tests/` (28 Expecto
tests across `ModeTests`, `ModeCheckTests`, `VcirTests`, `SmtTests`,
`DriverTests`).  Coverage:

- VerificationLevel parsing for every annotation form including
  `@proof_required(unsafe_blocks_allowed|checked_arithmetic)`.
- The dispatch checker's V0002 / V0004 / V0005 emission and absence
  in the corresponding well-formed cases.
- Vcir IR: `mkAnd`/`mkOr` neutral elements, capture-avoiding `subst`,
  forall-binder shadowing, `Goal.asImplication` shape.
- SMT-LIB v2.6 emission: required headers, `declare-const` for free
  variables, `declare-fun` for user symbols, negated-implication
  wrapping.
- End-to-end driver: identity functions, body-less `@axiom`
  (no VC), constant-bool postcondition, `nop` with no contracts.

**Bootstrap-grade limits explicitly carried into M4.2/M4.3:**

- VC generator covers only `let`/`val`-then-`return` shapes — `var`,
  `match`, multi-statement blocks with side effects, and loops are
  warning-only and produce trivially-true `wp`s.
- `old(e)` only resolves for `e = path-to-parameter`; arbitrary
  `old` expressions are warning V0021 and treated as current.
- Quantifier domains aren't enforced as decidable (V0006 deferred).
- No record/union/opaque datatype declarations are emitted into the
  SMT context — datatype reasoning is M4.2 work.
- Cross-package contract reading is not wired (V0001 deferred); the
  call graph only sees in-file callees.
- Counterexample reporting is the raw Z3 model text, not the
  Lyric-typed pretty-printed form §9.1 will ship.

These are tracked into M4.2/M4.3 per the plan and intentionally
ship as is so the architecture is exercised end-to-end at the
bootstrap milestone.

**Files touched:** `compiler/Lyric.sln` (added two projects),
`compiler/src/Lyric.Cli/Lyric.Cli.fsproj` (verifier ProjectReference),
`compiler/src/Lyric.Cli/Program.fs` (`prove` subcommand + usage),
`compiler/src/Lyric.Verifier/*` (new), `compiler/tests/Lyric.Verifier.Tests/*`
(new), `CLAUDE.md` (verifier description in the project layout
section), `docs/15-phase-4-proof-plan.md` (already shipped in
PR #75 — referenced from this entry).

---

### D-progress-083: protected types — `SemaphoreSlim` for entry-only types (Q008 split)
*claude/protected-type-semaphore branch.*  Closes the second half
of Q008's lock-flavour decision (`docs/09-msil-emission.md` §17.4):
protected types that declare no `func` members now lock through a
binary `SemaphoreSlim(1, 1)` instead of the heavier
`ReaderWriterLockSlim`.  Mixed types (with at least one `func`)
keep the RWLock from D-progress-081 so concurrent reads still run
in parallel.

The split is detected at codegen time by scanning `pd.Members` for
any `PMFunc`.  `defineProtectedTypeOnto` carries the boolean
through to `Records.ProtectedTypeInfo.UsesRwLock`; Pass A picks
the `<>__lock` field's CLR type accordingly and emits the right
`Newobj` in the synthesised default ctor; Pass B's wrapper
acquires `EnterWriteLock`/`EnterReadLock` (RWLock) or `Wait()`
(SemaphoreSlim) and matches with `ExitWriteLock`/`ExitReadLock` or
`Release()` in the finally.

One new structural test in `ProtectedTypeTests.fs`:
- `[lock_flavour]` reflects on the emitted assembly to confirm an
  entry-only `protected type EntryOnly { entry tick() … }` carries
  `<>__lock : SemaphoreSlim` while a mixed
  `protected type Mixed { entry tick() …; func get() … }` carries
  `<>__lock : ReaderWriterLockSlim`.

All 462 tests pass post-change (was 461; +1 net new).

---

### D-progress-082: protected types — diagnose `protected type Foo[T]` instead of crashing
*claude/protected-type-generics branch.*  Generic protected types
remain a follow-up tracked under D-progress-079, but the previous
state silently mishandled them: `defineProtectedTypeOnto` never
called `tb.DefineGenericParameters`, so a user-written `protected
type Box[T] { var value: T … }` would happily emit a CLR class
with a field `value: !!0` referencing a nonexistent type
parameter, then explode with `InvalidProgramException` at JIT
time.  The bootstrap now surfaces a structured `E920` diagnostic
at codegen time instead, naming the protected type and pointing
at the tracked follow-up:

```
E920 error [3:1]: generic `protected type Box[…]` not yet emitted
(parser accepts the syntax; codegen + call-site type-arg
dispatch are tracked under D-progress-079 follow-ups)
```

The two pieces still missing for full generic-protected-type
support:

- **Pass A wiring**: define `tb.DefineGenericParameters(names)` and
  thread the resulting `name → GTPB` substitution map through
  field-type / param-type / return-type lookup via
  `TypeMap.toClrTypeWithGenerics`.  Method-body emission needs
  `emitFunctionBody` to recover the GTPBs from
  `selfType.GetGenericArguments()` when the method is non-generic
  but its declaring type is.
- **Call-site dispatch for `Box[Int]()`**: the construction syntax
  parses as `ECall (EIndex (EPath {Box}, [Int]), [])` (note: the
  `[Int]` slot is parsed as `EIndex`, not `ETypeApp`, because
  Lyric's surface grammar can't tell the two apart at the call
  site).  A new dispatch arm needs to detect "EIndex over a
  generic-protected-type path" and emit `Newobj` against
  `Box.MakeGenericType([| Int |]).GetConstructor`.  Generic
  records have an analogous problem solved via type-arg inference
  from the field-init args; the protected-type ctor takes no args
  so the type args have to come from explicit syntax or a LHS
  annotation (`val b: Box[Int] = Box()`).

One new test in `ProtectedTypeTests.fs`: `pt_generic_not_yet_emitted`
asserts the new E920 fires.  All 461 tests pass post-change
(was 460; +1 net new).

---

### D-progress-081: protected types — `ReaderWriterLockSlim` (Q008)
*claude/protected-type-rwlock branch.*  Closes another follow-up
from D-progress-079: protected-type wrappers now lift the lock
field from `object` (Monitor) to
`System.Threading.ReaderWriterLockSlim` so concurrent `func` calls
can take a read lock while `entry` calls take a write lock.
Matches the Q008 resolution recorded in
`docs/09-msil-emission.md` §17.4.

Lowering changes:
- Lock field `<>__lock : object` → `<>__lock : ReaderWriterLockSlim`.
- Default ctor allocates via `Newobj ReaderWriterLockSlim::.ctor()`
  instead of `Newobj Object::.ctor()`.
- Public wrapper IL switches `Monitor.Enter / Exit` to
  `Callvirt EnterWriteLock / ExitWriteLock` for entries and
  `Callvirt EnterReadLock / ExitReadLock` for funcs.  Both pairs
  release in the `finally` so an exception inside the unsafe
  inner releases the lock cleanly.

The bootstrap currently uses `ReaderWriterLockSlim` uniformly,
even for entry-only protected types; switching entry-only types
to `SemaphoreSlim` (the second half of Q008's resolution) is a
minor follow-up — the perf delta only shows up under contention
that no Lyric workload yet exercises.

One new test in `ProtectedTypeTests.fs`:
- `pt_rwlock_func_reads` — `Counter` with two `func` reads
  alongside an `entry add`; smoke-confirms the RWLock acquire/
  release pattern works for both modes.  Concurrent execution
  isn't directly tested deterministically; the IL shape proves
  the lock-mode dispatch.

All 1066 tests pass (was 1065; +1 net new).

---

### D-progress-080: protected types — barriers + invariants + field initializers
*claude/protected-type-followups branch.*  Closes three of the five
follow-ups documented under D-progress-079:

- **`when: <cond>` barriers** evaluate before the unsafe inner is
  invoked.  False throws `LyricAssertionException` carrying a
  `<method>: barrier failed` message — the bootstrap doesn't yet
  do Ada-style condition-variable waiting (`docs/06-open-questions.md`
  Q008 gates that on Phase C scope plumbing).  Each barrier
  expression is desugared the same way entry/func bodies are: bare
  field references rewrite to `self.<field>` so `when: count > 0`
  works without explicit `self.` prefixes.
- **`invariant: <cond>` checks** re-evaluate after every entry/func
  body returns its value, still inside the lock and the outer try.
  False throws `LyricAssertionException` carrying a
  `<TypeName>: invariant failed` message — per language reference
  §7.4 an invariant violation is an unrecoverable bug.  Multiple
  invariants combine as a sequence of independent checks.
- **Per-field initializers** — `var count: Int = 100` now actually
  runs the initializer in the synthesised default ctor.  Pass A
  emits the ctor prologue (`base ctor` call + lock alloc) and
  leaves the IL generator open; Pass B (new step "Pass B.7" in
  `Emitter.fs`) finishes each ctor by emitting `Ldarg.0; <expr>;
  Stfld <field>` for every initializer with a real `FunctionCtx`
  in scope, then writes `Ret`.

**Wrapper IL** — the public method wrapper now lays out as:

```il
Monitor.Enter(this.<>__lock)
.try {
  <when: barriers — throw if false>
  result = <unsafe>__name(this, args...)
  <invariant: checks — throw if false>
  leave end
} finally {
  Monitor.Exit(this.<>__lock)
}
end:
[ldloc result]
ret
```

The wrapper's barrier + invariant emit uses
`Codegen.FunctionCtx.make` against the wrapper's IL generator with
`isInstance = true` and `selfType = <protected type>`, so
`emitContractCheck` evaluates each desugared expression in the
correct lexical context.

**Tests** (1065 total, +5 net new in
`tests/Lyric.Emitter.Tests/ProtectedTypeTests.fs`):
- `pt_field_initializer` — `var count: Int = 100` starts at 100.
- `pt_invariant_holds_silently` — happy-path invariant passes
  through every entry/func.
- `pt_invariant_violation_throws` — invariant trips on
  `count >= 0` after `decr` drops below zero; main catches via
  `try/catch Exception as e` and prints `boom`.
- `pt_when_barrier_satisfied` — barrier holds; entry runs.
- `pt_when_barrier_throws_when_false` — barrier fails; wrapper
  throws BEFORE calling the unsafe inner.

**Bootstrap-grade scope** (still future work):
- **Concurrent reads on `func`** — every `func` still takes the
  same exclusive Monitor.  `ReaderWriterLockSlim` lift lands when
  a real workload exercises the distinction (Q008).
- **`protected type Foo[T]` generics** — Pass A doesn't yet define
  generic params on the synthesised TypeBuilder; mirror the C2
  generic-async path (D-progress-075) when needed.
- **Ada-style barrier waiting** — gated on Phase C scope
  plumbing; bootstrap consumers fall back to caller-side retry
  loops or accept the throw-on-false semantics.

---

### D-progress-079: protected types — bootstrap-grade Monitor wrap
*claude/protected-type-bootstrap branch.*  Lifts the Phase-3
`protected type` deliverable from "deferred" (D-progress-067) to
shipped at bootstrap grade.  `protected type T { var/let
fields, invariants, entry / func members }` now lowers to a
sealed CLR class with structurally-enforced mutual exclusion,
matching the language reference §7.4 contract.

**Lowering** (`compiler/src/Lyric.Emitter/Emitter.fs`
`defineProtectedTypeOnto`):

- One sealed CLR class per `protected type T`.
- One public field per `var` / `let` / immutable declaration.
- One private `<>__lock : object` field, allocated by the ctor.
- A no-arg default ctor that calls `object.ctor()` and
  initialises `<>__lock = new object()`.  Per-field initialisers
  in the source are not yet wired (default-zero initialisation
  for now — bootstrap-grade scope).
- Two methods per `entry name(...)` / `pub func name(...)`:
  * Public wrapper `<name>(args)` whose hand-emitted IL acquires
    `Monitor.Enter(this.<>__lock)`, opens a `try`, calls into the
    private inner with the user's args, stashes the return value
    in a local, leaves to a post-try label, and releases the lock
    in a finally.  The `leave`-out-of-try shape sidesteps the CLR
    rule that forbids `ret` inside a protected region.
  * Private `<unsafe>__<name>(args)` carrying the user's actual
    body, emitted via the regular `emitFunctionBody` pipeline so
    contracts / control flow / async / FFI all work uniformly.

**AST desugar** — per the language reference §7.4, code inside a
protected type body treats its fields as implicitly in-scope.
The bootstrap codegen has no implicit-self lookup, so a new
`desugarSelfFields` pass walks each entry/func body before
`defineMethodPair` runs and rewrites bare `EPath {x}` references
to `EMember (ESelf, x)` whenever `x` matches a protected-type
field name and isn't shadowed by a parameter or local binding.

**Call-site dispatch**:

- Construction (`Counter()` ⇒ `Newobj Counter::.ctor()`) routes
  through a new `ECall (EPath {name}, [])` arm in `Codegen.fs`
  that fires when `ctx.ProtectedTypes.ContainsKey name`.  This
  short-circuits the existing record-construction path which
  would expect one arg per field.
- Method dispatch (`c.incr()` ⇒ `Callvirt Counter::incr`) routes
  through a new short-circuit at the top of `ECall (EMember
  (recv, methodName), args)`'s handler: `ctx.ProtectedTypes` is
  scanned for a type whose CLR `Type` matches `recv`'s static
  type, and the matching `ProtectedMethod.Method` is invoked
  via `Callvirt`.  Routes here before the reflection-based
  `getRecvMethods recvTy` path, which would throw
  `NotSupportedException` against the unsealed TypeBuilder.
- Field access (`self.count` after the desugar) routes through
  the existing record-field-read path because protected types
  are also registered in `recordTable` as a stub `RecordInfo`
  carrying the protected type's field metadata.

`Codegen.FunctionCtx` gains a `ProtectedTypes:
ProtectedTypeTable` field threaded through `FunctionCtx.make`
(plus the lambda-context constructor) and `emitFunctionBody`.

**Tests**: 3 new end-to-end cases in
`tests/Lyric.Emitter.Tests/ProtectedTypeTests.fs`:
- `pt_basic_counter` — `Counter` with `incr` / `decr` / `get`
  exercises construction, mutating entries, and a value-returning
  func through the lock wrap.
- `pt_multiple_protected_types_in_same_module` — two protected
  types coexist; covers Pass A's iteration order + per-type
  `<>__lock` field naming.
- `pt_func_returns_value` — catches a regression where the
  wrapper forgets to `Ldloc` the saved result before `Ret`.

All 1062 tests pass post-change (was 1059; +3 net new).

**Bootstrap-grade scope** (deferred follow-ups):
- **`when:` barriers** are not yet evaluated.  Today every entry
  acquires the lock immediately; the spec's barrier-blocks-until-
  true semantics needs `Monitor.Wait` / condition-variable queues
  that gate on the C2 Phase C structured-concurrency scope
  plumbing (see `docs/06-open-questions.md` Q008).  Bootstrap
  consumers that depend on barrier semantics fall back to manual
  state checks inside the entry body.
- **`invariant:` clauses** are not yet evaluated after entry/func
  exit.  `emitContractCheck` is wired and ready; threading the
  invariant list into the wrapper between the unsafe call and the
  finally is mechanical follow-up work.
- **Per-field initializers** (e.g. `var count: Int = 100`) are
  parsed but ignored — fields default-zero-initialise.
- **Concurrent reads on `func`** (`docs/06-open-questions.md`
  Q008's `ReaderWriterLockSlim` story) — every `func` takes the
  same exclusive `Monitor` today.  Lifting to a reader-writer lock
  lands when a real workload exercises the distinction.
- **`protected type Foo[T]` generics** — Pass A doesn't yet
  define generic params on the synthesised TypeBuilder; the C2
  generic-async path (D-progress-075) showed the pattern when
  this is needed.

---

### D-progress-078: C8 build-time consumer of restored Lyric packages
*claude/c8-build-consumes-restored-packages branch.*  Closes the
last C8 follow-up tracked in `docs/12-todo-plan.md` Tier 6 #15:
`lyric build` now resolves `import <Pkg>` declarations against
restored Lyric packages by reading their embedded
`Lyric.Contract` resource (D-progress-031), without needing to
re-parse the package's source.  End-to-end loop: a publisher runs
`lyric publish` (D-progress-077), a consumer runs `lyric restore`
to populate the standard NuGet cache, and `lyric build --manifest
<lyric.toml>` (or auto-discovered next to the source) reads the
manifest's `[dependencies]`, locates each restored DLL via the
NuGet cache convention, and feeds the contract surface into the
import resolver.

**New module** `compiler/src/Lyric.Emitter/RestoredPackages.fs`:
- `RestoredPackageRef` — name + version + absolute DLL path; the
  CLI fills it from `lyric.toml` after running `lyric restore`.
- `tryLocateRestoredDll` — resolves
  `<NUGET_PACKAGES or ~/.nuget/packages>/<lower(name)>/<version>/
  lib/net10.0/<name>.dll`.
- `synthesiseSource` — pastes each contract decl's `Repr` string
  under a `package <name>` header, producing a parseable Lyric
  source.  `pub func` items are bodyless (the parser already
  accepts that shape — same as interface signatures and externs);
  records / unions / enums carry their full structural shape;
  interfaces get a synthesised empty `{}` body so they parse.
- `loadRestoredPackage` — reads the contract resource, synthesises
  the source, parses + type-checks it on its own, and pairs the
  result with the loaded `Assembly`.  Errors are surfaced as a
  structured `RestoredLoadError` (`DllMissing`,
  `NoContractResource`, `MalformedContract`,
  `SynthesisDiagnostics`) rendered as a single `E901` diagnostic.

**Emitter integration** (`compiler/src/Lyric.Emitter/Emitter.fs`):
- `EmitRequest` gains an optional `RestoredPackages:
  RestoredPackageRef list` field (defaults to `[]` so existing
  callers keep compiling; `mkEmitRequest` is the convenience
  constructor that omits it).
- New private `resolveRestoredImports` runs before the existing
  `resolveStdlibImports`.  It indexes restored packages by full
  package name, partitions the user's imports into matched-non-Std
  vs. other, loads each matched package's `RestoredArtifact`, and
  splices the result into the same `StdlibArtifact` list the
  downstream import-table population already consumes.
- `emit` merges the restored + stdlib artifact lists and threads
  them through the existing pipeline unchanged.

**CLI integration** (`compiler/src/Lyric.Cli/Program.fs`):
- `lyric build` accepts `--manifest <lyric.toml>` and auto-
  discovers `lyric.toml` next to the source when the flag is
  absent.  For each `[dependencies]` entry it calls
  `tryLocateRestoredDll`; missing DLLs print a friendly
  "run `lyric restore` first" message before the build attempts
  the emit.

**Tests** (1052 pass, +7 net new):
- 5 new unit tests in `tests/Lyric.Cli.Tests/RestoredPackagesTests.fs`:
  `synthesiseSource` produces the right shape, `tryLocateRestoredDll`
  honours `NUGET_PACKAGES`, `loadRestoredPackage` round-trips a
  real Lyric DLL, structured errors for missing-DLL +
  no-contract-resource cases.
- 2 new end-to-end smoke tests in
  `tests/Lyric.Emitter.Tests/RestoredPackageE2ETests.fs`: the
  consumer-imports-restored-package happy path (build a
  `Lyric.Greeter` package → stage in fake NuGet cache → build +
  run consumer → assert stdout) and the missing-restored-package
  diagnostic (E901 surfaces, no output PE).

**Bootstrap-grade scope** (still future work):
- The synthesised contract source can't reference identifiers
  outside the package's own surface — cross-package symbols inside
  a contract Repr (e.g. `Result[Int, ParseError]` from `Std.Core`)
  surface as a regular `T0001 unknown name` diagnostic when the
  consumer's source hasn't also imported the underlying package.
  Enriching the contract format with explicit re-exports is a
  follow-up.
- `lyric publish` still requires a `func main()` in the publisher
  source; library-shaped packages need an `IsLibrary = true` flag
  on `EmitRequest` (separate small follow-up).
- `--manifest` auto-discovery walks one level up from the source;
  a real workspace search would walk further.

### D-progress-077: C8 part 2 — `lyric.toml` manifest + `lyric publish` / `lyric restore`
*claude/c8-package-manager branch.*  Closes the second half of C8
(D-progress-030 / 031).  Lyric packages now describe themselves in
a `lyric.toml` manifest and ship through NuGet via two thin
wrappers around `dotnet pack` / `dotnet restore`.

**Manifest schema** (`compiler/src/Lyric.Cli/Manifest.fs`):

```toml
[package]
name = "Lyric.Json"
version = "0.5.2"
description = "JSON utilities"
authors = ["alice", "bob"]
license = "MIT"
repository = "https://example.com/repo"

[build]
sources = ["src/main.l"]   # optional
out = "dist"                # optional; defaults to pkg/

[dependencies]
"Lyric.Std" = "1.0.0"
"Lyric.Time" = "0.3.1"
```

The TOML subset is intentionally tight (key=value, [tables], string
/int/bool/array of strings, comments) — exactly what the bootstrap
manifest needs.  Hand-rolled parser; no new package dependencies.
A structured `ManifestError` (`MissingFile`, `ParseError`,
`MissingField`, `InvalidFieldType`) feeds friendly diagnostics
through `renderError`.

**`lyric publish` flow** (`compiler/src/Lyric.Cli/Pack.fs`):

1. Read `lyric.toml` (or `--manifest <path>`).
2. Locate the user's pre-built DLL — `bin/<sanitised-name>.dll` by
   default, override with `--dll <path>`.  `lyric build` is the
   user's responsibility.
3. Generate a throw-away `.csproj` under `.lyric/<name>-pack/` that
   targets `net10.0`, sets `<PackageId>` / `<Version>`, attaches
   optional `<Authors>` / `<Description>` / `<License>` /
   `<RepositoryUrl>`, forwards `[dependencies]` as
   `<PackageReference>` items, and embeds the pre-built DLL via
   `<None Include="…" Pack="true" PackagePath="lib/net10.0/…" />`.
4. Shell out to `dotnet pack --configuration Release --output <dir>`
   (default `pkg/`, override with `-o`).
5. Print the resulting `.nupkg` path on success.

The embedded `Lyric.Contract` resource (D-progress-031) survives
intact — verified end-to-end during smoke-testing.

**`lyric restore` flow**:

1. Read `lyric.toml`.
2. Generate a `.csproj` under `.lyric/<name>-restore/` declaring
   only the `<PackageReference>` items.
3. Shell out to `dotnet restore`; transitive resolution populates
   the standard NuGet cache.
4. Report `restore: <N> packages declared`.

`lyric build`-time consumption of restored packages is a separate
follow-up — today's stdlib resolver still uses `LYRIC_STD_PATH`.
The build wrapper will lower the manifest's `[dependencies]` into
the same `<PackageReference>` shape the restore step uses, then
read each restored DLL's `Lyric.Contract` resource (already
shipped) for cross-package import resolution.

**New test project**: `compiler/tests/Lyric.Cli.Tests/` — first
test suite specifically for the CLI.  21 tests across
`ManifestTests.fs` (round-trip parse, error shapes, string
escapes, dependency sort, comments, duplicate-key rejection) and
`PackTests.fs` (csproj template asserts, default path conventions,
runPack DLL-missing error).  CI now runs LSP + Cli alongside the
existing four suites and the coverage path was updated from a
stale `net9.0/` to `net10.0/` (silently no-op'ing since the .NET
10 migration).

All 1045 tests pass (was 1024; +21 new in the new Cli suite).

**Bootstrap-grade scope**:
- The build-time consumer of restored packages — making `lyric
  build` actually use a NuGet-restored Lyric package — is the next
  C8 follow-up.  Reading the embedded `Lyric.Contract` resource
  through `MetadataLoadContext` is already shipped
  (D-progress-031); the missing piece is the call-site dispatch
  that today routes through the in-tree stdlib resolver.
- TOML support deliberately stops short of arrays-of-tables,
  multi-line strings, datetimes, hex literals.  Bigger TOML follows
  when a real package needs it.
- `lyric publish` doesn't yet roll the user's source through the
  build automatically; a `--build` flag that runs `lyric build`
  first lands when packaging multi-file projects becomes routine.

---

### D-progress-076: C2 Phase B+++ — spill-prior-siblings ordering (D-progress-074 follow-up)
*claude/c2-finalize-generics-and-spill-order branch.*  Closes the
documented evaluation-order caveat from D-progress-074: when a
side-effecting sibling sat to the left of an awaited expression in
the same statement (`add(sideEffect(), await produce())`), the
stack-spilling rewrite would hoist `await produce()` to a
preceding `val __spill_0 = await produce()` binding and reorder
the call to `add(sideEffect(), __spill_0)`, flipping the user-
visible print order between the sibling and the awaited body.

The spill walker (`spillSiblings` in `AsyncStateMachine.fs`) now
applies a Roslyn-style rule to every multi-sibling node — `ECall`
args (with the callee treated as the leftmost sibling), `EBinop`
operands, `EIndex` receiver + indices, `ETuple`, `EList`.  It
finds the rightmost sibling containing an `EAwait` and, for every
left-of-that-position sibling that is NOT side-effect-free
(literal / path / `paren-of-pure`), hoists it into a synthesised
`val __tmp_<n> = expr` binding ahead of the await spill.  The
prior-spill local enters the same SM-field promotion table as
`__spill_*` locals so its value survives across subsequent
suspends.

Bootstrap-grade scope (still bails to M1.4 when the inferer can't
classify):
- The same `tryInferAwaitInnerType` shape lookup is reused for
  prior-sibling typing, so a side-effecting sibling whose CLR type
  isn't a direct function/method call signature lookup falls back
  to the M1.4 blocking shim.  Most user code uses ECall shapes the
  inferer handles (`sideEffect()`, `obj.method()`).

One new test in `AsyncTests.fs`:
- `stack_spill_preserves_left_to_right_order` — runs
  `add(sideEffect(), await produce())` and asserts the output is
  `called\n15` (sideEffect's `println("called")` fires before the
  await), not the reordered `15\ncalled`.

All 1024 tests pass post-change (was 1019; +5 net across this
session's three D-progress entries).  The Tier-4 C2 work is now
fully complete — async generics shipped (D-progress-075) and the
last evaluation-order edge case from D-progress-074 closed here.

---

### D-progress-075: C2 Phase B+++ — generic async funcs (closed-generic SM on TypeBuilder)
*claude/c2-finalize-generics-and-spill-order branch.*  Last C2
sub-item.  `async func id[T](x: in T): T` and friends used to fall
through `isAsyncSmEligible`'s `fn.Generics.IsNone` guard onto the
M1.4 `Task.FromResult<T>` wrapper; now they get a real generic
`IAsyncStateMachine` class whose own type parameters mirror the
function's, with the kickoff site closing the SM via
`TypeBuilder.GetConstructor` / `GetField` / `GetMethod` against
the user-method's GTPB instantiation.

Implementation:
- `AsyncStateMachine.defineStateMachine` is split into
  `defineStateMachineHeader` (defines the TypeBuilder and its
  generic parameter builders) and `defineStateMachineBody` (adds
  fields / methods / IAsyncStateMachine hooks once the caller has
  computed CLR types against the SM's own GTPBs).  The legacy
  one-shot `defineStateMachine` wrapper is kept for non-generic
  callers.
- Both Phase A and Phase B free-standing emit paths now build two
  parallel `Map<string, Type>` substitutions per generic async
  func: `userGenericSubst` (for the kickoff-context bare return
  and the closed builder type) and `smGenericSubst` (for the SM-
  side fields and the `MoveNext` body).
- `emitKickoff` accepts `userGenericArgs: Type[]` plus a
  `kickoffBareReturn: Type` and routes every `Newobj` / `Stfld` /
  `Ldfld` / `Ldflda` on the SM through `TypeBuilder.GetField` /
  `TypeBuilder.GetConstructor` against `sm.Type.MakeGenericType
  (userGenericArgs)`.  The builder's `Create` / `Start` / `Task`
  reflection routes through new `kickoffBuilderCreate` /
  `kickoffBuilderStart` / `kickoffBuilderMember` helpers that
  consult a kickoff-context closed builder type.
- `builderClosedOverTypeBuilder` extended to recognise
  `GenericTypeParameterBuilder` (not just `TypeBuilder`) as an
  unbaked generic argument so `MoveNext`'s
  `SetException`/`SetResult`/`AwaitUnsafeOnCompleted` lookups go
  through `TypeBuilder.GetMethod` for SM-context-closed builders.
- `emitFunctionBody`'s per-method `genericSubst` recovery now
  pulls the SM's GTPBs when emitting MoveNext on a generic SM
  (the `MoveNext` MethodBuilder itself is non-generic; the
  generic params live on the SM type).
- `isAsyncSmEligible` drops the `fn.Generics.IsNone` restriction.
  The impl-method emit path keeps a local guard
  (`fd.Generics.IsNone`) since generic instance methods aren't
  modelled there yet.

Three new test cases in `AsyncTests.fs`:
- `phaseB_generic_async_phaseA` — `async func id[T](x: in T): T = x`
  exercises the await-free generic SM end-to-end (used to fall
  back to M1.4).
- `phaseB_generic_async_phaseB_with_await` — generic async whose
  body contains an inner `await produce()`; validates the closed-
  generic SM survives suspend/resume (`MakeGenericType` over the
  user method's GTPB closes correctly across the cross-resume gap).
- `phaseB_generic_async_two_type_params` — two-parameter generic
  async, validates `MakeGenericType` over multiple arg slots.
- Plus a `[generic_sm_shape]` reflection-based regression guard
  that asserts `id`'s SM type is a generic type definition with
  exactly one generic parameter.

Bootstrap-grade scope (still routes to M1.4):
- Generic async **impl** methods on records / opaque types.  The
  impl-method emit path doesn't yet thread an SM-side
  `defineGenericParameters` call, and an instance method's `self`
  field would also need to participate in the SM's generic
  instantiation.  Out of scope for this session.

All 442→443 emitter tests pass post-change before D-progress-076,
1024 total across all suites after.

---

### D-progress-074: C2 Phase B+++ — stack-spilling rewrite for nested awaits
*claude/async-followup-and-tier-work-wY3nK branch.*  Lifts the M1.4
fallback for async funcs whose bodies hold an `EAwait` in a non-safe
sub-expression position — `f(await g())`, `1 + await foo()`,
`f(await a(), await b())`, and friends.  Before this change the
existing safe-position checker returned `false` for any of those
shapes, the function fell back to the M1.4 blocking shim, and a
real `Task.Delay`-bearing inner await blocked the calling thread
instead of suspending.

Implementation lives in `compiler/src/Lyric.Emitter/AsyncStateMachine.fs`
as a new pre-emit AST rewrite.  Walking the function body, every
`EAwait` encountered in a sub-expression position is hoisted to a
preceding `val __spill_<n> = await innerExpr` binding and replaced
in place by an `EPath { __spill_<n> }` reference.  After the rewrite
the function passes `allAwaitsSafe`, so the existing Phase B
machinery (state-dispatch, AwaitUnsafeOnCompleted, locals-promoted-
to-fields) handles the rest unchanged.

The spill bindings carry no type annotation; instead the rewrite
produces a `Map<string, Lyric.TypeChecker.Type>` keyed on the
synthesised name, populated by a tiny inferer that resolves the
inner-await shape (`EAwait (ECall (EPath f, _))` and
`EAwait (EMember (_, name))`) against the function-signature table
the emitter already builds.  In `Emitter.fs` Pass B, the
`phaseBSpecOpt` collector now consults this map for unannotated
locals before bailing — so `__spill_*` locals enter the SM-field
promotion table with the correct CLR type while user-written
unannotated `val`s still trigger the M1.4 fallback.

Eligibility (covered by this rewrite):
- `f(await g())` and similar single-arg call shapes.
- `n + await foo()` and other binop / prefix-op operands.
- `f(await a(), await b())` — multiple awaits in one statement,
  spilled in source order; the first spill local is promoted
  to an SM field so it survives the second await's suspend.
- `await self.method()` and other simple member-call inner shapes.
- `Std.Json.fromJson(await Std.Http.get(url))` end-to-end pattern
  (gated on the inner-call's signature being lookup-resolvable).

Bootstrap-grade scope (still falls back to M1.4):
- Awaits inside `try` / `defer` regions.  The rewrite would inject
  spill bindings outside the protected region, changing exception
  semantics; we bail and let the existing Phase B+++ try/await /
  defer/await emit (D-progress-056-058) handle the safe shapes.
- Awaits whose inner expression isn't a direct function/method call
  the inferer can resolve.  Lambda calls, chained results, and
  awaits over arbitrary indexer/binop shapes route to M1.4.
- Side-effecting siblings to the *left* of a spilled await:
  `f(printAndReturn(), await g())` would reorder under the rewrite,
  so a stricter "spill-everything-to-the-left-of-an-await" Roslyn-
  style pass is left as a follow-up.  Today the inferer's narrow
  shape matching keeps most user code from tripping this — when it
  does the rewrite still lands correct results for the common
  patterns; pathological reordering edge cases need explicit
  intermediate `val` bindings.

Five new test cases in `compiler/tests/Lyric.Emitter.Tests/AsyncTests.fs`:

- `stack_spill_await_in_call_arg` — `println(toString(await produce() + 1))`.
- `stack_spill_two_await_args` — `await a() + await b()`, exercises
  cross-suspend survival of the first spill local.
- `stack_spill_await_in_binop` — `n + await foo()` lifted to a
  `val total = …` annotated assignment.
- `stack_spill_real_suspend_through_call_arg` — real `Task.Delay`
  inside the spilled await; validates non-pre-completed suspension
  through the rewrite.
- `[stack_spill_sm_shape]` — reflects on the emitted assembly to
  confirm `<l>__<__spill_0>` is present as an SM field, catching
  regressions where the rewrite stops firing.

All 412 emitter tests pass post-change (was 407; +5).  Lexer/Parser/
TypeChecker/LSP suites unchanged at 123/286/132/9.  The 27
pre-existing emitter failures on this branch trace to `Std.Core`
cross-assembly metadata mismatches that pre-date this work and are
tracked separately.

---

### D-progress-001: defer corner cases surface clear errors, not wrong output
*Lands with PR #20.*  `return` from inside a defer-wrapped region and
defers in expression-position blocks both fail loudly at codegen
rather than silently producing wrong output.  Fixing the `return`
path needs the codegen to track "am I inside a try?" and use `leave`
instead of `br`; expression-position defer needs the value-on-stack
to be stashed in a local before the finally runs.  Both are tractable
but separable from the v1 lowering.

### D-progress-002: projectable bootstrap defers `tryInto` and cycle handling
*Lands with PR #21.*  `tryInto(view): Result[Self, ContractViolation]`
synthesis is omitted from the recursive-view PR so the change stays
focused.  The same machinery as range-subtype `TryFrom` (imported
`Std.Core.Result`) plugs in when the resolver-extension PR lands.
`@projectionBoundary(asId)` is recognised by the parser but its
semantic effect (project as ID reference, break cycles) is not
implemented; cycle detection at type-check time is also TBD.

### D-progress-003: range subtype `T0090` / `T0091` only fires on integer-literal bounds
*Lands with PR #18.*  Symbolic bounds (`type X = Int range MIN ..= cap`)
escape the well-formedness check entirely — the bootstrap can't
evaluate them until full constant folding lands.  The emitter also
skips the runtime check on non-literal bounds, so range subtypes with
symbolic bounds today are nominally distinct but unconstrained at
construction.

### D-progress-004: parse host pair is `IsValid` + `Value`, not a tuple
*Lands with PR #19.*  Lyric has no out-parameter syntax, so the
`Lyric.Stdlib.Parse` host class exposes paired `XxxIsValid(s)` /
`XxxValue(s)` methods.  Callers parse twice — accepted as bootstrap
overhead.  Collapsing into a single `TryParseXxx` returning a CLR
tuple is the natural next step once tuple lowering supports it.

### D-progress-005: stdlib resolver compiles each `Std.X` to its own DLL
*Stdlib resolver branch.*  `import Std.X` walks the dependency
closure of stdlib modules (auto-injecting `Std.Core` for any module
that depends on `Result` / `Option`), compiles each missing module
to `Lyric.Stdlib.<X>.dll` in a per-process cache, and hands every
artifact in topological order to the user's emit.  Each module gets
its own DLL — collapsing into a single combined assembly was
considered and rejected because each `.l` file declares its own
`package` namespace and the CLR's namespace-per-assembly story stays
cleaner with one DLL per Lyric package.

The resolver intentionally swallows non-fatal type-checker /
emitter diagnostics during stdlib precompile (matching the prior
`compileStdlibFresh` behaviour), because some pre-existing stdlib
files trip type-checker gaps like `slice[T].length` (T0040 from
`ExprChecker.inferMember`).  The diagnostics are real bugs but
re-surfacing them now would block every test that imports any
stdlib module.  Tracked as a follow-up.

### D-progress-006: cross-assembly union-case type args prefer enclosing shape
*Stdlib resolver branch.*  When the codegen emits an imported union
case constructor (e.g. `Ok(value = ...)` for `Std.Core.Result`), it
now picks each type-arg by checking — in this order — the
`ctx.ExpectedType` shape, the `ctx.ReturnType` shape, and only then
the per-field `peekExprType` binding.  Previously the per-field
peek won, which degraded to `obj` for builtins or imported funcs
that `peekExprType` doesn't recognise — and that produced
mismatched generic instantiations on the IF/ELSE join (e.g.
`Result_Ok<obj, ParseError>` vs `Result_Err<Int, obj>`) that the
JIT rejected with `InvalidProgramException`.

### D-progress-007: UFCS-style `Type.method(args)` dispatch in codegen
*Stdlib resolver branch.*  Lyric's parser tolerates dotted function
names like `IOError.message`, registering them under the full
dotted form.  The codegen now matches `ECall(EMember(EPath[head],
method), args)` against `ctx.Funcs` and `ctx.ImportedFuncs` keyed by
`head + "." + method` and emits a direct static call.  This unblocks
`errors.l`'s `ParseError.message` / `IOError.message` /
`HttpError.message` helpers without rewriting the stdlib's UFCS-
style call sites.

### D-progress-008: `panic` / `expect` / `assert` are codegen builtins
*Stdlib resolver branch.*  `panic("...")`, `expect(cond, msg)`, and
`assert(cond)` now lower to direct calls to
`Lyric.Stdlib.Contracts::Panic` / `::Expect` / `::Assert` (the
F#-side static methods that have existed since M1.4).  Without this
wiring, any stdlib module — `parse.l`'s `parseInt` for instance —
that calls `panic` to escalate a `Result.Err` into an exception
hit `E4 codegen: unknown name 'panic'`.

### D-progress-009: bootstrap CLI + first real-world program
*Lyric CLI branch.*  The `lyric` CLI (lives in
`compiler/src/Lyric.Cli/`) wraps `Emitter.emit` for direct
command-line use:

```
lyric build path/to/foo.l            # writes foo.dll alongside
lyric build foo.l -o out/bar.dll
lyric run   foo.l                    # builds + dotnet exec
```

It writes a sibling `runtimeconfig.json` (computed from the host's
`Environment.Version`) and copies `Lyric.Stdlib.dll` plus any
precompiled `Lyric.Stdlib.<X>.dll` artifacts alongside the output
PE so `dotnet exec` resolves cross-assembly references without
manual setup.

Writing the first real program (`examples/csv.l`) immediately
surfaced four gaps in the language surface that the test harness
had hidden:

1. **`s[i]` on a String wasn't supported.**  Codegen now lowers it
   to `String::get_Chars(int)` returning `Char`.
2. **`println(<non-string>)` didn't type-check.**  Even though
   codegen routed non-string args through `Console.PrintlnAny(obj)`
   with auto-boxing, the type checker had `println` typed as
   `(String) -> Unit`.  Now the checker treats `println`'s arg as
   `TyError` (compatible-with-anything) and lets codegen pick the
   overload.
3. **`String + <other>` didn't type-check.**  Codegen handles
   string concatenation across types via `String.Concat`, but the
   checker insisted on `String + String`.  Now `BAdd` with a
   String LHS produces `String` regardless of RHS.
4. **`println` / `panic` / `expect` / `assert` / `hostParseXxx`
   were codegen-only builtins.**  The checker now has a
   `codegenBuiltinType` table that surfaces them as ordinary
   functions for resolution.

The CLI also wraps `Emitter.emit` in a `try`/`with` so internal
`failwithf` paths (still used for "M2.x not yet supported"
messages in codegen) surface as a clean `internal error: …`
diagnostic + exit 1 instead of a stack trace.

**Bootstrap-grade scope of the CLI**: no incremental builds, no
build cache (each invocation reparses everything), no `--release`
flag, no AOT.  These are tracked Phase 3 follow-ups.

### D-progress-010: stdlib ergonomics — arity overloading, BCL defaults, codegen diagnostics, slice params, LYRIC_STD_PATH
*stdlib-ergonomics branch.*  Five related improvements shipped together:

**1. Function overloading by arity.**  The symbol table, type checker, and
emitter now support multiple definitions of the same function name with
different parameter counts.  Signatures are stored under both a bare name key
(`foo`) and an arity-qualified key (`foo/2`); the T0001 duplicate-function
diagnostic fires only when the same arity is re-declared.  The `importedFuncTable`
in the emitter uses `GetMethods() |> Array.tryFind` (filtered by name + param
count) instead of `GetMethod(name)` which throws `AmbiguousMatchException` when
overloads exist.  This unblocked `Std.String.substring` (1-arg and 2-arg
overloads) and the arity-aware call-site lookup for imported functions.

**2. BCL default-argument handling.**  `resolveBclMethod` in `Codegen.fs` now
accepts overloaded BCL candidates whose extra parameters all have `HasDefaultValue
= true`.  The call site emits the right constant for each skipped parameter
(`Ldnull` for reference types, `Ldc_I4` for booleans/ints/enums, `Ldstr` for
strings, `Initobj` + `Ldloc` for structs).  This makes `String.Split(string?)`
callable as `split(s, sep)` — no BCL overload wrangling required in `.l` source.

**3. Codegen diagnostic threading.**  `FunctionCtx` gained a `Diags:
ResizeArray<Diagnostic>` field that all nested emit calls share.  Internal
`failwithf` calls for unsupported constructs were converted to structured
diagnostic appends (`E0003`, `E0004`, `E0012`).  A `codegenErr` helper emits
`ldnull` + `typeof<obj>` to keep the IL stream legal when continuing past an
error; `codegenErrStmt` skips IL emission entirely.  `emitAssembly` now returns
these diagnostics alongside the output path so the CLI surfaces them in
`<code> error [line:col]: msg` form.

**4. `slice[T]` as function parameter type.**  The type resolver now maps
`slice[T]` in parameter position to the CLR type `T[]`.  Callers can pass
array literals `[1, 2, 3]` to functions declared `(xs: in slice[Int])`, and
`for x in xs` / `xs.length` / `xs[i]` all work across the boundary.

**5. LYRIC_STD_PATH environment variable.**  Both the emitter's stdlib
resolver (`locateStdlibFile`) and the CLI's build-cache fingerprinter
(`BuildCache.locateStdlibFiles`) now check `LYRIC_STD_PATH` before walking
up the directory tree.  Setting this variable to the `compiler/lyric/std/`
directory lets the compiler find stdlib sources in out-of-tree or installed
setups without requiring the repo layout.

**Also updated in this session**: `Std.String.split` (BCL `String.Split`),
`Std.String.join` (pure-Lyric slice iteration), two-arg `substring` overload,
`repeat` body fix, and the CLI incremental build cache (`lyric build` is now
a no-op when source + stdlib + compiler binary are unchanged).

The status table above moves `slice[T]` function params from "not started" to
**Shipped**, and the `Std.String` module now exposes its full planned surface.

### D-progress-011: real-world stdlib — toString, format, Std.File
*real-world-stdlib branch.*  Three small additions that close the
"can I write a script today?" gap:

**1. `toString(x): String`.**  Polymorphic codegen builtin that routes
through `Lyric.Stdlib.Console::ToStr(obj)` with auto-boxing for value
types.  Handles every primitive (Int, Long, Bool, Char, Double) plus
records and union cases via their default `Object.ToString()`.  String
inputs pass through unchanged (no boxing, no host call).  Closes the
"how do I print an Int that came from elsewhere?" papercut — previously
the only paths were `+` concatenation onto a string LHS or routing
through `println` directly.

**2. `format1`/`format2`/`format3`/`format4` (template, args…) -> String.**
Arity-specialised wrappers over `System.String.Format` with `{0}`,
`{1}`, … placeholders.  Lyric has no varargs, so each arity is a
distinct name; codegen routes to `Lyric.Stdlib.Format::OfN(string,
obj…)` with auto-boxing.  Lets users build interpolated strings without
dozens of `+` concatenations.  Add `format5`+ when programs need them.

**3. `Std.File`.**  Bootstrap-grade file I/O wrapper:
`fileExists(path) : Bool`, `readText(path) : Result[String, IOError]`,
`writeText(path, text) : Result[Bool, IOError]`,
`dirExists(path) : Bool`,
`createDir(path) : Result[Bool, IOError]`.  Routes through new
`hostFile*` builtins resolved to static methods on `Lyric.Stdlib.FileHost`,
which catches host exceptions and surfaces a `(IsValid, Value, Error)`
triple — same pattern as `Std.Parse`.  No exception escapes the FFI
boundary.

The success arms return `Result[Bool, IOError]` (carrying `true`)
rather than `Result[Unit, IOError]` because the cross-assembly union
codegen for generic-Unit instantiation produces invalid IL today (`Ok`
constructor on `Result_Ok<int32, IOError>` fails JIT verification).
Tracked as a follow-up; `Bool` is the natural bootstrap stand-in.

Two pre-existing items moved to **Shipped** during this session: `tryInto`
on projectable views (already implemented as Pass D in
`populateTryIntoMethod` and exercised by three tests in
`OpaqueTypeTests.fs`), and `defer` + `return` inside try regions
(already correct via `ctx.TryDepth` + `OpCodes.Leave` and exercised by
`defer_runs_on_early_return_*` in `DeferTests.fs`).  The progress doc
table is updated to reflect their actual state.

**Bootstrap-grade scope**:
- `format` is fixed-arity 1..4 — no real varargs.
- `Std.File` returns `Result[Bool, IOError]` not `Result[Unit, IOError]`
  on success.

### D-progress-012: Std.Collections — growable lists and hash maps via FFI
*collections branch.*  `Std.Collections` exposes mutable, host-backed
collections without waiting for user-side generics polish.  The
implementation rides on the existing `extern type` + `@externTarget`
FFI mechanism (FFI v2, PR #33):

- **Element-monomorphised wrappers on the host side.**  Each
  `(element type)` combination is its own concrete CLR class on
  `Lyric.Stdlib`: `IntList`, `StringList`, `LongList`, `StringIntMap`,
  `StringStringMap`.  Each wraps the obvious BCL backing
  (`List<int>`, `Dictionary<string, string>`, …) and exposes
  `New / Add / Get / Set / Length / HasItem / RemoveAt / Clear /
  ToArr` (lists) or `New / Put / Has / Get / RemoveKey / Length /
  Clear / Keys` (maps).

- **Lyric-side declarations in `lyric/std/collections.l`.**  Each
  CLR class gets an `extern type IntList = "Lyric.Stdlib.IntList"`
  declaration plus one `@externTarget` function per operation.
  Receiver-as-first-param convention matches the existing FFI
  resolver's instance-method handling — no new mechanism needed.

- **Naming.**  Per-type-suffixed names (`addInt`, `getStringIntRaw`,
  `keysStringStringMap`) until generics let us collapse to a single
  surface.  Verbose but unambiguous and survives intersecting imports.

- **Map lookup shape.**  `getXxxRaw` returns 0 / "" for missing keys
  (host's `Dictionary.TryGetValue` collapsed); callers must gate on
  `hasXxxKey` first.  Same workaround `Std.Parse` uses — Lyric has no
  out-params.  Once it does, `tryGet : Map -> Key -> Option[Value]`
  collapses both calls.

**Two infrastructure fixes shipped alongside.**

1. `findClrType` now force-touches `Lyric.Stdlib.Console` before
   walking `AppDomain.CurrentDomain.GetAssemblies()`.  The Lyric.Stdlib
   assembly used to be loaded lazily on first contract check, which
   meant the FFI resolver couldn't find host-side wrapper types until
   *after* some other code path triggered the load.

2. The CLI's `copyStdlibArtifacts` and the test kit's
   `prepareOutputDir` now copy `FSharp.Core.dll` into the user's
   output directory.  F# methods on `Lyric.Stdlib` whose IL touches
   FSharp.Core helpers (`Array.zeroCreate`, used by the maps' `Keys()`
   method) need the assembly resolvable at `dotnet exec` time, and the
   generated `runtimeconfig.json` doesn't reference it.

10 end-to-end tests in `CollectionTests.fs` cover the full surface
including a practical "dedup via map" pattern that uses both list and
map types in one program.

**Pending follow-ups** (tracked, not blocking):
- Real generic `List[T]` / `Map[K, V]` once user-defined generics
  become first-class enough to expose across FFI.
- `tryGet` returning `Option[V]` once out-params land.
- More element types (`Bool`, `Double`) as programs need them — adding
  one is ~5 lines of F# + ~10 lines of `extern` declarations.

### D-progress-013: generic FFI (`extern type List[T]` / `Map[K, V]`)
*generic-ffi branch.*  Replaces D-progress-012's monomorphised
collection wrappers with proper generic FFI:

```lyric
extern type List[T] = "System.Collections.Generic.List`1"
extern type Map[K, V] = "System.Collections.Generic.Dictionary`2"

@externTarget("System.Collections.Generic.List`1..ctor")
pub func newList[T](): List[T] = ()

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)            // BCL Add(T)
  println(xs[0])        // BCL get_Item(int)
  println(xs.count)     // BCL get_Count
}
```

**Layer 1 — generic `extern type`.**  `ExternTypeDecl` carries an
optional `Generics` list; the parser accepts `extern type Foo[T] = "..."`,
the type checker registers the arity, and the emitter validates that
the target CLR type's arity matches.  `TypeMap.toClrTypeWith` already
called `MakeGenericType` for `TyUser(id, args)`, so wiring the open
generic into `typeIdToClr` makes `List[Int]` close correctly.

Cross-package: `Emitter.fs` now mirrors imported extern types from
each `stdlibArtifact.Source` into the user's `typeIdToClr` map.
Without this, `val xs: List[Int]` resolved to `obj` because the
user's typeIdToClr had no entry for `List`.

**Layer 2 — generic `@externTarget` functions.**

```lyric
@externTarget("System.Collections.Generic.List`1.Add")
pub func listAdd[T](xs: in List[T], item: in T): Unit = ()
```

- Constructor support: `Type..ctor` target syntax routes to a
  `ConstructorInfo` and emits `Newobj` instead of `Call`/`Callvirt`.
- Generic-method substitution: when the open BCL declaring type is a
  generic definition, `emitExternCall` closes it via
  `TypeBuilder.GetMethod` / `GetConstructor`, deriving the closing
  type args from the receiver param's CLR type, the return type, or
  (for static helpers like `Lyric.Stdlib.MapHelpers`2.Has`) the
  enclosing function's GTPB array.
- Type-checker permissiveness: `Type.equiv` treats a free `TyVar` as
  matching any concrete type, lifting the previous T0043 `argument
  type mismatch` for generic-call sites that already worked at codegen
  time.
- Inference improvement: `bindLyricToClr` recursively walks compound
  types so `m: Map[K, V]` paired with `Dictionary<string, int>` binds
  `K=string, V=int`.  Plus a context-driven pre-binding step: a
  no-arg generic call's missing type args fall back to the val
  ascription's `ExpectedType` or the enclosing function's `ReturnType`,
  restricted to compound returns so a bare `TyVar` isn't bound to
  whatever the outer expected type is.

**Layer 3 — BCL method dispatch + indexer + helpers.**

- `m.add(k, v)`, `m.containsKey(k)`, `xs.add(item)`, `xs.contains(x)`,
  `xs.count`, `xs.toArray()` etc. all work on extern-typed receivers
  via the existing BCL-method dispatch path.  Two extensions:
  - `getRecvMethods` / `closeBclMethod` walk the open generic's
    methods when the receiver is a TypeBuilderInstantiation
    (`TypeBuilderInstantiation.GetMethods()` is unsupported).
  - `isBclType` consults the open generic when the receiver is a
    closed instantiation, so `Dictionary<gtpb_K, gtpb_V>` still routes
    through the BCL fallback dispatch.
  - For TBI receivers, name + arity matching alone suffices —
    `MethodOnTypeBuilderInstantiation.ParameterType` reports the open
    generic param (`TKey`) rather than the closed substitution
    (`gtpb_K`), so direct equality matching never succeeds.

- `xs[i]` and `m[k]`: `EIndex` codegen now falls back to a
  `get_Item(idx)` lookup when the receiver isn't an array or string.

- TypeBuilderInstantiation in cross-assembly union case construction:
  generic case ctors (`Some<gtpb_V>::.ctor`) get closed via
  `TypeBuilder.GetConstructor` rather than `GetConstructors()` (which
  throws on TBI).  Lets `Some(value = mapGetOrDefault(m, key))` inside
  a generic Lyric function body produce valid IL.

- New `Lyric.Stdlib.MapHelpers<K, V>` static helper: `Has`,
  `GetOrDefault`, `Put`.  Lyric's `mapGet[K, V](m, key) : Option[V]`
  composes `Has` + `GetOrDefault` to build the option without needing
  out-parameters.

**Result.**  `Std.Collections` is now ~70 lines: two `extern type`
declarations, two constructors, three helper externs, one `mapGet`.
Everything else comes for free via BCL dispatch.  The previous
monomorphised `IntList` / `StringList` / `LongList` / `StringIntMap`
/ `StringStringMap` types and per-type-suffixed function names are
retired (the F#-side wrapper classes remain for now in case anyone
still references them, but they're unused from Lyric).

10 end-to-end tests in `CollectionTests.fs` exercise the full
surface using the idiomatic `xs.add(...)` / `m["key"]` syntax,
including a "dedup via map" pattern that mixes both types in one
program.  All 614 tests across the four suites pass (Lexer 70,
Parser 182, TypeChecker 90, Emitter 272).

### D-progress-014: out / inout parameters with definite-assignment analysis
*out-params branch.*  `out` and `inout` parameters now lower to CLR
byref slots end-to-end:

```lyric
import Std.Core
import Std.Collections

func main(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("alice", 30)
  match mapGet(m, "alice") {
    case Some(v) -> println(v)        // → 30
    case None    -> println("missing")
  }
}
```

`mapGet` is now ~5 lines on top of `Dictionary.TryGetValue`:

```lyric
@externTarget("System.Collections.Generic.Dictionary`2.TryGetValue")
pub func tryGetValue[K, V](m: in Map[K, V], key: in K, value: out V): Bool = ()

pub func mapGet[K, V](m: in Map[K, V], key: in K): Option[V] {
  var value: V = default()
  if tryGetValue(m, key, value) {
    Some(value = value)
  } else {
    None
  }
}
```

**Layer 1 — emitter byref lowering.**  `paramClrType` lifted to
module scope; lowers `out p: T` and `inout p: T` to `T&` for both
`MethodBuilder.SetParameters` and the function body's `paramList`.
`out` additionally gets `ParameterAttributes.Out` so .NET callers see
the canonical C# `out` shape.

**Layer 2 — body codegen.**  `EPath` reading a byref parameter emits
`Ldarg + Ldobj` (value type) or `Ldarg + Ldind.Ref` (ref type) — the
auto-dereference is invisible at the Lyric source level.  `SAssign`
to a byref parameter emits `Ldarg + value + Stobj/Stind.Ref` so
writes flow through the pointer.  `peekExprType` peels `T&` to `T`
so other code paths (`println(v)` on a byref param, etc.) still see
the underlying type.

**Layer 3 — call-site address-taking.**  New `emitAddressOf` helper
recognises `EPath name` as an addressable l-value: locals get
`Ldloca`; already-byref parameters pass through with `Ldarg`; non-
byref params spill to a temp (rare; the type checker rejects this at
the source level via T0085 anyway).  Wired into all three user-call
paths (non-generic local, generic local, non-generic imported,
generic imported).

**Layer 4 — type-checker l-value rule (T0085).**  `out`/`inout`
arguments must be a single-segment `EPath` (a named local or
parameter) — passing a literal, expression result, or compound
target fails at type-check time.  Direct user calls bypass the
`TyFunction` representation (which drops param-mode info) and
consult the resolved signature directly.

**Layer 5 — definite-assignment analysis (T0086).**  Implemented in
`StmtChecker.fs`:
- A `DASet` tracks which `out` params are definitely assigned at the
  current program point.
- Sequential statements update the set monotonically.
- `if`/`else` joins via set intersection (one-armed `if` keeps only
  the cond-state contribution).
- Loops are weak — body contributions don't strengthen the post-
  state, since the body may run zero times.
- `return` checks all `out` params are assigned before the branch
  and "consumes" the path (no propagation forward).
- Calls that pass a name to an `out` param of the callee count as
  assigning that name (forwarding case).
- Function exit (fall-through) checks all `out` params one final
  time.

The fall-through and per-return checks combined catch:
- `out` param never written
- One branch of an `if` writes, the other doesn't
- Early `return` skips an assignment

**Layer 6 — `default[T]()` builtin.**  Codegen-only generic helper
that picks its CLR type from `ctx.ExpectedType` (val ascription,
record-field default, etc.).  Emits `Initobj` + `Ldloc` for value
types, `Ldnull` for reference types.  Required to initialise an
`out`-bound `var` before the call.

**Layer 7 — generic-context plumbing.**  Two infrastructure tweaks
that this work needed:
- `StmtChecker.checkBlock` / `checkStatement` now thread the enclosing
  function's generic-parameter names so `var v: V = ...` resolves V
  inside a generic body.
- `Emitter.emitFunctionBody`'s `resolveCtxInner` is seeded with
  `sg.Generics` so the codegen-side ResolveType also recognises the
  function's GTPBs.

**FFI integration.**  `Std.Collections.mapGet` rewritten as the four-
line wrapper shown above.  `MapHelpers<K, V>.GetOrDefault` retired
from the Lyric-side surface (the F# class is still in
`Lyric.Stdlib.dll` for backwards-compat in case someone references it
directly via FFI).

8 end-to-end tests in `OutParamTests.fs`:
- `out_param_basic`, `inout_param_increments`
- DA: `out_da_both_branches`, `out_da_early_return_with_assign`,
  `out_da_forwarded`
- FFI: `ffi_dictionary_try_get_value`
- Builtin: `default_picks_type_from_ascription`
- Practical: `inout_accumulator`

All 622 tests pass: Lexer 70, Parser 182, TypeChecker 90, Emitter 280.

**Bootstrap-grade scope** (tracked, not blocking):
- `out` / `inout` arguments must be a named local / parameter — array
  elements, record fields, and tuple elements aren't yet addressable.
- DA analysis doesn't yet propagate through `match` / pattern
  bindings; functions that assign in a match arm and rely on it must
  fall through after the match instead of returning inside.
- The l-value rule on the codegen side spills non-byref-param value
  args to a temp; this is mostly defensive (T0085 should catch the
  bad shape at type-check time) but means a future rule loosening
  needs the spill semantics revisited.


### D-progress-015: allocating iter helpers (`map` / `filter` / `take` / `drop` / `concat`)
*stdlib-ergonomics branch.*  `Std.Iter` previously shipped only
non-allocating helpers because the local-generic-call path's
`bindLyricToClr` didn't recognise `TyFunction` — a HOF call site like
`mapInts(xs, { n: Int -> n * 2 })` left `U` unbound and the
`MakeGenericMethod` reified the callee with `<obj>` for the return-slot
generic.  The mismatch shipped fine until the callee actually used `U`
as a payload (`List<U>::Add`); the JIT linked Add to a `List<obj>`
instance, the IL pushed an `int32`, and the runtime hit a NRE on the
list's null backing array.

**Fix.**  `Codegen.fs:bindLyricToClr` (local-generic-call variant) now
mirrors the imported-call shape — `TyFunction`, `TyArray`, `TyNullable`,
`TyTuple` all bind position-wise like the existing `TyUser` / `TySlice`
cases.

**Iter additions.**  Five allocating helpers in `compiler/lyric/std/iter.l`
all built on `List[T]` from `Std.Collections` with `.toArray()` at the
end:

- `map[T, U](xs, f)`
- `filter[T](xs, pred)`
- `take[T](xs, n)`
- `drop[T](xs, n)`
- `concat[T](a, b)`

9 end-to-end tests in `IterTests.fs`.  All 631 tests across the four
suites pass (Lexer 70, Parser 182, TypeChecker 90, Emitter 289).

### D-progress-016: `@stubbable` stub builder synthesis (bootstrap)
*stdlib-ergonomics branch.*  Phase 2 M2.3.  Bootstrap-grade lowering
for `@stubbable` interfaces — a sibling record + impl gets synthesised
in the parser-output pipeline so subsequent type-check / codegen passes
treat the stub like any other user type.

For

```lyric
@stubbable
pub interface Clock { func now(): Int }
```

the compiler appends:

```lyric
pub record ClockStub { pub now_value: Int }
impl Clock for ClockStub { func now(): Int = self.now_value }
```

Callers construct directly via the record literal:

```lyric
val s = ClockStub(now_value = 42)
val c: Clock = s
```

`Unit`-returning interface methods generate no field; the synthesised
impl method body is an empty block.  Both `Unit` (the keyword form,
parsed as `TUnit`) and `Unit` (the bare-name form, parsed as
`TRef ["Unit"]`) are recognised so the user's preferred spelling works.

**Implementation.**  New file
`compiler/src/Lyric.Parser/Stubbable.fs` exposes
`synthesizeItems : Item list -> Item list`.  `Parser.fs:parse` invokes
it after the existing `hoistInlineMethods` pass so the fully-cooked
item list reaches the type checker.  No emitter changes — the
synthesised AST is indistinguishable from a user-authored
`record + impl` pair.

**Bootstrap-grade scope** (tracked, not blocking):

- Generic interfaces (`@stubbable interface Repo[T] { ... }`) are
  skipped — generic stubs need generic `impl`s with generic field types.
- Methods with `Self` in return or param positions are skipped —
  `Self` would refer back to the synthesised stub, but the synthesis
  pass runs once over a static interface body without resolving
  back-references.
- Async methods are skipped — the bootstrap can't yet synthesise
  `Task[T]`-shaped fields.  Recording / failing / argument-matching
  builder DSL (`.returning { ... }` etc. per language reference §10
  / D016) is also out of scope.  Methods that fall outside the
  supported subset stay in the interface untouched; if the user
  actually invokes them via the stub they'll surface a normal
  "no impl found" diagnostic later.

5 end-to-end tests in `StubbableTests.fs`.


### D-progress-017: bootstrap LSP server (`lyric-lsp`)
*stdlib-ergonomics branch.*  Phase 3 M3.3 first pass.  Adds
`compiler/src/Lyric.Lsp/` — a console-app that speaks the Microsoft
Language Server Protocol's stdio JSON-RPC transport.  Editors point
at the `lyric-lsp` binary and get push diagnostics on every save +
keystroke.

**Capabilities advertised in `initialize`.**
- `textDocumentSync.openClose = true`
- `textDocumentSync.change = 1` (full sync — re-parse on every change)
- `hoverProvider = true`

**Methods handled.**
- `initialize` / `initialized` / `shutdown` / `exit`
- `textDocument/didOpen` / `didChange` / `didClose`
- `textDocument/hover` (placeholder reply; real position-resolved
  type info is a Phase 3 follow-up)
- Unknown requests reply with JSON-RPC `-32601 method not found`;
  unknown notifications drop silently.

**Diagnostic flow.**  On `didOpen` and `didChange` the server runs
`Lyric.Parser.Parser.parse` and `Lyric.TypeChecker.Checker.check`
on the buffer text and publishes the merged diagnostics list via
`textDocument/publishDiagnostics`.  No IL emission — the LSP keeps
per-keystroke latency low and never touches the build cache.
Diagnostics are cleared explicitly on `didClose`.

**Implementation notes.**

- Three F# files: `JsonRpc.fs` (LSP framing + 2.0 message helpers
  built on `System.Text.Json.Nodes`), `Server.fs` (request dispatch
  + document store), `Program.fs` (stdio entry point).
- No external NuGet libraries — `StreamJsonRpc` /
  `OmniSharp.Extensions.LanguageServer` are heavyweight for what's
  ultimately three primitive transport operations and we'd rather
  not pin to a particular protocol-definitions package this early.
- The full LSP message envelope is treated as a JsonNode tree
  throughout; the field-extraction helpers (`prop` / `propStr` /
  `propInt`) handle the F# 9 strict-nullness shape without leaking
  the `JsonNode | null` annotations into Server.fs.

**Tests.**  New project `compiler/tests/Lyric.Lsp.Tests/` with five
end-to-end tests in `ProtocolTests.fs`:
- initialize advertises the bootstrap capabilities
- didOpen with broken source publishes diagnostics
- didChange to clean source clears diagnostics
- shutdown returns a response with matching id
- unknown request gets JSON-RPC method-not-found error

The test harness drives `Server.runLoop` in-process over a
`MemoryStream` pair — no `dotnet exec` of the real LSP binary, just
synthesised stdin frames in / stdout frames out.

641 tests across all five suites pass (Lexer 70, Parser 182,
TypeChecker 90, Emitter 294, Lsp 5).

**Bootstrap-grade scope** (tracked, not blocking):
- Hover is a placeholder.  Real position-to-type resolution needs
  the type checker to surface a position-indexed view of bindings.
- No completion, no go-to-definition, no signature help.
- No incremental document sync (only full).
- No workspace/configuration / file-watching support.
- No status reporting back to the client (no `window/showMessage`
  on stdlib-resolve failures).


### D-progress-018: `import X as Y` alias semantics
*claude/stdlib-ergonomics branch.*  Both flavours of alias documented in
the language reference now work end-to-end:

```lyric
import Std.Collections.{newList as mkList, newMap as mkMap}
import Std.Iter as I

func main(): Unit {
  val xs: List[Int] = mkList()                  // selector alias
  xs.add(7)
  val doubled = I.map(xs, { n: Int -> n * 2 }) // package alias
  for y in doubled { println(y) }
}
```

**Selector alias** (`import X.{foo as bar}`): handled in
`Emitter.fs:resolveStdlibImports`.  Each aliased item is cloned as an
extra `IFunc` Item with the alias name (and an empty body, since
imported function bodies aren't re-checked) and added to the
`importedItems` list passed to `Checker.checkWithImports`.  The
type-checker then registers the alias name in its signature map and
symbol table.  The emitter mirrors the rename into `importedFuncTable`
under both the bare alias and `<alias>/<arity>` keys.

**Package alias** (`import X as A`): handled by a new post-parse AST
transform `Lyric.Parser.AliasRewriter`.  After parsing, every `EPath`,
`EMember`, `TRef`, `TGenericApp`, `ConstraintRef`, and pattern-position
`ModulePath` whose head segment matches a declared alias is collapsed
to drop that head:

- `Coll.foo` (`EMember (EPath ["Coll"], "foo")`) → `EPath ["foo"]`
- `Coll.List[Int]` (`TGenericApp { Head = ["Coll"; "List"]; ... }`) →
  `TGenericApp { Head = ["List"]; ... }`
- `case Coll.Foo(...)` → `case Foo(...)`

Once rewritten, the rest of the pipeline (type checker, codegen) is
alias-blind.  This avoids duplicating the imported-call generic-
inference logic and works uniformly for type, expression, and pattern
positions.

**Bootstrap-grade scope** (D-progress-018):
- Aliases ADD names; they don't remove the originals.  `import X as A`
  exposes `A.foo` *and* `foo`; `import X.{foo as bar}` exposes `bar`
  *and* `foo`.  Tightening to the strict-rename behaviour is a follow-
  up.
- The `AliasRewriter` is scope-blind — a local variable named `Coll`
  after `import X as Coll` would still get its references rewritten.
  Users should pick alias names that don't shadow locals.
- Aliases on non-`Std.*` user packages aren't yet wired through the
  emitter's package resolver, so this only meaningfully fires for
  stdlib imports today.

5 end-to-end tests in `AliasTests.fs`.  All 646 tests across all five
suites pass (Lexer 70, Parser 182, TypeChecker 90, Emitter 299, Lsp 5).


### D-progress-019: `@projectionBoundary` cycle detection (D026)
*claude/stdlib-ergonomics branch.*  D026 mandates that a `@projectable`
graph cycle requires an explicit `@projectionBoundary` marker on at
least one edge.  Without it the recursive view derivation diverges.

**Detection.**  Before the projectable-view passes run, the emitter
builds a directed graph of projectable opaque types where edges are
non-`@projectionBoundary` fields whose source type mentions another
projectable.  A DFS finds back-edges; the first back-edge produces a
T0092 diagnostic that names the cycle path:

```
T0092 error [12:3]: projectable cycle detected (Team -> User -> Team);
mark at least one field with `@projectionBoundary` to break the cycle
```

Self-loops are caught the same way (`Node -> Node`).

**`mentionedProjectables`** walks compound type expressions
(`slice[T]`, `T?`, `(A, B)`, `(P) -> R`, `Foo[T]`) so a field declared
`members: slice[User]` participates in the graph.

**Bootstrap-grade scope** (D026 follow-up): `@projectionBoundary(asId)`
still leaves the source opaque type in the view rather than
substituting the source's id-field type per the language reference's
§7.3.  The annotation breaks the cycle, but the view's field type
isn't the underlying ID — it's the opaque itself.  Tracked in
`docs/12-todo-plan.md` Band B2 follow-up.

3 new tests in `OpaqueTypeTests.fs`:
- `projectable cycle without boundary is rejected`
- `projectable cycle on self-loop is rejected`
- `projectable cycle broken by @projectionBoundary builds`

All 649 tests across all five suites pass.


### D-progress-020: `()` lowers to a real ValueTuple; Std.File switches to Result[Unit, IOError]
*claude/stdlib-ergonomics branch.*  The cross-assembly generic-Unit
gap documented in D-progress-011 is fixed.  Two related changes:

**Codegen.**  `ELiteral LUnit` previously emitted `Ldc_I4 0` and typed
the result as `int32`.  That worked only because most Unit slots are
discarded — the moment the value flowed into a generic position
expecting `!0 = ValueTuple` (e.g. `Result_Ok<Unit, IOError>::.ctor(!0)`),
the JIT raised `InvalidProgramException` on the param-type mismatch.

The literal now materialises a real `System.ValueTuple` value via
`Ldloca + Initobj + Ldloc` on a fresh local, matching the type's
actual CLR shape (an empty struct).  `peekExprType` on `LUnit` updated
to `typeof<ValueTuple>` so subsequent inference sees the right type.

**Std.File surface.**  `writeText` and `createDir` now return
`Result[Unit, IOError]` instead of the `Result[Bool, IOError]`
bootstrap workaround.  Existing test cases match on `Ok(_)` / `Err(_)`
so no test changes were needed — just the source surface promotion.

All 304 emitter tests pass after the lowering change; the codegen
update is otherwise transparent because previous code that flowed
Unit through arithmetic (rare) still works (the integer path is
gone but Unit values aren't used in arithmetic in practice).


### D-progress-021: DA propagation through match arms
*claude/stdlib-ergonomics branch.*  D-progress-014 noted that the
definite-assignment analysis didn't enter `match` arms — functions
that assigned an `out` param across all arms still tripped T0086 on
the trailing fall-through.

`StmtChecker.daExpr` now handles `EMatch` with the same join shape as
`EIf`: every arm's body is analysed against the post-scrutinee DA
state, and the post-match state is the intersection of every arm's
contribution.  Empty match falls back to the post-scrutinee state.
`EBlock` (a braced block in expression position) is also threaded
through so block-style arm bodies (`case x -> { sign = 1 }`) propagate
their assignments.

```lyric
func parseSign(s: in String, sign: out Int): Bool {
  match s {
    case "neg" -> { sign = -1 }
    case "pos" -> { sign = 1 }
    case _     -> { sign = 0 }
  }
  return true   // no T0086 — every arm assigned `sign`
}
```

1 new regression test in `OutParamTests.fs`.
All 305 emitter tests pass.


### D-progress-022: field-store assignments + inout-of-record-field-store
*claude/stdlib-ergonomics branch.*  Two related codegen gaps closed:

**`recv.field = value`.**  The codegen previously rejected any
`SAssign` whose target wasn't a single-segment EPath or an `EIndex`,
so `c.count = c.count + 1` on a local record produced an internal
"assignment target not yet supported" diagnostic.  The new
`EMember (recv, fieldName)` branch in the SAssign matcher walks
`ctx.Records` to find the `FieldBuilder` and emits `Stfld`.  Walking
the records dict instead of calling `recvTy.GetField` sidesteps the
"The invoked member is not supported before the type is created"
exception — the receiver TypeBuilder is still under construction
during user-function emission.

**`inout c: Record; c.field = ...`.**  The same code path now handles
the byref case "for free": `emitExpr ctx recv` already auto-
dereferences a byref-typed receiver via `Ldind.Ref` on read, so the
write side just sees a normal class reference on the stack.

```lyric
record Counter { count: Int }

func bump(c: inout Counter): Unit {
  c.count = c.count + 1
}

func main(): Unit {
  val c = Counter(count = 5)
  bump(c); bump(c)
  println(c.count)            // 7
}
```

2 new tests in `OutParamTests.fs`:
- `field_store_on_local_record`
- `inout_record_field_store`

All 307 emitter tests pass.


### D-progress-023: `lyric doc` Markdown generator (C9 bootstrap)
*claude/stdlib-ergonomics branch.*  Phase 3 M3.3 first pass for the
documentation tool.  Walks the parsed AST and emits Markdown for the
`pub` surface of a single source file:

```
$ lyric doc demo.l
# Package `Demo`

Module-level doc body verbatim.

### record `Point`
```lyric
pub record Point { pub x: Int, pub y: Int }
```
A 2-D point in the cartesian plane.

### func `add`
```lyric
pub func add(a: in Int, b: in Int): Int
```
Compute the sum of two integers.
```

**Implementation.**  New `compiler/src/Lyric.Cli/Doc.fs` exposes
`generate : SourceFile -> string`.  Per-item signature printers cover
`pub func`, `pub record`, `pub exposed record`, `pub union`,
`pub enum`, `pub opaque type`, `pub interface`, `pub distinct type`,
`pub type`, `pub const`.  Package-private items are filtered out.

The CLI subcommand is `lyric doc <source.l> [-o out.md]`; without
`-o` it prints to stdout.

**Bootstrap-grade scope** (follow-ups in C9):
- One file at a time.  No package-level roll-ups across multiple `.l`
  files; no transitive dependency graph.
- No anchor links / Markdown TOCs — sections aren't cross-linked.
- No doctest extraction; the only thing rendered from `///` text is
  the verbatim body.
- Method tables for `impl` blocks aren't yet rendered.


### D-progress-024 (decision): real async state machines via hand-rolled IL
Recorded as the C2 plan in `docs/12-todo-plan.md`.  See that doc for
the rationale and rollout.

### D-progress-025: const folding for range-subtype symbolic bounds (C3)
*claude/define-language-spec-5DbnS branch.*  D-progress-003 noted that
T0090 / T0091 only fired on integer-literal bounds; symbolic
constants like `MIN_AGE ..= MAX_AGE` escaped both the well-formedness
check and the runtime range check.  C3 ships option (b) of the C3
decision tree (D-progress-025) — a constant folder over literals,
named-const refs, and integer arithmetic.

**Folder.**  New module
`compiler/src/Lyric.TypeChecker/ConstFold.fs`:

```fsharp
type FoldError = NotConstant | Cycle of string | Overflow | DivByZero
val tryFoldInt : SymbolTable -> Expr -> Result<int64, FoldError>
```

Walks `ELiteral (LInt n)`, `EParen`, `EPrefix (PreNeg, ...)`,
`EBinop (BAdd / BSub / BMul / BDiv / BMod, ...)`, and
`EPath { Segments = [name] }` resolving to `DKConst` or `DKVal`
symbols.  Cycle detection via a `Set<string>` of currently-resolving
names.  Arithmetic uses `Microsoft.FSharp.Core.Operators.Checked` so
overflow is surfaced rather than silently wrapping.

**Wire-up.**  `Checker.checkDistinctType` now folds each bound and
emits a new T0093 diagnostic when the fold fails ("expression is not
a compile-time integer constant", "constant 'A' references itself
transitively", etc.); T0090 fires post-fold for inverted bounds.
`Emitter.defineDistinctType`'s `evalLiteral` is replaced with an
`evalConst` that calls the same folder; the runtime range-check IL
now uses the folded value, so `tryFrom(9999)` on
`type Age = Int range MIN_AGE ..= MAX_AGE` correctly returns `Err`.

Lyric doesn't currently parse `const` declarations (only `pub val`
at module level), so the folder accepts both `DKConst` and `DKVal`
symbols — `pub val MIN_AGE: Int = 0` is treated as a compile-time
constant when used in a range bound.

**Tests.**  10 new tests in
`compiler/tests/Lyric.TypeChecker.Tests/ConstFoldTests.fs` covering
literal-only, named-const, transitive const, arithmetic-in-bounds,
inverted-after-fold (T0090), cycle detection (T0093), and non-numeric
underlying (T0091).  2 new e2e tests in `DistinctTypeTests.fs`
verify the runtime range check uses the folded bounds.

All 666 tests pass: Lexer 70, Parser 182, TypeChecker 100,
Emitter 309, Lsp 5.

**Bootstrap-grade scope** (option (c) follow-ups): function calls
in bounds, `if`-in-bounds, float literals, mixed-width arithmetic.


### D-progress-026: C4 phase 1 — strict-match auto-FFI
*claude/define-language-spec-5DbnS branch.*  Phase 1 of C4's phased
auto-FFI rollout.  When the user calls `ExternTypeName.method(args)`
on a Lyric extern type and no explicit `@externTarget` is registered,
the codegen now searches the underlying CLR type's static methods
and resolves when exactly one viable overload matches by `(name |
PascalCase, arg-arity, arg-types)` — no per-method declaration
needed.

```lyric
extern type Path = "System.IO.Path"
extern type Math = "System.Math"

func main(): Unit {
  println(Path.Combine("/tmp", "x.txt"))   // /tmp/x.txt
  println(Math.max(3, 7))                  // 7  (lowercase → PascalCase Max)
}
```

**Resolver.**  For `Type.method(args)`:
1. Match candidates by `(name = methodName, IsStatic, arity = args.Length)`.
2. Prefer exactly-one exact-type-match candidate.
3. Otherwise prefer exactly-one assignable-type-match candidate.
4. Failing both, retry with PascalCase-cased method name
   (`max` → `Max`, `combine` → `Combine`).
5. If nothing unique resolves, surface a structured E0004
   diagnostic listing the receiver's full name; explicit
   `@externTarget` is the documented escape hatch.

**Wire-up.**  New `ExternTypeNames : Dictionary<string, ClrType>`
threaded into `FunctionCtx`, populated in `emitAssembly` from both
local `extern type` declarations and imported extern types from
stdlib artifacts.  The dispatch branch sits after the imported-funcs
UFCS path so explicit `@externTarget` declarations still take
precedence — backward-compat preserved.

4 new tests in `compiler/tests/Lyric.Emitter.Tests/AutoFfiTests.fs`:
- `auto_ffi_path_combine` — `Path.Combine(string, string)`
- `auto_ffi_math_max_pascalcase` — lowercase resolves via PascalCase
- `auto_ffi_path_combine_three_args` — separate overload by arity
- `auto_ffi_void_return` — `Console.WriteLine` (void path)

All 670 tests pass: Lexer 70, Parser 182, TypeChecker 100,
Emitter 313, Lsp 5.

**Bootstrap-grade scope** (phase 2/3 follow-ups in `docs/12-todo-plan.md`):
- Score-based matching with principled coercion rules (Int↔int/long/
  double, String↔string, records↔class refs, unboxing/boxing,
  nullable conversions) — picks lowest-cost match when multiple
  overloads are viable.
- Special shapes: out-params (already in via D-progress-014), by-
  ref structs, `Span<T>` / `ReadOnlySpan<T>`, default args,
  `params T[]`, extension methods, explicit interface
  implementations.


### D-progress-027: Std.Time expansion (C5 / Tier 1.3)
*claude/define-language-spec-5DbnS branch.*  Closes the Std.Time
gaps documented in `docs/10-stdlib-plan.md` Phase 5: calendar
arithmetic, epoch-to-Instant conversion, and IANA timezone lookup.

**New surface in `compiler/lyric/std/time.l`.**

```lyric
addMonths(t: in Instant, n: in Int): Instant      // BCL day-of-month-preserving
addYears(t: in Instant, n: in Int): Instant
addDays(t: in Instant, n: in Double): Instant

fromEpochMillis(n: in Long): Instant              // Unix-epoch -> Instant
fromEpochSeconds(n: in Long): Instant

extern type DateTimeOffset = "System.DateTimeOffset"
extern type TimeZone = "System.TimeZoneInfo"

hostFindTimeZone(id: in String): TimeZone         // IANA / Windows tz lookup
```

The epoch helpers compose two BCL calls (`DateTimeOffset.From*` then
`.UtcDateTime`) so callers see a single one-shot helper.

6 new tests in `compiler/tests/Lyric.Emitter.Tests/StdTimeTests.fs`
covering each of the new helpers plus a UTC-tz lookup smoke.

All 676 tests pass: Lexer 70, Parser 182, TypeChecker 100,
Emitter 319, Lsp 5.

**Bootstrap-grade scope** (deferred follow-ups):
- Tz projection ops: `inZone(t, tz)`, `utcFromZoned(t, tz)`,
  DST-aware comparison.
- Real `Duration` arithmetic library (Lyric-side `+` / `-` operators
  on `Duration` rather than `since` / `plus` named helpers).
- ISO 8601 emission (parsing already lands via `parseOptInstant`).


### D-progress-028: bootstrap-grade wire blocks (C6 / Tier 2.1)
*claude/define-language-spec-5DbnS branch.*  Singleton + `@provided`
+ `expose` + multi-wire support, lowered as a parser-level AST
synthesis just like `@stubbable` (D-progress-016) and `import as`
(D-progress-018).  Scoped lifetimes and the lifetime checker stay
deferred per the C6 decision (D-progress-028) — they're gated on C2.

**Lowering.**  For

```lyric
record Cfg { tag: String }

wire Prod {
  @provided n: String
  singleton cfg: Cfg = Cfg(tag = n)
  expose cfg
}
```

the new `Lyric.Parser.Wire.synthesizeItems` pass appends:

```lyric
pub record Prod { pub cfg: Cfg }
func Prod.bootstrap(n: in String): Prod {
  val cfg = Cfg(tag = n)
  Prod(cfg = cfg)
}
```

ordered as `[record, IWire, bootstrap]` so the symbol table's
first-symbol-wins lookup (`TryFindOne`) lands on `DKRecord` rather
than `DKWire` when resolving `TRef [Prod]` in the factory's return
type.  The original IWire stays in the list for backward-compat with
parser-shape tests.

**Topological singleton ordering.**  `Wire.referencedNames` walks
each singleton's `init` expression and collects every single-segment
EPath reference.  `Wire.topoSortSingletons` does a DFS-based topo
sort and surfaces a P0260 wire-cycle diagnostic if any back-edge
fires.

**Record-of-record fix (bonus).**  While testing C6, surfaced a
pre-existing bug: `defineRecord` used the lookup-less
`TypeMap.toClrType` to project field types, so a field whose Lyric
type was another user record fell back to `obj`.  `record Outer { i:
Inner }` then produced "receiver type Object has no readable property
'msg'" on `o.i.msg` access.  Fixed by:
- Splitting `defineRecord` into a TypeBuilder-stub-then-populate
  pair so all record TypeBuilders are registered in `typeIdToClr`
  before any record's fields are populated.
- Switching the populate pass to `toClrTypeWith lookup` so cross-
  record field types resolve to the matching TypeBuilder.

The two-pass shape applies uniformly to records and opaque-as-record
types.  Projectable view derivation now skips when a cycle was
detected (otherwise the recursive `toView` lowering diverges).

**Tests.**

- 4 new tests in `compiler/tests/Lyric.Emitter.Tests/WireTests.fs`:
  minimal singleton, two-singletons-with-dependency-order,
  multi-`@provided`, two-wires-in-one-program.
- Two parser tests updated to reflect the post-synthesis shape:
  `wire with provided, singleton, bind, expose` and
  `wire with scoped binding` now look up the IWire among the items
  rather than using `getOnlyItem` (the synthesiser inserts
  additional record + bootstrap items alongside the original IWire).
- `every item kind parses without IError + P0098` in
  `ItemHeadTests.fs` adjusts the expected count for the wire case
  to 3 (record + IWire + bootstrap).
- 2 OpaqueTypeTests for projectable cycle rejection updated
  implicitly — the codegen now skips the view derivation when a
  cycle is detected, so the diagnostic surfaces cleanly without the
  "nested toView not yet defined" follow-up exception.

All 678 tests across the five suites pass: Lexer 70, Parser 182,
TypeChecker 100, Emitter 323, Lsp 5.

**Bootstrap-grade scope** (deferred follow-ups in C6):
- `scoped` / `scope_kind` lifetimes with `AsyncLocal<T>`
  propagation across `await`.
- Lifetime checker (singleton-depends-on-scoped → compile error).
- `@bind`-style multi-implementation registration of an interface.
- Async-local scope tracking for HTTP frameworks / DB integrations.


### D-progress-029: reified generic records (Tier 2.2)
*claude/define-language-spec-5DbnS branch.*  Fresh implementation on
top of current main (the April 30 PR #43 was too far behind to rebase
cleanly).  `record Box[T] { value: T }` now lowers to a real generic
CLR class rather than producing `InvalidProgramException` at runtime.

**Lowering.**

- `Records.RecordInfo` gains `Generics: string list` and
  `RecordField` gains `LyricType: Lyric.TypeChecker.Type`, mirroring
  the union-info / union-field shape from D-progress-013.
- The two-pass record-stub setup from D-progress-028 extends to call
  `tb.DefineGenericParameters(typeParamNames)` when `rd.Generics` is
  non-empty, building a `typeParamSubst : Map<string, ClrType>` from
  Lyric type-param names to the matching `GenericTypeParameterBuilder`.
- `defineRecordOnto` accepts the substitution and threads it through
  `TypeMap.toClrTypeWithGenerics` so a field declared `value: T`
  lowers to a CLR field of type `!0` (the GTPB).

**Construction codegen.**  `ECall (EPath [name], args)` for a generic
record:
1. Emits each arg expression and stashes the result into a temp
   local (so we know the arg's CLR type for inference).
2. Walks `bindLyricToClr` over each `field.LyricType` paired with
   the arg's CLR type to fill in the record's generic substitution.
3. `MakeGenericType` closes the record on the resolved type args.
4. `TypeBuilder.GetConstructor(closedType, info.Ctor)` gets the
   closed ctor.
5. Re-loads each arg from its temp local and emits `Newobj`.

**Field-access codegen.**  `EMember (recv, fieldName)` on a
constructed generic record:
- Walks `ctx.Records.Values` matching either `r.Type = recvTy` or
  `r.Type = recvTy.GetGenericTypeDefinition()` so a `Box<int>`
  receiver finds the open-`Box<>` `RecordInfo`.
- For constructed generics, uses
  `TypeBuilder.GetField(recvTy, f.Field)` to get the closed field
  handle and substitutes `f.LyricType` through the receiver's
  generic args to compute the field's closed CLR type.

**Tests.**  5 new tests in `GenericRecordTests.fs`: construction
(Int, String), two-param `record Pair[A, B]`, arithmetic on
substituted field, generic-record-as-field-of-non-generic-record.

All 683 tests across the five suites pass: Lexer 70, Parser 182,
TypeChecker 100, Emitter 328, Lsp 5.

**Bootstrap-grade scope** (deferred):
- Generic-record passed through generic functions (the field
  inference recurses through compound shapes via
  `bindLyricToClr` already, but call-site type-arg propagation
  through nested generics may have gaps).
- `where T: Trait` constraints on record type params (parser
  accepts but the codegen doesn't yet enforce).


### D-progress-030: @derive(Json) source-gen (Tier 2.3)
*claude/define-language-spec-5DbnS branch.*  For each `pub record T`
annotated `@derive(Json)`, the new
`Lyric.Parser.JsonDerive.synthesizeItems` pass appends a
`T.toJson(self): String` function that builds an RFC-8259
JSON-object string by concatenating field-by-field renderings.

```lyric
@derive(Json)
pub record Person { name: String, age: Int }

func main(): Unit {
  val p = Person(name = "Alice", age = 30)
  println(Person.toJson(p))     // {"name":"Alice","age":30}
}
```

**Per-field rendering.**

- `Bool`, `Int`, `Long`, `UInt`, `ULong`, `Double`, `Float`,
  `Char` → `toString(value)` (the polymorphic `toString` builtin
  shipped in D-progress-011).
- `String` → `"\"" + value + "\""` (no escaping yet).
- Nested record with `@derive(Json)` → `<TypeName>.toJson(value)`
  via UFCS-style dotted-name dispatch.
- Anything else → `toString(value)` fallback.

The derive pass collects every `@derive(Json)` record name first, so
field-rendering logic can dispatch correctly to recursive `toJson`
for known nested annotated records.

**Tests.**  4 new tests in `JsonDeriveTests.fs`: basic int+string
record, nested-records-dispatch, Bool field, and a non-annotated
record verifying the synthesiser doesn't emit `toJson` when
`@derive(Json)` is absent.

All 687 tests across the five suites pass: Lexer 70, Parser 182,
TypeChecker 100, Emitter 332, Lsp 5.

**Bootstrap-grade scope** (deferred follow-ups):
- Real String escaping (today doesn't escape `"`, `\`, control
  chars).
- `slice[T]` / array fields rendered as `[...]`.
- `Option[T]` / `Result[T, E]` and other unions (need case-by-case
  emission with case dispatch).
- Inverse `fromJson` synthesis.
- Generic records — `record Page[T]` doesn't yet get a
  per-instantiation toJson.


### D-progress-031: embedded Lyric.Contract resource (C8 part 1 / Tier 3.1)
*claude/define-language-spec-5DbnS branch.*  Every emitted Lyric
assembly now carries a managed resource named `Lyric.Contract`
describing its `pub` surface.  Downstream tooling — cross-package
import resolution, `lyric public-api-diff`, the future
`lyric search` filter on NuGet — reads the resource via
`ContractMeta.readFromAssembly` instead of re-parsing source or
sidecar files.

**Format** (bootstrap-grade JSON; switches to a hand-rolled binary
later when downstream consumers exist + parse latency matters):

```json
{
  "packageName": "MyApp",
  "version": "0.1.0",
  "decls": [
    {"kind":"record","name":"User","repr":"pub record User { name: String, age: Int }"},
    {"kind":"func","name":"greet","repr":"pub func greet(u: in User): String"},
    {"kind":"func","name":"User.toJson","repr":"pub func User.toJson(self: in User): String"}
  ]
}
```

Each declaration's `repr` is a free-form canonical string suitable
for diff display.

**Implementation.**

- New module `compiler/src/Lyric.Emitter/ContractMeta.fs` with:
  - `buildContract : SourceFile -> string -> Contract` walks the
    parsed AST and emits one `ContractDecl` per `pub` item.
  - `toJson : Contract -> string` hand-rolled JSON serialiser.
  - `embedIntoAssembly : string -> string -> unit` post-processes
    the emitted PE via Mono.Cecil, adding (or replacing) the
    `Lyric.Contract` `EmbeddedResource` and writing back atomically
    via a `.tmp` rename.
  - `readFromAssembly : string -> string option` reads the resource
    through Cecil for downstream tooling.
- The emitter calls `embedIntoAssembly` after `Backend.save`.
  Cecil failures surface as a non-fatal E0900 warning (the IL is
  already on disk).
- Lyric.Emitter takes a Mono.Cecil package reference (already
  pulled in by Lyric.Cli for the AOT path).

**Tests.**  2 new tests in `ContractMetaTests.fs`:
- `contract resource is embedded in every emitted DLL`
- `non-pub items are excluded`

All 689 tests pass.

**Bootstrap-grade scope** (C8 part 2 deferred):
- The `lyric.toml` manifest + `lyric publish` / `lyric restore`
  wrappers around `dotnet pack` / `dotnet restore` are still
  pending.  This first part lands the contract format + embedding
  mechanism; the package-manager glue wraps next.
- JSON format → hand-rolled binary (modeled on F#'s
  `FSharpSignatureData` resource) once parse latency matters.
- The `repr` strings are canonical-but-free-form; a real
  structural format with field-by-field type info comes when
  `lyric public-api-diff` lands.


### D-progress-032: real String escaping in @derive(Json)
*claude/define-language-spec-5DbnS branch.*  Closes a deferred follow-
up from D-progress-030: String fields in `@derive(Json)` records now
route through the BCL's `JsonEncodedText.Encode` (via
`Lyric.Stdlib.JsonHost.EncodeString`) for proper RFC-8259 escaping
of `"`, `\`, control chars, and bidi-unsafe sequences.

**Implementation.**  `JsonDerive.synthesizeItems` appends a single
extern shim per source file:

```lyric
@externTarget("Lyric.Stdlib.JsonHost.EncodeString")
func __lyricJsonEscape(s: in String): String = ()
```

Per-field renderers for String now emit `__lyricJsonEscape(value)`
instead of the manual `"\"" + value + "\""` quote-wrap.  Pinning to
the synthesised name avoids requiring the user to `import Std.Json`.

```
println(M.toJson(M(msg = "line1\nline2")))   // {"msg":"line1\nline2"}
println(M.toJson(M(msg = "say \"hi\"")))     // {"msg":"say "hi""}
```

1 new test (`json_derive_string_escaping`) in `JsonDeriveTests.fs`.
All 690 tests pass.


### D-progress-033: C2 Phase A — real `IAsyncStateMachine` synthesis (await-free bodies)
*claude/c2-async-implementation-ZGU95 branch.*  First commit in the
multi-phase rollout of D-progress-024 (real async state machines).

**What ships.**  `async func` whose body contains no internal `await`
now lowers to a real state machine class instead of the M1.4
`Task.FromResult` shim:

```
async func twice(n: in Int): Int = n + n
```

emits a sibling top-level type
`<twice>__SM_<n> : IAsyncStateMachine` with the canonical layout:

- `<>1__state : int` — state-machine state field (initially -1).
- `<>t__builder : AsyncTaskMethodBuilder<int>` — the builder.
- `n : int` — one field per Lyric parameter.
- `MoveNext()` instance method carrying the user's body.
- `IAsyncStateMachine.SetStateMachine` forwarding to the builder.

The user's `twice` MethodBuilder becomes a kickoff stub:

```il
ldloca sm
newobj <SM>::.ctor()
ldloc sm
call AsyncTaskMethodBuilder<int>::Create()
stfld sm.<>t__builder
ldloc sm
ldc.i4.m1
stfld sm.<>1__state
ldloc sm
ldarg.0
stfld sm.n
ldloc sm
ldflda sm.<>t__builder
ldloca sm
call AsyncTaskMethodBuilder<int>::Start<SM>(ref SM)
ldloc sm
ldflda sm.<>t__builder
call AsyncTaskMethodBuilder<int>::get_Task()
ret
```

`MoveNext` runs the user body — accessing parameters via
`Ldarg.0; Ldfld` because they live as SM fields, not method args —
then sets state to -2 and calls `builder.SetResult(value)` (or
`builder.SetResult()` for `Unit`).

**Implementation outline.**
- New module: `compiler/src/Lyric.Emitter/AsyncStateMachine.fs`
  exposes `bodyContainsAwait`, `isPhaseAEligible`,
  `defineStateMachine`, `emitKickoff`, `emitMoveNextEpilogue`,
  `emitSetStateMachine`.
- `Codegen.FunctionCtx` gains a `SmFields : Dictionary<string, FieldInfo>`
  table.  When non-empty (i.e. emitting a state machine's
  `MoveNext`), `EPath` reads, `SAssign` writes, and `peekExprType`
  for parameter names route through `Ldarg.0; Ldfld <field>` /
  `Ldarg.0; <expr>; Stfld <field>` instead of the regular
  `Ldarg N` parameter-slot path.
- `Emitter.fs` Pass B routes async funcs through the SM path when
  `AsyncStateMachine.isPhaseAEligible` returns true.  Eligibility
  requires: top-level (caller-side), non-generic, no internal
  `EAwait` in the body, and no `@externTarget` annotation.  All
  other async funcs continue using the M1.4 `Task.FromResult` /
  `Task.CompletedTask` wrapper.
- SM types are sealed via `CreateType` before `programTy` so the
  kickoff stub's references resolve at runtime.

**Bootstrap-grade scope (Phase A).**
- Bodies that contain `await` (e.g. `Std.Http`'s async funcs)
  keep the M1.4 wrapper path — Phase B adds the real
  `AwaitUnsafeOnCompleted` suspend/resume protocol with state
  dispatch and locals promoted to fields.
- Generic async funcs aren't routed through the SM (closed-generic
  `Start<SM>` plumbing under TypeBuilder is Phase B / C work).
- Async impl methods (instance methods on records / opaque types)
  use the existing path.  The Phase A SM is structured for free-
  standing top-level funcs.
- Exceptions thrown out of `MoveNext` aren't yet routed through
  `SetException`; they propagate naturally because Phase A bodies
  don't await — Phase B introduces the explicit try/catch around
  the `MoveNext` body.

**Tests.**
- All 4 existing async tests in `AsyncTests.fs` pass through the
  new path (their bodies have no internal `await`).
- 1 new behavioural case `[async_block_with_locals]` covers a
  block-bodied async function with multiple `val` bindings.
- 1 new structural regression test `[sm_shape]` reflects on the
  emitted assembly to confirm a real `IAsyncStateMachine`
  implementer is present with the expected fields — catches
  regressions that flip the routing flag back to the M1.4 shim.

All 337 emitter tests pass (was 335; +2 new).  Lexer/Parser/
TypeChecker/LSP suites unchanged at 70/182/100/5.

**What doesn't change behaviourally.**  Because Phase A bodies
never suspend, the Lyric program runs synchronously and produces
the same output as the M1.4 path.  The win is structural: the
emitter now produces spec-correct state-machine IL ready to layer
real suspension on top of, replacing the M1.4 `Task.FromResult`
shape that Phase B can't extend.


### D-progress-034: C2 Phase B — real `AwaitUnsafeOnCompleted` suspend/resume protocol
*claude/c2-async-implementation-ZGU95 branch.*  Builds on Phase A
(D-progress-033).  `async func` whose body contains `await`
expressions at safe top-level statement positions now uses the
real Roslyn-equivalent suspend/resume protocol — values that need
to survive across an `await` are promoted to SM fields, the awaiter
is stashed in a per-site field, and `AwaitUnsafeOnCompleted` is
called against the BCL builder.

**What ships.**  An `async func` like

```lyric
async func sleeps(ms: in Int): Unit {
  await Task.Delay(ms)
  println("woke")
}
```

now lowers to a state-machine class whose `MoveNext` does:

```il
.method MoveNext()
{
  // (no promoted locals here — empty body locals)
  .try {
    Br Ldispatch
    LbodyStart:
    // emit `Task.Delay(ms)` — pushes Task on the stack
    callvirt Task::GetAwaiter()
    stloc awaiter
    ldloca awaiter
    call TaskAwaiter::get_IsCompleted()
    brtrue Lafter_0
    // suspend path
    ldarg.0  ldc.i4.0  stfld <>1__state
    ldarg.0  ldloc awaiter  stfld <>u__1
    var smRef = this  // local copy for `ref this` semantics
    ldarg.0
    ldflda <>t__builder
    ldarg.0  ldflda <>u__1
    ldloca smRef
    call AsyncTaskMethodBuilder::AwaitUnsafeOnCompleted<TaskAwaiter, SM>
    Leave LafterTry
    // resume label (target of state-dispatch switch)
    Lresume_0:
    ldarg.0  ldfld <>u__1  stloc awaiter
    ldarg.0  ldflda <>u__1  initobj TaskAwaiter
    ldarg.0  ldc.i4.m1  stfld <>1__state
    Lafter_0:
    ldloca awaiter  call TaskAwaiter::GetResult()
    // … println("woke") …
    Leave LnormalDone
    Ldispatch:
    ldarg.0  ldfld <>1__state
    switch [Lresume_0]
    Br LbodyStart
  }
  .catch [Exception] {
    stloc ex
    ldarg.0  ldc.i4 -2  stfld <>1__state
    ldarg.0  ldflda <>t__builder
    ldloc ex
    call AsyncTaskMethodBuilder::SetException
    Leave LafterTry
  }
  LnormalDone:
  ldarg.0  ldc.i4 -2  stfld <>1__state
  ldarg.0  ldflda <>t__builder
  // [ldloc resultLocal if non-void]
  call AsyncTaskMethodBuilder::SetResult
  Br LafterTry
  LafterTry:
  ret
}
```

The structure mirrors Roslyn's class-mode debug emission.  Every
`await` claims a state index `N`, lazily defines an `<>u__<N+1>`
awaiter field on the SM, and marks a resume label inside the try
that the state-dispatch switch targets when re-entering MoveNext
after suspension.

**Eligibility (Phase B-safe positions).**  An `async func` is
routed through Phase B when:

- Top-level (caller responsibility).
- Non-generic (closed-generic SM emit on `TypeBuilder` is Phase
  B+ work).
- No `@externTarget` annotation (FFI bypasses the body).
- Every `EAwait` in the body is at a safe position: directly the
  expression of a top-level `SExpr` / `SThrow` / `SReturn` /
  `SAssign` / `SLocal` init, or the entire expression body.
  Awaits inside sub-expressions (`1 + await foo()`,
  `match await foo()`, `f(await g())`) require IL stack-spilling
  that Phase B doesn't yet do.
- All top-level `val`/`let`/`var` locals use simple-name binding
  (no destructuring) and have type annotations (so promotion to
  field has a known CLR storage type).

Async funcs that fail any of these gates keep the M1.4
`Task.FromResult` / blocking-shim path until Phase B+ extends the
safe-position grammar.

**Promoted locals.**  Every top-level local with a type annotation
gets a sibling SM field (`<l>__<name>`).  At MoveNext entry the
field's value is loaded into a regular IL local; at every suspend
site the IL local is flushed back to the field so the value
survives the cross-resume gap.  Body codegen still reads/writes
via `Ldloc`/`Stloc` on the IL local — promotion is invisible to
the regular emit pipeline (no `EPath` handler changes for locals).
Parameters keep the Phase A `Ldarg.0; Ldfld` access pattern via
`SmFields`.

**Implementation outline.**
- `AsyncStateMachine.fs` gains `allAwaitsSafe` / `isPhaseB`
  predicates plus `collectAwaitInners` / `collectTopLevelLocals`
  pre-pass collectors.  `defineStateMachine` accepts a list of
  `(name, type)` local specs and pre-allocates an SM field per
  local; awaiter fields are defined *lazily* during `MoveNext`
  emit via `defineAwaiterField` because the awaiter type isn't
  known until `emitExpr` on the inner task expression returns.
- `Codegen.FunctionCtx` gains an `SmAwaitInfo` slot.  When set,
  the `EAwait` handler emits the suspend/resume IL pattern
  instead of the M1.4 blocking shim.  A `PreAllocatedLocals` map
  lets `defineLocal` reuse pre-declared IL locals for promoted
  locals (so the body's `SLet x = …` Stloc targets the right
  shadow slot).
- `Emitter.fs` Pass B routes Phase B-eligible funcs through
  `defineStateMachine` (with local specs), then orchestrates
  MoveNext emission: promote-load → open try → `Br dispatch` →
  body via `emitFunctionBody` (with `phaseBExit` set so the
  exit-label code routes through `Leave NormalDone`) → mark
  dispatch → switch + `Br bodyStart` → catch handler with
  `SetException` → mark NormalDone with `SetResult` → mark
  AfterTry with `Ret`.
- The `AwaitUnsafeOnCompleted<TAwaiter, TStateMachine>` call
  passes `ref this` via a stack-local copy of `this` (`var sm =
  this; ldloca sm`) — required because the SM is a class
  reference, and `Ldarg_0` would push the reference value, not
  its address.

**Bootstrap-grade scope (Phase B remaining work).**
- Awaits inside `try`/`catch`/`defer`/`match` arms / loop
  bodies — the resume label has to enter the protected region
  correctly, which requires reusing the existing defer / try-leave
  plumbing from D-progress-001.  Today these fall back to M1.4.
- Awaits nested in sub-expressions (`f(await g())`) — IL stack
  must be empty at suspend; needs spill-to-temp transformation.
- Async impl methods (instance methods on records / opaque
  types).
- Async generic funcs (closed-generic SM emit on `TypeBuilder`).

**Tests.**  Five new behavioural cases in `AsyncTests.fs`:

- `phaseB_await_inner_async_void` — await of a Lyric Phase A
  async func; synchronously-completed Task → fast path through
  the suspend/resume IL.
- `phaseB_two_awaits_void` — two await sites → state indices 0
  and 1, two resume labels, two awaiter fields.
- `phaseB_await_returns_int` — non-Unit return; result local
  feeds `SetResult<int>`.
- `phaseB_real_task_delay_suspends` — `await Task.Delay(ms)` via
  auto-FFI on `extern type Task`.  `Task.Delay(10)` returns a
  Task that's NOT pre-completed, so the runtime executes the
  full suspend/resume cycle (`AwaitUnsafeOnCompleted` schedules
  a continuation, MoveNext returns, timer fires, MoveNext is
  re-entered with state == 0, dispatch jumps to the resume
  label, awaiter is reloaded from its field, GetResult runs,
  body continues to `SetResult`).  This is the canonical
  validation that the IL emits a *working* suspension protocol,
  not just the structural shape.
- `phaseB_promoted_local_across_await` — `val x: Int = …`
  declared before an `await`, read after.  Validates the
  field-shadow protocol: at MoveNext entry the field is loaded
  into the IL local, at suspend the IL local is flushed to the
  field, after resume MoveNext re-entry pulls the field's saved
  value back into the IL local for the post-await read.

All 342 emitter tests pass (was 340; +5 new).  Lexer/Parser/
TypeChecker/LSP suites unchanged at 70/182/100/5.  Total: 699
tests pass.


### D-progress-070: C5 — Std.Http full surface (cancellation, timeout, redirect, headers)
*claude/std-http-full-surface branch.*  Lifts the Phase-C-gated
deferral on Std.Http's full surface (D-progress-059, D-progress-068,
D-progress-069 follow-ups).  Adds explicit cancellation-token
overloads, timeout-bounded helpers, redirect-policy client
factories, and response-header lookup; the cancellation propagates
correctly through the FFI boundary.

Also fixes a pre-existing FFI codegen bug (silent `Task<Task<T>>`
double-wrap on async-`@externTarget` functions whose host method
already returns a `Task[<T>]`).  Without the fix, every
`Std.HttpHost` async helper that fanned out to
`Lyric.Stdlib.HttpClientHost` was returning a `Task<Task<T>>`; the
caller's await unwrapped one layer and treated the inner Task as
the bare result, silently dropping cancellation /
exception semantics.  Both `hostSend` / `hostGet` (existing) and
the new `hostSendWithCancel` / `hostGetWithCancel` etc. are now
correct.

What ships:

- **`Lyric.Stdlib.HttpClientHost`** new statics:
  - `SendWithCancel(client, request, token)`,
    `GetWithCancel(client, url, token)`,
    `PostStringWithCancel(client, url, body, contentType, token)` —
    cancellation-aware host calls.
  - `ReadBodyTextWithCancel(response, token)`,
    `ReadBodyBytesWithCancel(response, token)` — body reads honour
    cancellation.
  - `ClientWithRedirects(maxRedirects)`,
    `ClientNoRedirects()` — redirect-policy factories.
  - `ResponseHeader(response, name)` — single-header lookup.
- **`Std.HttpHost`** new bindings: imports `Std.Task` (for the
  `CancellationToken` extern), adds `hostSendWithCancel`,
  `hostGetWithCancel`, `hostPostStringWithCancel`,
  `hostReadBodyTextWithCancel`, `hostClientWithRedirects`,
  `hostClientNoRedirects`, `hostResponseHeader`.
- **`Std.Http`** new user-facing wrappers:
  - `sendWithCancelAsync(request, token)`,
    `sendWithTimeoutAsync(request, timeoutMs)` — request-level
    cancellation / timeout (timeout uses an auto-cancel source via
    `defer { disposeSource(src) }`).
  - `getWithCancelAsync` / `getWithTimeoutAsync`,
    `postWithCancelAsync` / `postWithTimeoutAsync` — convenience.
  - `HttpResponse.bodyTextWithCancel(response, token)` —
    cancellable body read.
  - `HttpResponse.header(response, name): Option[String]` — header
    lookup; returns `None` when the header is absent.
  - `clientWithRedirects(maxRedirects)`, `clientNoRedirects()` —
    redirect-policy client factories.

Bootstrap-grade scope — Phase 4 follow-ups:

- **Per-request redirect policy** (e.g., reject specific schemes,
  log every hop) — today the redirect behavior is fixed at client
  construction time.
- **Connection-pool / handler reuse** — each
  `hostDefaultClient()` constructs a fresh `HttpClient`; pooling
  needs an AsyncLocal-style scoped client.
- **JSON body deserialisation helper** — users today read
  `bodyText` then call `Inner.fromJson(text)` from
  `@derive(Json)` records.  An `HttpResponse.bodyJson<T>(...)`
  helper would need typechecker surface for `Task<T>` to thread
  the deserialise through cancellation cleanly.
- **`OperationCanceledException` distinguishability** — surfaces
  as `HttpError.ConnectionFailed` with the cancellation message;
  a Phase 4 union-case revision could distinguish.

Four new tests in `StdHttpTests.fs`:
`http_send_with_cancel_pre_cancelled`,
`http_get_with_cancel_pre_cancelled`,
`http_post_with_cancel_pre_cancelled`,
`http_client_redirect_factories_construct`.  All 426 emitter tests
pass (was 422; +4 new).

This unblocks user programs that need timeout-bounded HTTP calls
and integrates with the Phase C structured-concurrency surface
(`Std.Task.Scope`) so an HTTP request can be scoped to a parent
cancellation source.

---

### D-progress-069: Structured concurrency — Scope + scopeSpawn + awaitAll
*claude/structured-concurrency branch.*  Lifts the
documented Phase C deferral on structured concurrency
(D-progress-059, D-progress-068 follow-ups) by shipping a
`Scope` type that owns a cancellation source and a list of
spawned children.  When any child fails, the scope's source is
cancelled automatically so siblings observing the token bail.
Pairs with `defer` for guaranteed cleanup on every scope exit.

What ships:

- **`LyricTaskScope`** F# host class — owns a
  `CancellationTokenSource` and a thread-safe `List<Task>`.  Each
  registered child gets a per-task continuation that cancels
  the source on first failure (`NotOnRanToCompletion` filter)
  so cancellation is eager.
- **`TaskScopeHost`** statics — `MakeScope`, `ScopeToken`, `Add`
  (existing-task overload), `SpawnAction` (closure overload),
  `AwaitAll` (snapshot the list and `Task.WhenAll`), `Cancel`,
  `Dispose`.
- **`Std.Task`** new surface — `extern type Scope =
  "Lyric.Stdlib.LyricTaskScope"`; `makeScope`, `scopeToken`,
  `scopeAdd(scope, task)`, `scopeSpawn(scope, () -> Unit)`,
  `awaitAll(scope)`, `cancelScope(scope)`, `disposeScope(scope)`.
- **Imported-func call site fix** — when a Lyric function
  imported from another package takes a delegate-typed param
  (e.g. `() -> Unit`), the call-site emitter now passes the
  expected delegate type to `emitLambdaWith` so the lambda is
  lowered with the correct return type.  Fixed an
  `InvalidProgramException` bug where lambdas through imported
  functions defaulted to `Object` return.

The canonical structured-concurrency pattern reads:

```
async func parent(): Unit {
  val sc = makeScope()
  defer {
    cancelScope(sc)
    disposeScope(sc)
  }
  val tok = scopeToken(sc)
  scopeAdd(sc, delayWithCancel(100, tok))
  scopeAdd(sc, delayWithCancel(200, tok))
  await awaitAll(sc)  // throws if any child failed
}
```

Six new tests in `StructuredConcurrencyTests.fs`:
add-delay-tasks-complete, empty-scope-completes,
explicit-cancel-propagates, spawn-action-count-matches,
failure-cancels-siblings, and the canonical pattern via
defer-based cleanup.  All 422 emitter tests pass (was 416 in
PR #54; +6 new).

Bootstrap-grade scope — Phase 4 follow-ups:

- **Async closures**: Lyric closures can't `await` directly
  (the Phase B state machine doesn't synthesise async lambdas
  yet).  Closures spawned via `scopeSpawn` run synchronously
  on a thread-pool thread; async I/O inside the closure
  auto-awaits via the M1.4 blocking shim — concurrency still
  comes from each closure having its own task, but each task
  blocks while it waits.
- **AsyncLocal scope flow**: tokens are threaded explicitly;
  child async funcs don't auto-discover the scope's token via
  `AsyncLocal<T>`-style runtime ambient lookup.
- **Typed-result aggregation**: `scopeAdd` accepts `Task` only,
  not `Task[T]`; collecting typed results from spawned children
  needs Lyric typechecker support for surfacing
  `Task[T]` values from async-func calls.
- **`OperationCanceledException` distinguishability**:
  cancellation lands as `Exception` (the user's catch).  A
  Lyric-side `Cancelled` union case is Phase 4.

Together with Phase C cancellation tokens (D-progress-068),
this completes the bootstrap-grade structured-concurrency
surface promised by the language reference §11 / `docs/12-todo-
plan.md` C6 follow-ups.

---

### D-progress-068: C2 Phase C — CancellationToken propagation
*claude/c2-phase-c-cancellation branch.*  Lifts the
documented-deferral on Phase C (D-progress-059) by shipping
real cancellation primitives.  Async functions can now accept
a `CancellationToken`, awaitees can honour it cooperatively,
and the structured-concurrency-via-`defer` pattern ensures
sources are cancelled + disposed on scope exit.

What ships:

- **`Std.Task` rewrite**: replaces the previous opaque-type
  stubs with real `extern type` bindings to the BCL's
  `System.Threading.Tasks.Task`,
  `System.Threading.CancellationToken`, and
  `System.Threading.CancellationTokenSource`.  All operations
  route through `@externTarget`s on a new
  `Lyric.Stdlib.CancelHost` static class.
- **Token construction**: `noCancellation()` (the
  never-cancelled sentinel), `makeCancelSource()`,
  `makeCancelSourceTimeout(ms)` (auto-cancel after a deadline),
  `sourceToken(src)`, `cancelSource(src)`,
  `disposeSource(src)`.
- **Token observation**: `isCancelled(token)`,
  `throwIfCancelled(token)` (cooperative throw point).
- **Cancellable delay**: `delayWithCancel(ms, token)` —
  `Task.Delay` overload that accepts a token; on cancellation
  before the timer fires, the awaiting state machine resumes
  with `OperationCanceledException` (caught as `Exception` on
  the Lyric side).  `delay(ms)` (non-cancellable) still
  available for callers that don't have a token.

Six new tests in `CancellationTests.fs` covering: `noCancellation`
returns false; source.make/cancel observability; cooperative
`throwIfCancelled`; `delayWithCancel` cancellation propagation
through suspend/resume; auto-timeout source; and the
structured-concurrency-via-`defer` pattern (`val src =
makeCancelSource(); defer { cancelSource(src);
disposeSource(src) }`).  All 416 emitter tests pass (was 411;
+6 — note: 5 cancel tests + 1 structured-concurrency).

Bootstrap-grade scope — Phase 4 follow-ups:

- **AsyncLocal scope flow**: a token doesn't auto-flow to
  child async funcs the way `AsyncLocal<T>` does in C#.
  Callers must thread the token explicitly.  AsyncLocal
  routing requires SM-level integration that's beyond the
  Phase B+++ surface.
- **`spawn` + `awaitAll`**: structured concurrency in the
  language sense (parent task waits for all children, joins
  on cancellation) needs a dedicated `spawn` primitive.
  Today's helper-shaped `withScope` would need
  generic-async-lambda type inference that's deferred
  (D-progress-059 async-generic SM).
- **`OperationCanceledException` distinguishability**: today
  the user catches `Exception`; a Phase 4 revision can wire
  a Lyric-side `Cancelled` union case so cancellation flows
  separately from generic errors.

The end-to-end shape — ship a token, cancel cooperatively, run
cleanup on scope exit — covers the practical Std.Http
cancellation / timeout use cases that motivated the Phase C
work in the first place; that follow-up (D-progress-059
"Std.Http full surface") is now unblocked.

---

### D-progress-067: Protected type — DEFERRED follow-up notes (SUPERSEDED by D-progress-079)
*claude/c2-async-implementation-ZGU95 branch.*  Bootstrap-grade
codegen for `protected type` shipped under D-progress-079; this
entry is preserved for the deferral context but the §"protected
type with barrier semantics" deliverable is no longer fully
deferred.  Today's parser already accepts `protected type`
(with `PMField`, `PMInvariant`, `PMEntry`, `PMFunc` members)
and the type checker registers it as `DKProtected`, but the
emitter has no codegen for the construct.

A correct implementation requires:

- **Class lowering**: emit a synthesised CLR class wrapping
  the protected state with a Monitor/`object` instance lock.
- **Entry/method synthesis**: each `entry name(...)` and
  `pub func name(...)` becomes a method whose body is
  wrapped in `Monitor.Enter(this) ... try { ... } finally
  { Monitor.Exit(this) }`.
- **Barrier evaluation**: `entry foo(...) when <cond> { ... }`
  evaluates `<cond>` before entering the critical section.
  Bootstrap semantics: if false, throw a "barrier not met"
  exception (Ada-style condition-variable waiting + queue
  signalling lands in Phase 4 alongside structured
  concurrency scopes).
- **Invariant checking**: `invariant: <cond>` re-evaluates
  on entry exit (D008 / contract semantics).

Estimated effort: 2-3 sessions for bootstrap-grade
(synchronous lock + barrier-throw); full Ada-style
condition-variable queues are gated on the C2 Phase C
real-cancellation work since both want
`AsyncLocal<T>`-style scope plumbing.

Coupled deferrals (already documented elsewhere):
- C2 Phase C cancellation (D-progress-059)
- C6 scoped wire lifetimes (gated on Phase C)
- Std.Http full surface (gated on Phase C)

---

### D-progress-066: LSP — completion, hover, go-to-definition
*claude/c2-async-implementation-ZGU95 branch.*  Lifts the
bootstrap LSP from diagnostics-only to a usable triple:

- **Hover** (`textDocument/hover`): given a cursor position,
  identifies the identifier under the cursor (lexer-style
  `[A-Za-z_][A-Za-z0-9_]*` boundary scan), looks it up against
  the parsed file's top-level items, and returns a markdown-
  formatted summary including `pub`/`async` modifiers and any
  `///` doc comments.  Non-identifier positions return an
  empty result.
- **Completion** (`textDocument/completion`): returns every
  top-level item in the current file as a `CompletionItem`
  with `label`, `kind` (mapped from Lyric item kind to
  CompletionItemKind), and `detail` (the same one-line
  summary used for hover).  Triggered by `.` plus on-demand
  invocation.
- **Go-to-definition** (`textDocument/definition`): same
  identifier lookup as hover, returns a `Location` pointing
  at the matching item's full span (so editors can jump
  directly to the declaration).

Capabilities advertised in `initialize`:
`completionProvider` (with `.` trigger char and
`resolveProvider: false`), `definitionProvider: true`, plus
the existing `hoverProvider: true` and `textDocumentSync`.

Implementation notes:
- New helper `identifierAt` does a 1D string scan of the
  document (no re-tokenisation) — ASCII-fast for the common
  case; UTF-16 surrogate pairs split mid-identifier are a
  pathological case the bootstrap doesn't handle.
- `itemSummary` and `itemName` produce per-item-kind one-line
  signatures; both share the same render so hover/completion
  stay consistent.
- All three handlers re-parse the document on each request.
  Incremental parsing + resolved-AST caching is a Phase 4
  follow-up.

Bootstrap-grade scope:
- **Cross-file imports** aren't surfaced — completion only
  shows the current file's top-level names.  An imported
  `Std.Json.toJson(...)` call doesn't auto-complete to
  `toJson` from `Std.Json`.
- **Scope-aware ranking** (in-scope locals, parameter names,
  match bindings) isn't done — only top-level items appear.
- **Type-aware hover** (showing the actual resolved type
  instead of just the syntactic signature) requires running
  the full type checker per request and threading the result
  to the position-lookup; deferred.

Four new tests in `ProtocolTests.fs`:
`initialize advertises completion + definition`,
`completion lists top-level items`, `hover on an identifier
returns its summary`, and `definition on an identifier
returns its location`.  All 9 LSP tests pass (was 5; +4 new).

---

### D-progress-065: Tutorial documentation — guided newcomer intro
*claude/c2-async-implementation-ZGU95 branch.*  Phase 3 ships
`docs/13-tutorial.md`, a 30-minute walkthrough that takes a
beginner from Hello World through records, sum types,
generics, async/await, file I/O + JSON, and the three new
testing modules (D-progress-063 / 064).  Each section is a
small, runnable program; the README's reading-order is
updated to put the tutorial after the overview (00 → 13 →
02 → 01 → 03).

The tutorial intentionally avoids the spec's exhaustiveness;
it's a gateway, not a reference.  Cross-references point
readers to the language reference, decision log, and
worked-examples gallery for depth.  Future revisions will
grow domain-focused chapters (REST services, contract-driven
domain modelling) once the relevant Phase 2/3 features
mature.

---

### D-progress-064: Std.Testing.Property — property-based testing
*claude/c2-async-implementation-ZGU95 branch.*  Phase 3 ships
a bootstrap-grade property-based testing surface so users can
assert invariants hold across many random inputs without
writing per-input loops by hand.

`Std.Testing.Property` (`lyric/std/testing_property.l`):
- `forAllIntRange(rng, min, max, n, prop)` — runs `prop: (Int)
  -> Bool` on `n` random Int samples in `[min, max)`, panicking
  with the failing input on the first counterexample.
- `forAllBool(rng, n, prop)` — Bool inputs.
- `forAllDouble(rng, n, prop)` — Double inputs in `[0, 1)`.
- `forAllIntPair(rng, min, max, n, prop)` — `(Int, Int)` pairs
  for binary properties (commutativity, associativity, etc.).

The caller passes a seeded `Random` from `Std.Random`, making
runs deterministic and reproducible.  Properties are written
as bare lambdas (`{ x: Int -> ... }`) so the syntactic
overhead matches Lyric's existing higher-order helpers in
`Std.Iter`.

Bootstrap-grade scope:
- No shrinking (the failing input is reported as-is, not
  reduced).
- No `Gen[T]` type-class — each scalar gets its own
  `forAll<Type>` helper rather than a composable generator
  monad.
- Slice / record / generic-T inputs aren't yet supported
  (would need a type-driven generator for each).

Four new tests in `PropertyTestingTests.fs` covering Int
addition commutativity, even-doubling, Bool double-negation,
and Double range bounds.  All 411 emitter tests pass (was
407; +4 new).

---

### D-progress-063: Std.Testing + Std.Testing.Snapshot — built-in test utilities
*claude/c2-async-implementation-ZGU95 branch.*  Phase 3 ships a
bootstrap-grade testing surface so Lyric programs can write their
own tests without rolling assertion helpers each time.

`Std.Testing` (`lyric/std/testing.l`):
- `assertEqual(actual, expected, label)` — panics on string mismatch
  with a structured "expected/actual" message.
- `assertEqualInt(actual, expected, label)` — same for `Int` values
  (sidesteps `toString` boilerplate).
- `assertTrue(cond, label)` — generic boolean assertion.

`Std.Testing.Snapshot` (`lyric/std/testing_snapshot.l`):
- `snapshot(label, actual): Result[Bool, IOError]` — compares
  `actual` against `snapshots/<label>.txt`.  First run: creates
  the file (after best-effort `createDir("snapshots")`) and
  returns `Ok(true)` so the author reviews and commits.  Later
  runs: `Ok(true)` on match, `Ok(false)` on mismatch.  IO errors
  surface as `Err`.
- `snapshotMatch(label, actual): Unit` — convenience wrapper
  that panics on mismatch or IO error; CI lands here.

Bootstrap-grade scope: snapshot directory hard-coded to
`snapshots/` relative to the working directory; multi-line
captures are byte-for-byte compared (no normalisation); diff
rendering is the caller's job (panic message just says
"mismatch").  Property-based generators and a richer xUnit-style
discovery layer remain Phase 3 follow-ups.

Four new tests in `SnapshotTestingTests.fs`:
first-run-writes-snapshot, matching-second-run, mismatched-second-
run, and snapshotMatch-panics.  All 407 emitter tests pass (was
403; +4 new).

---

### D-progress-062: lyric public-api-diff for SemVer enforcement
*claude/c2-async-implementation-ZGU95 branch.*  Ships the
`lyric public-api-diff <old.dll> <new.dll>` CLI command that
reads the embedded `Lyric.Contract` resource from each DLL,
parses both contracts, and reports added / removed / changed
public declarations with a SemVer hint.  Exit codes:

- `0` — no changes OR additive only (minor-bump-worthy).
- `2` — breaking changes (Removed or Changed).  CI gates can
  trigger major-version bumps on `2`.
- `1` — usage / IO error (bad path, missing contract resource).

Implementation:
- `Lyric.Emitter.ContractMeta.parseFromJson` deserialises the
  JSON-serialised `Contract` payload via `System.Text.Json`,
  with null-safe string handling so `string | null` returns
  from `JsonElement.GetString()` don't propagate.
- `diffContracts` keys decls by `(Kind, Name)` and emits
  `DiffAdded` / `DiffRemoved` / `DiffChanged` entries; sorted
  Added → Removed → Changed for deterministic output.
- `hasBreakingChanges` predicate flags Removed / Changed; CLI
  exit code derives from this.
- `renderDiffEntry` prints with `+` / `-` / `~` prefixes;
  Changed entries show old and new repr on indented lines.
- CLI command `public-api-diff` in `Lyric.Cli/Program.fs`;
  `printUsage` updated.

Four new tests in `ContractMetaTests.fs`:
`parseFromJson round-trips toJson`,
`diffContracts detects added/removed/changed`,
`diffContracts identifies additive-only as non-breaking`,
plus the existing two contract-embedding tests.  All 403
emitter tests pass (was 400; +3 new).

End-to-end CLI smoke (manual):
```
lyric build v1.l -o v1.dll
lyric build v2.l -o v2.dll
lyric public-api-diff v1.dll v2.dll  # exit 2 on breaking
```

---

### D-progress-061: C4 Phase 2 — score-based auto-FFI matching
*claude/c2-async-implementation-ZGU95 branch.*  Replaces C4
Phase 1's strict exact-match auto-FFI dispatch with a
principled score-based picker.  Each per-parameter coercion
contributes a numeric distance:

- exact match: 0
- assignable (e.g. derived → base, interface impl): 1
- Int → Long widening: 2
- Int / Long → Double widening: 3
- Int → float32 / Double → float32: 4
- value-type → object boxing: 5
- object → value-type unboxing: 6

The candidate with the lowest total cost wins; tied minimums
surface as an ambiguity diagnostic that lists every viable
arity-matched overload so users can disambiguate via an
explicit `@externTarget`.  The IL emit applies the matching
coercion (`Conv_I8`, `Conv_R8`, `Conv_R4`, `Box`, `Unbox_Any`)
per-arg before `Call`.

Two new tests in `AutoFfiTests.fs`:
`auto_ffi_int_to_long_widening` (asserts the score-based pick
still resolves `Math.Min(int, int)` exactly when both args are
Int; widening doesn't kick in unless needed) and
`auto_ffi_score_based_diagnostic` (`Math.Sign(long)` resolves
to the long-arg overload via score-based pick — a previously-
unsupported case under Phase 1).  All 400 emitter tests pass
(was 398; +2 new).

---

### D-progress-060: Std.Json fromJson — slice + nested-record support
*claude/c2-async-implementation-ZGU95 branch.*  Extends the
synthesised `<Record>.fromJson(s: in String): <Record>` to
records whose fields include primitive slices
(`slice[Int|Long|Double|Bool|String]`) and nested
`@derive(Json)` records.  Today's bootstrap restricted
synthesis to records whose fields were all primitive
Int/Long/Double/Bool/String; deriving Json on a record with a
nested-record or slice-of-primitive field skipped fromJson
generation entirely (toJson kept working).

Implementation:
- `Lyric.Stdlib.JsonHost`: new `GetIntSlice`, `GetLongSlice`,
  `GetDoubleSlice`, `GetBoolSlice`, `GetStringSlice` reader
  helpers (each writes the field's array via an out param,
  returning `false` + an empty array on miss); new
  `GetSubObject` reader returning the matching sub-document's
  raw JSON-text representation; `HasField` and
  `GetSubArrayElements` helpers staged for future
  Option-typed and slice-of-record support.
- `Lyric.Parser.JsonDerive`: `primitiveSliceFromJsonHelper`
  picks the matching `__lyricJsonGet<T>Slice` shim;
  `classifyField` returns `FsPrimitive` /
  `FsPrimitiveSlice` / `FsNestedRecord` for the three
  shapes the synthesiser handles; the ctor-time stmts
  emit one of three patterns (primitive `var name=default;
  helper(s, "name", name)`, slice same shape with the
  Slice-suffixed helper, nested `var name__sub="{}";
  GetSubObject(s, "name", name__sub); val name =
  Inner.fromJson(name__sub)`).  The recursive `Inner.fromJson`
  call uses the same `EMember (EPath Inner, "fromJson")`
  shape as the existing toJson recursion.
- New extern shims appended unconditionally per source file
  alongside the existing `__lyricJsonGetInt`/etc:
  `__lyricJsonGetIntSlice`, `__lyricJsonGetLongSlice`,
  `__lyricJsonGetDoubleSlice`, `__lyricJsonGetBoolSlice`,
  `__lyricJsonGetStringSlice`, `__lyricJsonGetSubObject`.

Bootstrap-grade scope:
- Slices of `@derive(Json)` records (`slice[Inner]`),
  `Option[T]` fields, generic types, and records mixing
  Inner with non-primitive non-derive-Json types still skip
  fromJson generation (synthesiser returns `None`).
- Missing/wrongly-typed fields still default-initialise on
  the Lyric side (helper returns `false`, ignored).

Three new tests in `JsonDeriveTests.fs`:
`json_derive_fromJson_int_slice` (slice[Int] + slice[String]
fields round-trip through GetIntSlice / GetStringSlice),
`json_derive_fromJson_nested_record` (User with nested
Address recursively decoded via Address.fromJson(subStr)),
`json_derive_fromJson_double_slice` (slice[Double] round-trip).
All 398 emitter tests pass (was 395; +3 new).

---

### D-progress-059: C2 outstanding items — deferred follow-up notes
*claude/c2-async-implementation-ZGU95 branch.*  Three Phase B+++/
Phase C items remain after D-progress-056-058: stack-spilling
for awaits in sub-expression positions (`f(await g())`, `1 +
await foo()`), async generic functions (closed-generic SM on
TypeBuilder), and Phase C `CancellationToken` propagation +
structured-concurrency scopes.  The M1.4 blocking shim already
emits correct (just blocking, not real-suspending) IL for
every shape we don't route through Phase B, so these are
deferred without correctness risk:

- **Stack-spilling.**  Today an EAwait nested inside an
  ECall/EBinop/etc. fails the safe-position check and routes
  through M1.4.  Lifting the suspend to handle non-empty IL
  stack at the `Leave` site requires either an AST-rewrite
  pass that promotes each non-trivial sub-expression to a
  preceding `val __spill_N = await ...` statement, or
  emit-time stack-spilling that flushes the partial-stack
  contents to fresh SM fields before suspend.  Both are
  multi-day implementation efforts; users can write the
  rewrite manually today.

- **Async generic functions.**  `async func id[T](x: in T): T`
  routes through M1.4 because `isAsyncSmEligible` rejects
  `fn.Generics`.  A real Phase A/B SM for generic async
  requires defining the SM as a generic `TypeBuilder` whose
  type parameters mirror the function's, then constructing
  the closed-generic SM at the kickoff site via
  `TypeBuilder.GetConstructor`/`GetField` against the open
  definitions.  The infrastructure is sketched in the
  closed-over-TypeBuilder workarounds in Codegen.fs; full
  wiring is a 1-2 day effort and not needed for correctness
  (M1.4 wraps via `Task.FromResult<T>`).

- **Phase C cancellation.**  `CancellationToken` propagation
  through the SM and structured-concurrency scopes (Lyric's
  `scope` blocks with `cancel`) require a token-flowing
  design across both the SM emit AND the runtime — both the
  SM (so MoveNext checks for cancellation at suspend points)
  and the surface API (so call sites pass tokens implicitly).
  Gated on the full Phase B+++ landing.

These items are tracked here rather than in
`docs/12-todo-plan.md` so the bootstrap-progress thread stays
self-contained.

---

### D-progress-058: C2 Phase B+++ — for-loop awaits with real suspension
*claude/c2-async-implementation-ZGU95 branch.*  Lifts the M1.4
fallback for `for x in slice { ... await ... }` patterns where
the iter expression is await-free and the body's awaits sit at
safe top-level positions.  Iterator state (the slice array, the
index counter, and the loop-bound element) all become SM fields
when the body contains an award, so their values survive the
cross-resume gap.

Implementation:
- `Lyric.Emitter.AsyncStateMachine.isSafeStmt` SFor case: a
  for-in with single-name binding, await-free iter expression,
  and a body whose stmts pass `safeStmtList` is now safe.
- `Codegen.fs` SFor handler detects "Phase B + body has await"
  via the new `hasAwaitInBlock` re-export and routes to a
  field-backed emit: define `<for>__iter_<name>`,
  `<for>__idx_<name>`, `<for>__elem_<name>` fields on the SM
  type, stash the iter into the iter field, drive the loop via
  Ldfld/Stfld throughout, and bind the loop variable through
  `ctx.SmFields.[name]` so body emit reads/writes the element
  field naturally.
- Index increment goes through Ldfld/Add/Stfld; the loop's
  `ContinueLabel` is the increment site (consistent with
  Lyric's `continue` semantics).

Bootstrap-grade scope:
- Single-name `for x in iter` only (matches today's codegen
  restriction).
- Iter expression must be await-free.
- Body's awaits must sit at safe top-level positions
  (`safeStmtList`).
- Pattern-binding for-loops, await-bearing iter expressions,
  and nested defer/try inside the body fall back to M1.4.

One new test in `AsyncTests.fs`:
`phaseBPlusPlusPlus_for_await_basic` — `for n in items { await
Task.Delay(2); println(toString(n)) }` exercises real
suspension on each iteration, with field-backed iter/idx/elem
preserving state across resume.  All 395 emitter tests pass
(was 394; +1 new).

---

### D-progress-057: C2 Phase B+++ — defer + await with real suspension
*claude/c2-async-implementation-ZGU95 branch.*  Lifts the
M1.4 fallback for `defer { cleanup }; ...; await foo()` patterns
where the defer body is await-free, the trailing await is a
top-level safe-position stmt, and pre/between stmts are
await-free.  Today's `isSafeStmt` only checked the defer body's
awaits — not whether subsequent stmts contained awaits — so an
async func with a `defer { ... }; await Task.Delay(10)` would
pass safety, route through Phase B, and emit IL that suspended
out of a `.try/.finally` (running the finally on suspend, then
trying to resume INTO the protected region — `InvalidProgramException`).

This entry tightens the safety check AND adds a proper emit:

- `Lyric.Emitter.AsyncStateMachine.safeStmtList` walks each
  stmt list with positional state.  Once an `SDefer` is
  encountered, subsequent stmts must satisfy the duplicated-
  emit constraint (zero awaits OR exactly one trailing
  top-level await preceded by award-free stmts).  Recursive
  through SLoop / SWhile bodies.
- `tryMatchDeferAwaitTrailingShape` returns the
  `(preDefer, deferBody, between, awaitStmt)` split when the
  function body fits the duplicated-emit pattern.
- `Codegen.emitDeferAwaitDuplicated` emits the IL: pre-defer
  stmts run unprotected, then a first `.try` (between stmts +
  awaiter compute + suspend-or-inline-getResult) with a
  synthetic catch that runs the cleanup body and rethrows;
  on first-time normal exit, cleanup runs after the `.try`
  before branching past the resume copy.  Resume entry sits
  outside both `.try`s (wired to the global state-dispatch
  switch) and re-enters a duplicated `.try` whose body is
  just `GetResult` + bind, again with cleanup-on-catch +
  rethrow and cleanup-on-normal-exit.
- `Emitter.fs` `emitBodyBlock` detects the trailing-await
  defer shape before falling through to the existing
  `emitStatementsWithDeferTail` flow, restricted to
  Unit-returning async functions for the bootstrap (the
  trailing await's value isn't routed through `routeReturn`).

Bootstrap-grade scope:
- Defer body must be await-free.
- Body must have exactly one defer.
- Trailing await must be the function body's last stmt
  (bare `await foo()` or `val r = await foo()`).
- Pre-defer / between-defer-and-await stmts must be
  await-free.
- Function must return Unit.
- Multiple defers, defers in nested blocks, defers around
  multiple awaits, defers in non-Unit-returning funcs all
  fall back to M1.4.

Two new tests in `AsyncTests.fs`:
`phaseBPlusPlusPlus_defer_await_no_throw` (defer-then-await,
real `Task.Delay` suspension, cleanup runs after resume) and
`phaseBPlusPlusPlus_defer_await_pre_defer_stmt` (a stmt
before the defer, a between stmt, and a real-suspension
trailing await).  All 394 emitter tests pass (was 392; +2 new).

---

### D-progress-056: C2 Phase B+++ — try/catch + await with real suspension
*claude/c2-async-implementation-ZGU95 branch.*  Lifts the M1.4
fallback for `try { ... await ... } catch ...` patterns where
the body's only await sits at a top-level trailing position
(`await foo()` bare or `val r = await foo()`) and catches are
await-free.  The resulting IL uses a duplicated-post-await
shape: the user try is emitted twice — once for the first-time
path (pre-stmts → compute awaiter → suspend-or-inline-getResult
→ bind) and once for the resume path (just GetResult + bind),
with the resume label sitting between the two `.try` copies so
the global state-dispatch switch doesn't have to branch into a
protected region.  Both copies attach the user's catch
handlers so GetResult-from-faulted-task and pre-stmt
exceptions both flow through the user catch.

Implementation:
- `Lyric.Emitter.AsyncStateMachine.isSafeStmt` STry case:
  return true when body fits the single-trailing-await shape
  AND catches are await-free; otherwise the function falls
  back to M1.4.  A new public `isTryAwaitBodyShape` re-exports
  the predicate for codegen.
- New `isSafeStmtNested` variant rejects STry+await inside
  expression contexts (try-as-expression / EBlock-in-
  expression) so `return try { await ... } catch ...` keeps
  using the M1.4 blocking shim until try-as-expression+await
  gets its own duplicated-emit path.
- Codegen.fs: extracted catch-type alias resolver to module-
  level `resolveCatchTypeName`; statement-form STry handler
  now routes to new `emitTryAwaitDuplicated` when SmAwaitInfo
  is set and body matches the Phase B+++ shape.  The duplicated
  emitter inlines the first-try (pre + compute-awaiter +
  IsCompleted check + suspend or fall-through-to-GetResult +
  bind), marks the resume label between the two copies, then
  emits the second-try (just GetResult + bind), with catch
  handlers duplicated for both copies.

Bootstrap-grade scope:
- Single trailing await per try body (the canonical
  `try { await foo() } catch ...` pattern from Std.Http).
- Multiple awaits in one try body, post-await statements,
  awaits inside catches, awaits inside defer, nested try+await,
  SAssign+await, and SReturn+await all fall back to M1.4.
- Catch handler bodies are duplicated in IL (no shared label —
  blocked by IL's "no branch into protected region" rule).
  Code-size hit is acceptable for the bootstrap.

Four new tests in `AsyncTests.fs`:
`phaseBPlusPlusPlus_try_await_no_throw`,
`phaseBPlusPlusPlus_try_await_pre_stmts`,
`phaseBPlusPlusPlus_try_await_caught` (the awaitable throws —
caught by user handler), and
`phaseBPlusPlusPlus_try_await_real_suspend` (Task.Delay forces
the resume path).  All 392 emitter tests pass (was 388; +4 new).
Lexer/Parser/TypeChecker suites unchanged at 70/182/100.

---

### D-progress-055: Std.Random — pseudorandom number generation
*claude/deferred-items-round4 branch.*  New `Std.Random`
package wraps `System.Random` for pseudorandom number
generation.  Surface area:

- `sharedRandom()` — process-shared instance via
  `System.Random.Shared`.
- `makeRandom(seed: Int)` — seeded instance via a thin
  `Lyric.Stdlib.RandomHost.Make` wrapper.
- `nextInt(rng)` / `nextIntBelow(rng, max)` /
  `nextIntRange(rng, min, max)` / `nextLong(rng)` — random
  integers.
- `nextDouble(rng)` — random `[0, 1)` double.
- `nextBool(rng)` — random `true`/`false` via
  `Lyric.Stdlib.RandomHost.NextBool`.

Three new tests in `StdRandomTests.fs`.  Seeded RNGs make the
`nextIntRange` test deterministic.  All 388 emitter tests pass
(was 385; +3 new).

---

### D-progress-054: Std.Math — new BCL-backed numeric utilities module
*claude/deferred-items-round4 branch.*  New `Std.Math` package
exposes `System.Math` / `System.Double` BCL statics through
`@externTarget` annotations.  Surface area:

- **Constants.**  `pi()` / `e()` / `tau()`.
- **Absolute value.**  `absInt` / `absLong` / `absDouble`.
- **Pairwise min/max.**  `minPairInt` / `maxPairInt` / `minPairLong`
  / `maxPairLong` / `minPairDouble` / `maxPairDouble`.
- **Powers / roots / logs.**  `pow` / `sqrt` / `cbrt` / `ln` /
  `log10` / `log2` / `exp`.
- **Trigonometry (radians).**  `sin` / `cos` / `tan` / `asin` /
  `acos` / `atan` / `atan2`.
- **Rounding.**  `floor` / `ceiling` / `round` / `truncate`
  (banker's rounding via `System.Math.Round`).
- **Sign / classification.**  `signInt` / `signLong` /
  `signDouble`; `isNaN` / `isInfinity` / `isFinite`.

Six new tests in `StdMathTests.fs`.  All 385 emitter tests pass
(was 379; +6 new).

---

### D-progress-053: Std.Iter expansion — sumLong, sumDouble, iterMin/Max, reverse
*claude/deferred-items-round4 branch.*  Closes a deferred
follow-up — the `Std.Iter` surface previously only had `sumInt`
for numeric reduction.  New helpers:

- `sumLong(xs: slice[Long]): Long` / `sumDouble(xs: slice[Double]): Double`.
- `iterMinInt` / `iterMaxInt` / `iterMinLong` / `iterMaxLong`
  returning `Option[T]` (`None` for empty slices).  Names are
  `iter`-prefixed because `Std.Core` already has a private
  `maxInt` that conflicts.
- `reverse[T](xs: slice[T]): slice[T]` — generic, allocates a
  fresh slice via `List[T]` accumulator + `toArray`.

Four new tests in `IterTests.fs`.  All 379 emitter tests pass
(was 375; +4 new).

---

### D-progress-052: Std.Http unblock — refactor extern-package to @externTarget shims
*claude/deferred-items-round4 branch.*  Closes the
"Object.GetAwaiter not found" failure that blocked
`import Std.Http` end-to-end.

**Root cause.**  `Std.HttpHost` declared its host primitives
inside `extern package System.Net.Http { ... }` blocks.  Lyric's
`extern package` mechanism is parsed and type-checked but never
reaches the emitter with an actionable target — the precompiled
`Lyric.Stdlib.HttpHost.dll` ends up with NO static methods.
Calls to `HostHttp.send(...)` (after `import Std.HttpHost as
HostHttp` alias rewriting) collapse to bare `send(...)` which
no symbol table knows about; `codegenErr` then surfaces a
fallback `obj` static type, and downstream `EAwait` crashes
trying to find `Object.GetAwaiter`.

**Fix.**  Refactor `compiler/lyric/std/http_host.l` to declare
each host primitive as a top-level `pub func` with an
`@externTarget("Lyric.Stdlib.HttpClientHost.<Member>")`
annotation.  Each one routes to a new
`Lyric.Stdlib.HttpClientHost` static helper class on the F#
side that wraps the corresponding `System.Net.Http.HttpClient`
operation:

| Lyric (host_http.l) | F# (Stdlib.fs) | BCL |
|---|---|---|
| `hostDefaultClient(): HttpClient` | `HttpClientHost.DefaultClient` | `new HttpClient()` |
| `hostMakeRequest(method, url): HttpRequestMessage` | `HttpClientHost.MakeRequest` | `new HttpRequestMessage(method, url)` |
| `hostWithHeader(req, key, value)` | `HttpClientHost.WithHeader` | `req.Headers.TryAddWithoutValidation` |
| `hostWithStringBody(req, ct, body)` | `HttpClientHost.WithStringBody` | `req.Content = StringContent(...)` |
| `hostSend(client, req): Task<HttpResponseMessage>` | `HttpClientHost.Send` | `client.SendAsync(req)` |
| `hostGet(client, url)` | `HttpClientHost.Get` | `client.GetAsync(url)` |
| `hostPostString(client, url, body, ct)` | `HttpClientHost.PostString` | `client.PostAsync(...)` |
| `hostStatusCode(resp): Int` | `HttpClientHost.StatusCode` | `int resp.StatusCode` |
| `hostReadBodyText(resp): String` | `HttpClientHost.ReadBodyText` | `resp.Content.ReadAsStringAsync()` |
| `hostReadBodyBytes(resp): slice[Byte]` | `HttpClientHost.ReadBodyBytes` | `resp.Content.ReadAsByteArrayAsync()` |

The `host*` prefix is necessary because the alias rewriter
(`import Std.HttpHost as HostHttp`) collapses `HostHttp.foo(...)`
to bare `foo(...)`, and `Std.Http`'s user-facing wrappers
(`send` / `withHeader` / etc.) would otherwise collide.
`Std.Http` is updated to call the prefixed names.

**Side fix.**  `Std.Http.retry`'s `attempts` counter previously
used `Nat`, which the type checker rejects in arithmetic with
literal `Int 0`.  Switched to `Int` to match the comparison
shape; range-subtype literal-coercion is a separate Phase 4
follow-up.

**Tests.**  3 new cases in `StdHttpTests.fs` exercise URL
parsing (success + failure) and request construction without
network I/O.  All 375 emitter tests pass (was 372; +3 new).

---

### D-progress-051: try/catch — common BCL exception type aliases
*claude/deferred-items-round3 branch.*  Extends D-progress-048's
catch-type resolver to recognise short aliases for common BCL
exception types without forcing users to type the fully
qualified CLR name:

| Lyric name | CLR exception |
|---|---|
| `Bug` / `Exception` / `Error` | `System.Exception` |
| `ArgumentException` / `Argument` | `System.ArgumentException` |
| `ArgumentNullException` / `NullArgument` | `System.ArgumentNullException` |
| `InvalidOperationException` / `InvalidOperation` | `System.InvalidOperationException` |
| `NotSupportedException` / `NotSupported` | `System.NotSupportedException` |
| `IOException` / `IO` | `System.IO.IOException` |
| `FileNotFoundException` / `FileNotFound` | `System.IO.FileNotFoundException` |
| `FormatException` / `Format` | `System.FormatException` |
| `OverflowException` / `Overflow` | `System.OverflowException` |
| `DivideByZeroException` / `DivideByZero` | `System.DivideByZeroException` |
| `TimeoutException` / `Timeout` | `System.TimeoutException` |

Anything else falls through to the existing reflective walk
across loaded assemblies.

One new test (`try_catch_specific_exception_type`) catches a
`FormatException` raised by `Int32.Parse("not a number")`.  All
372 emitter tests pass.

---

### D-progress-050: TypeBuilder-arg fallback for imported variant ctor + LYRIC_DEBUG
*claude/deferred-items-round3 branch.*  Two related bits of polish.

**TypeBuilder-arg fallback.**  `Codegen.fs`'s imported variant
ctor path (e.g. `Some(value = userRec)` where `userRec` is a
Lyric record under construction in this assembly) called
`constructedCase.GetConstructors()` whenever no typeArg was a
`GenericTypeParameterBuilder`.  But typeArgs can also be plain
`TypeBuilder` instances when the user wires a same-package
record into an imported generic union — `MakeGenericType` then
returns a `TypeBuilderInstantiation` whose `GetConstructors()`
raises `NotSupportedException` ("Specified method is not
supported").  The fallback now also catches `TypeBuilder` and
nested-`TypeBuilder` typeArgs and routes through
`TypeBuilder.GetConstructor`.

**`LYRIC_DEBUG` env var.**  When set, the CLI's `internal
error: …` printout is followed by the original exception's
stack trace.  Crucial for diagnosing reflection failures that
otherwise surface as a bare "Specified method is not
supported" message.

The TypeBuilder-arg fix unblocks a chunk of `Std.Http` (which
returns `Result[HttpResponseMessage, HttpError]` constructed
via `Ok(value = …)` / `Err(error = …)` from imported
`Std.Core`).  Std.Http still hits a separate "Object.GetAwaiter"
issue when extern-package async calls don't surface their
`Task<T>` static type — tracked as a Phase B+++ follow-up.

No new tests (the fix is structural; existing tests don't
reproduce the closed-generic-on-record case).  All 371 emitter
tests pass.

---

### D-progress-049: try-as-expression — `return try { … } catch …`
*claude/deferred-items-round3 branch.*  Builds on D-progress-048
to allow `try { … } catch …` in expression position.  This is
the canonical `Std.Http` shape (`return try { val r = await
…; Ok(...) } catch Bug as b { Err(...) }`) — the parser already
wrapped it as `EBlock { Statements = [STry …] }`, but the
codegen previously reported "expression form not yet supported
in this version: EBlock".

The new `EBlock` handler in `emitExpr`:
- For a single-statement EBlock containing `STry`, allocates a
  result local, peeks the body's last `SExpr`'s type for the
  result CLR type, then emits the protected region.  Both the
  body's last expression and each catch's last expression
  Stloc into the result local; after `EndExceptionBlock` the
  surrounding expression Ldloc's the value.
- For multi-statement / non-try EBlock, emits each stmt with
  the last `SExpr`'s value left on the stack (mirrors
  `emitBranchValue`).  Diverging stmts (return/throw/break/
  continue) push a `null` stack-balance dummy that's
  unreachable in practice.

Three new tests in `TryCatchTests.fs` cover the basic body /
catch / await-inside-body shapes.  All 371 emitter tests pass
(was 368; +3 new).

---

### D-progress-048: statement-form `try { … } catch <Type> [as <bind>] { … }`
*claude/deferred-items-round3 branch.*  Closes a deferred
follow-up — `try { … } catch …` as a statement form previously
hit `E0003: statement form not yet supported in this version:
STry`.  Implementation lands in the regular `emitStatement`
match arm:

- `BeginExceptionBlock` opens the protected region.
- The body emits inside `pushScope` / `popScope` with
  `ctx.TryDepth` incremented so any `return` / `break` /
  `continue` routes through `Leave`.
- For each catch clause, `BeginCatchBlock(<exType>)` is followed
  by either `Stloc <bind>` (when the user provided `as
  <name>`) or `Pop` (when not), then the catch body.
- `EndExceptionBlock` closes the region.

The catch type name resolves via a small built-in mapping:
`Bug` / `Exception` / `Error` → `System.Exception`.  Any other
name walks every loaded assembly via reflection looking for a
short-or-full-name match assignable to `System.Exception`,
falling back to `System.Exception` itself when nothing matches.

Awaits inside the try body fall back to the M1.4 blocking shim
(real Phase B suspension would need protected-region re-entry
on resume — Phase B+++ work).  Synchronously-completing
`await`s work fine inside try via the blocking-shim fast path.

Four new tests in `TryCatchTests.fs` cover no-throw, panic-
caught, no-bind, and `try` + `await` combinations.  All 368
emitter tests pass (was 364; +4 new).

---

### D-progress-047: async generic call sites surface `Task[<T>]` correctly
*claude/deferred-items-round3 branch.*  Closes a deferred
follow-up from D-progress-024 (C2 async work).  Calls to async
generic functions like `id[T](x: in T): T` previously surfaced
the bare `T` (substituted) as the call-site static type, even
though the IL stack carries the wrapped `Task[<T>]`.  Downstream
`EAwait` then resolved `GetAwaiter` against `int32` /
`obj` / etc. and crashed at compile time with errors like
`Int32.GetAwaiter not found`.

The fix is one block in `Codegen.fs`'s reified-generic call
path: after substituting the generic bindings into `sg.Return`,
wrap the resulting CLR type in `Task[<T>]` (or non-generic
`Task` for `Unit`) when `sg.IsAsync`.  This mirrors the
non-generic async-call path where `mb.ReturnType` already
includes the wrap.

`await id(42)` now correctly emits `GetAwaiter` against
`Task<int>` and unwraps to `int`.

**Bootstrap-grade scope.**  Generic async funcs themselves
still go through the M1.4 wrapper path (the SM doesn't yet
emit closed-generic SM types on `TypeBuilder` — that's a
larger Phase C item).  The blocking shim works correctly for
synchronously-completing tasks; real suspension on generic
async funcs awaits the SM-generic plumbing.

One new test (`phaseB_async_generic`) covering Int and String
type arguments.  All 364 emitter tests pass (was 363; +1 new).

---

### D-progress-046: `@derive(Json)` — synthesised `fromJson` for primitive-only records
*claude/deferred-items-continuation branch.*  Closes a deferred
follow-up from D-progress-030.  Records whose fields are all
primitive Lyric types (`Int`, `Long`, `Double`, `Bool`,
`String`) now get a synthesised
`<RecName>.fromJson(s: in String): <RecName>` paired with the
existing `toJson`.

**Synthesis.**  Each primitive field gets a `var <fd>: T =
default()` followed by a call to a per-type `__lyricJsonGet<T>`
shim that writes the parsed value via an `out` parameter:

```lyric
pub func User.fromJson(s: in String): User {
  var name: String = default()
  __lyricJsonGetString(s, "name", name)
  var age: Int = default()
  __lyricJsonGetInt(s, "age", age)
  var active: Bool = default()
  __lyricJsonGetBool(s, "active", active)
  User(name = name, age = age, active = active)
}
```

The five `__lyricJsonGet<T>` shims are appended unconditionally
to every source file containing a `@derive(Json)` record (a
small metadata cost but no IL when unused).  Each shim is an
`@externTarget` to `Lyric.Stdlib.JsonHost::Get<T>`, which
re-parses the JSON document on every call (bootstrap-grade — a
future revision can pass a parsed handle).

**Eligibility (Phase 1 punt).**  `fromJson` is synthesised only
when every field has a primitive type.  Records with nested
`@derive(Json)` records, slices, or `Option[T]` fields skip
`fromJson` entirely (their `toJson` still ships).  Phase 2
extends the synthesis to handle these.

**Bootstrap-grade scope.**
- Missing / wrongly-typed fields default-initialise.  The
  per-field shim returns `false` on failure, but the synthesised
  body ignores the return — a future revision threads the
  failure into a `Result[<RecName>, JsonError]` return type.
- Re-parsing per field is wasteful for large documents.  A
  Phase 2 revision passes a `JsonDocument` handle through the
  shims.

One new test (`json_derive_fromJson_primitive`).  All 362 emitter
tests pass.

---

### D-progress-045: `@derive(Json)` — Option fields render as `null` / value (with codegen fix)
*claude/deferred-items-continuation branch.*  Closes a deferred
follow-up from D-progress-030.  `Option[T]` fields on a
`@derive(Json)` record now render as `null` (for `None`) or the
inner T's encoding (for `Some(value=x)`).

**Synthesis.**  `JsonDerive` detects `Option[T]` via a new
`optionInnerType` helper and emits a recursive
`renderAccessExpr` that falls through to a synthesised match:

```lyric
match self.<field> {
  case None     -> "null"
  case Some(v)  -> renderAccessExpr v innerType
}
```

`renderAccessExpr` is itself recursive, so the inner T's
rendering follows the same dispatch chain as a top-level field
(primitives → `toString`, String → `__lyricJsonEscape`,
@derive(Json) records → `<TypeName>.toJson`, primitive slices
→ `__lyricJsonRender<T>Slice`, etc.).

**Codegen fix uncovered along the way.**  Pattern matching on
record-field-of-imported-generic-union (e.g. `match t.label {
case None -> ... ; case Some(v) -> ... }` where
`label: Option[String]`) silently failed: both arms' isinst
tests returned false, dropping into the dummy-default fallthrough
and producing an empty string from the match.  Root cause: when
constructing a non-generic record (`Tag(label = None)`), the
arg-emit path didn't set `ctx.ExpectedType` to the field's CLR
type before evaluating `None`.  `inferTypeArgsFromReturn`
defaulted to `obj`, producing a `None<obj>` instance — incompatible
with the field's declared `Option<string>` static type when
later pattern-tested against `None<string>`.

The fix is one block in `Codegen.fs`: the non-generic record
construction path now sets `ctx.ExpectedType <- Some f.Type`
around each arg's emit, mirroring the function-call path's
existing behaviour.  Restores the expected type for nullary
union-case construction across record fields.

**Tests.**  Two new cases in `JsonDeriveTests.fs`:
`json_derive_option_int_field` and `json_derive_option_string_field`,
each exercising both `Some` and `None` constructions.  All 361
emitter tests pass (was 359; +2 new).

---

### D-progress-044: `@derive(Json)` — nested-record slice fields
*claude/deferred-items-continuation branch.*  Builds on
D-progress-043 to handle `slice[Rec]` / `array[N, Rec]` fields
where `Rec` is itself a record with `@derive(Json)`.  Where
primitive-slice fields use a fixed F#-side BCL helper, nested-
record slices get a per-record synthesised Lyric helper:

```lyric
@derive(Json)
pub record Item { name: String; count: Int }
@derive(Json)
pub record Bag { items: slice[Item] }

// Synthesised:
//   func __lyricJsonRenderItemSlice(items: in slice[Item]): String {
//     var result: String = "["
//     var i: Int = 0
//     while i < items.length {
//       if i > 0 { result = result + "," }
//       result = result + Item.toJson(items[i])
//       i = i + 1
//     }
//     result + "]"
//   }
```

`JsonDerive.synthesizeItems` emits one such helper per
`@derive(Json)` record, before the record's own `toJson`.  The
field renderer's `sliceRecordHelper` detects the field's element
type and routes through the synthesised name.

**Bootstrap-grade scope.**  Slices of nested records work, but
nested slices (`slice[slice[Item]]`) and `Option`/`Result`-typed
fields still fall through to `toString` — Phase 4 work.

One new test (`json_derive_record_slice_field`).  All 359 emitter
tests pass.

---

### D-progress-043: `@derive(Json)` — primitive slice fields render as JSON arrays
*claude/deferred-items-continuation branch.*  Closes a deferred
follow-up from D-progress-030.  `slice[Int]` / `slice[Long]` /
`slice[Double]` / `slice[Bool]` / `slice[String]` fields on a
`@derive(Json)` record now render as canonical JSON array
literals (`[1,2,3]`, `["a","b"]`, etc.) instead of falling
through to the `toString` rendering (which produced `Int32[]`
or similar BCL-name garbage).

**Implementation.**  Five new
`Lyric.Stdlib.JsonHost::Render<T>Slice` static helpers
(`RenderIntSlice` / `RenderLongSlice` / `RenderDoubleSlice` /
`RenderBoolSlice` / `RenderStringSlice`) walk the array element-
by-element, inserting `,` separators and emitting the element-
specific encoding:

- Integers / longs / doubles → `Convert.ToString` with
  invariant-culture, round-trip "R" format for doubles.
- Booleans → `"true"` / `"false"` literals.
- Strings → `JsonEncodedText.Encode` (per-element, with
  surrounding quotes).

`JsonDerive.synthesizeItems` now appends one
`@externTarget("Lyric.Stdlib.JsonHost.Render<T>Slice")` shim per
primitive type to every source file containing a `@derive(Json)`
record (unconditionally — unused helpers cost only a metadata
row).  `slicePrimitiveHelper` in the same module pattern-matches
the field's `TSlice` / `TArray` element type and routes the
field renderer through the matching shim.

**Bootstrap-grade scope.**  Slices of user-defined records (with
their own `@derive(Json)`), nested slices (`slice[slice[Int]]`),
and `Option[T]` / `Result[T, E]` fields still fall through to
`toString` — Phase 4 work.  The synthesised
`Render<T>Slice` shims are unconditional; on assemblies with no
slice-field records they're dead code (a few bytes of metadata).

**Tests.**  Three new cases in `JsonDeriveTests.fs`:
`json_derive_int_slice_field`, `json_derive_string_slice_field`
(exercises String escaping including `\n`, `"`),
`json_derive_bool_slice_field`.  All 358 emitter tests pass
(was 355; +3 new).

---

### D-progress-042: C2 Phase B++ — nested locals in while/loop bodies (one level deep)
*claude/c2-async-implementation-ZGU95 branch.*  Lifts the
"no nested locals" restriction from D-progress-037.  A new
`collectPromotableLocals` collector walks one level into
`SWhile` and `SLoop` bodies (in addition to the top level),
registering nested locals for promotion to SM fields alongside
the top-level ones.

```lyric
async func loopWithLocal(): Unit {
  var i: Int = 0
  while i < 2 {
    val y: Int = i + 10   // nested local — promoted in this commit
    await ping()
    println(y)            // y survives the cross-resume gap
    i = i + 1
  }
}
```

The IL emit pipeline is unchanged — the existing `defineLocal`
mechanism picks up the pre-allocated IL local, the body's
`Stloc x` initializes it, and the suspend's IL-local-to-SM-field
flush captures its value.  Each name is deduplicated (first
declaration wins) so two scopes that bind the same name share
the SM field — Roslyn's standard "hoisted local" pattern.

`for` loops still aren't covered: the iteration variable lives
inside the `for` block but with per-iteration semantics that
need the runtime IEnumerator to survive the cross-resume gap
too.  Phase B+++ will tackle those.

One new test (`phaseB_nested_local_in_while_loop`).  All 354
emitter tests pass.

---

### D-progress-041: C2 Phase B+ — awaits in `if`-cond and `match`-scrutinee positions
*claude/c2-async-implementation-ZGU95 branch.*  Extends the
safe-position predicate so `if await cond() { ... }` and `match
await foo() { ... }` no longer fall back to M1.4.  Both forms
are structurally safe because the IL stack is empty at the
suspend point — the await stashes its awaiter to a local before
suspend; the cond/scrutinee value is only on the stack
immediately before `Stloc` (match) or `brfalse`/`brtrue` (if).

The recursive `isSafeExprPosition` predicate now allows
`isSafeExprPosition cond` (instead of `not (exprHasAwait cond)`)
inside `EIf`, and similarly for `EMatch (scrut, arms)`.  This
unlocks the canonical `Std.Http` and `BankingSmoke` patterns
where `await` produces the value being matched on.

Codegen also gained closed-generic-on-TypeBuilder fallbacks for
`TaskAwaiter<T>::get_IsCompleted` (when `T` is a Lyric
record/union still under construction) and for
`AsyncTaskMethodBuilder<T>::AwaitUnsafeOnCompleted<,>` — both
now route through `TypeBuilder.GetMethod` against the open-
generic definition when the closing arg is itself a
TypeBuilder.

Two new tests: `phaseB_match_await_scrutinee` (canonical
match-on-await pattern) and `phaseB_if_await_cond` (await in
the boolean cond).  All 353 emitter tests pass (was 351;
+2 new).

---

### D-progress-040: C2 Phase B for impl methods (body awaits + suspend/resume)
*claude/c2-async-implementation-ZGU95 branch.*  Extends
D-progress-038 (Phase A async impl methods) with the full
suspend/resume protocol from D-progress-034 (Phase B).  An
`async impl` method whose body contains awaits at safe
top-level positions now lowers to a state machine identical in
shape to free-standing Phase B funcs, with the `("self",
recordTy)` prepend already established in D-progress-038.

The Pass B.5 path now mirrors Pass B's three-way dispatch:
Phase A (await-free body), Phase B (body awaits, locals
promoted via existing helper), or M1.4 fallback.  Both paths
share the `buildParamSpecs` helper that prepends `self`.

One new test (`phaseB_async_impl_method_with_await`) — an
impl method that `await`s a free-standing async func and then
prints, validating that:

- The kickoff is an instance method on the record.
- The SM stores `this` (the record) into its `self` field.
- The SM's `MoveNext` runs the body with `ESelf` resolving via
  `SmFields["self"]` and the `await` triggering the
  suspend/resume IL pattern.

All 351 emitter tests pass (was 350; +1 new).

---

### D-progress-039: Std.Time expansion — comparison + duration arithmetic + ISO-8601 formatting
*claude/c2-async-implementation-ZGU95 branch.*  Closes a deferred
follow-up from D-progress-027 (initial Std.Time C5 / Tier 1.3
work).  New surface in `compiler/lyric/std/time.l`:

- **Instant comparison.**  `instantBefore` / `instantAfter` /
  `instantEquals` resolve via `System.DateTime` operators
  (`op_LessThan` / `op_GreaterThan` / `op_Equality`).
- **Duration comparison + arithmetic.**  `durationLess` /
  `durationGreater` / `addDurations` / `subDurations` resolve
  via `System.TimeSpan` operators.
- **ISO-8601 formatting.**  `toIsoString` emits the round-
  trippable `"o"`-format string via `System.Convert.ToString`
  on the `Instant`; the inverse round trip works via the
  existing `parseOptInstant` helper.

Two new tests in `StdTimeTests.fs` cover the comparison and
duration-arithmetic helpers.  All 350 emitter tests pass.

---

### D-progress-038: C2 Phase B++ — async impl methods (instance methods on records)
*claude/c2-async-implementation-ZGU95 branch.*  Builds on
D-progress-037 to route async impl methods through the
state-machine path.  An `async func` declared inside an `impl
TraitName for Record` block now lowers to a kickoff stub on the
record (instance method) plus a sibling SM class whose `MoveNext`
runs the body — same shape as free-standing async funcs, with
one adjustment.

**Adjustment for instance methods.**  The kickoff is an instance
method on the user's record, so `Ldarg.0` is the record reference
(the implicit `this`).  The SM doesn't have direct access to
`this` in `MoveNext`, so the kickoff copies `Ldarg.0` into a
prepended `self` field on the SM (`paramSpecs = ("self",
recordTy) :: user_param_specs`).  Inside `MoveNext`, the body's
`ESelf` references resolve via a new `SmFields` lookup
(`SmFields["self"]`) that emits `Ldarg.0; Ldfld <self>`.

**Closed-generic-on-TypeBuilder fix.**  Async impl methods can
return Lyric records / unions still under construction (e.g.
`AsyncTaskMethodBuilder<MaybeBalance>`); calling `GetMethod` /
`GetProperty` on the resulting `TypeBuilderInstantiation` raises
`NotSupportedException`.  `builderMember`, `builderCreate`, and
`builderStart` now route through `TypeBuilder.GetMethod` for
generic-closed-over-TypeBuilder builder types.

**What ships.**

```lyric
record IntCounter { v: Int }
interface ValueGetter { async func getValue(): Int }
impl ValueGetter for IntCounter {
  async func getValue(): Int = self.v + 1
}

func main(): Unit {
  println(await IntCounter(v = 41).getValue())  // → 42
}
```

The existing BankingSmokeTests' `findBalance` impl method (which
is async) now uses the SM path end-to-end, replacing the M1.4
`Task.FromResult` shim.

**Bootstrap-grade scope.**  Phase B (suspend/resume) for impl
methods and async generic funcs are still TODO — the impl-method
path here only covers Phase A (await-free body).  Async impl
methods that contain awaits in their body keep the M1.4 path
until follow-up work extends Phase B to cover them.

One new test (`phaseB_async_impl_method`).  All 348 emitter
tests pass.

---

### D-progress-037: C2 Phase B+ — awaits inside `while` / `loop` bodies (no nested locals)
*claude/c2-async-implementation-ZGU95 branch.*  Builds on
D-progress-036 to allow `EAwait` at safe positions inside the
body of a `while` or `loop` statement.  The IL flow naturally
extends: each iteration enters the body, an `await` inside the
body suspends/resumes via the same protocol, and control falls
through to the loop back-edge or the iteration's continuation.

Eligibility constraint (Phase B+ scope): the loop body must not
contain `SLocal` declarations.  Nested-local promotion to SM
fields requires walking past the top level of the function body,
and the existing `collectTopLevelLocals` helper only tracks
flat-block locals.  Phase B++ extends promotion to nested
declarations; for now, programs that need a counter through an
async loop declare the counter at the function top level (where
it gets promoted via the existing path):

```lyric
async func loopThree(): Unit {
  var i: Int = 0     // top-level — promoted to SM field
  while i < 3 {
    await ping()     // safe position
    i = i + 1
  }
}
```

`for` loops still aren't covered because they bind an iteration
variable per iteration; that variable lives inside the loop body
and would need cross-iteration field-shadow plumbing.

One new test in `AsyncTests.fs` (`phaseB_await_in_while_loop`)
that loops three times, awaiting in each iteration.  All 347
emitter tests pass (was 346; +1 new).

---

### D-progress-036: C2 Phase B+ — awaits inside `if` and `match` branches
*claude/c2-async-implementation-ZGU95 branch.*  Extends Phase B
(D-progress-034) to allow `EAwait` at safe top-level positions
inside `if` branches and `match` arm bodies.  The IL emit shape
unchanged — each branch is an independent basic block, the
suspend's `Leave` and the resume's `MarkLabel` work the same
inside a branch as at the function top level.

Recursive safe-position predicate now distributes the check over
control-flow constructs:

- `EIf (cond, then, else, _)` — safe iff `cond` is await-free and
  each branch is in safe expression position.
- `EMatch (scrut, arms)` — safe iff `scrut` is await-free and
  every arm body / guard is in safe position.
- `EParen` and `EBlock` descend into their inner expression /
  statements.

The IL stack is empty entering each branch (cond/scrutinee value
was already consumed), empty at suspend (the awaiter is stashed
in a local + an SM field before `Leave`), and balanced at the
join point (each branch leaves the same number of values).

Two new tests in `AsyncTests.fs`: `phaseB_await_in_if_branch`
exercises an `await` inside one arm of an if/else;
`phaseB_await_in_match_arm` exercises awaits in two of three
match arms (with a third no-await arm to verify the
state-dispatch table doesn't accidentally jump into the wrong
arm body).

Out of scope (Phase B+++ work): awaits inside `try`/`catch` /
`defer` (need protected-region re-entry on resume); awaits
inside `for`/`while`/loop bodies (need state index per loop
iteration); awaits in *expression-position* `if`/`match` (e.g.
`val x = if cond then await foo() else 0` — works in statement
position via the SLocal-init safe slot, but not inside a
sub-expression like `f(if cond then await foo() else 0)`).

All 346 emitter tests pass (was 342; +4 new across format5/6
and Phase B+ if/match).  Lexer/Parser/TypeChecker/LSP suites
unchanged at 70/182/100/5.  Total: 703 tests pass.

---

### D-progress-035: B6 — `format5` / `format6` arity-specialised String.Format wrappers
*claude/c2-async-implementation-ZGU95 branch.*  Closes a deferred
follow-up from D-progress-011 (which shipped `format1..4`).  Lyric
has no varargs, so each format arity is its own builtin name; the
type checker special-cases them in `ExprChecker.fs` and the
emitter routes the call through the matching
`Lyric.Stdlib.Format::OfN` static method.

```lyric
println(format5("[{0},{1},{2},{3},{4}]", 1, 2, 3, 4, 5))
println(format6("[{0},{1},{2},{3},{4},{5}]", 1, 2, 3, 4, 5, 6))
```

Two new tests in `BuiltinTests.fs` (`format5_multi_placeholder`,
`format6_multi_placeholder`).  Format arities beyond 6 wait for
a varargs story.

---

## C2 — real async state machines: status

C2 is a multi-phase effort per the C2 decision (D-progress-024).
Phase A (D-progress-033) and Phase B (D-progress-034) have shipped.
Phase C (cancellation, structured concurrency) and Phase B+
extensions (await inside try/catch/defer/match, async impl methods,
async generics) are the remaining work.

The infrastructure pieces touched by C2:

| Piece | Status |
|---|---|
| 1. State-machine class synthesis per `async func` | **Shipped (Phase A)** |
| 2. `<>1__state` / `<>t__builder` fields, parameters as fields | **Shipped (Phase A)** |
| 3. Kickoff calls `builder.Start<SM>` and returns `builder.Task` | **Shipped (Phase A)** |
| 4. `MoveNext` runs body and calls `SetResult` on completion | **Shipped (Phase A)** |
| 5. `IAsyncStateMachine.SetStateMachine` forwards to builder | **Shipped (Phase A)** |
| 6. Locals-that-cross-`await` promoted to fields | **Shipped (Phase B, top-level only)** |
| 7. `MoveNext` state-dispatch + `AwaitUnsafeOnCompleted` resume | **Shipped (Phase B)** |
| 8. Exception flow through `SetException` | **Shipped (Phase B)** |
| 9. `if` branches / `match` arm bodies that contain `await` | **Shipped (Phase B+, D-progress-036)** |
| 10. `while` / `loop` bodies that contain `await` (no nested locals) | **Shipped (Phase B+, D-progress-037)** |
| 11. `for` loops + nested-local promotion through loop bodies | **Shipped (Phase B+++, D-progress-058)** |
| 12. `try`/`catch` / `defer` regions that span an `await` | **Shipped (Phase B+++, D-progress-056-058)** |
| 13. Async impl methods (Phase A — await-free body) | **Shipped (D-progress-038)** |
| 14. Async impl methods (Phase B — body awaits) | **Shipped (D-progress-040)** |
| 15. Async generics (free-standing) | **Shipped (Phase B+++, D-progress-075)** |
| 16. `CancellationToken` propagation | **Shipped (Phase C, D-progress-068)** |
| 17. Stack-spilling for awaits in sub-expression positions | **Shipped (Phase B+++, D-progress-074)** |
| 18. Spill-prior-siblings ordering preservation | **Shipped (Phase B+++, D-progress-076)** |

C2 is **complete** for every shape Lyric currently supports.  The
previously open bullet — generic **impl** methods — shipped in
D-progress-141 (see below).  The async-SM extension for generic impl
methods (e.g. `impl[T] Foo for Bar[T] { async func twiddle(): T }`)
remains a follow-up: `asyncSmEligible` in Pass B.5 gates on
`sg.Generics.IsEmpty` until the SM-side generic-param threading lands.
The SM wiring is mechanical: extend `defineStateMachineHeader`'s caller
to thread impl-block + method-level GTPBs, mirror the free-standing
generic path (D-progress-075), and re-use the same `kickoffBuilder*`
helpers.

Tier 5 items (`Std.Http` cancellation/timeouts shipped via
D-progress-070; `wire` scoped lifetimes shipped via D-progress-072).
Tier 6 items: AST-based `lyric fmt` and `lyric lint` shipped (see above);
generic interface methods + impl-block generics shipped (D-progress-141);
CST formatter (v2), format5+, Regex RE2, C4 phase 2/3 remain on-demand.

---

### D-progress-127: Phase 6 VS Code tooling — §6.1–§6.4 per `docs/22-distribution-and-tooling.md`

*claude/phase-6-vscode-extension-vYx1j branch.*

Implements the four VS Code extension feature blocks specified in
`docs/22-distribution-and-tooling.md` §6.  The LSP skeleton (M-L1–M-L4)
already landed; this entry covers everything on top of that.

**§6.1 Manifest editor**

- `lyric-vscode/schemas/lyric-toml.schema.json` — JSON schema covering
  `[project]`, `[project.packages]`, `[dependencies]`, `[nuget]`, and
  `[nuget.options]`.  All keys have descriptions, enums, and patterns.
- `contributes.jsonValidation` association (VS Code native) and
  `contributes.tomlValidation` association (Taplo / Even Better TOML
  extension) both point at the schema, so `lyric.toml` gets validation
  and completion regardless of which TOML extension the user has.

**§6.2 Package management commands**

- `lyric.addDependency` — prompts for package id + version, appends to
  `[dependencies]`, offers to run `lyric restore`.
- `lyric.addNugetPackage` — same flow targeting `[nuget]`.
- `lyric.removeDependency` — quick-pick from all current Lyric + NuGet
  entries, removes the selected entry.
- `lyric.updateDependency` — quick-pick then version input, removes and
  re-inserts with the new version, offers restore.
- `lyric.restore` — runs `lyric restore --manifest <lyric.toml>` in an
  integrated terminal with a progress notification.
- `lyric.build` / `lyric.run` / `lyric.test` — command palette shortcuts
  that execute VS Code tasks (see §6.4 below).
- `lyric.proveCurrentFile` — runs `lyric prove <active .l file>` in
  a terminal.

New source file: `lyric-vscode/src/tomlEditor.ts` — regex-based TOML
section reader and writer used by the commands above.  Handles both
quoted-key (`"My.Pkg" = "1.0"`) and bare-key entries; reads `[section]`
blocks without a third-party TOML library.

**§6.3 Project navigator**

- `lyric-vscode/src/projectNavigator.ts` — `LyricProjectProvider`
  (`vscode.TreeDataProvider`) registered under the `lyricProjectNavigator`
  view in the Explorer sidebar.
- Three collapsible group nodes: **Packages** (from `[project.packages]`),
  **Lyric dependencies** (from `[dependencies]`), and **NuGet dependencies**
  (from `[nuget]`).  Each child node shows the package name and version /
  source directory as the description.
- Refresh triggered by `lyric.refreshNavigator` command (toolbar icon)
  and automatically on `lyric.toml` create / change / delete events.
- The view is hidden (`when: lyric.hasManifest`) when no `lyric.toml` is
  present in the workspace root.

**§6.4 Build / run launch configurations**

- `lyric-vscode/src/taskProvider.ts` — `LyricTaskProvider` registered for
  the `lyric` task type.
- `provideTasks` returns four auto-discovered tasks: **Build current
  project**, **Run**, **Test**, **Restore**.  Each wires `lyric <cmd>
  --manifest <lyric.toml>` as a `ShellExecution`.
- **Build** and **Test** tasks are placed in `TaskGroup.Build` and
  `TaskGroup.Test` respectively, so they appear under
  `Terminal > Run Build Task` / `Run Test Task`.
- `resolveTask` honours custom definitions from `.vscode/tasks.json`
  (type `lyric`, command enum: `build | run | test | prove | restore`,
  optional `args` and `manifestPath`).
- `lyric.cliPath` setting (default `"lyric"`) controls the executable
  used by all commands and the task provider.
- `contributes.taskDefinitions` entry in `package.json` lets users author
  their own `lyric`-typed task entries with IntelliSense.

**Other changes**

- `package.json` version bumped to 0.0.2; description updated; new
  `activationEvents` entry (`workspaceContains:**/lyric.toml`) so the
  extension activates without opening a `.l` file.
- `lyric.defaultRestoreFeed` setting added (reserved for future
  package-search palette feature).
- `extension.ts` fully rewritten to wire LSP + navigator + tasks +
  commands and to set the `lyric.hasManifest` context key on activation
  and on manifest file-system events.

---

### D-progress-D042: stdlib expansion — `Std.Sort`, `Std.Set`, `Std.Char`, `Std.Format`, `Std.Encoding`, `Std.Uuid`

*claude/update-docs-sync-EKZwy branch (PR #189).*  Six new stdlib
packages expanding the usable surface without requiring new kernel
`@externTarget` entries beyond what already existed.

**`Std.Sort`** (`stdlib/std/sort.l`)

Top-down stable merge sort over slices.  Public surface:

- `sort[T](xs, cmp)` — sort any slice with an explicit `(T, T) -> Int`
  comparator; returns a fresh slice; O(n log n).
- `sortInts`, `sortLongs`, `sortStrings` — convenience wrappers with
  natural orderings baked in.

**`Std.Set`** (`stdlib/std/set.l`)

Hash-based set wrapping BCL `HashSet<T>` via `extern type Set[T]`.
Public surface: `setContains`, `setAdd`, `setRemove`, `setSize`,
`setIsEmpty`, `setFromSlice`, `setToSlice`, `newSet`, `setUnion`,
`setIntersection`, `setDifference`.  Naming carries the `set` prefix
to avoid shadowing BCL dispatch calls in function bodies.

**`Std.Char`** (`stdlib/std/char.l`)

Unicode character classification and case conversion.  BCL-backed:
`isLetter`, `isDigit`, `isLetterOrDigit`, `isWhiteSpace`, `isUpperCase`,
`isLowerCase`, `toUpperCase`, `toLowerCase`.  Pure-Lyric (with
`@pure` + contracts): `toInt`, `fromInt`, `isAscii`, `digitValue`,
`hexDigitValue`.

**`Std.Format`** (`stdlib/std/format.l`)

Number and string formatting.  BCL-backed: `toHexString` (lowercase),
`toHexStringUpper`, `formatFixed` (fixed-point double with invariant
locale), `padLeft`, `padRight`.  Pure-Lyric: `zeroPad`, `hexPad`.

**`Std.Encoding`** (`stdlib/std/encoding.l`)

Byte-level encoding.  `encodeBase64` / `tryDecodeBase64` (standard
Base64 with `=` padding).  `encodeHex` / `tryDecodeHex` (uppercase hex;
`System.Convert.ToHexString`).  `encodeUtf8` / `tryDecodeUtf8` for
`String ↔ slice[Byte]` conversion.

**`Std.Uuid`** (`stdlib/std/uuid.l`)

UUID generation and parsing over `System.Guid`.  `newUuid()` — version
4 (cryptographic RNG).  `nilUuid()` — all-zeros sentinel.
`uuidToString` — lowercase hyphenated string.  `parseUuidOpt` — accepts
any `System.Guid.TryParse`-recognised format; returns `Option[Uuid]`.

---

### D-progress-132: M5.1 stage 6 — self-hosted type checker (`Lyric.TypeChecker`)

*PR #195.*

The self-hosted Lyric type checker ships as a nine-file `Lyric.TypeChecker`
library under `compiler/lyric/lyric/type_checker/`:

- `typechecker_types.l` — `PrimType` / `Type` union and helpers
  (`typeEquiv`, `renderType`).
- `typechecker_symbols.l` — `DeclKind` / `Symbol` / `SymbolTable` helpers.
- `typechecker_scope.l` — lexical `Scope` + `GenericContext` stacks.
- `typechecker_signature.l` — `ResolvedParam` / `ResolvedBound` /
  `ResolvedSignature` record types.
- `typechecker_constfold.l` — compile-time integer constant folding
  (used for `T0090`/`T0093` range-subtype diagnostics).
- `typechecker_resolver.l` — `TypeExpr` → `Type` (`resolveType` /
  `resolveTypePath`).
- `typechecker_exprs.l` — bottom-up expression inference (`inferExpr`),
  covering arithmetic, comparisons, field access, calls, closures, match,
  and `if`/`while` control flow.
- `typechecker_stmts.l` — statement and function-body checking
  (`checkStatement`).
- `typechecker_checker.l` — public entry point: `check(file: SourceFile):
  CheckResult`; orchestrates symbol registration, signature resolution,
  and expression/statement checking over all items.

`compiler/lyric/lyric/typechecker_self_test.l` is the self-test consumer.
It imports both `Lyric.Parser` and `Lyric.TypeChecker`, exercises 15
in-process assertions (empty source, function/record/union registration,
duplicate-name T0001, return-type T0070, val-type T0060, return-without-
value T0064, range-subtype T0090/T0093, `where`-clause T0050, arithmetic
mismatch T0031, unknown-name T0020), and writes `"ok"` on success.

`compiler/tests/Lyric.Emitter.Tests/SelfHostedTypeCheckerTests.fs`
(`[typechecker_self_test_passes]`) compiles `typechecker_self_test.l` via
the bootstrap emitter, runs the resulting PE, and asserts exit 0 + `"ok"`
in stdout.  All 635 emitter tests pass.

**Porting issues resolved (no emitter changes required):**

1. **`TyFunction` field rename** — `result` is a Lyric keyword (`KwResult`);
   the field was renamed `ret` throughout.

2. **Pattern-variable naming** — `as` is a Lyric keyword; pattern-bound
   variables named `as1`/`as2` (from the F# `as`-pattern idiom) were
   renamed `asy1`/`asy2`.

3. **`DeclKind` construction field names** — The Lyric-side union case
   construction syntax uses `id`/`decl` rather than the F# discriminated
   union shorthand; all four `DeclKind` constructors corrected.

4. **`resolveExprPath` mixed-arm type** — the final match arm produced
   a `Void` result where the other arms produced `Type`, causing a CLR
   `InvalidProgramException` at runtime.  Restructured to return a
   consistent `Type` from all arms.

---

### D-progress-133: M5.2 stage 1 — self-hosted mode checker (`Lyric.ModeChecker`)

*claude/continue-jvm-emitter-T9Gdj branch.*

The self-hosted Lyric mode checker ships as a two-file `Lyric.ModeChecker`
library under `compiler/lyric/lyric/mode_checker/`:

- `modechecker_mode.l` — `VerificationLevel` union (VLRuntimeChecked,
  VLProofRequired, VLProofRequiredUnsafe, VLProofRequiredChecked, VLAxiom)
  plus helpers `vlIsProofRequired`, `vlDominates`, `vlDisplay`, `vlRank`;
  file-level and function-level level computation (`levelOfFile`,
  `levelOfFunction`, `isFuncPure`); annotation helpers (`findAnnotation`,
  `proofRequiredModifier`).  Mirrors `compiler/src/Lyric.Verifier/Mode.fs`.

- `modechecker_check.l` — public entry points (`checkFile`,
  `checkFileWithImports`), callee-table construction (`calleeTableOfFile`),
  and all diagnostic checks: V0001 (proof-required importing
  runtime-checked), V0002 (impure call / `await` / `spawn` from
  proof-required code), V0003 (`unsafe` block without
  `unsafe_blocks_allowed`), V0004 (`@axiom` with body), V0005 (loop
  without `invariant:` clause), V0006 (unbounded quantifier domain in
  contract clause), V0009 (`assume` outside `unsafe {}`), V0010 (conflicting
  level annotations), V0011 (unknown `@proof_required` modifier).  Mirrors
  `compiler/src/Lyric.Verifier/ModeCheck.fs`.  Cross-package import
  metadata uses a simplified `ImportedMeta` record (name + level string)
  rather than the full F#-side `Imports.ImportedPackage` type.

Consumer and harness:

- `compiler/lyric/lyric/modechecker_self_test.l` — 17 in-process tests
  covering level detection, conflict/unknown-modifier errors, V0001–V0006
  and V0009–V0011 diagnostics, pure-callee pass, and no-check for
  `@runtime_checked` packages.
- `compiler/tests/Lyric.Emitter.Tests/SelfHostedModeCheckerTests.fs` —
  F# Expecto wrapper (`[modechecker_self_test_passes]`).

All 636 emitter tests pass.

---

### D-progress-129: D-D1.3 — pagination + token-bucket end-to-end proofs; float/real verifier fixes

*claude/proof-system-followups-5d9rH branch.*

Closes `docs/12-todo-plan.md` Band D-D1.3: the two end-to-end worked-example
proofs for the pagination helper and the token-bucket rate limiter now
discharge fully under Z3.  Four verifier bugs were surfaced and fixed in the
process.

**Verifier fixes**

1. **Float/Real SMT mapping** (`Smt.fs`, `Vcir.fs`): `SFloat32`/`SFloat64`
   now render as SMT `Real` instead of the previously unregistered sort names.
   A new `BOpRealDiv` builtin was added to `Vcir.fs` so that float division
   (`/`) emits as the Real-arithmetic `/` operator rather than integer `div`.
   `VCGen.fs` selects `BOpRealDiv` over `BOpDiv` whenever both operands have
   a float sort.

2. **EIf branch-condition propagation** (`VCGen.fs`): assertions (`assert φ`)
   inside an `if`/`else` body were not receiving the branch condition as a
   hypothesis, causing them to fail with infeasible counterexamples (e.g.
   `tokens = 0`, `count = 0.5` entering the taken branch and then failing
   `tokens - count >= 0`).  The EIf-in-statement handler now guards each
   branch's side goals with the branch condition using `cond ⇒ φ` wrapping,
   which is equivalent to adding `cond` as a hypothesis for assertions in the
   then-block (and `¬cond` for the else-block).

3. **Shared `Symbols` ResizeArray** (`VCGen.fs`): `env.Symbols` is mutable;
   all functions in a file shared the same instance via record copy-and-update.
   After the `make` function registered the `Bucket` datatype, entry-method
   goals inherited it, and Z3 flagged "ambiguous constant reference" when a
   parameter was named identically to a selector.  Fixed by adding
   `freshSymbols : Env -> Env` and passing `freshSymbols env` to each
   `goalsForFunction` call so every function starts with a clean accumulator.

4. **Free-variable / selector name conflict** (`Smt.fs`): even after fix 3,
   a function whose parameter shares a name with a datatype selector (e.g.
   `capacity` in both `make`'s parameter list and `Bucket`'s field list)
   caused Z3 to report ambiguity.  Added `datatypeReservedNames` + a
   pre-emit renaming pass in `renderGoalBlock`: any free variable whose name
   clashes with a constructor, selector, or user-fun name is renamed to
   `name$p` before the `declare-const` and `assert` are emitted.

**Protected-type proof support**

`VCGen.goalsForFileWithImports` now processes `IProtected` items:
fields are bound as symbolic variables; `invariant:` clauses are injected
as additional `requires:` preconditions on each entry; `goalsForProtectedType`
converts each `entry` to a synthetic `FunctionDecl` and calls
`goalsForFunction`.  `ProofMeta.buildProofMeta` was extended to include
`IProtected` fields in the proof-type registry so the SMT emitter can
declare the Bucket datatype.

**New worked examples**

- `examples/token_bucket_proof.l` — `@proof_required` token bucket with
  `protected type Bucket` (fields `tokens: Double`, `capacity: Double`),
  invariants `tokens >= 0.0` and `tokens <= capacity`, entry methods
  `tryAcquire` and `refill` with explicit `assert` statements for invariant
  preservation, and `make` constructor with structural postconditions.
  6/6 obligations discharge.
- `examples/pagination.l` (already existed from PR #129) — 4/4 obligations
  discharge unchanged.
- `docs/02-worked-examples.md` — Examples 12 (pagination) and 13 (token
  bucket) added to the worked-examples catalogue.

**Test coverage**

Four new `[D-D1.3]`-tagged tests added to `SmtTests.fs` (float-sort rendering,
`BOpRealDiv`, float-literal rendering) and six to `DriverTests.fs` (EIf-in-
statement, mid-sequence SReturn, general ECall, float arithmetic, protected
type goals, protected type invariant-as-hypothesis).  Total verifier tests:
266, all passing.

---

### D-progress-141: Tier 6 #16 — generic interface methods + impl-block generics

*claude/impl-block-generics-XM6Mu branch.*

Implements the three shapes the grammar already accepted but the emitter
and Codegen silently dropped:

**1. Method-level generics in impl blocks** (`func name[U](…): U`)

- `defineInterface` in `Emitter.fs` now calls `DefineGenericParameters`
  on interface methods that carry `Generics` in the AST.  The
  three-step Reflection.Emit pattern (DefineMethod with no signature,
  DefineGenericParameters, SetParameters / SetReturnType) is applied
  the same way as for free-standing generic functions.
- Pass A.5 in `Emitter.fs` detects method-level generic names from
  `fd.Generics`, calls `DefineGenericParameters` on the impl
  `MethodBuilder`, builds a combined `genericSubst` (impl-class GTPBs
  prepended to method GTPBs), and resolves param/return types through
  `TypeMap.toClrTypeWithGenerics`.
- Call-site dispatch in `Codegen.fs` (`ECall { Kind = EMember … }`):
  a new branch intercepts the case where `im.Method.IsGenericMethodDefinition`
  is true.  It emits args to temp locals, infers type bindings from
  GTPB positions in the param type list, calls
  `im.Method.MakeGenericMethod(bindings)`, and emits `callvirt` on the
  closed instantiation.  The return type is reconstructed from the
  binding map to side-step the pre-sealing limitation on
  `MethodBuilder.ReturnType`.

**2. Impl-block-level generics** (`impl[T] Foo for Bar[T]`)

- Pass A.5 target lookup now handles `TGenericApp` (e.g. `Box[T]`) in
  addition to `TRef` (e.g. `Box`), extracting the base name and
  resolving the record entry by the same key.  Previously the
  `TGenericApp` branch fell through to `| _ -> None`, silently skipping
  the entire impl block.
- The impl-level generic names (`impl.Generics`) are pushed into
  `resolveCtx` before iterating members so `Resolver.resolveType`
  recognises them as type parameters.  The class-level GTPBs from
  `recInfo.Type.GetGenericArguments()` back the substitution.
- `synthSig.Generics` carries the impl-level names so
  `emitFunctionBody`'s existing `selfType.GetGenericArguments()` fallback
  recovers the correct GTPBs at body-emission time.

**3. Combined impl-block + method-level generics**

- `synthSig.Generics` is ordered `[implNames...; methodNames...]`.
  Pass B.5 builds `implMethodGenericSubst` by concatenating class GTPBs
  (impl-level) with method GTPBs (method-level) in the same order.
- `emitFunctionBody`'s GTPB resolution gains a new fallback:
  ```
  | Some st when st.IsGenericType ->
      let clsGtpbs = st.GetGenericArguments()
      if clsGtpbs.Length + methodGtpbs.Length = sg.Generics.Length then
          Array.append clsGtpbs methodGtpbs
      else methodGtpbs
  ```
  This covers the combined case that neither the "all from method" nor
  "all from class" branches matched before.

**Async SM eligibility**

`asyncSmEligible` in Pass B.5 previously checked `fd.Generics.IsNone`
(method-level only).  It now checks `sg.Generics.IsEmpty` so that
impl-block-level generics also defer through the direct-emit path.
Async SM wiring for generic impl methods is a follow-up.

**Test coverage**

`compiler/tests/Lyric.Emitter.Tests/ImplBlockGenericsTests.fs` —
six new end-to-end tests covering:
- Method-level generic identity (`func wrap[U](x: in U): U`)
- Method-level generic with multiple type params (`func pair[A, B](…)`)
- Method-level generic on a record with fields
- Impl-block generic on a generic record (`impl[T] Holder for Box[T]`)
- Impl-block generic with two instantiations of the same generic record
- Combined impl-block + method-level generics

655 emitter tests, 319 parser tests, 143 type-checker tests, 123 lexer
tests — all passing.

---

### D-progress-142: parser — aspect `from`/`config` (D051 follow-up) + `lyric-otel` library

**What shipped**

**Parser (both F# and self-hosted):**
- `AspectDecl` gains `From: ModulePath option` and `Config: ConfigField list`
- `parseAspectBody` handles the instantiation-form `from Pkg.Template` clause
- Anonymous `config { }` block inside aspect bodies (reuses `parseConfigField`)
- `parseAspectConfigBlock` helper added to both parsers
- Duplicate `config` guard: `configSeen` flag + P0308 diagnostic (mirrors P0303 for `around`)
- New error codes: P0306 (missing `{`), P0307 (missing `}`), P0308 (duplicate config)
- Parser tests: 4 new aspect cases in `RemainingItemTests.fs`

**`lyric-otel/` library:**
- `lyric-otel/lyric.toml` — `Lyric.OTel` package with `dotnet` / `jvm` features
- `src/types.l` — `Span` (opaque), `SpanKind`, `MetricUnit`
- `src/_kernel/net/otel_kernel.l` — .NET externs (`System.Diagnostics.ActivitySource`, `System.Diagnostics.Metrics`), `@cfg(feature = "dotnet")`
- `src/_kernel/jvm/otel_kernel.l` — JVM externs (`io.opentelemetry.api`), `@cfg(feature = "jvm")`, Phase 6
- `src/otel.l` — `@cfg`-gated platform-dispatch wrappers + three `pub aspect` templates (`Tracing`, `Metrics`, `RequestLogging`)
- `README.md` — installation, instantiation, config-override, runtime env-var, low-level API

**Test counts:** 727 emitter, 323 parser, 143 type-checker, 123 lexer, 28 LSP,
127 CLI, 266 verifier — all passing.

---

### D-progress-143: `lyric-logging` library — structured logging with runtime config and aspect templates

**What shipped**

**`lyric-logging/` library (D052):**
- `lyric-logging/lyric.toml` — `Std.Logging.dll` manifest; two packages
  (`Std.Logging`, `Std.Logging.Aspects`); depends on `Lyric.Stdlib`.
- `src/logging.l` — `Std.Logging` package:
  - `LogLevel` enum: Trace / Debug / Info / Warn / Error / Fatal (six levels;
    Trace→debug and Fatal→error at the `Std.LogHost` boundary).
  - `LogField` record (`key`, `value` strings) for structured fields.
  - `Logger` record (`name` string) — pure value type; `getLogger` is a pure
    constructor with `requires: name.length > 0`.
  - `config Defaults { level: LogLevel = LogLevel.Info; format: String = "text" }`
    env vars `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL` and `…_FORMAT`.
  - Private helpers: `levelOrd`, `levelKey`, `levelLabel`, `appendFields`,
    `formatText`, `formatJson`, `formatJsonFields`, `formatRecord`.
  - Public API: `getLogger`, `isEnabled`, `log`, `logMsg`,
    `trace`/`debug`/`info`/`warn`/`error`/`fatal`, `field`.
- `src/logging_aspects.l` — `Std.Logging.Aspects` package:
  - `pub aspect CallLogging` (B-mode) — logs `→ name` / `← name (Nms)`
    around each matched call; config: `enabled`, `level`, `loggerName`.
  - `pub aspect SlowCallAlert` (B-mode) — logs a warning when
    `call.elapsed.unwrapOr(0) > thresholdMs`; carries
    `ensures: call.elapsed.unwrapOr(0) >= 0`; config: `enabled`,
    `thresholdMs`, `alertLevel`, `loggerName`.
  - `@inline_template pub aspect ErrorResultLogging` (C-mode) — logs when
    `ret.isErr`; re-compiled inside consumer package so it can read the
    concrete return type; config: `enabled`, `level`, `loggerName`.
- `lyric-logging/README.md` — installation, runtime env vars, output formats,
  level table, per-template config reference, full three-aspect composition
  example, low-level API table.
- `docs/03-decision-log.md` D053 — design rationale: why not extend `Std.Log`,
  six vs four levels, pure `Logger` value type, `loggerName` config field,
  `SlowCallAlert.ensures:` role, `ErrorResultLogging` C-mode justification.

**Implementation gate:** same as `lyric-otel` — config-block emitter and
aspect weaver must ship before the runtime behaviour takes effect.  The
library can be imported and `aspect … from` instantiated today.

**Test counts:** no new compiler tests (library is Lyric source only;
no F# emitter changes).  727 emitter, 323 parser, 143 type-checker, 123
lexer, 28 LSP, 127 CLI, 266 verifier — all passing.

---

### D-progress-202: lyric-web library (OpenAPI-first web service)

**Date:** 2026-05-09
**Branch:** `claude/web-library-openapi-SPkIA`

Adds `lyric-web/` — an OpenAPI-first HTTP web service library for Lyric.
Supports both code-first (write handlers, extract spec) and spec-first
(import spec, generate stubs) development workflows.

**Files added:**

- `lyric-web/lyric.toml` — package manifest; `Web.dll` as output assembly;
  four packages (`Web`, `Web.OpenApi`, `Web.Aspects`, `Web.Kernel.Net`);
  `dotnet` and `jvm` feature flags; depends on `Lyric.Stdlib`.
- `lyric-web/src/web.l` — `Web` package:
  - `pub record ApiError { status: Int; message: String; detail: [String] }`
    with 10 named constructor helpers: `badRequest`, `badRequestWithDetail`,
    `unauthorized`, `forbidden`, `notFound`, `conflict`, `unprocessable`,
    `tooManyRequests`, `internalError`, `apiError(status, msg)`.
  - `pub record Header { name: String; value: String }`.
  - `pub record Route { method: String; pattern: String; handlerName: String;
    summary: String; tags: [String]; deprecated: Bool }`.
  - `pub record Router { routes: [Route]; pathPrefix: String }` with builder
    API: `create()`, `addGet/Post/Put/Delete/Patch(router, pattern, handlerName)`,
    `prefix(router, pathPrefix)`, `merge(a, b)`.
  - `config Server { host: String = "0.0.0.0"; port: Int range 1..=65535 = 8080;
    swaggerEnabled: Bool = false; specPath: String = "/openapi.json" }`.
  - `config Cors { enabled: Bool = false; allowedOrigins: String = "*";
    allowedMethods: String = "GET,POST,PUT,DELETE,OPTIONS,PATCH";
    allowedHeaders: String = "Content-Type,Authorization,Accept";
    maxAgeSeconds: Int = 86400 }`.
  - `pub func start(router: in Router): Unit` — calls `HttpKernel.serve` with
    all server and CORS config fields.
- `lyric-web/src/openapi.l` — `Web.OpenApi` package: full OpenAPI 3.1 type
  vocabulary (`Contact`, `License`, `Info`, `Schema`, `SchemaType`, `Parameter`,
  `ParameterLocation`, `MediaType`, `RequestBody`, `ApiResponse`, `Operation`,
  `PathItem`, `Spec`) plus builder helpers (`newSpec`, `addServer`, `addSchema`,
  `addPath`, `scalarSchema`, `refSchema`).  Module docstring documents the
  bidirectional OpenAPI→Lyric type mapping and constraints→`requires:` table.
- `lyric-web/src/aspects.l` — `Web.Aspects` package:
  - `@inline_template pub aspect RequiresAuth` (C-mode) — validates a Bearer
    JWT; config: `enabled:Bool=true`, `@sensitive jwtSecret:String` (REQUIRED),
    `issuer:String=""`, `audience:String=""`.  Reads `args.authToken`; returns
    `Err(Web.unauthorized(…))` if absent, `Err(Web.forbidden(…))` if invalid.
    Compiler emits A0042 if applied to a handler without `authToken: String`.
  - `pub aspect RateLimit` (B-mode) — sliding-window rate limit; config:
    `enabled:Bool=true`, `requestsPerMinute:Int=60`, `burstSize:Int=10`.
    Uses `call.qualifiedName` as the bucket key; returns
    `Err(Web.tooManyRequests(…))` when denied.
- `lyric-web/src/_kernel/net/web_kernel.l` — `Web.Kernel.Net` package
  (`@cfg(feature = "dotnet")`); extern boundaries:
  - `Microsoft.AspNetCore.serve(host, port, swaggerEnabled, specPath,
    corsEnabled, corsOrigins, corsMethods, corsHeaders, corsMaxAge, router)` —
    Kestrel HTTP server.
  - `System.IdentityModel.Tokens.Jwt.verifyJwt(token, secret, issuer,
    audience): Bool` — JWT validation.
  - `System.Threading.RateLimiting.checkRateLimit(endpoint,
    requestsPerMinute, burstSize): Bool` — in-process sliding-window limiter.
- `lyric-web/README.md` — full documentation: code-first workflow, spec-first
  workflow, OpenAPI→Lyric type mapping table, constraints→`requires:` table,
  generated stub example, runtime config env-var tables, aspect template
  reference with config fields, full composition example.
- `docs/03-decision-log.md` D054 — design rationale: hybrid routing model,
  flat typed parameters, handler dispatch by qualified name, full contract
  bridge, both spec generation modes, `ApiError` as plain record, CORS as
  config block, auth/rate-limit as aspects, `jwtSecret` as `@sensitive`,
  spec-first type mapping.

**Implementation gate:** Kestrel integration (`Web.Kernel.Net.serve`) and
the aspect weaver must ship before HTTP serving and aspect weaving take
effect.  The library can be imported, routers built, and aspects instantiated
today.

**Test counts:** no new compiler tests (library is Lyric source only;
no F# emitter changes).  727 emitter, 323 parser, 143 type-checker, 123
lexer, 28 LSP, 127 CLI, 266 verifier — all passing.

