# 10 — Bootstrap implementation status

Tracks the shipped state of the bootstrap compiler against the phased plan in
`docs/05-implementation-plan.md`.  Historical per-feature implementation notes
have been removed; see the git log for details.

The phased plan lives in `docs/05-implementation-plan.md`; this file records
what has shipped and what remains open.

---

## Status against `05-implementation-plan.md`

### Phase 0 — design freeze
All seven deliverables landed (see `CLAUDE.md` table).  Q011 / Q012
deferred to Phase 3 by design.

### Phase 1 — bootstrap compiler MVP
- M1.1 lexer + parser — shipped.
- M1.2 type checker — shipped.
- M1.3 MSIL emitter — shipped.
- M1.4 contracts / async / FFI / generics — shipped.  Real async state
  machines (C2 chain), reflection-driven FFI (C4), and reified generics
  all landed; see the Phase 2 table below for milestone cross-references.

### Phase 5 — self-hosting

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
| MSIL PE emitter Stages M31–M83 — 53 additional opcodes: `ldftn` + delegate (M31), `initobj` (M32), `ldtoken` + GetTypeFromHandle (M33), `sizeof` (M34/M50), `tail.` prefix (M35/M52), `ldind.i4`/`stind.i4` (M36), `ldelema` (M37), `add.ovf`/`sub.ovf`/`mul.ovf` (M38), `conv.ovf.i4`/`conv.ovf.i8` (M39), `volatile.` prefix (M40/M51), `conv.ovf.*.un` family (M41), `stind.i1`/`i2`/`ldind.u1`/`i2` (M42), `localloc` (M43), `conv.r.un`/`ckfinite` (M44), `initblk`/`cpblk` (M45), `conv.i1`/`i2` (M46), `conv.i`/`conv.u` (M47), `stind.i`/`ldind.i` (M48), typed `ldelem.i4`/`stelem.i4` (M49), bitwise/unary/shift/remainder/stack misc (M56–M60), overflow arith + int/float conversions + misc loads (M61–M65), checked conversions + float literal loads (M66–M70), `div`/signed branches/unsigned branches/`ldc.i4` variants/`ldloc`/`stloc` forms (M71–M75), `ldloca.s` + selective `ldind` families + `ldarg.2-3/s/a` + `starg.s` (M76–M79), `cgt`/`clt`/`conv.r.un` + typed `stelem`/`ldelem` (M80–M82), `constrained.`/`ldvirtftn`/`ldsflda` (M83) | **Shipped** | D-progress-170..D-progress-205 |
| M5.2 stage 2 — self-hosted contract elaborator (`Lyric.ContractElaborator` + `contract_elaborator_self_test.l`) | **Shipped** (this branch) | D-progress-137 |
| M5.2 stage 3a — self-hosted MSIL PE / opcode / tables layer (M1–M83) | **Shipped** | D-progress-213..D-progress-219 |
| M5.2 stage 3b — self-hosted MSIL high-level lowering (`Msil.Lowering`), `Msil.Codegen`, `Msil.Bridge`, F# bridge `SelfHostedMsil.fs` | **Shipped** | D-progress-227 / D-progress-238 / D-progress-240 |
| M5.2 stage 4 — self-hosted monomorphizer (`Lyric.Mono` package: call-site specialisation for same-package generic functions) | **Shipped** | D-progress-229 |
| M5.3 manifest self-test — `manifest_self_test.l` + `SelfHostedManifestTests.fs` exercise the `Lyric.Manifest` TOML parser | **Shipped** | D-progress-230 |
| M5.3 — self-hosted verifier (`Lyric.Verifier` package: VCGen, SMT emission, trivial discharger, `prove` driver + `verifier_self_test.l`) | **Shipped** | D-progress-234 |
| M5.3 — self-hosted stdlib / formatter / package manager / CLI | **Shipped** (`Lyric.Manifest`, `Lyric.Fmt` CST formatter, `Lyric.ManifestBridge`, `Lyric.TestSynthBridge`, `Lyric.Cli` full command dispatcher handling all CLI commands natively via `SelfHostedCli.fs`) | — |

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
- CST formatter (`lyric fmt`) — **shipped** (`Lyric.Fmt` self-hosted package, wired via `SelfHostedFmt.fs`): round-trip-faithful printing, full `//` and `/* */` comment preservation at item / member / statement / nested-block boundaries, intentional blank-line preservation (max one per spot, Black-style), width-driven multi-line expression layout at 120-char budget. `--write` and `--check` flags.
- Linter (`lyric lint`) — **shipped** (`Lint.fs` in `Lyric.Cli`, backed by `Lyric.SelfHostedLint.fs`): five AST-only rules: L001 PascalCase types, L002 camelCase funcs, L003 pub-doc, L004 no TODO/FIXME in docs, L005 pub block-body funcs need contracts. `--error-on-warning` flag. Runs on non-compiling code.
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
| M4.2 — `std.core.proof` standard-library subpackage | **Shipped** | D-progress-091 (`stdlib/std/core_proof.l`; 9/9 obligations self-discharge under the trivial checker) |
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
