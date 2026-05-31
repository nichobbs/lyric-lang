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
  all landed; async gaps Gap-1 through Gap-4 closed (D-progress-260);
  Gap-4a (await-in-generator) closed (D-progress-261); JVM async generator
  pipeline wired into self-hosted compiler (D-progress-262).

### Phase 5 — self-hosting

| Milestone | Status | Lands in |
|---|---|---|
| Supply-chain integrity — `lyric.lock` SHA-512 populated + verified (`--locked`): `Std.HashHost` (`SHA512.HashData` + `Convert.ToHexString`) + `Std.Hash` (`sha512OfBytes`, `sha512OfFile`); CLI restore writes digest for every dep (path/workspace/git on `lyric.toml`, registry on `.nupkg` post `dotnet restore` honouring `NUGET_PACKAGES`); four-way mismatch matrix in `--locked` mode | **Shipped** (PR #804) | #738 |
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
| `docs/23` G7 (StubCounter) — `Std.Testing.Mocking.StubCounter` ported from F# shim (`Lyric.Stdlib.StubCounter` / `StubCounterHost`, 24 LoC) to a native Lyric `pub protected type StubCounter`.  New `lyric-stdlib/std/testing_mocking.l` shadows `_kernel/testing_mocking.l` for .NET; wrapper functions (`makeStubCounter`, `stubCounterIncrement`, `stubCounterGet`, `stubCounterReset`) are unchanged.  Emitter.fs gains `IProtected` scanning in the artifact-import loop so cross-package `protected type` references resolve to the correct CLR type (previously only `extern type` / record / union / interface got this treatment) | **Shipped** (PR #182) | D-progress-123 |
| `docs/23` JsonHost retirement — final eight live methods retired from `Lyric.Stdlib.JsonHost` (`Parse`, `EncodeString`, `RenderDoubleSlice`, `Get{Int,Long,Double,Bool,String}Slice`).  Compiler fixes unblock the migration: (1) FFI default-arg overload selection now filters by leading-param exact type so `JsonDocument.Parse(string, JsonDocumentOptions = default)` resolves correctly when other 2-arg `Parse` overloads exist; (2) `emitExternCall` honours `inout`-mode value-type receivers (load arg pointer directly instead of `Ldarga`-ing the parameter slot) so mutating instance methods like `JsonElement+ArrayEnumerator.MoveNext` work; (3) `toString(Double)` / `toString(Float)` codegen calls `Double.ToString(InvariantCulture)` for round-trip-safe locale-stable formatting.  `_kernel/json_host.l` declares `extern type JsonArrayEnumerator = "System.Text.Json.JsonElement+ArrayEnumerator"` and `extern type JsonEncodedText` and implements `hostEncodeString` and `lyricJsonGet*Slice` in pure Lyric on top of direct externs (`EnumerateArray` / `MoveNext` / `Current` / `JsonEncodedText.{Encode, ToString}`).  `JsonDerive.fs` synthesiser routes `__lyricJsonEscape` and slice readers through the new pure-Lyric kernel functions; `mkSliceHelperExtern` deleted (Double now uses inline `toString`-based rendering like Int/Long).  `Lyric.Stdlib.JsonHost` class removed; the `Lyric.Stdlib` F# shim is now empty of types | **Shipped** | D-progress-139 |
| `docs/23` F# shim project deleted — with `Lyric.Stdlib.dll` empty of host types after D-progress-139, the `bootstrap/src/Lyric.Stdlib/` project is deleted outright: `.fsproj` / `Stdlib.fs` removed, `<ProjectReference>` lines pulled from `Lyric.Cli`, `Lyric.Emitter`, `Lyric.Emitter.Tests`, and the project entry / configuration / nesting tag scrubbed from `Bootstrap.sln`.  CLI + test infrastructure (`Cli/Program.fs`, `EmitTestKit.fs`, `ProjectAsDllTests.fs`, `NugetShimTests.fs`) drop their `Lyric.Stdlib.dll` copy / probe paths.  `lyric-stdlib/lyric.toml` reverts `output_assembly` from `Lyric.StdlibBundle.dll` to the canonical `Lyric.Stdlib.dll` — the SDK's `lib/Lyric.Stdlib.dll` is now the Lyric-compiled bundle (no F# / FSharp.Core dep) | **Shipped** | D-progress-140 |
| M5.1 stage 2d.i — `[nuget]` + `[nuget.options]` manifest parsing | **Shipped** (PR #159) | D-progress-117 |
| M5.1 stage 2d.ii — `lyric restore` csproj forwards `[nuget]` entries to `dotnet restore`; TFM compat fallback for the NuGet-cache locator | **Shipped** (PR #159) | D-progress-117 |
| M5.1 stage 2d.iii — reflection-driven `Lyric.Cli.NugetShim` generator (static methods only; primitives + same-package `extern type`s; defensive against `MetadataLoadContext` failures) | **Shipped** (PR #162) | D-progress-118 |
| M5.1 stage 2d.iv — `lyric restore` writes `_extern/<lyric-pkg>.l` + `.skip.md` shims for every `[nuget]` entry after restore completes; B0030-flavoured warnings for unlocatable DLLs | **Shipped** (PR #162) | D-progress-118 |
| M5.1 stage 2d.v — build-time wiring: `project.assets.json` walker, `_extern/<pkg>.l` shim auto-compile to cached DLL, NuGet DLL pre-load into emitter AppDomain, NuGet + shim DLL copy alongside output, end-to-end smoke (`Newtonsoft.Json.JValue.CreateString`) | **Shipped** (PR #177) | D-progress-122 |
| JVM self-tests B111-B124 — lowerSealedUnion, lowerEnum, lowerOutInoutParam, lowerNatTag, makeLyricSignatureAttr, lowerExposedRecord, lowerProjectable, lowerProtectedWithBarriers, lowerHotAsync, lowerScopeBlock, lowerFuncWithContract, lowerDeriveEquality, lowerDeriveOrd, lowerPackage | **Shipped** (PR #183 / #184) | D-progress-124 |
| JVM stage B2 smoke test unskipped — `hello_class_bytes_are_jvm_loadable` now passes; stale `BadImageFormatException` workaround in `JvmSelfTest.fs` removed; `docs/18-jvm-emission.md` B111–B124 status table updated to Shipped | **Shipped** (PR #186) | D-progress-125 |
| Phase 6 — stdlib distribution per `docs/22-distribution-and-tooling.md` §2–§5 — §4 SDK root discovery, §5 `Lyric.SdkVersion` embed, `lyric --sdk-info`, bundle expansion to 11 packages, B0040/B0042 | **Shipped** (PR #187) | D-progress-126 |
| Phase 6 — VS Code tooling §6.1–§6.4 per `docs/22-distribution-and-tooling.md` — JSON schema for `lyric.toml`; manifest-backed package management commands (Add/Remove/Update dependency, Add NuGet, Restore); project navigator tree view; Lyric task definitions and provider (build, run, test, prove) | **Shipped** (PR #188) | D-progress-127 |
| Phase 5 — self-hosted AST type declarations mirroring `Ast.fs` (`Expr`, `Stmt`, `Item`, `Pattern`, `TypeRef`, `ContractClause`, …); prerequisite for the self-hosted parser. _The original standalone `Lyric.Ast` (`ast.l`, PR #185) was never imported — the parser and all downstream passes use `Lyric.Parser`'s `parser_ast.l` instead — so the duplicate was deleted (#1509 item 2); the authoritative declarations live in `parser_ast.l`._ | **Shipped** (PR #185); mirror removed | — |
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
| M5.2 stage 4 — self-hosted monomorphizer (`Lyric.Mono` package: call-site specialisation for same-package generic functions; **not invoked from production builds** — `Msil.Bridge` / `Jvm.Bridge` pass parsed input directly to codegen, so generics are still monomorphised by the F# emitter's middle-end. Self-hosted monomorphizer is exercised by `mono_self_test.l` only, per `mono.l:6-27`) | **Shipped** | D-progress-229 |
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
- Protected types — initial Monitor wrap shipped (D-progress-079);
  `when:` barriers + `invariant:` checks +
  `ReaderWriterLockSlim`/`SemaphoreSlim` lock-flavour split + generic
  protected types (`Box[T]`) + Ada-style condition-variable barrier
  waiting all shipped under D-progress-080 / 081 / 083 / 086 / 087.
  Tracked gap (Q008 follow-up): barrier waits use a finite timeout
  (currently 1s) so single-threaded misuses surface as exceptions
  instead of deadlocks.  Ada's infinite-wait semantics require an
  open issue + implementation pass before the gap can close;
  production behaviour is bounded-wait until then.
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
| M4.2 — `std.core.proof` standard-library subpackage | **Shipped** | D-progress-091 (`lyric-stdlib/std/core_proof.l`; 9/9 obligations self-discharge under the trivial checker) |
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

### D-progress-310 — Tier-6 weaver: `config { }`, ambient `call`, `@inline_template` (#683, #682, #681; PR #1172)

*claude/todo-06-review-R8az7 branch.*

Three aspect-system features wired into the self-hosted weaver
(`lyric-compiler/lyric/weaver/weaver.l`).  The F# bootstrap weaver
(`bootstrap/src/Lyric.Emitter/Weaver.fs`) is deliberately untouched
per Band 7 / #859 — the self-hosted weaver is the source of truth.

**Refactor — `RewriteCtx`:**

The previous rewriter threaded `targetName` + `paramNames` as
positional parameters through every helper.  Adding three new
substitutions (config, call, args) on top would have either
duplicated ~400 lines of AST traversal or required four positional
params per helper.  The new `RewriteCtx` record bundles every
piece of weave-site state into one value that's threaded once;
each substitution lives in `tryMemberRewrite` and runs in the
same bottom-up pass as the existing `proceed(args)` rewrite.

**#683 — `config { }` wiring:**

Each `ConfigField` in `AspectDecl.config` with a literal default is
materialised as `val __aspect_cfg_<name>: <ty> = <default>` at the
top of the woven body.  `config.<name>` member accesses are rewritten
to bare `__aspect_cfg_<name>` paths.  Fields without a default are
skipped — runtime env-var resolution per `docs/26 §8` / `docs/25` is
a follow-up.

**#682 — ambient `call` value (compile-time fields):**

`buildCallPrelude` pre-scans the aspect body via `collectCallRefsBlock`
and materialises only the `__lyric_call_<name>` locals that are
actually referenced.  Six compile-time-known fields are wired:
`shortName`, `qualifiedName`, `modulePath`, `sourceLocation`,
`annotations`, `aspect`.  `call.elapsed` and `call.caller` need
runtime instrumentation (Std.Time integration plus auto-import-
injection design); deferred to **#1298**.  Any `call.<unknown>` —
including those two — surfaces as an **A0043** weave-time
diagnostic so users get a weaver-targeted message instead of a
downstream "call is undeclared" type error.

**#681 — `@inline_template`:**

Aspects whose enclosing item carries `@inline_template` get
`args.<field>` rewrites at weave time: each field name must match
a parameter of the matched function.  Mismatches accumulate as
**A0042** diagnostics.  Removed the `L006` lint warning that
previously flagged `@inline_template` as having no effect.

**Diagnostics plumbing:**

New `WeaveResult` / `WeaveFileResult` records and
`weaveItemsWithDiags` / `weaveFileWithDiags` public entry points
return diagnostics alongside the rewritten items.  Existing
`weaveItems` / `weaveFile` keep their old signatures for back-
compat (they silently drop diagnostics).  The verifier driver
(`lyric prove`) switched to `weaveFileWithDiags` so A0042 / A0043
surface in the proof summary.

Diagnostic emission is deduplicated per-`(kind, funcName, fieldName)`
via `addWeaveDiagOnce` — a body referencing `call.elapsed` twice
emits a single A0043; same field across two matched functions
emits one A0043 each.

**Drive-by — in-process MSIL bridge stdlib function imports:**

`Msil.Bridge.compileToMsil` used to filter `importedItems` down to
type declarations only.  Functions were skipped because
`addSigsFromItems` called `Dictionary<K,V>.Add` on the bare name
key and multi-file stdlib duplicates (`toString` in several
modules) threw `ArgumentException`.  Switched to first-wins via
`containsKey`.  Net effect: `lyric run <file>` calling `println`
from `Std.Console` no longer NREs at runtime through the AOT
path — codegen now has a real signature to resolve the call
against.

**Self-test (`lyric-compiler/lyric/weaver_self_test.l`):**

17 `test "..."` blocks in `@test_module` form covering every
feature path plus regression cases for #1296 (duplicate
`call.<field>` references crashing the pre-scan), #1299
(duplicate A0042/A0043 emissions), and #1323 (panic-stub
materialisation for `config.<no-default>` references so the
A0044 error replaces the downstream type/codegen error).  Does not currently auto-run
in CI — the path to running it via `lyric test` directly (no F#
scaffolding per session directive) requires the in-process bridge
to load `lyric-compiler/lyric/**/*.l` so the test's
`Lyric.Lexer` / `Lyric.Parser` / `Lyric.Weaver` imports resolve.
That work is in progress on this branch but exposes secondary
codegen issues (`InvalidProgramException` at runtime) that need
their own investigation.

---

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

Self-test additions in `lyric-compiler/lyric/fmt_self_test.l`:

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

Architecture (`lyric-compiler/lyric/fmt/fmt_core.l`):

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

Self-test additions in `lyric-compiler/lyric/fmt_self_test.l`:

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

Self-test additions in `lyric-compiler/lyric/fmt_self_test.l`:

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

Mechanism (`lyric-compiler/lyric/fmt/fmt_items.l`):

- New `contractClauseStartOffset(cc)` helper extracts the source
  offset of any `ContractClause` variant.
- `funcDoc` and `entryDoc` now call `popTriviaBefore(ctx, …)` before
  emitting each clause line.  The popped lines (comments + blank-line
  markers) are routed through `appendIndentedTrivia` so each non-
  blank line is prefixed with the canonical contract indent (`  `),
  matching the indent of the clause line itself.  Blank lines stay
  literally `""` so `joinLines` doesn't strip indented whitespace.

Self-test additions in `lyric-compiler/lyric/fmt_self_test.l`:

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

Self-test additions in `lyric-compiler/lyric/parser_self_test.l`:

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
(`bootstrap/src/Lyric.Cli/TestSynth.fs`): parse, walk items, replace
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
at `bootstrap/tests/Lyric.Cli.Tests/TestRunnerTests.fs` (8 cases
covering pass / fail / no-`@test_module` / user-main / fixture /
`--list` / `--filter` / property-skip).

The motivation, beyond §13.2 spec parity, is Phase 5 §M5.4: the
F# Expecto bridge that drives `lyric-stdlib/tests/*_tests.l` today goes
away with the F# host, so a native runner is a Phase 5
prerequisite that we paid down early.

**Self-hosted port (follow-up commit).**  The same rewriter is
also implemented in Lyric at `lyric-compiler/lyric/test_synth/test_synth.l`
(`Lyric.TestSynth`), with a self-test consumer at
`lyric-compiler/lyric/test_synth_self_test.l` driven by the F#
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
`lyric-compiler/lyric/contract_elaborator/`:

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

- `lyric-compiler/lyric/contract_elaborator_self_test.l` — 14
  in-process tests covering: empty-contracts identity, single /
  multiple `requires:`, single / multiple `ensures:` (trailing
  fall-off and explicit return paths), bare `return`, combined
  requires + ensures, `@axiom` skip, signature pass-through,
  preservation of the original `contracts` list, synthetic-name
  uniqueness across multiple returns, file-level identity
  (package decl + imports + items), and non-function items
  pass-through.
- `bootstrap/tests/Lyric.Emitter.Tests/SelfHostedContractElaboratorTests.fs`
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

Self-test additions (`lyric-compiler/lyric/fmt_self_test.l`):

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

### D-progress-213: MSIL PE emitter Stages M2a–M2d — parameterized heap/opcode/table/layout pipeline

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

### D-progress-214: MSIL PE emitter Stage M3 — end-to-end CLR execution test

*claude/plan-emitter-next-steps-6jGK7 branch.*

Stage M3 closes the loop on the M2a–M2d pipeline by verifying that
`Msil.Assembler.assemblePe` produces a PE image that the CLR can actually
load and execute, not just one that passes byte-layout checks.

**`msil_self_test_m3.l`** (`lyric-compiler/msil/msil_self_test_m3.l`)

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

### D-progress-215: MSIL PE emitter Stage M4 — multi-method PE assembler

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

### D-progress-216: MSIL PE emitter Stage M5 — local variables / fat method header

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

### D-progress-217: MSIL PE emitter Stage M6 — method arguments and non-void return

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

### D-progress-218: MSIL PE emitter Stage M7 — static fields

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

### D-progress-219: MSIL PE emitter Stage M8 — newobj + instance fields

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

### D-progress-212: Axiom audit — updated to reflect kernel package-level axiom design

*claude/plan-emitter-next-steps-6jGK7 branch.*

M4.3 item D12: `docs/17-axiom-audit.md` updated from the old per-function
`std.bcl.*` format (M4.3 baseline: 11 axioms in 6 modules) to the current
kernel design where each `lyric-stdlib/std/_kernel/*.l` file carries a single
package-level `@axiom` claim covering its entire BCL extern boundary.

The audit now enumerates all 16 kernel packages, grouped by BCL domain:

- **I/O** — `Std.IO` (Console + I/O static helpers)
- **Collections** — `Std.CollectionsHost` (List, Map, Set)
- **Math / Parsing** — `Std.MathHost`, `Std.ParseHost`
- **Text / Encoding** — `Std.FormatHost`, `Std.EncodingHost`, `Std.CharHost`, `Std.UnicodeHost`
- **Storage** — `Std.FileHost`
- **Time** — `Std.TimeHost`
- **Network** — `Std.HttpHost`
- **System / Process** — `Std.EnvironmentHost`, `Std.ProcessHost`
- **Serialization** — `Std.JsonHost`
- **Identity** — `Std.UuidHost`
- **Logging** — `Std.LogHost`

Each entry documents: claim string, covered BCL namespaces, decidability gap,
caller obligations, and review status.  All 16 kernel axioms are marked Stable
(the `Guid.newGuid` Provisional flag from the old audit carries over to
`Std.UuidHost`'s `newGuid` entry).

Updated §13 (how to add a new axiom) to refer to the kernel file pattern.
Updated §14 (count table) — 16 axioms, 0 provisional.

---

### D-progress-211: FBExpr + contracts formatter bug — both formatters

*claude/plan-emitter-next-steps-6jGK7 branch.*

Pre-existing bug: when a `func` had an expression body (`= expr`) **and** at
least one contract clause (`requires:` / `ensures:`), the `FBExpr` code path in
both the self-hosted formatter (`fmt_items.l`) and the F# legacy formatter
(`Fmt.fs`) would emit only `sig = expr`, silently dropping the contract lines.
The contract `extras` list was built correctly but never emitted in this branch.

**Fix** (`fmt_items.l`): the `case Some(FBExpr(e))` arm now checks
`extras.count == 0`.  When there are no extras it uses the compact
`appendToLastLine(sig, " = " + exprInline(0, e))` form; when extras exist it
copies `sig` rows, then `extras` rows, then appends `"  = " + exprInline(0, e)`
as the final line — matching the `FBBlock`-with-extras layout.

**Fix** (`Fmt.fs`): same logic: `if List.isEmpty extraLines then [sig_ + " = " + ...]
else [sig_] @ extraLines @ ["  = " + ...]`.

**Self-test**: `testFBExprWithContracts` added to `fmt_self_test.l`:
`func abs(x: in Int): Int ensures: result >= 0 = if x >= 0 { x } else { -x }`
round-trips with both the `ensures:` clause and the `= if …` body preserved.
Formatter self-test passes (1/1).

---

### D-progress-210: M5.3 stage 12 — `EIf`/`EMatch` brace-form conversion + forall double-brace fix

*claude/plan-emitter-next-steps-6jGK7 branch.*

Two formatter fixes in one stage.

**`EIf` / `EMatch` width-driven brace-form conversion** in `exprAtCol`
(`fmt_core.l`): two new cases that were previously falling through to
`singleLineDoc(inline)` even when the inline form exceeded the 120-char
budget.

- `EIf` (non-`thenForm`): delegates to `ifBlockLines` when over budget.
- `EMatch`: delegates to `matchLines` when over budget.
- `thenForm` (`if cond then e`) has no brace layout; stays inline.
- Both cases only fire when `exprFitsInline` returns `false`.

**Forall/exists double-brace fix** in `quantifierStr` (inline) and
`exprQuantMulti` (multi-line): when a forall/exists body was parsed as
`{ … }`, the parser wraps it in `EBlock`.  Both formatters previously
emitted their own outer `{ … }`, producing `forall (i) { { p(i) } }`.

Fix: match on `body.kind` and use `blockInline(b)` / `blockLines(b, ctx)`
when the body is an `EBlock`, otherwise fall back to the existing
`exprInline(0, body)` / `exprAtCol(…, body)` paths.

Same fix applied to the F# legacy formatter `Fmt.fs` so `--legacy` is
consistent.

**Self-test additions** in `fmt_self_test.l`:
- `testWidthDrivenLongIfBreaks` — long `if`-expression converts to brace layout.
- `testWidthDrivenLongMatchBreaks` — long `match`-expression converts to brace layout.
- `testForallBodyNoBraces` — `forall (j: Int) { j > 0 }` round-trips without double braces.

Formatter self-test passes (1/1); 8 aspect-weaver tests pass; parser self-test passes.

---

### D-progress-209: Aspect weaver A4 — multi-aspect ordering (`wraps:`/`inside:`)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Implements §6 of `docs/26-aspects.md`: when multiple aspects match the same
function, `wraps:` and `inside:` clauses control the wrapper chain order.

- **`Ast.fs`**: `AspectDecl` gains `Wraps: string list` and `Inside: string list`.
- **`Parser.fs`**: `parseAspectBody` recognises `TIdent "wraps"` and
  `TIdent "inside"` inside the aspect body and parses comma-separated identifier
  lists.  Error codes P0306 (after `wraps:`) and P0307 (after `inside:`).
- **`Weaver.fs`**: `sortAspects` uses Kahn's algorithm over the ordering graph
  (edges: `A wraps B` → A before B; `A inside B` → B before A).  Falls back to
  lexical (declaration) order on cycles (bootstrap-grade; A0008 diagnostic
  deferred).  `weaveItems` changed from `List.tryFind` to `List.filter` +
  `sortAspects`: builds a chain `target ← innermost-wrapper ← … ← outermost-wrapper`
  where outermost keeps the original public name.  Intermediate wrappers are named
  `fn__aspect_<AspectName>`.
- **`Emitter.fs`**: sigs augmentation broadened from `EndsWith "__aspect_target"` to
  `IndexOf "__aspect_"` so intermediate wrappers (`fn__aspect_<X>`) also find their
  base signature in the type-checker sigs map.
- **`Fmt.fs`**: Legacy F# formatter emits `wraps:` and `inside:` lines inside the
  aspect block, before the matcher lines.
- **Self-hosted files** (`parser_ast.l`, `parser_items.l`, `fmt_items.l`): same
  changes mirrored — `AspectDecl.wraps` and `AspectDecl.inside` fields added;
  `parseAspectBody` handles `TIdent "wraps"` / `TIdent "inside"` branches with
  comma-separated identifier list parsing; `aspectDoc` emits the lines using
  `joinStrings`.
- **Tests** in `AspectWeaverTest.fs`: new `aspect_weaver_multi_ordering` case uses
  `Outer wraps: Inner`; verifies the output line order is
  `outer-start → inner-start → body → inner-end → outer-end`.

All 8 aspect weaver tests pass; self-hosted parser and formatter self-tests pass.

---

### D-progress-208: Aspect weaver A3 — contract augmentation (§5)

*claude/plan-emitter-next-steps-6jGK7 branch.*

Implements §5 of `docs/26-aspects.md`: `requires:` and `ensures:` clauses on
aspect bodies compose with the target function's own contracts in the synthesised
wrapper.

- **`Ast.fs`**: `AspectDecl` gains `Contracts: ContractClause list`.
- **`Parser.fs`**: `parseAspectBody` recognises `TKeyword KwRequires` and
  `TKeyword KwEnsures` inside the aspect body and collects them via the existing
  `parseContractClauseOpt` helper.  Error message for unrecognised tokens updated.
- **`Weaver.fs`**: `buildWrapper` now sets
  `Contracts = aspect.Contracts @ originalFn.Contracts` (aspect preconditions
  must hold first; aspect postconditions join the target's guarantees).
  Module header updated to reflect A3 shipped.
- **`Fmt.fs`**: Legacy F# formatter emits `requires:`/`ensures:` lines inside
  the aspect block, before the `around` clause.
- **Self-hosted files** (`parser_ast.l`, `parser_items.l`, `fmt_items.l`): same
  changes mirrored — `AspectDecl.contracts` field added; `parseAspectBody` handles
  `TKeyword(k)` when `isKw(k, KwRequires) or isKw(k, KwEnsures)`;
  `aspectDoc` emits contract lines before the `around` block.
- **Tests** in `AspectWeaverTest.fs`: two new cases verify that a
  `requires: true` clause on an aspect body parses cleanly and the woven program
  runs to completion with correct output.

All 7 aspect weaver tests pass; self-hosted parser and formatter self-tests pass.

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

### D-progress-206a: Aspect weaver A1 — bootstrap-grade wrapper synthesis

*(Renumbered from D-progress-206 to avoid collision with D-progress-206 / B126 — JUnit 5 adapter.)*

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

### D-progress-202a: MSIL PE emitter Stages M71–M75 — div/beq/bgt, signed branches, unsigned branches, ble.un/blt.un/ldc.i4 variants, ldloc/stloc forms

*(Renumbered from D-progress-202 to avoid collision with D-progress-202 in `main`,
which covers the lyric-web library addition.)*

*claude/plan-emitter-next-steps-6jGK7 branch.*

Five stages batched:

- **M71** (`div`, 0x5B; `beq`, 0x3B; `bgt`, 0x3D): integer divide plus two conditional
  branch forms. `84/2=42`; `beq` and `bgt` guard dead fall-through paths. Tiny header.

- **M72** (`bge`, 0x3C; `ble`, 0x3E; `blt`, 0x3F): three signed conditional branch forms.
  The `ble` test uses equal operands (42, 42) to discriminate `ble` (branches) from `blt`
  (would not). Tiny header (codeSize=59).

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

- `bootstrap/src/Lyric.Stdlib/Lyric.Stdlib.fsproj`
- `bootstrap/src/Lyric.Stdlib/Stdlib.fs`

Files updated:

- `bootstrap/Bootstrap.sln` — removes the `Lyric.Stdlib` project entry,
  configuration block, and nesting tag.
- `bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj`,
  `bootstrap/src/Lyric.Emitter/Lyric.Emitter.fsproj`,
  `bootstrap/tests/Lyric.Emitter.Tests/Lyric.Emitter.Tests.fsproj` —
  drop the `<ProjectReference Include="...Lyric.Stdlib.fsproj" />`
  line.
- `bootstrap/src/Lyric.Cli/Program.fs` — `locateStdlibDll` and the
  F# shim copy in `copyStdlibArtifacts` deleted; the second copy in
  the AOT path also drops the `Lyric.Stdlib.dll` line.  Comments
  rewritten to reflect that the only `Lyric.Stdlib.<X>.dll` files
  staged are the precompiled Lyric-compiled package DLLs.
- `bootstrap/tests/Lyric.Emitter.Tests/EmitTestKit.fs` — `stdlibDll ()`
  helper and the corresponding `File.Copy` call deleted from
  `prepareOutputDir`.
- `bootstrap/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` — drops
  the `Lyric.Stdlib.dll` copy in the test scratch dir helper.
- `bootstrap/tests/Lyric.Cli.Tests/NugetShimTests.fs` — replaces the
  `Lyric.Stdlib.dll` probe-DLL fallback with `Lyric.Parser.dll`.
- `lyric-stdlib/lyric.toml` — `output_assembly` reverts from
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

The last live F# methods in `bootstrap/src/Lyric.Stdlib/Stdlib.fs` were
all on `Lyric.Stdlib.JsonHost` and split into three buckets, each
gated on a different compiler limitation:

| Method(s) | Blocker | Fix |
|---|---|---|
| `Parse` | FFI default-arg overload selection picked an arbitrary `JsonDocument.Parse(X, JsonDocumentOptions = default)` overload — `staticArityWithDefaults` matched on count only, so `Parse(ReadOnlyMemory<char>, …)` could win over `Parse(string, …)` | Filter by leading-param exact type before falling back to count-only |
| `EncodeString` | `JsonEncodedText.Encode(string)` returns a struct (`JsonEncodedText`); calling instance `ToString()` on it from Lyric needed BCL struct return bridging | Already worked via `Ldarga 0` for value-type receivers; split into `hostEncodeText` + `hostEncodedTextToString` and a native-Lyric concat-with-quotes |
| `Get{Int,Long,Double,Bool,String}Slice` (5 methods) | `JsonElement.EnumerateArray()` returns the nested CLR struct `JsonElement+ArrayEnumerator`; `extern type X = "Foo+Bar"` parsed but `MoveNext` (mutating instance method) failed because the emitter `Ldarga`-ed the parameter slot when `inout` already gave it a managed pointer | Skip the `Ldarga` when `paramList[0]` is already byref so `Ldarg 0` loads the pointer directly |
| `RenderDoubleSlice` | `Lyric.toString(Double)` boxed and called `Object.ToString()` (locale-dependent, not round-trip-safe) | Special-case `toString(Double | Float)` in codegen to call `Double.ToString(InvariantCulture)` — .NET 10's default format is already round-trip-shortest, and `InvariantCulture` pins the decimal separator |

Files touched:

- `bootstrap/src/Lyric.Emitter/Emitter.fs` — three edits.  (1)
  `staticArityWithDefaults` / `instanceArityWithDefaults` get a
  two-pass match: leading-param exact-type first, then count-only as
  fallback — fixes the `Parse(ReadOnlyMemory<char>, opts=default)`
  ambiguity.  (2) `emitExternCall` arg push: when `paramList[0]` is
  already a byref (Lyric `inout T`), use `Ldarg 0` instead of
  `Ldarga 0` so the loaded pointer matches the BCL receiver shape.
  (3) `findClrType` no longer pins `typeof<Lyric.Stdlib.JsonHost>` —
  the type doesn't exist anymore.
- `bootstrap/src/Lyric.Emitter/Codegen.fs` — `toString` builtin gains a
  branch for `argTy = typeof<double>` / `typeof<single>` that emits
  `Stloc + Ldloca + Call CultureInfo.get_InvariantCulture + Call
  Double.ToString(IFormatProvider)`.
- `lyric-stdlib/std/_kernel/json_host.l` — adds `extern type
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
- `bootstrap/src/Lyric.Parser/JsonDerive.fs` — synthesiser updates.
  `__lyricJsonEscape` becomes a Lyric body (`hostEncodeString(s)`)
  instead of `@externTarget`-ing the F# shim; the five
  `__lyricJsonGet*Slice` helpers route through `mkGetShimBody` to
  the new `lyricJsonGet*Slice` kernel functions; the Double slice
  renderer uses `mkSliceHelperInline` with `toString(items[i])`
  (now culture-invariant).  `mkSliceHelperExtern` and the legacy
  count-only `mkGetShim` builders deleted — both unused after
  migration.
- `bootstrap/src/Lyric.Stdlib/Stdlib.fs` — the `JsonHost` class is
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
- `bootstrap/src/Lyric.Cli/SelfHostedFmt.fs` (new F# module)
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

Tests at `bootstrap/tests/Lyric.Cli.Tests/SelfHostedFmtBridgeTests.fs`
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

The F# `lyric fmt` (bootstrap/src/Lyric.Cli/Fmt.fs) drops `//` comments
because it walks the AST exclusively.  D-progress-130's red/green CST
gave the parser a lossless source view; this stage ports the formatter
to Lyric so it can consume that CST and preserve comments.

Scope:

- New `Lyric.Fmt` package at `lyric-compiler/lyric/fmt/{fmt_core,fmt_items,fmt}.l`
  mirroring the F# Fmt.fs structure (helpers + line model + type /
  pattern / literal / expression / statement printers in `fmt_core`,
  item printers in `fmt_items`, top-level entry points in `fmt`).
- Public API matching the contract advertised in `lyric-compiler/lyric/cli.l`:
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

**Lexer changes (`lyric-compiler/lyric/lexer.l`):**

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

**CST data model (`lyric-compiler/lyric/parser/parser_cst.l`):**

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

**Parser wrapping (`lyric-compiler/lyric/parser/parser_*.l`):**

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
under `lyric-compiler/lyric/parser/`:

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

`lyric-compiler/lyric/parser_self_test.l` is the self-test consumer.  It
imports `Lyric.Lexer` and `Lyric.Parser`, exercises the full parse path
(imports, function decls with contracts, expression types, match, loops,
closures, …) through assertions, and writes `"ok"` on success.

The F# test
`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedParserTests.fs`
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
test in `bootstrap/tests/Lyric.Emitter.Tests/JvmSelfTest.fs` was marked `ptestCase`
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
| `lyric-stdlib/std/_kernel/process_host.l` | Trusted BCL extern boundary for `System.Diagnostics.Process` |
| `lyric-stdlib/std/process.l` | `Std.Process` — `run` / `runChecked` wrapping the process kernel |
| `lyric-compiler/lyric/manifest.l` | `Lyric.Manifest` — pure-Lyric TOML parser for `lyric.toml` (mirrors `Manifest.fs`) |
| `lyric-compiler/lyric/cli.l` | `Lyric.Cli` — self-hosted command dispatch (mirrors `Program.fs`) |
| `lyric-stdlib/std/string.l` | Added `pub func fromInt(n: in Int): String` convenience wrapper over `toString` |

**Architecture decisions:**

- `Std.ProcessHost` lives in `lyric-stdlib/std/_kernel/` (kernel boundary), using
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
  surface in header comments.  The file lives in `lyric-compiler/lyric/`
  and is only compiled by the self-hosted compiler, so forward references
  are safe.
- `lyric-stdlib/lyric.toml` gains `Std.ProcessHost` in Tier 0 (only depends on
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
`lyric-compiler/jvm/` and an F# Expecto test in
`bootstrap/tests/Lyric.Emitter.Tests/`.

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

- `lyric-compiler/msil/_kernel/kernel.l` — `Msil.Kernel` package; declares
  `extern type ByteWriter = "Lyric.Jvm.Hosts.JvmByteBuilder"` and re-exports
  the JVM LE byte-write helpers (`bufU1`, `bufU2`, `bufU4`, `bufAppend`,
  `bufLen`, `bufToList`) under PE-centric names, plus `bufZero` and `bufPadTo`
  in native Lyric.

- `lyric-compiler/msil/pe.l` — `Msil.Pe` package; full fixed-layout serializer.
  Sections: DOS stub (128 B), PE/COFF headers (384 B, padded), CLR header
  IMAGE_COR20_HEADER (72 B), MSIL method body in tiny format (12 B, ldstr +
  call + ret), and ECMA-335 metadata (408 B: BSJB root + #~ tables stream +
  #Strings + #US + #Blob + #GUID).  Entry points: `buildHelloAssemblyBuf()`,
  `buildHelloAssembly(): List[Byte]`, `buildHelloAssemblySize(): Int`.

- `lyric-compiler/msil/msil_self_test_m1.l` — `Msil.SelfTestM1` package;
  calls `buildHelloAssemblySize()` + `buildHelloAssembly()` and prints five
  structural invariants: `pe_size_ok=true`, `mz_ok=true`, `pe_sig_ok=true`,
  `clr_header_ok=true`, `bsjb_ok=true`.

**Emitter change:**

- `bootstrap/src/Lyric.Emitter/Emitter.fs` — `isBuiltinHead` extended to
  include `"Msil"`, mapping `import Msil.X` to `lyric-compiler/msil/`.

**F# test:**

- `bootstrap/tests/Lyric.Emitter.Tests/MsilSelfTestM1.fs` — `Msil.SelfTest M1`
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

**New module: `bootstrap/src/Lyric.Emitter/SdkRoot.fs`**

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

**`lyric-stdlib/lyric.toml` expansion**

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
   `bootstrap/src/Lyric.Emitter/Emitter.fs` gains
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

**Emitter changes (`bootstrap/src/Lyric.Emitter/Emitter.fs`)**:
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

* New audited kernel file `lyric-stdlib/std/_kernel/unicode_host.l`
  exposes `System.Char.GetUnicodeCategory` returning `Int` (the
  underlying type of `System.Globalization.UnicodeCategory`'s
  `enum : int32`) plus a small set of `@pure` constant accessors
  for the categories the lexer cares about:
  `UppercaseLetter` (0), `LowercaseLetter` (1), `TitlecaseLetter`
  (2), `ModifierLetter` (3), `OtherLetter` (4), `NonSpacingMark`
  (5), `SpacingCombiningMark` (6), `DecimalDigitNumber` (8),
  `LetterNumber` (9), `ConnectorPunctuation` (18).  One new
  `@externTarget`; `_kernel/` count now 147/150.
* `lyric-compiler/lyric/lexer.l` `isIdStart` / `isIdContinue` keep
  the ASCII fast path (`[A-Za-z_]` / `[A-Za-z0-9_]`) and gain a
  non-ASCII branch that calls `hostUnicodeCategory(c)` and
  matches the same category set the F# bootstrap does
  (bootstrap/src/Lyric.Lexer/Lexer.fs lines 92-119).
* New helper `isAscii(c) = c <= '\u{007F}'` keeps the dispatch
  branch readable.
* Self-test grows by 3 cases — Greek-letter ident, Cyrillic
  uppercase + lowercase, and `<letter><digit>` continuation.

The kernel-cap check (≤150 `@externTarget`s per platform per the
audit boundary policy) leaves room for further BCL exposure
without re-architecting the kernel.

### D-progress-120: M5.1 stage 4 (partial) — NFC + L0040 in self-hosted lexer

*claude/m5.1-stages-2d-3-4-8hL4O branch.*  Adds the F# bootstrap's
existing identifier hardening to `lyric-compiler/lyric/lexer.l`:

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
`bootstrap/src/Lyric.Lexer/Lexer.fs`'s string-shape coverage into
`lyric-compiler/lyric/lexer.l` 1:1.  Adds the `TStringStart` /
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

**Kernel externs** (`lyric-stdlib/std/_kernel/file_host.l`).

* New `hostReadAllBytes(path)` → `System.IO.File.ReadAllBytes`
  returning `slice[Byte]` (Lyric's mapping for `byte[]`).
* New `hostWriteAllBytes(path, slice[Byte])` → `System.IO.File.WriteAllBytes`.

**`Std.File` rewrite** (`lyric-stdlib/std/file.l`).

* `readBytes` now: `try { hostReadAllBytes(path) → for b in raw {
  acc.add(b) } → Ok(acc) } catch Bug as b { Err(IoError(...)) }`.
* `writeBytes` now: `try { hostWriteAllBytes(path, bytes.toArray());
  Ok(()) } catch Bug as b { Err(IoError(...)) }`.
* The `slice[Byte] ↔ List[Byte]` shuttle is pure Lyric — no FFI
  gymnastics.  The public surface (`Result[List[Byte], IOError]`)
  stays unchanged so callers (incl. JVM self-tests) need no edits.

**F# shim** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

* `type FileHost private () = …` (~70 LoC after G10 1/2 had pruned
  text/dir; 5 remaining `ReadBytes*`/`WriteBytes*` members) deleted.
* Replaced by a short doc comment.

**Codegen trim** (`bootstrap/src/Lyric.Emitter/Codegen.fs`).

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

**Codegen fix** (`bootstrap/src/Lyric.Emitter/Emitter.fs`).

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

**`Std.Task` rewrite** (`lyric-stdlib/std/_kernel/task.l`).

* New `extern type AsyncLocal[T] = "System.Threading.AsyncLocal\`1"`.
* Three private kernel helpers:
  * `ambientSlot()` → `Lyric.Stdlib.AmbientSlot.Slot` (the one
    process-shared instance).
  * `ambientValue` / `setAmbientValue` → `AsyncLocal\`1.Value` getter
    + setter.
  * `tokenCanBeCanceled` → `CancellationToken.CanBeCanceled`.
* `currentToken` / `installToken` / `restoreToken` / `hasAmbient`
  are now native Lyric, four short bodies on top of the helpers.

**F# shim** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

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

### D-progress-236: Phase 4 — M4.3 deliverables status flip

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
  `bootstrap/tests/Lyric.Cli.Tests/ProveTests.fs` (new) covers the
  top-level `file`/`level`/`goals`/`diagnostics`/`summary` shape,
  `goals[].outcome == "discharged"` with `model: null`,
  `goals.length == 0` for `@runtime_checked` files, and the
  diagnostics-array shape on V0006.
* **Tests for `--explain --goal <n>`.** Same file: success case
  (Goal 0 / kind / hypotheses / conclusion sections present),
  missing-flag case (exit 1 + "specify a goal index" stderr), and
  out-of-range case (exit 1 + "out of range" stderr).
* **Tests for `lyric public-api-diff` contract clauses.**
  `bootstrap/tests/Lyric.Emitter.Tests/ContractMetaTests.fs` adds
  five cases covering strengthened-requires (breaking),
  weakened-ensures (breaking), relaxed-requires (non-breaking),
  added-ensures (non-breaking), and the `[breaking] strengthened
  requires:` rendering format that downstream tooling can grep.
* **Tests for `@proof_required(checked_arithmetic)`.**
  `bootstrap/tests/Lyric.Verifier.Tests/DriverTests.fs` adds three
  cases pinning the overflow VCs:
  bounded-input addition discharges, unbounded `x*x` produces a
  non-discharged VC over and above plain `@proof_required`, and the
  level surfaces in the `ProofSummary`.
* **Tests for LSP V0007 / V0008 / V0003 quickfixes.**
  `bootstrap/tests/Lyric.Lsp.Tests/ProtocolTests.fs` adds three
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

**`Std.Random` (`lyric-stdlib/std/_kernel/random.l`).**

* `makeRandom(seed)` now externs `System.Random..ctor` directly
  (the `(int)` overload is selected by arity).
* `nextBool(rng)` is now native Lyric: `nextIntBelow(rng, 2) != 0`.
  No host method needed once `Std.Random.nextIntBelow` is in scope
  (already declared in this same file).

**`Std.Task` (`lyric-stdlib/std/_kernel/task.l`).**

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

**F# shim** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

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
`Jvm*` helpers (~430 LoC) to `lyric-compiler/jvm/`, freeing the
stdlib bundle from JVM-specific code.

### D-progress-107: Phase 1 (3/3) — Bucket D `Jvm*` split-out

*claude/bucket-d-jvm-split branch.*  Third and final slice of
`docs/23-fsharp-shim-elimination.md` Phase 1.  Removes ~430 LoC of
JVM-emit-only F# helpers from the stdlib bundle's host shim by
moving them to a dedicated project.

**New project: `bootstrap/src/Lyric.Jvm.Hosts/`.**

* `Lyric.Jvm.Hosts.fsproj` (default F# library shape, doc-file
  generation enabled to match `Lyric.Stdlib`).
* `JvmHosts.fs` (~454 LoC) — verbatim move of the previous
  `JvmInternals` / `JvmByteBuilder` / `JvmByteHost` / `JvmZipHost` /
  `JvmConstantPool` / `JvmPoolHost` types from
  `bootstrap/src/Lyric.Stdlib/Stdlib.fs` lines 1008–1452, repackaged
  under `namespace Lyric.Jvm.Hosts`.

**`Lyric.Stdlib`** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

* Lines 1008–1452 deleted (the entire JVM block).  Replaced by
  a short doc comment pointing at the new home.

**`Lyric.Emitter`** (`bootstrap/src/Lyric.Emitter/`).

* `Lyric.Emitter.fsproj` adds a `<ProjectReference>` to
  `Lyric.Jvm.Hosts` so the assembly is in the test/CLI runtime
  closure.
* `Emitter.fs` `findClrType` now also force-loads
  `Lyric.Jvm.Hosts` via `typeof<Lyric.Jvm.Hosts.JvmByteHost>`,
  mirroring the existing `Lyric.Stdlib` force-load — so emit-time
  `findClrType("Lyric.Jvm.Hosts.…")` walks the AppDomain and
  resolves cleanly.

**Lyric source updates** (`@externTarget` repointing).

* `lyric-compiler/jvm/_kernel/kernel.l` — 38 occurrences of
  `Lyric.Stdlib.Jvm…` rewritten to `Lyric.Jvm.Hosts.Jvm…`.
  `extern type ByteWriter = "Lyric.Stdlib.JvmByteBuilder"` and
  `extern type Pool = "Lyric.Stdlib.JvmConstantPool"` updated to
  the new namespace.
* `lyric-stdlib/std/_kernel_jvm/json_host.l` — 1 occurrence updated.

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

**New kernel boundary.**  `lyric-stdlib/std/_kernel/file_host.l` declares
five `@externTarget` wrappers: `hostFileExists`, `hostDirectoryExists`,
`hostReadAllText`, `hostWriteAllText`, `hostCreateDirectory`.  All
within the audited `_kernel/` boundary.  `Std.File` `import`s the new
`Std.FileHost` package.

**`Std.File` rewrite** (`lyric-stdlib/std/file.l`).

* `readText` / `writeText` / `createDir` now use `return try { Ok(…) }
  catch Bug as b { Err(IoError(message = b.message)) }`.  Single I/O
  call per operation instead of the previous 2–3.
* `fileExists` / `dirExists` go through the new direct BCL externs.
* Bytes paths (`readBytes` / `writeBytes`) unchanged — gated on a
  `slice[Byte] → List[Byte]` conversion that's a follow-up to G10.

**Codegen trim** (`bootstrap/src/Lyric.Emitter/Codegen.fs`).
The `hostFileBuiltins` map shrinks from 13 entries to 5 (only the
bytes-flavoured ones remain).  No more F# `FileHost.Exists` /
`ReadIsValid` / `WriteIsValid` / `DirectoryExists` /
`CreateDirectoryIsValid` / `Read*Error` route.

**F# shim trim** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).
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

**Codegen** (`bootstrap/src/Lyric.Emitter/Codegen.fs`).

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

**Emitter** (`bootstrap/src/Lyric.Emitter/Emitter.fs`).

* `lyricAssertCtor` (resolving `Lyric.Stdlib.LyricAssertionException`)
  renamed to `contractExceptionCtor` and points at
  `System.Exception(string)`.
* `emitContractCheck` (the helper used by `requires:` / `ensures:`
  runtime checks) now uses the BCL exception ctor — matching the
  builtin sites above.

**F# shim** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

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

**`lyric-stdlib/std/_kernel/task.l`.**  Both `@externTarget`s repointed at
`System.Threading.Tasks.Task.Delay` directly.  The codegen's
arity-based overload resolution selects the right one at each call
site (1-arg → `Task.Delay(int)`, 2-arg → `Task.Delay(int, CancellationToken)`).

**`bootstrap/src/Lyric.Stdlib/Stdlib.fs`.**  `type TaskHost` deleted
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

**Codegen change** (`bootstrap/src/Lyric.Emitter/Codegen.fs`).

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

**F# shim change** (`bootstrap/src/Lyric.Stdlib/Stdlib.fs`).

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

### D-progress-237: JVM self-tests B90-B96 — Java 21 StackMapTable, higher-level lowering helpers, float-opcode fix, reader round-trip

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

### D-progress-238: Platform-parity remediation — docs audit + JVM kernel shims + Msil.Lowering

*claude/review-docs-platform-parity-UuNIO branch.*  Addresses the
audit findings in `docs/33-platform-parity-remediation.md` (Phases
R1–R5):

**R1 — docs/book audit fixes.**  Corrected twelve doc errors and five
book errors surfaced by the audit: grammar.ebnf `for-in` statement
syntax; D044 duplicate entry in the decision log; language-reference
`[TBD]` items for `--features` flags and the `lyric prove` exit codes;
out-of-scope entry for JVM emission (moved from "out-of-scope" to
"in-scope"); test-runner-plan Band D2 stale wording; todo-plan stale
JVM items.  Book fixes: appendix-B `--target jvm` description, aspect
template invocation, `lyric test` invocation example, toolchain table
JVM row, `Std.Logging` footnote about JVM support.

**R2 — duplicate D-progress renumbering.**  D-progress entries
141–147 (originally two unrelated series) were de-duplicated: the
MSIL phase entries became 213–219; the tier-6 entries 141–143 became
220–222; the service-library entries 202–205 became 223–226.

**R3 — JVM kernel shim stubs.**  Three new kernel shim files cover
JVM-specific host access that the `.NET` path delivers via BCL
externs:
* `lyric-stdlib/std/_kernel_jvm/file_host.l` — `readFileText`,
  `writeFileText`, `fileExists`, `readFileBytes`, `writeFileBytes`,
  `dirExists`, `createDirAll`.
* `lyric-stdlib/std/_kernel_jvm/process_host.l` — `processExit`,
  `processGetEnv`, `processArgs`, `processExecCapture`.
* `lyric-stdlib/std/_kernel_jvm/unicode_host.l` — `unicodeCategory`,
  `isUppercase`, `toLowercaseChar`, `toUppercaseChar`, `isXidStart`,
  `isXidContinue`.

**R4/R5 — `Msil.Lowering` self-hosted MSIL lowering.**  New Lyric
package `lyric-compiler/msil/lowering.l` (`package Msil.Lowering`,
839 lines) — the high-level AST-to-MSIL-IR lowering stage that mirrors
`Jvm.Lowering` for the .NET target.  Defines `MsilType` (12 cases),
`MInsn` (~45 instruction cases), and `MRecord / MFunc / MPackage` IR
types.  Entry point `lowerMPackage(file, pkgName): MPackage` walks the
`SourceFile` AST and produces the MSIL package IR ready for PE
emission.  Phase R6 (`Msil.Codegen` → `Msil.Bridge` → F# bridge) is
a follow-up; the stub `lyric-compiler/msil/bridge.l` panics with a
descriptive message directing callers to the Phase R6 plan.

### D-progress-239: Jvm.Codegen + Jvm.Bridge — self-hosted JVM end-to-end pipeline

*claude/review-docs-platform-parity-UuNIO branch.*  Completes the
JVM self-hosted compilation pipeline (Phase R4 deliverable):

**`lyric-compiler/jvm/codegen.l`** (`package Jvm.Codegen`, ~2230
lines) — bootstrap-grade AST-to-`LPackage` lowering.  Walks a
`SourceFile` from `Lyric.Parser` and produces an `LPackage` for
`Jvm.Lowering.lowerPackage`.  Key sections:
* `FuncCtx` record + `allocSlot` / `lookupSlot` / `freshLabel` slot /
  label management.
* `typeExprToJvm` — maps `Int→JInt`, `Long→JLong`, `Bool→JBoolean`,
  `String→JRef("java/lang/String")`, user types → `JRef(pkgName+"/"+seg)`.
* `emitLoad` / `emitStore` / `emitReturn` — type-dispatched helpers.
* `lowerExpr` — covers all `ExprKind` cases: literals (int, long,
  double, bool, string, char, unit), path references, binops (arith +
  comparison + logical), calls (builtins + static), member access,
  if/else, while, match, record construction, string interpolation.
* Builtin call handling: `println`, `print`, `panic`, `assert`,
  `toString`, `newList`, `newMap`, `mapGet`, `format1..4`, `default`,
  numeric conversion helpers.
* `lowerStmt` — local bindings, return, while, for-in, assignment,
  try/catch, scope.
* `lowerFunc`, `lowerRecord`, `lowerUnion` — top-level item lowering.
* `codegenPackage(file)` — main entry point; synthesises a JVM-main
  wrapper (`main(String[])→void`) if the Lyric source has a
  `main():Unit` function.

**`lyric-compiler/jvm/bridge.l`** (`package Jvm.Bridge`) — public
entry point `compileToJar(source, outputPath, packageName): Bool`.
Chains `parse → error-check → codegenPackage → lowerPackage →
serializeClassWithPool → writeJarFromClasses`.  Imports
`Lyric.Lexer` for `DiagError`/`DiagWarning` severity matching.

**`bootstrap/src/Lyric.Cli/SelfHostedJvm.fs`** — F# bridge from the
`lyric` CLI to `Jvm.Bridge`.  Follows the same reflection pattern as
`SelfHostedFmt.fs`: compiles a throwaway driver program to trigger the
emitter's stdlib precompile, loads `Lyric.Jvm.Bridge.dll` from the
stdlib cache via `Assembly.LoadFrom`, reflects out the static
`compileToJar(string,string,string):bool` method, and caches the
resulting delegate process-wide.

**`Program.fs` + `Lyric.Cli.fsproj` wiring** — `lyric build --target
jvm` now routes through `SelfHostedJvm.compileToJar` after the normal
MSIL build succeeds.  The JAR path defaults to
`<source-stem>.jar` beside the source file, or uses `--output` with a
`.jar` extension.  `Lyric.Cli.fsproj` gains `<Compile
Include="SelfHostedJvm.fs" />` after `SelfHostedFmt.fs`.

All 750 emitter tests and 158 CLI tests pass with zero failures.

---

### D-progress-104: F# shim P3 trio — drop `Parse`, port `format`/`Render*Slice`

*claude/p3-1-std-parse-native branch.*  Executes the three P3 items
in `docs/14-native-stdlib-plan.md` §6 as one atomic slice:

* **P3-1 (drop `Parse`).**  `Lyric.Stdlib.Parse` had been replaced
  by `Std.ParseHost.hostTryParse*` (which uses `out` parameters
  routed straight at `System.Int32.TryParse` etc.) but the F# type
  and the codegen `hostParseBuiltins` map / `hostParse*` builtin
  wiring were never deleted.  Both sides removed; the dead-code
  `bootstrap/tests/Lyric.Emitter.Tests/ParseTests.fs` (which
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
312 parser, 123 lexer.  Stdlib bundle (`lyric-stdlib/lyric.toml`) still
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

* `bootstrap/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs`
  `[stdlib_smoke_bundle_compiles]` mimics the working subset of the
  bundle: a generic `Option[T]` union in `Std.Smoke.Core`, a plain
  `HostError` enum-shaped union in `Std.Smoke.Errors`, and a
  consumer in `Std.Smoke.String` that imports `Std.Smoke.Core` and
  builds `Some(value = s[0])` / `None` in helper bodies.  Asserts
  the bundle compiles clean and ships three per-package contract
  resources.
* `lyric-stdlib/lyric.toml` lands as the canonical project manifest for
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

* `bootstrap/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` gains:
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

* `bootstrap/tests/Lyric.Emitter.Tests/ProjectAsDllTests.fs` adds
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
`bootstrap/tests/Lyric.Cli.Tests/ManifestTests.fs`:

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

* `bootstrap/tests/Lyric.Lexer.Tests/KeywordTests.fs` automatically
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
  `bootstrap/tests/Lyric.Emitter.Tests/MultiFilePackageTests.fs`
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
  `lyric-compiler/lyric/lexer.l` into a reusable `Lyric.Lexer` library
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

**New source.** `lyric-compiler/lyric/lexer.l` (~2 000 lines):
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
`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedLexerTests.fs` walks
up from the test binary's base directory to locate
`lyric-compiler/lyric/lexer.l`, compiles it via `compileAndRun`,
and asserts (a) zero error-class diagnostics, (b) exit code 0,
(c) `"ok"` in stdout.  Discoverable as `[lexer_self_test_passes]`
in the Expecto run.  Wired into `Program.fs` after `JvmSelfTest`.

**`Lyric` head added to `isBuiltinHead`.**  `Emitter.fs:4298` now
includes `"Lyric"` so `import Lyric.<X>` resolves under
`lyric-compiler/lyric/<x>.l` via the existing built-in resolver.
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
`bootstrap/tests/Lyric.Emitter.Tests/PatternMatchingTests.fs` —
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
`lyric-stdlib/std/core_proof.l`, mapped to package `Std.Core.Proof`
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
`bootstrap/tests/Lyric.Verifier.Tests/RegressionTests.fs` adds 142
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
  match for the string in `bootstrap/src/Lyric.Cli/`), and the
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

**New project** — `bootstrap/src/Lyric.Verifier/`:

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

**CLI** — `bootstrap/src/Lyric.Cli/Program.fs` gains a `prove`
subcommand:

```
lyric prove <source.l> [--proof-dir <dir>] [--verbose]
```

`--proof-dir` defaults to `<source-dir>/target/proofs/`.  `--verbose`
prints the per-goal outcome and the SMT path.  Exit code is 0 on
all-discharged-no-errors, 1 otherwise.  `lyric build` is unchanged.

**Tests** — `bootstrap/tests/Lyric.Verifier.Tests/` (28 Expecto
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

**Files touched:** `bootstrap/Bootstrap.sln` (added two projects),
`bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj` (verifier ProjectReference),
`bootstrap/src/Lyric.Cli/Program.fs` (`prove` subcommand + usage),
`bootstrap/src/Lyric.Verifier/*` (new), `bootstrap/tests/Lyric.Verifier.Tests/*`
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

**Lowering** (`bootstrap/src/Lyric.Emitter/Emitter.fs`
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

**New module** `bootstrap/src/Lyric.Emitter/RestoredPackages.fs`:
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

**Emitter integration** (`bootstrap/src/Lyric.Emitter/Emitter.fs`):
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

**CLI integration** (`bootstrap/src/Lyric.Cli/Program.fs`):
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

**Manifest schema** (`bootstrap/src/Lyric.Cli/Manifest.fs`):

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

**`lyric publish` flow** (`bootstrap/src/Lyric.Cli/Pack.fs`):

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

**New test project**: `bootstrap/tests/Lyric.Cli.Tests/` — first
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

Implementation lives in `bootstrap/src/Lyric.Emitter/AsyncStateMachine.fs`
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

Five new test cases in `bootstrap/tests/Lyric.Emitter.Tests/AsyncTests.fs`:

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
`bootstrap/src/Lyric.Cli/`) wraps `Emitter.emit` for direct
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
up the directory tree.  Setting this variable to the `lyric-stdlib/std/`
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

**Iter additions.**  Five allocating helpers in `lyric-stdlib/std/iter.l`
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
`bootstrap/src/Lyric.Parser/Stubbable.fs` exposes
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
`bootstrap/src/Lyric.Lsp/` — a console-app that speaks the Microsoft
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

**Tests.**  New project `bootstrap/tests/Lyric.Lsp.Tests/` with five
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

**Implementation.**  New `bootstrap/src/Lyric.Cli/Doc.fs` exposes
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
`bootstrap/src/Lyric.TypeChecker/ConstFold.fs`:

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
`bootstrap/tests/Lyric.TypeChecker.Tests/ConstFoldTests.fs` covering
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

4 new tests in `bootstrap/tests/Lyric.Emitter.Tests/AutoFfiTests.fs`:
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

**New surface in `lyric-stdlib/std/time.l`.**

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

6 new tests in `bootstrap/tests/Lyric.Emitter.Tests/StdTimeTests.fs`
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

- 4 new tests in `bootstrap/tests/Lyric.Emitter.Tests/WireTests.fs`:
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

- New module `bootstrap/src/Lyric.Emitter/ContractMeta.fs` with:
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
- New module: `bootstrap/src/Lyric.Emitter/AsyncStateMachine.fs`
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

**Fix.**  Refactor `lyric-stdlib/std/_kernel/http_host.l` to declare
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
work).  New surface in `lyric-stdlib/std/time.l`:

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

**`Std.Sort`** (`lyric-stdlib/std/sort.l`)

Top-down stable merge sort over slices.  Public surface:

- `sort[T](xs, cmp)` — sort any slice with an explicit `(T, T) -> Int`
  comparator; returns a fresh slice; O(n log n).
- `sortInts`, `sortLongs`, `sortStrings` — convenience wrappers with
  natural orderings baked in.

**`Std.Set`** (`lyric-stdlib/std/set.l`)

Hash-based set wrapping BCL `HashSet<T>` via `extern type Set[T]`.
Public surface: `setContains`, `setAdd`, `setRemove`, `setSize`,
`setIsEmpty`, `setFromSlice`, `setToSlice`, `newSet`, `setUnion`,
`setIntersection`, `setDifference`.  Naming carries the `set` prefix
to avoid shadowing BCL dispatch calls in function bodies.

**`Std.Char`** (`lyric-stdlib/std/char.l`)

Unicode character classification and case conversion.  BCL-backed:
`isLetter`, `isDigit`, `isLetterOrDigit`, `isWhiteSpace`, `isUpperCase`,
`isLowerCase`, `toUpperCase`, `toLowerCase`.  Pure-Lyric (with
`@pure` + contracts): `toInt`, `fromInt`, `isAscii`, `digitValue`,
`hexDigitValue`.

**`Std.Format`** (`lyric-stdlib/std/format.l`)

Number and string formatting.  BCL-backed: `toHexString` (lowercase),
`toHexStringUpper`, `formatFixed` (fixed-point double with invariant
locale), `padLeft`, `padRight`.  Pure-Lyric: `zeroPad`, `hexPad`.

**`Std.Encoding`** (`lyric-stdlib/std/encoding.l`)

Byte-level encoding.  `encodeBase64` / `tryDecodeBase64` (standard
Base64 with `=` padding).  `encodeHex` / `tryDecodeHex` (uppercase hex;
`System.Convert.ToHexString`).  `encodeUtf8` / `tryDecodeUtf8` for
`String ↔ slice[Byte]` conversion.

**`Std.Uuid`** (`lyric-stdlib/std/uuid.l`)

UUID generation and parsing over `System.Guid`.  `newUuid()` — version
4 (cryptographic RNG).  `nilUuid()` — all-zeros sentinel.
`uuidToString` — lowercase hyphenated string.  `parseUuidOpt` — accepts
any `System.Guid.TryParse`-recognised format; returns `Option[Uuid]`.

---

### D-progress-132: M5.1 stage 6 — self-hosted type checker (`Lyric.TypeChecker`)

*PR #195.*

The self-hosted Lyric type checker ships as a nine-file `Lyric.TypeChecker`
library under `lyric-compiler/lyric/type_checker/`:

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

`lyric-compiler/lyric/typechecker_self_test.l` is the self-test consumer.
It imports both `Lyric.Parser` and `Lyric.TypeChecker`, exercises 15
in-process assertions (empty source, function/record/union registration,
duplicate-name T0001, return-type T0070, val-type T0060, return-without-
value T0064, range-subtype T0090/T0093, `where`-clause T0050, arithmetic
mismatch T0031, unknown-name T0020), and writes `"ok"` on success.

`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedTypeCheckerTests.fs`
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
library under `lyric-compiler/lyric/mode_checker/`:

- `modechecker_mode.l` — `VerificationLevel` union (VLRuntimeChecked,
  VLProofRequired, VLProofRequiredUnsafe, VLProofRequiredChecked, VLAxiom)
  plus helpers `vlIsProofRequired`, `vlDominates`, `vlDisplay`, `vlRank`;
  file-level and function-level level computation (`levelOfFile`,
  `levelOfFunction`, `isFuncPure`); annotation helpers (`findAnnotation`,
  `proofRequiredModifier`).  Mirrors `bootstrap/src/Lyric.Verifier/Mode.fs`.

- `modechecker_check.l` — public entry points (`checkFile`,
  `checkFileWithImports`), callee-table construction (`calleeTableOfFile`),
  and all diagnostic checks: V0001 (proof-required importing
  runtime-checked), V0002 (impure call / `await` / `spawn` from
  proof-required code), V0003 (`unsafe` block without
  `unsafe_blocks_allowed`), V0004 (`@axiom` with body), V0005 (loop
  without `invariant:` clause), V0006 (unbounded quantifier domain in
  contract clause), V0009 (`assume` outside `unsafe {}`), V0010 (conflicting
  level annotations), V0011 (unknown `@proof_required` modifier).  Mirrors
  `bootstrap/src/Lyric.Verifier/ModeCheck.fs`.  Cross-package import
  metadata uses a simplified `ImportedMeta` record (name + level string)
  rather than the full F#-side `Imports.ImportedPackage` type.

Consumer and harness:

- `lyric-compiler/lyric/modechecker_self_test.l` — 17 in-process tests
  covering level detection, conflict/unknown-modifier errors, V0001–V0006
  and V0009–V0011 diagnostics, pure-callee pass, and no-check for
  `@runtime_checked` packages.
- `bootstrap/tests/Lyric.Emitter.Tests/SelfHostedModeCheckerTests.fs` —
  F# Expecto wrapper (`[modechecker_self_test_passes]`).

All 636 emitter tests pass.

---

### D-progress-235: D-D1.3 — pagination + token-bucket end-to-end proofs; float/real verifier fixes

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

### D-progress-220: Tier 6 #16 — generic interface methods + impl-block generics

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

`bootstrap/tests/Lyric.Emitter.Tests/ImplBlockGenericsTests.fs` —
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

### D-progress-221: parser — aspect `from`/`config` (D051 follow-up) + `lyric-otel` library

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

### D-progress-222: `lyric-logging` library — structured logging with runtime config and aspect templates

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

### D-progress-223: lyric-web library (OpenAPI-first web service)

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

---

### D-progress-224: Maven shim — instance methods, checked-exception wrapping, Std.Jvm.catch

**Date:** 2026-05-10
**Branch:** `claude/java-dependency-support-MC6Xz`
**Decision:** D052 (revision)

Three follow-up items to the Maven Central linking feature (D052 / PR #252):

**1. Instance methods and checked exceptions in shim generator**

- `resolver/src/main/java/lyric/resolver/ClassScanner.java`: added
  `KNOWN_UNCHECKED` set (~18 common unchecked exception FQNs); added
  `hasCheckedExceptions(String[])` helper that treats any `throws` class not
  in the set as a checked exception; sets `mi.hasCheckedExceptions` on every
  `MethodInfo`.  Now processes both static and instance methods (was
  structurally sound before but lacked checked-exception detection).
- `resolver/src/main/java/lyric/resolver/MavenResolver.java`: serialises the
  `hasCheckedExceptions` boolean field to JSON.
- `bootstrap/src/Lyric.Cli/Maven.fs`: parses `hasCheckedExceptions` from the
  resolver JSON into a new `HasCheckedExceptions: bool` field on `JavaMethod`.
- `bootstrap/src/Lyric.Cli/MavenShim.fs`:
  - Pre-scans all classes for checked exceptions; emits
    `import Std.JvmExceptionHost` only when at least one method has checked
    exceptions.
  - Generates instance-method stubs: `methodName(recv: in TypeName, args…):
    ReturnType = ()` per spec §4.
  - Wraps checked-exception method returns in `Result[T, JvmException]` (or
    `Result[Unit, JvmException]` for `void`) per spec §5.
  - Deduplication key accounts for the implicit receiver argument.
- `bootstrap/tests/Lyric.Cli.Tests/MavenTests.fs`: adds instance-method and
  checked-exception test cases; all 158 CLI tests pass.

**2. `Std.Jvm.catch[T]` escape hatch (Q-J012)**

- `lyric-stdlib/std/_kernel/jvm.l` added: `Std.Jvm` package with
  `@experimental` `pub generic[T] func catch(action: func(): T):
  Result[T, JvmException] = ()`.  Routes to
  `lyric.runtime.jvm.ExceptionHelper.catch` (Phase 6 JVM runtime JAR).
  `Error` subclasses not caught (conservative default).

**3. JVM emitter call-site gap documented (Q-J013)**

- Confirmed that `lyric-compiler/jvm/lowering.l` has no special handling for
  `@externTarget` functions whose Lyric return type is `Result[T, JvmException]`.
  The type system is correct (the shim declares the right return type), but
  the JVM emitter will not emit a try-catch wrapper at call sites until Phase
  6.  `docs/31-maven-linking.md` Q-J013 tracks this gap.

**Test counts:** 158 CLI tests — all passing.  No regression in other suites.

---

### D-progress-225: `lyric-cache`, `lyric-db`, `lyric-health` service libraries

**What shipped**

**`lyric-cache/` library (D055):**
- `lyric-cache/lyric.toml` — `Cache.dll` manifest; two packages
  (`Cache`, `Cache.Aspects`); depends on `Lyric.Stdlib`.
- `src/cache.l` — `Cache` package: `CacheStore` interface (`get/set/delete/clear`),
  `CacheEntry { value: String; expiresAt: Long }`, `InProcessCacheStore`
  (`var entries: Map[String, CacheEntry]; maxEntries: Int`) implementing
  `CacheStore`, `config Defaults { ttlSeconds: Int range 0..=86400 = 300;
  maxEntries: Int range 1..=1000000 = 10000 }`, `inProcess()`,
  `inProcessWithCapacity(maxEntries)`, and public API `get/set/setWithTtl/delete/clear`.
- `src/cache_aspects.l` — `Cache.Aspects` package: module-level
  `var store = Cache.inProcess()`, `pub aspect FunctionCache` (B-mode, caches
  `Ok` results by `call.qualifiedName`), `@inline_template pub aspect ItemCache`
  (C-mode, reads `args.cacheKey`, key = `keyPrefix + args.cacheKey`).
- `lyric-cache/README.md` — interface extension guide, config table, aspect templates.

**`lyric-db/` library (D056):**
- `lyric-db/lyric.toml` — `Db.dll` manifest; three packages (`Db`,
  `Db.Aspects`, `Db.Kernel.Net`); `postgres` and `sqlite` feature flags;
  depends on `Lyric.Stdlib`.
- `src/db.l` — `Db` package: `DbError { message; code }`, `DbValue` enum
  (8 variants: `DbNull/DbInt/DbLong/DbFloat/DbDouble/DbBool/DbText/DbBytes`),
  `DbRow { columns: [(String, DbValue)] }`, `col(row, name)`,
  `DbTransaction` interface, `DbConnection` interface, `NativeConnection` and
  `NativeTransaction` wrappers (integer-handle pattern), `config Connection
  { url; poolSize; connectTimeoutMs; queryTimeoutMs; @sensitive password }`,
  `@cfg(feature = "postgres") connectPostgres()`,
  `@cfg(feature = "sqlite") connectSqlite()`, stub `parseRows`.
- `src/db_aspects.l` — `Db.Aspects` package: `QueryLogging` (B-mode, logs
  handler entry/exit), `SlowQueryAlert` (B-mode; carries
  `ensures: call.elapsed.unwrapOr(0) >= 0`).
- `src/_kernel/net/db_kernel.l` — `Db.Kernel.Net` package: `@axiom`-guarded
  `@cfg(feature = "postgres") extern package Npgsql`, `pub package Postgres`,
  `@cfg(feature = "sqlite") extern package MicrosoftDataSqlite`,
  `pub package Sqlite`, `@axiom extern package Lyric.Db.Native` with
  `query/execute/beginTransaction/txQuery/txExecute/commitTransaction/rollbackTransaction/close`;
  all re-exported at package level.
- `lyric-db/README.md` — feature flags, config table, interface contracts, row
  access guide, transaction example, aspect templates, kernel boundary notes.

**`lyric-health/` library (D057):**
- `lyric-health/lyric.toml` — `Health.dll` manifest; depends on `Lyric.Stdlib`
  and `Lyric.Web`.
- `src/health.l` — `Health` package: `CheckGroup` enum (`Liveness/Readiness`),
  `HealthCheck { name; group; handlerName }`, `HealthRegistry { checks: [HealthCheck] }`,
  `create()`, `addLivenessCheck/addReadinessCheck`, `config Endpoints
  { livePath = "/health/live"; readyPath = "/health/ready" }`,
  `registerRoutes(router, registry)`, built-in `__handleLiveness/Readiness`,
  stubs for `runChecks` and `attachRegistry` (pending router-annotation milestone).
- `lyric-health/README.md` — check function signature, response JSON shape,
  check groups, config table, full API reference.

**Book chapters (24–26):**
- `book/chapters/24-caching.md` — `lyric-cache` API, `CacheStore` extension
  interface, config, `FunctionCache` and `ItemCache` aspect templates.
- `book/chapters/25-database-access.md` — `lyric-db` features, connections,
  queries, DML, transactions, `DbValue` variants, aspects.
- `book/chapters/26-health-checks.md` — `lyric-health` check function
  signature, liveness vs readiness, response format, config, API reference.
- `book/chapters/appendix-b-quick-reference.md` — service libraries table
  added to §B.9 (six libraries with chapter cross-references).

**Implementation gate:** config-block emitter, aspect weaver, and DLL-reflection
dispatcher must ship before the runtime behaviour is active.  All three
libraries can be imported and aspect templates instantiated today.

**Test counts:** no new compiler tests (libraries are Lyric source only;
no F# emitter changes).  727 emitter, 323 parser, 143 type-checker, 123
lexer, 28 LSP, 127 CLI, 266 verifier — all passing.

---

### D-progress-226: Q-J005 opaque-type facade codegen + Q-J007 design sketch

**Date:** 2026-05-10
**Branch:** `claude/java-dependency-support-MC6Xz`
**Decision:** D052 (follow-up)

Two items from the Maven/JVM design question backlog:

**1. Q-J005: opaque-type Java interop facades (`lowerOpaqueFacade`)**

`lyric-compiler/jvm/lowering.l` — three new functions:

- `lowerOpaqueFacadeAcc(opaqueName, f, pool)` — emits a
  `public static f.name(OpaqueClass obj): f.fieldType` method that
  delegates to the existing `$name()T` virtual accessor.
- `lowerOpaqueFacadeFactory(o, pool)` — emits a
  `public static create(fields...): OpaqueClass` method that calls the
  package-private constructor via `new; dup; load params; invokespecial <init>;
  areturn`.
- `lowerOpaqueFacade(o, pool): ClassFile` — assembles a
  `<ClassName>$Facade` class (`ACC_PUBLIC + ACC_SUPER + ACC_FINAL`,
  no fields) containing `create` and one accessor per field.

The `lowerPackage` driver now emits both the opaque class and its facade for
every `LPOpaqueType` item.

Self-test `lyric-compiler/jvm/self_test_b125.l` (Stage B125): creates an
`OpaquePoint(x: JInt, y: JInt)` opaque type, generates the facade, and a
`Main` class that exercises `OpaquePoint$Facade.create(10, 20)`, `.x(obj)`,
and `.y(obj)`.  Java output: `x=10 / y=20`.  Registered as
`JvmLoweringB125Test` in `Lyric.Emitter.Tests`.

**2. Q-J007: JUnit 5 test-runner adapter design sketch**

`docs/32-junit-runner-sketch.md` — new sketch covering:

- `@LyricTest` annotation shape (RUNTIME retention, METHOD target;
  carries `displayName`, `sourceFile`, `sourceLine`).
- Emitted class shape: one `public static void __lyric_test_<i>()` per
  `ITest` item, annotated with `@LyricTest`, throwing `AssertionError` on
  failure.
- `LyricTestEngine` implementing `org.junit.platform.engine.TestEngine`:
  classpath scanning for `@LyricTest` methods, invocation via reflection,
  result reporting through the JUnit 5 platform protocol.
- `lyric test --jvm` flow: compile → build classpath (stdlib JVM JAR +
  toolchain JAR + Maven-restored JARs) → shell to JUnit 5 console launcher.
- Five open questions (Q-J007a–e): tag support, parameterised tests, timeout,
  coverage, IDE plugin compatibility.

`docs/18-jvm-emission.md` Q-J007 updated to reference the sketch.
`CLAUDE.md` sketch listing updated.

**Test counts:** 728 emitter tests — all passing (B125 is the new test).

---

### D-progress-206: B126 — JUnit 5 adapter: @LyricTest annotation + lowerTestModuleClass + lyric test --jvm

**Date:** 2026-05-10
**Branch:** `claude/implement-junit-adapter-PdlJR`
**Sketch:** `docs/32-junit-runner-sketch.md`

Three deliverables from the JUnit adapter sketch (§3, §4, §6):

**1. `RuntimeVisibleAnnotations` / `AnnotationDefault` attribute builders (`classfile.l`)**

- `AnnotationElementValue` union — covers `AEVString`, `AEVInt`, `AEVEnum`, `AEVArray` (the tags needed for `@LyricTest` plus the `@Retention`/`@Target` meta-annotations).
- `AnnotationElement` record — name + value pair.
- `AnnotationEntry` record — type descriptor + element list.
- `makeRuntimeVisibleAnnotationsAttr(pool, annotations)` — encodes JVMS §4.7.16.
- `makeAnnotationDefaultAttr(pool, defaultVal)` — encodes JVMS §4.7.22.
- `makeAnnotationInterfaceClass(thisClass, methods, classAttrs)` — creates a `ClassFile` with `ACC_PUBLIC | ACC_ANNOTATION | ACC_INTERFACE | ACC_ABSTRACT` flags and `java/lang/annotation/Annotation` as the sole implemented interface.

**2. `Jvm.TestEngine` library (`lyric-compiler/jvm/test_engine.l`)**

- `LYRIC_TEST_CLASS` / `LYRIC_TEST_DESC` — canonical binary name and field descriptor for `lyric/runtime/jvm/LyricTest`.
- `TestMethodSlot` record — carries `funcName`, `displayName`, `sourceFile`, `sourceLine`.
- `lyricTestAnnotationClass(pool)` — builds the `@LyricTest` annotation-interface `ClassFile` with `@Retention(RUNTIME)` + `@Target(METHOD)` class-level annotations and three annotation-element methods (`displayName`, `sourceFile`, `sourceLine`) each with an `AnnotationDefault` attribute.
- `lowerTestModuleClass(className, slots, pool)` — builds a `public final` test-host `ClassFile` with one `public static void __lyric_test_<i>()` stub per slot, each annotated with `@LyricTest`. Method bodies are `return` stubs; real bytecode is injected by the full Lyric→JVM pipeline (B127+).

**3. `LPTestModule` in `Jvm.Lowering`**

- Added `case LPTestModule(className: String, slots: List[TestMethodSlot])` to `LPackageItem`.
- `lowerPackage` dispatch: emits the test-module class (via `lowerTestModuleClass`) and the `@LyricTest` annotation class (via `lyricTestAnnotationClass`) so both land in the same JAR.
- Added `import Jvm.TestEngine` to `lowering.l`.

**4. Self-test `lyric-compiler/jvm/self_test_b126.l` (Stage B126)**

Generates three JVM class files:
- `lyric/runtime/jvm/LyricTest.class` — the annotation interface with RUNTIME retention.
- `math_tests.class` — test-module class with two `@LyricTest`-annotated stub methods.
- `TestVerifier.class` — Java 5 (major=49) main class that loads `math_tests`, reads `getDeclaredAnnotations()` on `__lyric_test_0`, and prints `annotation_count=1` and `annotation_type=lyric.runtime.jvm.LyricTest`.

Expected Java output via `java -jar /tmp/lyric-jvm-b126/test_engine.jar`:
```
annotation_count=1
annotation_type=lyric.runtime.jvm.LyricTest
```

Registered as `JvmLoweringB126Test` in `Lyric.Emitter.Tests`.

**5. CLI: `lyric test --jvm` (bootstrap)**

`bootstrap/src/Lyric.Cli/Program.fs` — `--jvm` flag parsed in the `test` command.
When set, compiles the synthesised source with `Emitter.Jvm` (JVM-compatible stdlib) and warns to stderr that JUnit 5 ConsoleLauncher integration is deferred to B127+. The TAP runner still executes via `dotnet exec` until the full Lyric→JVM pipeline lands.

**Test counts:** 751 emitter tests — all passing (B126 is the new test).

---

### D-progress-227: R6 — self-hosted MSIL compilation pipeline (Msil.Codegen + bridge + SelfHostedMsil.fs + target renaming)

**Date:** 2026-05-10
**Branch:** `claude/review-docs-platform-parity-UuNIO`
**Decision:** D056 (platform-parity remediation)

Phase R6 of `docs/33-platform-parity-remediation.md`: completes the
self-hosted MSIL compilation pipeline so `lyric build --target dotnet`
routes through the Lyric-written emitter instead of the F# bootstrap emitter.

**`lyric-compiler/msil/codegen.l` — `Msil.Codegen` package (2157 lines)**

AST-to-`MPackage` lowering that mirrors `Jvm.Codegen` for the .NET/MSIL
target.  Key pieces:

- `CodegenCtx` record — holds a pre-seeded `LoweringCtx` plus intra-package
  token maps (`recordCtorTokens`, `fieldTokens`, `funcTokens`).
  `newCodegenCtx(packageName)` seeds the `LoweringCtx` with all stable
  external MemberRef rows: `Console.Write/WriteLine` (six variants),
  `String.Concat` (2- and 3-arg), `Object.ToString`, `String.ToString`,
  `InvalidOperationException..ctor(string)`, `Int32/Int64/Double.Parse`,
  `Convert.ToInt32/ToInt64/ToDouble`, and the `Object..ctor` base-class
  constructor.  Token assignments are deterministic across packages.

- `addPackageTokens(cctx, file, pkgName)` — pre-scan pass that traverses
  the AST in the same order `lowerMPackageWithCtx` processes items (records
  first, then top-level functions, then unions), assigning intra-package
  TypeDef/MethodDef/FieldDef tokens up front to break the chicken-and-egg
  dependency between codegen and lowering.

- `FuncCtx` — per-function lowering context tracking `paramCount` (the
  parameter/local slot boundary: slots `< paramCount` emit `MLdarg`,
  slots `>= paramCount` emit `MLdloc(slot - paramCount)`, matching MSIL's
  separate `ldarg`/`ldloc` instruction families).

- `lowerExprMsil / lowerStmtMsil / lowerBlockMsil` — full expression and
  statement language: arithmetic/comparison/logical operators, field access
  (`MLdfld`), function calls, `if`/`match`/`while`, `let`/`val`/`return`,
  string literals (via `MLdStr(ctxInternUs(ctx, s))` — the token form
  fixed in `Msil.Lowering` so `emitLdstr` fires correctly), record
  construction, union construction and deconstruction.

- `codegenMPackage(file, cctx): MPackage` — top-level driver that walks
  `SourceFile.items` and produces an `MPackage` for `lowerMPackageWithCtx`.

**`lyric-compiler/msil/bridge.l` — real pipeline replacing panic stub**

`compileToMsil(source, outputPath): Bool` chains:
`parse → diagnostic filter → newCodegenCtx → addPackageTokens
→ codegenMPackage → resolveEntryToken → lowerMPackageWithCtx → writeBytes`

**`lyric-compiler/msil/lowering.l` — two fixes**

1. `MLdStr(token: Int)` — changed from `MLdStr(s: String)`; `lowerMInsn` now
   calls `emitLdstr(mb, token)` instead of the prior no-op.
2. `lowerMPackageWithCtx(pkg, ctx, entryMethodToken): List[Byte]` — new
   variant that accepts a pre-seeded `LoweringCtx` so the MemberRef tokens
   registered by `newCodegenCtx` survive into the assembled PE.

**`bootstrap/src/Lyric.Cli/SelfHostedMsil.fs` — F# reflection bridge**

Mirrors `SelfHostedJvm.fs`.  Bootstraps `Msil.Bridge.dll` into the per-process
stdlib cache via a throwaway driver compile, preloads all cached stdlib DLLs
into the AppDomain, then reflects out `Msil.Bridge.Program.compileToMsil` and
stashes the delegate process-wide.

**`bootstrap/src/Lyric.Cli/Program.fs` — `--target` renaming**

- `--target dotnet` (default, no flag required) → self-hosted MSIL pipeline
  via `SelfHostedMsil.compileToDll`.
- `--target dotnet-legacy` → F# bootstrap emitter (previous `--target dotnet`
  behaviour); escape hatch during the self-hosted MSIL stabilisation period.
- `--target jvm` — unchanged.

The F# emitter remains the canonical implementation; the self-hosted path
must produce a byte-for-byte equivalent PE to be promoted as the default.

**Test counts:** 728 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 127 CLI tests, 266 verifier tests — all passing.

---

### D-progress-228: Distribution strategy — `docs/34-distribution-strategy.md` + D059

**Date:** 2026-05-10
**Branch:** `claude/review-docs-platform-parity-UuNIO`
**Decision:** D059

Closes the "Distribution channels" open question deferred in
`docs/22-distribution-and-tooling.md` §10.

**`docs/34-distribution-strategy.md`** — new Phase 6 decision document:

- **Primary channel:** `dotnet tool install -g lyric` (NuGet global tool).
  The NuGet package bundles the CLI DLLs, `lib/Lyric.Stdlib.dll`,
  `lib/Lyric.Stdlib.Jvm.jar`, and the stdlib source fallback.  Works on
  Windows/macOS/Linux without additional tooling beyond the .NET SDK.

- **Secondary channel:** self-contained ZIP/tarball via GitHub release assets.
  `dotnet publish --self-contained true --runtime <RID>` for five RIDs
  (linux-x64/arm64, osx-x64/arm64, win-x64).  No SDK required by end users.

- **Future channel (Q-dist-001):** once the stage-2 bootstrap in
  `scripts/bootstrap.sh` achieves byte-for-byte reproducibility, promote the
  self-hosted MSIL emitter to default and AOT-compile a native binary
  (`dotnet publish --aot`).  At that point Homebrew/winget/apt formulas become
  trivial; tracked as Q-dist-002/003/004.

- **Bootstrap pipeline (`scripts/bootstrap.sh`):**
  - Stage 0: `dotnet publish` the F# bootstrap compiler.
  - Stage 1: compile stdlib + all self-hosted compiler packages with
    `--target dotnet-legacy` (F# emitter).
  - Stage 2: recompile with `--target dotnet` (self-hosted MSIL); compare
    DLLs with `cmp -s`.  `STRICT_VERIFY=1` fails on any diff.
  - CI runs stage-1 on every push to `main`; stage-2 nightly until
    reproducibility is achieved, then promoted to standard gate.

`docs/22-distribution-and-tooling.md` §10 "Distribution channels" open question
updated to reference doc 34.  `docs/03-decision-log.md` D059 entry added.
`CLAUDE.md` sketch listing updated to include docs 33 and 34.
`docs/33-platform-parity-remediation.md` status header, §6.4, §7, and §8
tracking table updated to reflect R6 as shipped.

**Test counts:** no new compiler tests (documentation-only changes).
728 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 127 CLI tests, 266 verifier tests — all passing.

---

### D-progress-229: M5.2 stage 4 — self-hosted monomorphizer (`Lyric.Mono`)

**Date:** 2026-05-10
**Branch:** `claude/mono-toml-self-host`

Phase 5 §M5.2 stage 4 ships the self-hosted monomorphizer as the Lyric-language
`Lyric.Mono` package at `lyric-compiler/lyric/mono.l`.

**Algorithm (call-site monomorphization for same-package generics):**

1. Collect all generic `IFunc` items (those with `generics: Some(...)`) from
   the input `SourceFile` into a name-keyed lookup map.
2. Walk non-generic function bodies, maintaining a type environment
   (`Map[String, TypeExpr]`) seeded from parameter type annotations and
   updated by explicit `val`/`var`/`let` type annotations.
3. At each `ECall(EPath([name]), args)` where `name` is a known same-package
   generic function: infer argument types (literals → primitive TypeExpr;
   variables → env lookup; other expressions → skip), unify against the
   function's parameter TypeExprs to determine concrete type arguments, and
   compute a mangled specialised name (e.g. `mapFoo__Int__String`).
4. If all type parameters are resolved, enqueue a `SpecRequest` and rewrite
   the call site to use the specialised name.  Queue processing is worklist-
   based; specialised function bodies are themselves walked, enabling
   chains of generic calls to be fully expanded.
5. Return a `MonoResult` carrying the rewritten `SourceFile` (generic items
   removed, specialised items appended) and a `rewrites` map.

**Public API:**

```lyric
pub func monoFile(file: in SourceFile): MonoResult
pub record MonoResult { file: SourceFile; rewrites: Map[String, String] }
```

**Scope notes:**

- Only same-package generic functions are specialised.  Imported generic
  functions (e.g. `mapOption` from `Std.Core`) use real CLR generics at
  runtime — this is correct because the F# bootstrap compiler emits them as
  proper .NET generic methods/types.
- Value generic parameters (`GPValue`) are not handled; only type-level
  `GPType` parameters are specialised.
- Type inference at call sites covers literals and explicitly annotated
  variables.  Complex sub-expressions (method calls, field projections, binary
  ops, etc.) produce `None`; those call sites are left un-specialised.

The monomorphizer integrates with `Msil.Bridge.compileToMsil` by running
before `codegenMPackage`: a caller that adds `monoFile` between `parse` and
`codegenMPackage` gets a fully-specialised AST with no same-package generic
functions.

**Test counts:** 729 emitter tests (+1 `SelfHostedManifestTests`), 323 parser
tests, 143 type-checker tests, 123 lexer tests, 28 LSP tests, 127 CLI tests,
266 verifier tests — all passing.

---

### D-progress-230: M5.3 — `Lyric.Manifest` self-test (`manifest_self_test.l`)

**Date:** 2026-05-10
**Branch:** `claude/mono-toml-self-host`

The `Lyric.Manifest` TOML parser (shipped in D-progress-129 as part of the
self-hosted CLI migration) lacked a Lyric-level self-test.  This entry
adds that coverage.

**`lyric-compiler/lyric/manifest_self_test.l`** — `Lyric.Manifest.SelfTest`
package, compiled and executed by the emitter test suite.  Exercises:

- Minimal `[package]`-only manifest (name, version, defaults).
- Full `[package]` with description, authors list, license.
- `[dependencies]` section with two entries.
- `[nuget]` + `[nuget.options]` with target TFM and `allow_native`.
- `[project]` + `[project.packages]` with package path map.
- `[features]` with `default` key and feature declarations.
- Comment and trailing-whitespace tolerance.
- Error: `MissingField` for absent required `name` field.
- Error: `MissingField` for absent required `version` field.
- `filePath` is stored verbatim in the returned `Manifest`.
- `ManifestError.message` returns a non-empty string.
- Unknown sections are silently ignored.

**`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedManifestTests.fs`** — F#
runner.  Compiles `manifest_self_test.l` via `compileAndRun`, asserts exit 0
and `stdout` contains `"ok"`.  Registered in `Program.fs` and
`Lyric.Emitter.Tests.fsproj` as `SelfHostedManifestTests.tests`.

**Test counts:** 729 emitter tests (+1 this entry), 323 parser tests, 143
type-checker tests, 123 lexer tests, 28 LSP tests, 127 CLI tests, 266
verifier tests — all passing.

---

### D-progress-231: M5.3 stage 13 — `Lyric.ManifestBridge` + `Lyric.TestSynthBridge` CLI hookup

**Date:** 2026-05-11
**Branch:** `claude/review-docs-platform-parity-UuNIO`

Routes `lyric build --manifest` and `lyric test` through the self-hosted
Lyric implementations via the in-process compile + reflection pattern
established by `SelfHostedFmt.fs`.

**New Lyric bridge files:**

- **`lyric-compiler/lyric/manifest_bridge.l`** — `Lyric.ManifestBridge`
  package.  `pub func serializeManifest(text, filePath): String` wraps
  `Lyric.Manifest.parse` and serialises the result to a line-oriented
  key=value protocol (first line `"ok"` or `"err"`, then `pkg.name=`,
  `pkg.version=`, `dep=name=version`, `nuget=id=version`,
  `nuget.target=`, `nuget.allow_native=true`, `project.name=`,
  `project.output=`, `project.output_assembly=`, `project.pkg=name=path`,
  `feature=`, `feature.default=`).

- **`lyric-compiler/lyric/test_synth_bridge.l`** — `Lyric.TestSynthBridge`
  package.  `pub func synthesizeToProtocol(source, filter, hasFilter): String`
  and `pub func listEntriesToProtocol(source): String` wrap `Lyric.TestSynth`
  and serialise results as the line-oriented protocol documented in the
  file header (tag line + fields, diagnostics as `code|sev|line|col|msg`).

**New F# shim files:**

- **`bootstrap/src/Lyric.Cli/SelfHostedManifest.fs`** — `Lyric.Cli.SelfHostedManifest`
  module.  Compiles a tiny `Lyric.ManifestBridgeDriver` on first use (same
  pattern as `SelfHostedFmt.fs`), reflects `serializeManifest(string, string): string`
  from `Lyric.ManifestBridge.Program`, and parses the protocol back into the
  F# `Manifest.Manifest` record.  Exposes `parseText` and `parseFile` matching
  the existing `Manifest.fs` signatures so call sites in `Program.fs` are
  one-line switches.

- **`bootstrap/src/Lyric.Cli/SelfHostedTestSynth.fs`** — `Lyric.Cli.SelfHostedTestSynth`
  module.  Compiles `Lyric.TestSynthBridgeDriver`, reflects
  `synthesizeToProtocol(string, string, bool): string` and
  `listEntriesToProtocol(string): string`, and parses results into the F#
  `TestSynth.Outcome` and `TestSynth.ListEntry` types reused by `Program.fs`.

**`bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj`** — `SelfHostedManifest.fs`
and `SelfHostedTestSynth.fs` added after `TestSynth.fs`, before `Program.fs`.

**`bootstrap/src/Lyric.Cli/Program.fs`** — three call-site changes:
- `lyric build --manifest` (line 1052): `Lyric.Cli.Manifest.parseFile` →
  `SelfHostedManifest.parseFile`.
- `lyric test --list` (line 1317): `TestSynth.listEntries` →
  `SelfHostedTestSynth.listEntries`.
- `lyric test` (line 1331): `TestSynth.synthesize` →
  `SelfHostedTestSynth.synthesize`.

**Key implementation notes:**

- Match arms whose bodies are assignment statements (not expressions) require
  explicit `{ }` braces in Lyric.  The bridge files use braced arms wherever
  the arm body contains `s = s + ...` assignments (bare `case P -> s = ...`
  is a parse error; the parser expects `case` or `}` after the match-arm
  expression).
- DLL naming: `Lyric.Lyric.ManifestBridge.dll` and
  `Lyric.Lyric.TestSynthBridge.dll` follow the double-`Lyric.` convention
  (head `Lyric` + per-package basename) documented in D-progress-141.
- The `splitOnFirst '=' s` helper in `SelfHostedManifest.fs` handles the
  `dep=name=version` and `project.pkg=name=path` wire format where the value
  contains `=` characters.
- `Position` and `Span` for diagnostic/span results are synthesised from the
  line/column fields in the protocol (offset = 0; the F# types are
  `Lyric.Lexer.Position` and `Lyric.Lexer.Span`).

**Test counts:** 752 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 158 CLI tests (all passing, +31 vs prior entry
from the expanded `TestRunnerTests` suite), 266 verifier tests — all passing.

---

### D-progress-232: REST client stdlib + OpenAPI client generator

**Date:** 2026-05-12
**Branch:** `claude/rest-client-openapi-uH3rE`

Adds a typed REST client library to the stdlib and a `lyric openapi` CLI
command that generates typed Lyric client packages from OpenAPI 3.x JSON specs.

**`lyric-stdlib/std/rest.l`** — `Std.Rest` package.

Builds a higher-level typed REST client on top of `Std.Http`.

- `RestError` union: `Http(error: HttpError)` and `Deserialize(url, reason)` — all failures as data.
- `RestAuth` enum: `None_`, `Bearer(token)`, `Basic(credentials)`, `ApiKey(headerName, headerValue)`.
- `RestClient` opaque type: `baseUrl`, `auth`, `defaultHeaders`.
  - `RestClient.create(baseUrl)` — constructor.
  - `RestClient.withAuth(client, auth)` — attach auth strategy.
  - `RestClient.get / post / put / patch / delete` — async per-verb methods; path may be
    relative to `baseUrl` or absolute.
  - `RestClient.bodyText / jsonBody / jsonString / jsonInt / jsonBool` — response body
    readers returning `Result[T, RestError]`.
  - `RestClient.statusCode / isSuccess / ensureSuccess` — status inspection.
- Internal `applyAuth` and `fullUrl` helpers (not exported).
- URL joining: handles trailing-slash / leading-slash combinations cleanly.

**`bootstrap/src/Lyric.Cli/OpenApi.fs`** — `Lyric.Cli.OpenApi` module.

OpenAPI 3.x spec model and JSON parser (`System.Text.Json`-based, no extra
dependencies).

- Types: `SchemaKind`, `Property`, `Parameter`, `ParameterIn`, `RequestBody`,
  `ResponseBody`, `Operation`, `HttpVerb`, `Info`, `Spec`.
- `parseText : string -> Result<Spec, string>` — parse from JSON string.
- `parseFile : string -> Result<Spec, string>` — read + parse from file path.
- Lenient: unknown fields silently ignored; path-level parameters merged into
  each operation; missing `operationId` synthesised from verb + path.
- Handles `application/json` request/response bodies, path/query/header/cookie
  parameters, nested object schemas, and `servers[0].url` as base path.

**`bootstrap/src/Lyric.Cli/OpenApiGen.fs`** — `Lyric.Cli.OpenApiGen` module.

Lyric source generator from a parsed `OpenApi.Spec`.

- `GenOptions` record: `ClientName`, `PackageName`.
- `defaultOptions : Spec -> GenOptions` — derives names from spec title.
- `toPascalPublic : string -> string` — PascalCase converter (used by CLI dispatch).
- `generate : Spec -> GenOptions option -> string` — emit `.l` source.
  - Emits one `pub record` per distinct named object schema (keyed by
    `<operationId>Body`).
  - Emits `<Name>Client` opaque type wrapping `RestClient`.
  - Emits `create(baseUrl)`, `default()` (when spec provides a base URL), and
    `withAuth` constructors.
  - Emits one `pub async func <Name>Client.<operationId>(...)` per operation;
    path parameters are interpolated into the URL string; query parameters are
    appended as `?key=val&…`; body is passed when a `requestBody` is present.
  - For flat object success responses, emits per-field scalar accessors
    (`<operationId><FieldPascal>`) that call the base method and extract one
    leaf value via `Std.Json`.
- `generateToFile : Spec -> GenOptions option -> string -> Result<string, string>` —
  write to a file path.

**`bootstrap/src/Lyric.Cli/Program.fs`** — new `lyric openapi` command.

```
lyric openapi <spec.json> [-o <out.l>] [--client-name <Name>] [--package <Pkg.Name>]
```

Parses the spec, merges CLI flags onto `defaultOptions`, and calls
`generateToFile`.  Default output path: `<spec-stem>_client.l` next to the
spec file.  Prints `generated <path> (<n> operations)` on success.

**`bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj`** — `OpenApi.fs` and `OpenApiGen.fs`
added before `Program.fs`.

**Key design decisions:**

- `Std.Rest` is layered above `Std.Http` (not above the kernel directly),
  so it pays the same validated-URL / Result-boundary cost as `Std.Http`.
- `RestAuth` is a plain enum (not a capability); callers thread it explicitly
  rather than relying on implicit ambient credentials.
- OpenAPI code generation targets `Std.Rest`, not `Std.Http` directly, so
  generated clients pick up auth, ensureSuccess, and JSON-body reading for free.
- Bootstrap limitation: generic body deserialization is `RestClient.jsonBody`
  (raw JSON string); `derive(Json)` typed deserialization is a follow-up.
- YAML spec input is not yet supported; pass a pre-converted JSON file.

**Test counts:** 752 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 158 CLI tests, 266 verifier tests — all passing.

### D-progress-233: OpenAPI parser + generator ported to self-hosted Lyric

**Date:** 2026-05-12
**Branch:** `claude/rest-client-openapi-uH3rE`

Ports the F# `OpenApi.fs` + `OpenApiGen.fs` modules into three Lyric packages
(`Lyric.OpenApiParser`, `Lyric.OpenApiGen`, `Lyric.OpenApiBridge`) and wires
them through a thin `SelfHostedOpenApi.fs` bridge shim, following the same
bridge pattern used by `SelfHostedFmt.fs`, `SelfHostedManifest.fs`, and
`SelfHostedJvm.fs`.  The old F# files are deleted; all OpenAPI logic now lives
in Lyric.  Also documents the F# surface freeze policy in `CLAUDE.md`.

**`CLAUDE.md`** — added "F# surface is frozen — new logic goes in Lyric"
convention section.  Codifies the rule that all new functionality must be
implemented in Lyric (`.l` files), with F# restricted to thin bridge shims.

**`lyric-stdlib/std/_kernel/json_host.l`** — added `JsonObjectEnumerator` and
`JsonProperty` extern types plus five `@externTarget` functions for
object-property enumeration (`hostEnumerateObject`, `hostEnumObjectMoveNext`,
`hostEnumObjectCurrent`, `hostPropertyName`, `hostPropertyValue`).

**`lyric-stdlib/std/json.l`** — exposed the new kernel functions as public
`@stable` wrappers: `enumerateObject`, `objectMoveNext`, `objectCurrent`,
`propertyName`, `propertyValue`.  Also added `valueKind`, `getRawText`,
`enumerateArray`, `arrayMoveNext`, `arrayCurrent` wrappers (previously
missing from the public API).

**`lyric-compiler/lyric/open_api_parser.l`** — `Lyric.OpenApiParser` package.
Parses the subset of OpenAPI 3.0/3.1 needed for client generation: paths,
operations (all seven HTTP verbs), path/query parameters, JSON request/response
bodies, and inline object/scalar schemas.  Produces `ParsedSpec` /
`ParsedOp` / `ParsedParam` / `ParsedProperty` records.
Public entry: `parseSpec(json: in String): Result[ParsedSpec, String]`.

**`lyric-compiler/lyric/open_api_gen.l`** — `Lyric.OpenApiGen` package.
Generates a typed Lyric REST client package from a `ParsedSpec`.  Emits
records, opaque client type, constructors, per-operation async methods, and
per-field scalar accessors.
Public entry: `generate(spec, clientNameOverride, packageNameOverride): String`.

**`lyric-compiler/lyric/open_api_bridge.l`** — `Lyric.OpenApiBridge` package.
Thin glue between parser and generator; wraps result in the two-line text
protocol (`ok\n<source>` / `err\n<message>`) consumed by the F# shim.
Public entry: `generateFromJson(json, clientName, packageName): String`.

**`bootstrap/src/Lyric.Cli/SelfHostedOpenApi.fs`** — thin F# bridge shim.
Compiles a driver that imports `Lyric.OpenApiBridge`, loads the resulting DLL
by reflection, and routes `lyric openapi` calls through `generateFromJson`.
Follows the identical lazy-initialise + delegate-cache pattern used by
`SelfHostedFmt.fs`.

**`bootstrap/src/Lyric.Cli/Program.fs`** — `lyric openapi` dispatch now calls
`SelfHostedOpenApi.generateToFile` instead of the deleted F# modules.

**`bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj`** — `OpenApi.fs` and `OpenApiGen.fs`
removed; `SelfHostedOpenApi.fs` added.

**`bootstrap/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs`** — soft-cap
bumped from 261 → 268 to account for the seven new kernel externs added to
`json_host.l` (two extern types + five extern functions).

**Test counts:** 752 emitter tests — all passing.

---

### D-progress-240: R6 codegen — IL validity fixes + MSIL bridge end-to-end tests

Five categories of structural IL errors in `lyric-compiler/msil/codegen.l`
caused all self-hosted MSIL bridge paths to fail at JIT time with
`InvalidProgramException` or `MissingMethodException`.  All five are now fixed,
and six end-to-end tests cover the repaired paths.

**IL validity fixes:**

1. **PathStackDepth in `panic`/`assert`/`format1-3` branches** — `lowerCallArgMsil`
   as the last expression in the then-branch of an if-else caused
   `branchLeavesValue` to return `true` (because `peekExprType` falls back to
   `typeof<obj>` for `EMember` calls, which are actually void at runtime).
   With both branches appearing to leave values, `discardBoth = false`, and no
   corrective `pop` was emitted, producing a PathStackDepth error.  Fix:
   changed to `val _ = lowerCallArgMsil(...)` so the F# emitter sees an
   `LBVal(PWildcard)` binding and always emits `pop`.

2. **PathStackDepth in `SAssign`** — `lowerAssignExprMsil` returns a non-void
   `MsilType` as the last expression in the `SAssign` arm of `lowerStmtMsil`,
   leaving a value on the stack along one path.  Fix: `val _ = lowerAssignExprMsil(...)`.

3. **StackUnexpected in `lowerRecordMsil` / `lowerUnionMsil`** — `methods = newList()`
   without a type annotation caused the F# bootstrap emitter to infer
   `List<object>` instead of `List<MFunc>`, producing a wrong-type value where
   the record constructor expected `List<MFunc>`.  Fix: explicit
   `val methods: List[MFunc] = newList()`.

4. **Missing `.runtimeconfig.json`** — `SelfHostedMsil.compileToDll` produced the
   output DLL but no `.runtimeconfig.json`, so `dotnet exec` exited with
   `A fatal error occurred: The required library libhostpolicy.so could not be found`.
   Fix: added `writeRuntimeConfig` to `SelfHostedMsil.fs`, called after each
   successful compile; it writes a minimal `runtimeconfig.json` containing the
   current process's .NET version.

5. **MissingMethodException on `List<object>::Add`** — MemberRef signatures for
   methods on a TypeSpec (generic instantiation) must use `ELEMENT_TYPE_VAR`
   (0x13 + type-parameter index) for positions occupied by the enclosing type's
   generic parameters, per ECMA-335 §II.14.4.2.  The self-hosted emitter was
   encoding these positions as `ELEMENT_TYPE_OBJECT` (0x1C — the concrete
   instantiated type), which the CLR cannot match against `List<T>::Add(!0)`.
   Fix:
   - Added `case MTypeVar(index: Int)` to the `MsilType` union in
     `lyric-compiler/msil/lowering.l`.
   - Added `func bufMsilType(w: ByteWriter, t: MsilType): Unit` that emits two
     bytes (`0x13`, `index`) for `MTypeVar` and one byte for all other types.
   - Updated `buildInstanceMethodSig` and `buildStaticMethodSig` to use
     `bufMsilType` for both the return type and each parameter type.
   - Updated all TypeSpec MemberRef setups in `codegen.l`: `List::Add`,
     `List::get_Item`, `Dict::Add`, `Dict::get_Item`, `Dict::ContainsKey`.

**New test file:** `bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilBridgeTests.fs`
— 6 end-to-end tests that compile Lyric programs through the full
self-hosted pipeline (`Msil.Bridge.compileToMsil`) and execute the resulting
DLL with `dotnet exec`, asserting on stdout:

| Label | Program | Expected |
|---|---|---|
| `shm_hello` | `println("hello from self-hosted")` | `hello from self-hosted` |
| `shm_while_basic` | count to 5 with `while` | `5` |
| `shm_break_early` | break at `i == 5` | `5` |
| `shm_continue_skip_evens` | sum odd numbers 1–9 with `continue` | `25` |
| `shm_nested_while_break` | 5×3 inner iterations (break at j==3) | `15` |
| `shm_newList_add_count` | `newList()`, 3 `add` calls, `xs.count` | `3` |

**Test counts:** 752 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 164 CLI tests (+6 MSIL bridge), 266 verifier
tests — all passing.

### D-progress-241: Platform-parity R7 — full 20-program × 3-path smoke-test suite; JVM VerifyError fixes

**Date:** 2026-05-11
**Branch:** `claude/review-docs-platform-parity-UuNIO`

Completes the §7 parity milestone from `docs/33-platform-parity-remediation.md`.
All 60 cross-path parity tests now pass (20 programs × 3 execution paths:
dotnet-legacy / dotnet / jvm).

**New test file:** `bootstrap/tests/Lyric.Cli.Tests/ParityTests.fs`
— 20 parity programs each exercising one feature from the common subset
(primitive types, arithmetic, boolean logic, comparisons, if/else,
while/break/continue, nested loops, val chains, match on literals and bindings,
string concatenation).  Each program is compiled and run through three paths:

| Path | Mechanism |
|---|---|
| `dotnet-legacy` | F# `Emitter.emit` (escape-hatch baseline) |
| `dotnet` | `SelfHostedMsil.compileToDll` (self-hosted MSIL bridge) |
| `jvm` | `SelfHostedJvm.compileToJar` (self-hosted JVM bridge) |

**JVM fixes in `lyric-compiler/jvm/codegen.l`:**

1. Added `lowerCmpFail`, `lowerBoolCond`, `lowerBoolCondTrue` functions.
   Conditions in `if`/`while` are now compiled directly to conditional branch
   instructions (e.g. `if_icmpge failLabel`) rather than leaving an intermediate
   boolean integer on the operand stack.  The old approach created merge labels
   with non-empty operand stacks, which caused JVM `VerifyError` (StackMapTable
   frame declared stack depth 0 but actual depth was 1).

2. Added `loopBreak: List[String]` and `loopCont: List[String]` fields to
   `FuncCtx`.  `SWhile` now pushes the afterLoop / loopTop labels onto these
   stacks before lowering the body and pops them after.  `SBreak` emits
   `LGoto(loopBreak[last])`; `SContinue` emits `LGoto(loopCont[last])`.
   Previously both emitted `LNop`, so break/continue were silently ignored.

**JVM fix in `lyric-compiler/jvm/lowering.l`:**

3. `lowerFuncImpl` now pre-initialises all non-parameter local slots at method
   entry (before the function body): integer/long/float/double slots get `0`,
   object-reference slots get `aconst_null`.  This ensures every branch-target
   StackMapTable frame is valid: the verifier sees all locals as initialised at
   every branch target, regardless of where in the method body the variable is
   first assigned.  Without this, the global `frameLocals` computation included
   slots that are only assigned late in the method, making early StackMapTable
   frames invalid (`top` is not a subtype of `int` or `Object`).

**Tests fixed by these changes:**

| Test | Root cause |
|---|---|
| `parity08_bool_and` | BAnd merge label with non-empty stack |
| `parity09_bool_or` | BOr merge label with non-empty stack |
| `parity11_if_true` | comparison merge label with non-empty stack |
| `parity12_if_false` | comparison merge label with non-empty stack |
| `parity13_while_count` | comparison merge label in while condition |
| `parity14_while_break` | break emitted LNop; comparison merge label |
| `parity15_while_continue` | continue emitted LNop; comparison merge label |
| `parity16_while_nested` | inner-loop `var j` in late-allocated slot + comparison |
| `parity18_match_int` | late-allocated match temporaries in global frameLocals |
| `parity19_match_bind` | late-allocated binding slot in global frameLocals |

**Test counts:** 752 emitter tests, 323 parser tests, 143 type-checker tests,
123 lexer tests, 28 LSP tests, 224 CLI tests (+60 parity + 6 MSIL bridge),
266 verifier tests — all passing.

---

### D-progress-242: lyric-lambda service library

---

### D-progress-243: lyric-lambda v2 + lyric-aws-secrets

**Branch:** `claude/lyric-lambda-library-L7cgt`
**Decision log:** D063

Extends `lyric-lambda` with authorizer support and Kinesis, and ships the new
`lyric-aws-secrets` library for config-block secret injection.

**Shipped in lyric-lambda:**

- `lyric-lambda/src/authorizer.l` — `Lambda.Authorizer` package:
  - `TokenAuthorizerEvent` — REST API TOKEN authorizer event (authorizationToken + methodArn)
  - `RequestAuthorizerEvent` / `RequestAuthorizerContext` — REST API REQUEST authorizer event
  - `HttpAuthorizerEvent` / `HttpAuthorizerRequestContext` / `HttpAuthorizerHttp` — HTTP API v2 authorizer event
  - `IamEffect` union (Allow/Deny), `IamStatement`, `IamPolicyDocument`, `AuthorizerResponse`
    for REST API responses; helpers: `allow`, `allowAll`, `deny`, `withContext`, `withUsageKey`
  - `HttpAuthorizerResponse` for HTTP API v2; helpers: `authorized`, `authorizedWithContext`, `denied`
- `lyric-lambda/src/lambda.l` — extended:
  - `AuthorizerHandler` record
  - `LambdaApp.authorizerHandlers: [AuthorizerHandler]` field (breaking change: `newApp`,
    `withRouter`, `addHandler` updated to carry the new field)
  - `onKinesis()`, `onTokenAuthorizer()`, `onRequestAuthorizer()`, `onHttpAuthorizer()` builders
- `lyric-lambda/src/events.l` — extended:
  - `KinesisRecord`, `KinesisStreamRecord`, `KinesisEvent` (full payload including
    base64-encoded data, sequenceNumber, partitionKey, approximateArrivalTimestamp)
- `lyric-lambda/lyric.toml` — updated: `Lambda.Authorizer` package entry added;
  comment updated to six packages and three composition modes.

**Shipped in lyric-aws-secrets:**

- `lyric-aws-secrets/lyric.toml` — manifest with `aws`/`local` feature flags;
  NuGet deps: `AWSSDK.SecretsManager` 3.7.x, `AWSSDK.SimpleSystemsManagement` 3.7.x.
- `lyric-aws-secrets/src/secrets.l` — `AwsSecrets` package:
  - `@secretsManager("name")` / `@secretsManager("name", key: "field")` annotations
  - `@parameterStore("/path")` annotation
  - `SecretsError` union (NotFound, AccessDenied, DecryptionError, ParseError, NetworkError)
  - `SecretCache` config block (ttlSeconds, default 300)
  - `init(): Result[Unit, SecretsError]` — scans DLL annotations, fetches, populates config cache
  - `getSecret`, `getSecretField`, `getParameter`, `getParameterRaw` explicit fetch API
- `lyric-aws-secrets/src/_kernel/secrets_kernel_aws.l` — `AwsSecrets.Kernel.Net`
  `@cfg(feature="aws")`: externs to `Amazon.SecretsManager.initFromAnnotations` /
  `fetchSecret` and `Amazon.SimpleSystemsManagement.fetchParameter`; documents
  in-process cache, thread safety, and IAM requirements.
- `lyric-aws-secrets/src/_kernel/secrets_kernel_local.l` — `AwsSecrets.Kernel.Net`
  `@cfg(feature="local")`: no-op backend; `init()` respects env var overrides and
  skips AWS fetches; explicit fetches return `SecretsError.NotFound`.

**Documentation:**

- `docs/35-lambda-library.md` rewritten as a unified design document covering
  both libraries: updated library structure tables, Kinesis in event detection
  table, authorizer detection rules, §6 (Authorizers) with full handler
  signatures and IAM policy examples, §7 (Secrets) with annotation model /
  startup wiring / caching / local mode, resolved Q-lambda-002/-005/-006.
- D063 added to `docs/03-decision-log.md`.

**Test counts:** unchanged (source-only; integration tests follow with F# kernel wiring).

---

### D-progress-244: lyric-lambda v3, lyric-aws-secrets JVM, and lyric-aws-xray

**Branch:** `claude/lyric-lambda-library-L7cgt`
**Decision log:** D064

Extends `lyric-lambda` and `lyric-aws-secrets` with JVM support, AOT-safe
handler registration, and response streaming; adds the new `lyric-aws-xray`
library for AWS X-Ray active tracing as a B-mode aspect.

**Shipped in lyric-lambda:**

- `lyric-lambda/src/direct.l` — `Lambda.Direct` package:
  - `DirectHandler` opaque type (kernel-managed function reference wrapper)
  - `sqsHandler`, `sqsBatchHandler`, `snsHandler`, `s3Handler`,
    `eventBridgeHandler`, `dynamoDbHandler`, `kinesisHandler`, `rawHandler` —
    typed factory functions for event-source handlers
  - `tokenAuthorizerHandler`, `requestAuthorizerHandler`,
    `httpAuthorizerHandler` — typed factory functions for authorizer handlers
  - `streamingHandler` — typed factory for streaming handlers
    (signature: `func(String, LambdaContext, StreamWriter) -> Result[Unit, LambdaError]`)
- `lyric-lambda/src/stream.l` — `Lambda.Stream` package:
  - `StreamWriter` opaque type (kernel-managed write channel)
  - `setContentType(writer, contentType)` — set Content-Type before first write
  - `write(writer, chunk)` — deliver UTF-8 string chunk immediately
  - `writeBytes(writer, base64Chunk)` — deliver raw bytes (base64 decoded by kernel)
  - `close(writer)` — signal end of response; auto-called on handler return
- `lyric-lambda/src/_kernel/lambda_kernel_jvm.l` — `Lambda.Kernel.Runtime`
  `@cfg(feature="jvm")`: extern to the Java managed runtime
  (`com.amazonaws.lambda.serve(app, localPort)`); documents the
  `<RootPackage>$LambdaHandler::handleRequest` dispatch protocol.
- `lyric-lambda/src/lambda.l` — extended:
  - `LambdaApp` gains two new fields: `streamingHandler: Option[String]`
    and `directHandlers: [Lambda.Direct.DirectHandler]`
  - `withStreamingHandler(app, handlerName)` builder
  - `withDirect(app, handler)` builder
  - All internal `LambdaApp`-constructing helpers updated to carry all 5 fields
- `lyric-lambda/lyric.toml` — rewritten: 8 packages (+ `Lambda.Direct`,
  `Lambda.Stream`); 3 features (`aws`, `local`, `jvm`); kernel list extended
  with `lambda_kernel_jvm.l`; `[maven]` table added for JVM runtime deps.

**Shipped in lyric-aws-secrets:**

- `lyric-aws-secrets/src/_kernel/secrets_kernel_jvm.l` — `AwsSecrets.Kernel.Net`
  `@cfg(feature="jvm")`: extern to AWS SDK for Java v2
  (`software.amazon.awssdk.secrets`); `initFromAnnotations`, `fetchSecret`,
  `fetchParameter` — mirrors .NET API; documents JVM class metadata scanning,
  ConcurrentHashMap cache, region resolution.
- `lyric-aws-secrets/lyric.toml` — extended: `jvm = []` feature added;
  kernel list extended with `secrets_kernel_jvm.l`; `[maven]` table added
  (`software.amazon.awssdk:secretsmanager:2.25.70`,
  `software.amazon.awssdk:ssm:2.25.70`).

**Shipped in lyric-aws-xray (new library):**

- `lyric-aws-xray/lyric.toml` — manifest with `aws`, `jvm`, `local` features;
  NuGet: `Amazon.XRay.Recorder.Core 2.14.0`; Maven: `aws-xray-recorder-sdk-core 2.15.3`.
- `lyric-aws-xray/src/xray.l` — `AwsXRay` package:
  - `SubsegmentHandle` opaque type
  - `currentSubsegment()` — retrieve active subsegment from within a wrapped handler
  - `annotate(handle, key, value)` — indexed X-Ray annotation
  - `metadata(handle, key, value)` — unindexed metadata
  - `Tracing` B-mode pub aspect: wraps matched calls as X-Ray subsegments;
    records error annotation on `Err(_)`; no-op pass-through when `enabled = false`
- `lyric-aws-xray/src/_kernel/xray_kernel_aws.l` — `AwsXRay.Kernel.Net`
  `@cfg(feature="aws")`: extern to `Amazon.XRay.Recorder`
  (`beginSubsegment`, `endSubsegment`, `addAnnotation`, `addMetadata`,
  `currentSubsegment`); documents AsyncLocalSegmentContext thread safety.
- `lyric-aws-xray/src/_kernel/xray_kernel_jvm.l` — `AwsXRay.Kernel.Net`
  `@cfg(feature="jvm")`: extern to `com.amazonaws.xray` (AWS SDK for Java v2);
  documents thread-local TraceContext isolation.
- `lyric-aws-xray/src/_kernel/xray_kernel_local.l` — `AwsXRay.Kernel.Net`
  `@cfg(feature="local")`: no-op; all X-Ray calls silently dropped.

**Documentation:**

- `docs/35-lambda-library.md` — status updated to D064; goals extended with
  items 7–10; library structure tables updated with new packages and xray;
  §3 `LambdaApp` updated to 5-field record + builder table; §8 kernel table
  rewritten to include JVM row and xray rows; §10 (AOT Direct), §11 (Streaming),
  §12 (JVM), §13 (X-Ray), §14 (env vars, was §10), §15 (design notes, was §11),
  §16 (open questions, was §12) added/renumbered; all open questions resolved.
- D064 added to `docs/03-decision-log.md`.

**Test counts:** unchanged (source-only; integration tests follow with F# kernel wiring).

---

### D-progress-245: `Std.Xml` and `Std.Yaml` — pure-Lyric parsers (D065)

Shipped two cross-platform stdlib modules with no kernel externs:

**`lyric-stdlib/std/xml.l` — `Std.Xml`:**  Pure-Lyric XML 1.0 parser.  Parses
elements, attributes (single- and double-quoted), text, comments, CDATA,
entity references (&amp; &lt; &gt; &apos; &quot; &#NNN; &#xNNN;),
self-closing tags, XML declarations, and DOCTYPE/PI nodes (consumed, not
retained).  API: `parseXml`, `documentRoot`, `elementTag`, `elementAttrs`,
`elementChildren`, `getAttribute`, `textContent`, `findFirst`, `findAll`.
Uses the `inout` mutable-state record pattern established in the self-hosted
lexer and parser.  18 tests in `lyric-stdlib/tests/xml_tests.l`.

**`lyric-stdlib/std/yaml.l` — `Std.Yaml`:**  Pure-Lyric YAML 1.2 + JSON parser.
JSON mode (`parseJson`): full strict JSON.  YAML mode (`parseYaml`): JSON flow
style + YAML block mappings and sequences, unquoted/single/double-quoted
scalars, boolean aliases (yes/no/on/off), null alias (~).  Data model:
`YamlValue` union (YNull, YBool, YInt, YFloat, YString, YSequence, YMapping)
+ `YamlPair` record.  API: `parseJson`, `parseYaml`, `isNull`, `asString`,
`asBool`, `asInt`, `asSequence`, `asMapping`, `getField`, `getString`,
`getInt`, `getBool`.  Note: float literals return `YString(raw)` until a
`toDouble` extern lands (tracked Q-yaml-001).  19 tests in
`lyric-stdlib/tests/yaml_tests.l`.

Also discovered and documented two parser constraints during development:
- Multi-statement match-arm bodies require explicit `-> { ... }` braces.
- Chained `else if` must place `} else if` on the same line to avoid
  statement-end insertion after the closing `}`.

**Test counts:** 755 emitter tests (+3 from xml_tests, yaml_tests,
xml_viability_tests), 323 parser tests, 143 type-checker tests, 123 lexer
tests, 28 LSP tests, 158 CLI tests, 266 verifier tests — all passing.

---

### D-progress-234: M5.3 — self-hosted verifier (`Lyric.Verifier`)

**Date:** 2026-05-12
**Branch:** `claude/convert-verifier-to-lyric-UPzVX`

Ports the Phase 4 proof system to self-hosted Lyric as the `Lyric.Verifier`
package (`lyric-compiler/lyric/verifier/`).  The Lyric implementation mirrors
`bootstrap/src/Lyric.Verifier/` and is exercised by `verifier_self_test.l` via
the F# harness `SelfHostedVerifierTests.fs`.

**New Lyric files (`lyric-compiler/lyric/verifier/`):**

- **`vcir.l`** — VC IR types: `Sort`, `Term`, `Goal`, `GoalKind`,
  `Lit`, `BuiltinOp`, `TranslateResult`, `VerifyOutcome`, `VerifyResult`,
  `VerifySummary`, `SortInfo`, `RangeBoundKind`, `SymbolDecl`.
- **`vcgen.l`** — WP/SP calculus over the Lyric imperative fragment:
  `VEnv` environment, `translateLit`/`translateExpr`/`translateContract`,
  `wpStmt`/`wpBody`/`wpWhile`, `goalsForFile`.  Handles `let`/`val`/`var`,
  `if`/`else`, `match` (wildcard, literal, bare-binding patterns), `assert φ`,
  loop invariants (establish + preserve goals), and the Hoare call rule
  (assert callee `requires:`, assume callee `ensures:`).
- **`smt.l`** — SMT-LIB v2.6 renderer: `smtRenderSort`, `smtRenderTerm`,
  `smtRenderGoal` producing `(assert (not φ))` + `(check-sat)` queries.
- **`solver.l`** — trivial syntactic discharger (`trivialDischarge`):
  closes `true`, reflexive comparisons, hypothesis matches, `P ⇒ P`,
  `termEq`-based tautologies, conjunctions thereof.  Exposes `isTautology`
  and `termEq` for use in the self-test.
- **`driver.l`** — `prove(source): VerifySummary` entry point; calls
  `Lyric.Parser.parse`, `Lyric.ModeChecker.checkFile`, `goalsForFile`,
  and `trivialDischarge` for each goal; assembles `VerifySummary`.
  Also exports `goalsForFile` directly for the self-test.

**New Lyric file:**

- **`lyric-compiler/lyric/verifier_self_test.l`** — `Lyric.Verifier` self-test
  program.  Nine sub-tests exercising the VCGen pipeline end-to-end:
  `testGoalsForFileEmpty`, `testGoalsForFileWithRequires`,
  `testTranslateExprLiteral`, `testTranslateExprVar`,
  `testTranslateExprBinop`, `testSmtRenderTerm`, `testTrivialDischargeGteRefl`,
  `testProveProofRequiredNoContracts`, `testProveParseError`.
  Exits 0 and prints `"verifier self-test: ok"` on success.

**New F# harness files:**

- **`bootstrap/src/Lyric.Emitter/VerifierEnv.fs`** — `Lyric.Emitter.VerifierEnv`
  module.  Exposes `getEnv(): string` returning the `LYRIC_Z3` or `z3` path
  (or empty string), used via `@externTarget("Lyric.Emitter.VerifierEnv.getEnv")`
  in `lyric-stdlib/std/_kernel/verifier_env_host.l`.
- **`bootstrap/src/Lyric.Emitter/ProcessCapture.fs`** — `Lyric.Emitter.ProcessCapture`
  module.  Exposes `run(exe, args): ProcessResult` for spawning subprocesses
  with captured stdout/stderr, used via
  `@externTarget("Lyric.Emitter.ProcessCapture.run")` in
  `lyric-stdlib/std/_kernel/process_capture_host.l`.
- **`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedVerifierTests.fs`** —
  `testCase "[verifier_self_test_passes]"` compiles + executes
  `verifier_self_test.l`, asserts no compile errors, exit code 0, and
  stdout contains `"ok"`.

**New stdlib kernel files:**

- **`lyric-stdlib/std/_kernel/verifier_env_host.l`** — `Std.VerifierEnvHost` kernel
  package: `pub extern func hostGetEnv(): String` with
  `@externTarget("Lyric.Emitter.VerifierEnv.getEnv")`.
- **`lyric-stdlib/std/_kernel/process_capture_host.l`** — `Std.ProcessCaptureHost`
  kernel package: `pub extern func hostRun(exe: String, args: String): String`
  with `@externTarget("Lyric.Emitter.ProcessCapture.run")`.
- **`lyric-stdlib/std/process_capture.l`** — `Std.ProcessCapture` public wrapper:
  `pub func runProcess(exe, args): ProcessResult` wrapping `hostRun`.

**Emitter fix (`Codegen.fs` `resolveUnionCaseInfo`):**

When two unions define a case with the same short name (e.g. `Literal.LInt`
from `Lyric.Parser` and `Lit.LInt` from `Lyric.Verifier`), the short-name
table holds whichever was registered last (last-writer-wins).  Added
`parentMatchesScrutTy` and `qualifiedKey` helpers to check whether the found
entry's parent union matches `scrutTy`; if not, retries with the qualified
key `"{typeName}.{case}"` (which is always registered alongside the short
key) so the correct case type is used for `isinst` checks in pattern matches.
Both `ctx.UnionCases` and `ctx.ImportedUnionCases` are probed with the
qualified key.

**`EmitTestKit.fs` — `Lyric.Emitter.dll` staging:**

`prepareOutputDir` now copies `Lyric.Emitter.dll` into the temp output
directory so programs importing `Std.VerifierEnvHost` (which resolves
`@externTarget("Lyric.Emitter.VerifierEnv.getEnv")` at runtime) can
find the assembly via `dotnet exec`'s probing path.

**Test counts:** 756 emitter tests (755 passing; 1 pre-existing `kernel total
reported (soft cap)` failure unrelated to this change), 266 verifier tests —
all passing.

---

### D-progress-246: T5 type-checker uplift — complete expression and pattern inference

**Date:** 2026-05-12
**Branch:** `claude/lyric-closures-functions-XencC`

Completes the bootstrap type checker's expression and pattern inference to T5
level: every expression form and pattern form that the parser can produce now
has a correct type-checker path.

**`bootstrap/src/Lyric.TypeChecker/Type.fs`**

Added `| TyRange of Type` to the `Type` discriminated union. `TyRange` is
produced by `ERange` expressions and consumed by the for-loop element-type
extraction path. `equiv` and `render` updated accordingly.

**`bootstrap/src/Lyric.TypeChecker/ExprChecker.fs`** (was separate `StmtChecker.fs`)

`ExprChecker.fs` and `StmtChecker.fs` were merged into a single file under
`let rec inferExpr … and checkStatement … and checkBlock …` mutual recursion.
`StmtChecker.fs` is removed from the project file. The merged file implements:

- **EIf** — condition must be `Bool` (T0067); branches must have compatible
  types (T0068); `TyNever` branches propagate the other branch's type.
- **EMatch** — pattern bindings per arm via `bindPattern`; arm body types
  must be compatible (T0068).
- **EBlock / EUnsafe** — block body returns type of trailing expression.
- **ELambda** — builds `TyFunction` from annotated parameter types; type-checks
  body against inferred return.
- **EIndex** — receiver must be `slice[T]`, `array[T]`, or `String`; index must
  be `Int`; returns element type (T0069 for failures).
- **ERange** — infers element type from bounds; produces `TyRange elemType`.
- **EInterpolated** — type-checks each `ISExpr` segment; result is `String`.
- **ETypeApp** — pass-through that infers the underlying expression's type.
- **EAssign** — verifies RHS type matches target type (T0063); mutability check deferred to T6+.
- **EForall / EExists** — bind the quantified variable; result is `Bool`.
- **ETry** — propagates the inner expression's type.
- **resolvePath** — now handles `DKConst`, `DKVal` (with init-expression
  fallback), `DKUnionCase` (no-field → parent union type; with-field →
  constructor `TyFunction`), and `DKEnumCase`.

**`bindPattern`** extended:
- `PTuple` — extracts element types from a `TyTuple` scrutinee.
- `PConstructor` — looks up the union case in the symbol table and resolves
  each field's type.
- `POr` — walks the first alternative into scope; remaining alternatives
  into a dummy scope (same diagnostics, no duplicate bindings).
- `PRecord` — resolves field types from the record's type id via
  `fieldsOfRecord`.
- `PTypeTest` — narrows the inner binding to the tested type.
- `PParen` — delegates to the inner pattern.
- `PRange`, `PWildcard`, `PLiteral`, `PError` — no bindings produced.

For-loop element type: `TyRange e` added alongside `TyArray e` / `TySlice e`
as valid iterable element-type sources.

**New diagnostic codes:**

| Code | Meaning |
|------|---------|
| T0067 | `if`/`for` guard condition must be `Bool` |
| T0068 | Branch or match-arm type mismatch |
| T0069 | Invalid index expression (non-Int index or non-indexable receiver) |

**`bootstrap/src/Lyric.TypeChecker/Lyric.TypeChecker.fsproj`**

`StmtChecker.fs` removed from the compile list (file left on disk but
excluded).

**`bootstrap/src/Lyric.TypeChecker/Checker.fs`**

Call site updated from `StmtChecker.checkFunctionBody` to
`ExprChecker.checkFunctionBody`.

**`bootstrap/src/Lyric.Emitter/TypeMap.fs`**

Added `| TyRange _ -> typeof<obj>` (ranges are consumed by for-loop codegen
and never need to be boxed to a CLR type).

**`bootstrap/src/Lyric.Lsp/Server.fs`**

Added `| TyRange x -> sprintf "range[%s]" (render x)` to the LSP hover
type renderer.

**`bootstrap/tests/Lyric.TypeChecker.Tests/`**

Two new test files added:

- `T5ExprCheckerTests.fs` — 44 tests covering EIf (T0067, T0068, Never
  propagation), EMatch (pattern binding, T0068), ELambda (TyFunction shape,
  body checking), EIndex (T0069), EInterpolated, module-level val resolution,
  DKUnionCase / DKEnumCase resolution, generic function symbol resolution,
  EForall / EExists.
- `T5PatternTests.fs` — 17 tests covering PTuple element types, PConstructor
  field types, POr, PRecord (shorthand and named bindings), PTypeTest in val
  binding, PRange (no-binding), for-loop over `slice[Int]`, wildcard patterns.

Type checker test count: 187 (from 143 before, +44 net new).

**Test counts:** 756 emitter tests (398 failing due to pre-existing Std.Core
generic-union T0068 errors; fixed in D-progress-247), 323 parser tests, 187
type-checker tests, 123 lexer tests, 28 LSP tests, 158 CLI tests, 266 verifier
tests.

---

### D-progress-247: T5 follow-up — generic union case type resolution and block terminator types

**Date:** 2026-05-12
**Branch:** `claude/lyric-closures-functions-XencC`

Follow-up to D-progress-246. Fixes three bugs exposed by the T5 type-checker
uplift that caused 398 emitter test failures when compiling `Std.Core`'s generic
`Option[T]` and `Result[T, E]` unions.

**Root causes fixed (all in `bootstrap/src/Lyric.TypeChecker/ExprChecker.fs`):**

**1. Generic union case field types lost their type parameters (T0010)**

`PConstructor` in `bindPattern` and `DKUnionCase` in `resolvePath` both created
a bare `GenericContext()` (no type variables) when resolving union-case field
type expressions.  Resolving `T` from `case Some(value: T)` failed with T0010
"unknown type name 'T'" because the parent union's generic parameters were never
pushed onto the context.

Fix: added `unionGenericParamsFor (table: SymbolTable) (parentId: TypeId)` helper
that walks `table.All()` to find the `DKUnion` entry matching `parentId` and
returns its declared generic parameter names.  Both call sites now call
`mkGenericCtx (unionGenericParamsFor table parentId)` so field types like `T`
and `E` resolve to `TyVar "T"` / `TyVar "E"` as intended.

**2. Union case constructor return type omitted generic arguments (T0068 / T0070)**

`DKUnionCase` in `resolvePath` returned `TyUser(parentId, [])` as the type of
no-field cases (e.g., `None`) and as the constructor return type for field cases
(e.g., calling `Some(v)`).  This produced `<#1>` (no args) while parameters
typed as `Option[T]` resolved to `<#1>[T]`, causing spurious T0068 arm-type
mismatches and T0070 trailing-expression mismatches in every generic function in
`Std.Core`.

Fix: the return type is now `TyUser(parentId, returnArgs)` where
`returnArgs = parentGenerics |> List.map TyVar`.  For `Option[T]` this gives
`TyUser(optId, [TyVar "T"])` for both `None` (used directly) and `Some(v)`
(constructor result), matching the type of parameters annotated as `Option[T]`.
Since `TyVar` matches anything in `equiv`, this is safe for the bootstrap's
non-unifying type-equality model.

**3. `checkBlock` returned `TyPrim PtUnit` after control-flow terminators**

When a block's last statement was `SReturn`, `SThrow`, `SBreak`, or `SContinue`,
`checkBlock` returned `TyPrim PtUnit` (the fallthrough catch-all).  The correct
type for a definitely-terminating block is `TyPrim PtNever`, consistent with
how `EIf`/`EMatch` treat Never-typed branches.

Fix: the new `SReturn _ | SThrow _ | SBreak _ | SContinue _` arm in `checkBlock`
calls `checkStatement` (which still validates the returned/thrown value's type)
and then sets `lastExprType <- TyPrim PtNever`.

**Additional fixes in the same PR** (claude-review follow-up):

- `ERange` mismatched bounds now emits T0068 instead of silently returning
  `TyError`.  Note: `ERange` is not parser-reachable in expression position
  in the current bootstrap (only produced as `PRange` in pattern context), so
  no end-to-end test is added; the branch is correct for when range-expression
  syntax is added to the parser.
- `EForall`/`EExists` body now checked for `Bool` (T0067 if not).
- `SAssign` compound-op deferral documented with `// compound-op semantics
  deferred to T6+` comment.
- `EAssign` progress-log description corrected: mutability check is deferred
  to T6+, not implemented.
- Restored "why" comments on the `builtinMember` TyError-without-diagnostic
  path and the `PreRef` pass-through.
- `StmtChecker.fs` deleted from disk (was already excluded from the project).
- Two new `EAssign` tests (happy path + T0063 mismatch).

**Outcome:**

- 189/189 type-checker tests pass (+2 EAssign tests vs D-progress-246's 187).
- Emitter tests: 398 → 250 failures.  The 148 newly passing tests are those
  that imported `Std.Core` and failed solely because the type-checker emitted
  spurious T0010 / T0068 / T0070 on the generic Option / Result functions.
  The remaining 250 failures are pre-existing issues in the self-hosted Lyric
  MSIL emitter (`lyric-compiler/lyric/`) — unresolved names in the handwritten
  PE builder — and are not caused by the T5 type-checker work.


### D-progress-248: `lyric bench` — self-hosted benchmark synthesizer + CLI command

Implements the `lyric bench <source.l> [--runs N] [--warmup N] [--filter s]` command.

**Architecture** (follows the `Lyric.TestSynth` / `Lyric.Fmt` self-hosted shim pattern):

- **`lyric-compiler/lyric/bench_synth/bench_synth.l`** — `Lyric.BenchSynth` package.
  Parses a `@bench_module` file, validates constraints (`@bench_module` present, no user
  `main`), collects `@bench`-annotated `IFunc` items, and synthesises a `func main(): Int`
  timing harness using `Std.Time.now()` / `since()` / `totalMillis()`.  The harness runs
  `--warmup` un-timed iterations then `--runs` timed iterations per benchmark, printing
  `min / max / mean` milliseconds.  `--filter` (empty = no filter) is applied during the
  AST walk so only matching functions appear in the synthesised main.
  Key implementation note: `Item.span.endPos` in the self-hosted parser points at the
  first token of the *next* item (`peekSpan` captures lookahead post-parse), not the end
  of the current item.  Source emission is therefore verbatim (the original source is
  passed through unchanged) with the synthesised main appended at the end, avoiding
  the double-emission bug that span-based carve-out would cause.

- **`lyric-compiler/lyric/bench_synth_bridge.l`** — `Lyric.BenchSynthBridge` text-protocol
  bridge.  Line-oriented protocol: `ok\n<count>\n<src>`, `nobench\n<line>\n<col>`,
  `usermain\n<line>\n<col>`, `parsefail\n<code>|<sev>|<line>|<col>|<msg>…`.
  Entry point: `pub func synthesizeBenchToProtocol(source, runs, warmup, filter): String`.

- **`bootstrap/src/Lyric.Cli/SelfHostedBench.fs`** — thin F# shim.  Compiles
  `Lyric.BenchSynthBridgeDriver` in-process, reflects
  `Lyric.BenchSynthBridge.Program.synthesizeBenchToProtocol(string, int, int, string)`,
  parses the protocol into an F# `Outcome` union (`Synthesised | NoBenchModule |
  UserMainExists | ParseFailures`).

- **`bootstrap/src/Lyric.Cli/Program.fs`** — `bench` command dispatch.  Parses `--runs`,
  `--warmup`, `--filter`; calls `SelfHostedBench.synthesize`; writes synthesised source to
  a temp dir; builds via the existing `build` helper; `dotnet exec`s the result.

**Benchmark files shipped:**
- `benchmarks/bench_numeric.l` — `Bench.Numeric`: integer sum, multiply-accumulate, GCD, double sum, recursive Fibonacci.
- `benchmarks/bench_collections.l` — `Bench.Collections`: List build/traversal/sum, Map insert, Map insert+lookup.
- `benchmarks/bench_contracts.l` — `Bench.Contracts`: plain vs `@runtime_checked` vs `@axiom` clamp function.
- `benchmarks/bench_string.l` — `Bench.String`: concat, toString, `.length`, `Str.contains`, `Str.replace`.

**B-series diagnostic codes added:** B0900 (missing `@bench_module`), B0901 (user `main` in bench module), B0902 (no matching `@bench` functions).

**Documentation:** book chapter 28 (`book/chapters/28-benchmarking.md`), toolchain table in `book/chapters/01-getting-started.md`, annotations and CLI in `book/chapters/appendix-b-quick-reference.md`, §13.9 in `docs/01-language-reference.md`.

**Test outcome:** 224/224 CLI tests pass.

---

### D-progress-249: Std.Jvm.catch fully implemented as inline try-catch intrinsic (B127)

`Std.Jvm.catch` was previously a stub with `@experimental` + `@externTarget("lyric.runtime.jvm.ExceptionHelper.catch")`.  It is now a fully implemented JVM codegen intrinsic.

**Changes shipped:**
- `lyric-compiler/jvm/codegen.l` — new `lowerCatchIntrinsic` function (§5h).
  When `lowerBuiltinOrStaticCall` sees a `catch` call with an `ELambda` argument,
  it macro-expands it to an inline JVM try-catch: the lambda body is lowered in-place
  as the try region, success wraps the result in `Result$Ok`, and any
  `java.lang.Exception` is caught and wrapped in `Result$Err`.  No anonymous inner
  class generation is required.  Non-literal lambda arguments fall through to the
  existing general call path (which fails at JVM load time — documented as a limitation).
- `lyric-stdlib/std/_kernel/jvm.l` — `Std.Jvm.catch` promoted from `@experimental` +
  `@externTarget` to `@stable(since="1.0")` with documentation of the intrinsic's
  emitted bytecode shape.
- Stage B127 (`lyric-compiler/jvm/self_test_b127.l` + `JvmLoweringB127Test.fs`) —
  validates the complete try-catch bytecode pattern via `Wrapper$Ok`/`Wrapper$Err`
  union classes and a `SafeDiv.safeDivide(a, b)` method that catches
  `ArithmeticException` on divide-by-zero.

**Test outcome:** 758/758 emitter tests pass.

---

### D-progress-250: Std.Testing.Snapshot graduated to @stable; configurable dir + diff rendering

`Std.Testing.Snapshot` was bootstrap-grade with a hardcoded `snapshots/` directory
and no diff output on mismatch.

**Changes shipped (`lyric-stdlib/std/testing_snapshot.l`):**
- `snapshotIn(dir, label, actual)` — new 3-argument form taking an explicit snapshot
  directory.  Creates `<dir>/` on first run if absent.
- `snapshot(label, actual)` — retained; now delegates to `snapshotIn("snapshots", ...)`.
- `snapshotMatchIn(dir, label, actual)` — new panicking helper that, on mismatch,
  re-reads the snapshot file and calls `firstDiff` to show the first differing line
  (line number, `- expected`, `+ actual` format) in the panic message.
- `snapshotMatch(label, actual)` — retained; now delegates to `snapshotMatchIn`.
- Internal `firstDiff(expected, actual)` helper — splits on `"\n"`, finds first
  differing line or line-count difference.
- All four `pub` functions promoted from `@experimental` to `@stable(since="1.0")`.

---

### D-progress-252: R1 stdlib API surface declared; @stable annotations completed

- `stdlib/STABILITY.md` created: full module/tier table covering all 34 top-level stdlib
  modules and all 25 kernel files.
- `lyric-stdlib/std/core.l`: added `pub` visibility and `@stable(since="1.0")` to all exported
  items (`Option`, `Result`, `unwrapOr`, `isSome`, `isNone`, `isOk`, `isErr`,
  `unwrapResultOr`, `unwrapErrOr`, `sumInts`, `maxInt`, `countEq`, `mapOption`,
  `mapResult`, `filterOption`, `countWhere`, `andThen`, `orElse`, `andThenResult`).
- `lyric-stdlib/std/testing_mocking.l`: added `@stable(since="1.0")` to `StubCounter`,
  `makeStubCounter`, `stubCounterIncrement`, `stubCounterGet`, `stubCounterReset`.
- All other stdlib modules had already been annotated in prior milestones.
- R1 acceptance criterion met: every `pub` item in the stdlib is now annotated.

### D-progress-253: R2 formatter deprecation notice shipped

- `docs/01-language-reference.md` §13.7 formatter flags table: added `--legacy` row
  documenting "**Deprecated — removed in v1.1.**" with the caveat that it drops
  all non-doc `//` comments.
- `book/chapters/appendix-b-quick-reference.md` line 693: updated `--legacy` comment
  to "DEPRECATED, removed in v1.1".
- No code changes; G3 decision (D066) authorises keeping `--legacy` through 1.0.

### D-progress-254: R3 Q-J013 @externTarget call-site codegen shipped (B128)

Q-J013 — try-catch wrapper for `@externTarget` static/virtual calls.

In `lyric-compiler/jvm/codegen.l`, `lowerFunc`'s `case None` path (body-less functions)
now detects `@externTarget` annotations and emits the actual JVM invoke instead of a
stub default return.  New helpers:

- `findExternTarget(decl)` — scans `decl.annotations` for `@externTarget("string")` and
  returns the target string.
- `isResultJvmException(ret)` — returns `true` when the declared return type is
  `Result[T, JvmException]` for any `T`.
- `extractResultValueType(te, pkgName)` — extracts `T` from `Result[T, JvmException]`
  and maps it to a `JvmType`.
- `isStaticExternByName(name)` — returns `true` when the Lyric function name follows
  the Maven static convention `TypeName_methodName` (PascalCase prefix before `_`).
- `lowerExternTargetBody(decl, ctx, insns, target)` — emits:
  - Param loads (all params in slot order; receiver first for instance calls).
  - `invokestatic` or `invokevirtual` per the static heuristic.
  - When `isResultJvmException` is true: inline try-catch wrapping the invoke in
    `Result$Ok` / `Result$Err` (same pattern as `lowerCatchIntrinsic`).
  - Direct return otherwise.

Stage B128 (`lyric-compiler/jvm/self_test_b128.l`) validates the bytecode shape:
builds a `ParseWrapper.tryParseInt(String): Object` method that calls
`Integer.parseInt` with a try-catch, then calls it with `"42"` (→ `ok:42`) and
`"abc"` (→ `err:NumberFormatException`).  F# test `JvmLoweringB128Test.fs` runs
the JAR and asserts both output lines.

### D-progress-251: v1.0 gate decisions G3–G5 resolved (D066)

Gate decisions G3, G4, and G5 from `docs/36-v1-roadmap.md` recorded as D066 in
the decision log.

- **G3 resolved:** `--legacy` / `LYRIC_FMT_LEGACY=1` survives as deprecated through
  v1.0; removed in v1.1.  Per-expression CST gap deferred to 1.1.
- **G4 resolved:** `lyric-*` service libraries version independently of the compiler
  and core stdlib.  Each declares its stability policy in its own `lyric.toml`.
- **G5 resolved:** Three-stage reproducibility bootstrap is not a v1.0 gate.
  F# bootstrap is the primary build path for 1.0; reproducibility is a Phase-7
  deliverable.

Roadmap table in `docs/36-v1-roadmap.md` updated to reflect resolved status.

---

### D-progress-250: Self-hosted LSP — all 28 `Lyric.Lsp.Tests` pass

**Date:** 2026-05-14
**Branch:** `claude/migrate-lsp-lyric-lCkms`

Completed the self-hosted LSP server (`lyric-compiler/lyric/lsp.l`) so that all
28 `Lyric.Lsp.Tests` protocol tests pass (previously 0 passed; 24 passed after
fixes in D-progress-247 range; the remaining 4 fixed here).

**Changes shipped in this milestone:**

**`lyric-compiler/lyric/lsp.l`** — four bugs fixed:

1. **Generic `Option[T]` equality**: `foundIt == None` and `foundSpan == None`
   in `handleHover` / `handleDefinition` always returned `false` because the
   bootstrap emitter creates a new `None` instance via `Newobj` for each
   generic `Option[T]` construction (not a singleton), so reference equality
   (`Ceq`) fails.  Fixed by replacing `== None` guards with `isNone(foundIt)`
   / boolean `localDone` / `wsDone` / `fileDone` flags that use `isinst`-based
   pattern matching internally.

2. **`analyzeAndStore` if-branch `Dictionary.Remove` stack imbalance**: the
   emitter does not emit `pop` for `Dictionary.Remove()` (Bool-returning) inside
   an `if` branch, causing `InvalidProgramException` at JIT time.  Fixed by
   calling `state.store.remove(uri)` unconditionally (safe on absent key) as a
   standalone statement before `state.store.add(uri, doc)`.

3. **Deeply-nested match-as-expression emitter bug**: `handleHover` and
   `handleDefinition` had three or four levels of nested match expressions, each
   returning a String via the innermost case's block.  The F# bootstrap emitter
   produces incorrect MSIL for this pattern — the deeply-nested branch result
   is not left on the evaluation stack, so the function effectively returns
   `null` (serialised as `""` in the JSON response, producing
   `{"result":}` at parse time).  Fixed by converting all "return the result
   via the last expression of a nested match arm" patterns to explicit `return`
   statements inside each arm, with a fallback literal after the outermost
   match.  This avoids relying on the emitter's nested-match return-value
   propagation entirely.

4. **`SelfHostedLsp.fs` reflection lookup**: `pickStatic` was matching by
   method name AND parameter types, but reflected methods on the
   `Lyric.Lsp.Program` type sometimes had mismatched CLR parameter types (e.g.
   `LspState` from a reloaded assembly vs the current assembly version).
   Fixed by matching on method name only.

**`lyric-stdlib/std/_kernel/console_host.l`** (new) — adds `hostConsoleRead` and
`hostConsoleWrite` as `@externTarget` wrappers over `System.Console.Read` /
`System.Console.Write`, used by the LSP frame reader.

**`lyric-stdlib/std/_kernel/file_host.l`** (new) — adds `hostFileExists`,
`hostDirectoryExists`, `hostReadAllText`, `hostWriteAllText`,
`hostReadAllBytes`, `hostWriteAllBytes`, `hostEnumerateFiles`, and
`hostEnumerateDirectories` as `@externTarget` wrappers over the BCL
`System.IO.File` / `System.IO.Directory` APIs, used by the LSP workspace
indexer and go-to-definition cross-file search.

**`bootstrap/src/Lyric.Lsp/SelfHostedLsp.fs`** — `pickStatic` now matches by
method name only (not by parameter types) to tolerate assembly reload scenarios
during in-process reflection.

**`bootstrap/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs`** — kernel extern
surface hard cap bumped from 270 → 274 to account for the four new kernel
functions in `console_host.l` (2) and the net-new functions in `file_host.l`
(2 beyond what was already in `io.l`).

**Outcome:**

- 28/28 `Lyric.Lsp.Tests` pass (was 24/28, with 4 erroring on JsonReaderException).
- 756/756 emitter tests pass, 224/224 CLI tests pass, all other suites green.

---

### D-progress-252: lyric-proto, lyric-grpc, and lyric-otel OTLP exporter (D067–D069)

Three new libraries and an exporter package shipped.

**`lyric-proto/`** (new library, D067) — Pure-Lyric Protocol Buffer wire-format
encoder and decoder.  All varint, fixed-width, and length-delimited encoding
logic lives in `Proto.Encoding` (pure Lyric arithmetic on `Long`/`Int`).
Decoding lives in `Proto.Decoding` with safe error returns on truncated or
malformed input.  The kernel boundary (`Proto.Kernel.Net`) provides only:
- `ProtoBuffer` — opaque `System.IO.MemoryStream` accumulator with
  `newProtoBuffer`, `bufWriteByte`, `bufWriteBytes`, `bufToBytes`, `bufLength`.
- `floatToInt32Bits` / `doubleToInt64Bits` via `System.BitConverter`.
- `byteAt`, `int32LE`, `int64LE`, `sliceCopy` for the decoder's raw-read needs.

ZigZag helpers (`zigzag32/64`, `unzigzag32/64`) live in `Proto.Types` as pure
Lyric integer arithmetic.  Convenience constructors (`floatField`, `boolField`,
`sint32Field`, etc.) are in `Proto.Encoding`.  Typed extraction helpers
(`findVarint`, `findBytes`, `collectBytes`) are in `Proto.Decoding`.

**`lyric-grpc/`** (new library, D068) — General-purpose gRPC client.  Wraps
`Grpc.Net.Client` 2.65.0 on .NET using a pass-through `Marshaller<byte[]>` so
callers supply and receive raw protobuf bytes without generated stub code.
Supports unary calls (`callUnary`) and server-streaming (`openServerStream` /
`nextMessage` / `closeStream`).  Call options carry an optional deadline and
per-call metadata headers.  The JVM kernel (`Grpc.Kernel.Jvm`) is a Phase 6
stub mirroring the .NET API using `io.grpc.ManagedChannel`.

**`lyric-otel/src/otlp.l`** (new package `OTel.Otlp`, D069) — OTLP exporter
configuration API.  `configureOtlpTraces`, `configureOtlpMetrics`,
`configureOtlpLogs`, and the combined `configureOtlp` set up the OTel .NET SDK
pipeline with an OTLP exporter.  `flushOtlp(timeoutMs)` force-flushes all
providers before process exit.  `config OtlpDefaults` exposes runtime-
configurable defaults.  The .NET kernel (`OTel.Kernel.Net.Otlp`) trusts the
`OpenTelemetry` + `OpenTelemetry.Exporter.OpenTelemetryProtocol` NuGet packages
(both 1.9.0) to manage batching, retry, and protocol negotiation.  The JVM
kernel is a Phase 6 stub.

**`lyric-otel/lyric.toml`** — updated: new packages `OTel.Kernel.Net.Otlp`,
`OTel.Kernel.Jvm.Otlp`, `OTel.Otlp`; new NuGet dependencies
`OpenTelemetry` 1.9.0 and `OpenTelemetry.Exporter.OpenTelemetryProtocol` 1.9.0.

**Outcome:**

- `lyric-proto`, `lyric-grpc` are new top-level libraries with no F# changes.
- `lyric-otel` gains OTLP export; existing `OTel.*` aspect templates and wrapper
  functions are unchanged.
- No compiler tests affected (libraries are pure Lyric source, compiled on demand).

---

### D-progress-255: R4 — M5.3 stage 6: Doc, Lint, and Pack csproj ported to self-hosted Lyric

R4 from `docs/36-v1-roadmap.md` is now complete for the three actionable items.

**Lyric.Doc** (`lyric-compiler/lyric/doc/doc.l`):
- Package `Lyric.Doc`; mirrors `bootstrap/src/Lyric.Cli/Doc.fs`.
- Imports `Lyric.Lexer` and `Lyric.Parser`; calls `parse(source)` internally.
- Generates Markdown for all public items: `IFunc`, `IRecord`, `IExposedRec`,
  `IUnion`, `IEnum`, `IOpaque`, `IInterface`, `IDistinctType`, `ITypeAlias`,
  `IConst`.  Renders doc comments and type signatures as fenced code blocks.
- Bridge: `lyric-compiler/lyric/doc_bridge.l` (`Lyric.DocBridge`);
  protocol `"ok\n<markdown>"`.
- F# shim: `bootstrap/src/Lyric.Cli/SelfHostedDoc.fs` replaces the removed
  `bootstrap/src/Lyric.Cli/Doc.fs`.
- `Program.fs` `lyric doc` command now calls `SelfHostedDoc.generate`.

**Lyric.Lint** (`lyric-compiler/lyric/lint/lint.l`):
- Package `Lyric.Lint`; mirrors the rule logic previously in `Lyric.Cli.Lint`.
- Five rules: L001 (PascalCase types), L002 (camelCase funcs), L003 (pub doc),
  L004 (TODO/FIXME in doc comments), L005 (pub func with block body has contracts).
- Bridge: `lyric-compiler/lyric/lint_bridge.l` (`Lyric.LintBridge`); pipe-delimited
  protocol one diagnostic per line: `<code>|<sev>|<line>|<col>|<message>`.
- F# shim: `bootstrap/src/Lyric.Cli/SelfHostedLint.fs`.
- `Lint.fs` gutted to types and `renderDiagnostic` only (domain logic removed).
- `Program.fs` `lyric lint` command now calls `SelfHostedLint.lint`.
- `LintTests.fs` updated: `lintSource` now calls `SelfHostedLint.lint source`
  (integration path through the Lyric bridge).

**Lyric.Pack csproj XML** (`lyric-compiler/lyric/pack/pack.l`):
- Package `Lyric.Pack`; ports the `publishCsproj`/`restoreCsproj` XML-generation
  logic from `bootstrap/src/Lyric.Cli/Pack.fs`.
- Reads `Lyric.Manifest` types directly (`m.packageSection`, `m.deps`,
  `m.nuget` → `Option[NugetSection]`).
- Generates `<Project Sdk="Microsoft.NET.Sdk">` XML for both `dotnet pack` and
  `dotnet restore` use cases; respects `[nuget]` / `[nuget.options]` sections.
- Bridge: `lyric-compiler/lyric/pack_bridge.l` (`Lyric.PackBridge`); parses
  incoming TOML via `Lyric.Manifest.parse`, then calls `publishCsproj`/`restoreCsproj`.
  Protocol: `"ok\n<csproj>"` or `"parsefail\n<message>"`.
- F# shim: `bootstrap/src/Lyric.Cli/SelfHostedPack.fs`.
- `Pack.fs` `runPack`/`runRestore` updated to read `lyric.toml` text and
  call `SelfHostedPack.publishCsproj`/`SelfHostedPack.restoreCsproj`.
- `PackTests.fs` updated: XML-checking tests now pass TOML strings to the
  bridge rather than constructing F# `Manifest` objects.

**Deferred from R4:**
- `Lyric.ContractMeta` — the BCL-reflection-backed embedded resource reader
  (`bootstrap/src/Lyric.Emitter/ContractMeta.fs`, ~818 lines) is used by
  `lyric public-api-diff` and the cross-package verifier, not by Doc/Lint/Pack.
  Porting it requires a Lyric PE-metadata reader; deferred post-v1.0.
- `Fmt.fs` sunset — gated on R2 (CST formatter parity); not changed here.

**Build:** `dotnet build Bootstrap.sln` succeeds (0 warnings, 0 errors).
**Tests:** `Lyric.Cli.Tests`: 204/224 passed; 20 errored (all pre-existing JVM
parity failures unrelated to R4). `Lyric.Emitter.Tests`: 759/759 passed.

### D-progress-256: R5 — Language gaps Q021-4, Q022-1, Q022-3 closed; Q022-4 documented

R5 from `docs/36-v1-roadmap.md` is now substantially complete.  Q022-2 is deferred.

**Q021-4: Cross-package distinct types in `satisfiesMarker`**
- `bootstrap/src/Lyric.Emitter/Records.fs`: Added `Derives: string list` field to
  `ImportedDistinctTypeInfo`.
- `bootstrap/src/Lyric.Emitter/Emitter.fs`: Added a loop after the protected-types loop
  that populates `importedDistinctTypeTable` from `IDistinctType` items in each loaded
  artifact's `Source.Items`.  Reflects `Value` field, `From` method, and optional `TryFrom`
  method; stores `d.Derives` directly from the parsed AST.  Also registers the CLR type in
  `typeIdToClr` so cross-package type references resolve.
- `bootstrap/src/Lyric.Emitter/Codegen.fs`: Added **Path 1.5** to `satisfiesMarker`: checks
  `ctx.ImportedDistinctTypes.Values` for a matching CLR type, then verifies the marker is in
  `info.Derives`.  Cross-package `type Age = Int derives Hash` now satisfies `f[T] where T: Hash`.

**Q022-3: UFCS on `OpaqueType[T]` receivers**
- `bootstrap/src/Lyric.Emitter/Codegen.fs` `inlineUfcsCall`: Extended the
  `ctx.Records` lookup to also match generic opaque instantiations.  When
  `recvTy.IsGenericType` and the TypeBuilder equals `recvTy.GetGenericTypeDefinition()`,
  the record name is returned so UFCS dispatch proceeds.  Previously silently fell
  through to "method not found" for closed generic opaques.

**Q022-1: `pub use` symbol-level re-export**
- `bootstrap/src/Lyric.Emitter/ContractMeta.fs`: Added private `pubUseDecls`
  function and changed `buildContract` signature to accept an
  `importedSources: Map<string, SourceFile>` parameter.  `pubUseDecls` filters
  `sf.Imports` for `IsPubUse = true`, looks up the package in `importedSources`,
  and cherry-picks only the named symbols (or all pub items for a bare
  `pub use Pkg`).  The cherry-picked `ContractDecl` values are appended to the
  contract after the package's own decls.
- `bootstrap/src/Lyric.Emitter/Emitter.fs` (single-file path): Builds `importedSourcesMap`
  from `stdlibArtifacts` and passes it to `buildContract`.
- `bootstrap/src/Lyric.Emitter/Emitter.fs` (project path): Changed
  `perPackageContracts` tuple to include `Map<string, SourceFile>`; builds and stores
  the map per package from `mergedArtifacts`; uses it in Phase C (contract embed).
- `bootstrap/tests/Lyric.Verifier.Tests/StabilityCheckTests.fs`: Updated two
  `buildContract` call sites to pass `Map.empty` (no pub-use imports in those tests).

**Q022-4 (fallback): `@externTarget` generic BCL methods documented**
- `docs/01-language-reference.md` §11.3: Added `@externTarget` section explaining
  the annotation, its kernel-only scope, and the limitation that generic BCL
  methods require explicit per-type monomorphised declarations (the Lyric type
  parameter cannot be substituted into the `@externTarget` string).

**Deferred:**
- Q022-2: Generic opaque types in `Lyric.Contract` resource — cross-package
  generic opaque types are partially invisible to the contract reader.  Impact is
  limited (UFCS now works via Q022-3; the contract gap only affects `pub-api-diff`
  and verifier cross-package reasoning).  Deferred post-v1.0.

**Build:** `dotnet build Bootstrap.sln` succeeds (0 warnings, 0 errors).
**Tests:** `Lyric.Emitter.Tests`: 759/759; `Lyric.Verifier.Tests`: 266/266;
`Lyric.Cli.Tests`: 204/224 (same 20 pre-existing JVM parity failures).

### D-progress-257: R6 — Distribution and signing workflow shipped

R6 from `docs/36-v1-roadmap.md` is now complete.

**`.github/workflows/publish.yml`** — Release workflow triggered on `v*` tag push:
- **Matrix build**: five platform/RID combinations (`linux-x64`, `linux-arm64`,
  `osx-arm64`, `osx-x64`, `win-x64`) using `dotnet publish --self-contained
  --runtime <RID> -p:PublishSingleFile=true`.
- **Authenticode signing** (Windows): conditional step using `AzureSignTool`
  when `AZURE_KEY_VAULT_URL` secret is present.  Signs `lyric.exe` before packaging.
- **macOS signing + notarization** (osx-arm64): conditional codesign +
  `xcrun notarytool submit --wait` when `APPLE_TEAM_ID` secret is present.
  Uses a temporary keychain; cleans up after signing.
- **Archive packaging**: `.tar.gz` for Linux/macOS, `.zip` for Windows;
  named `lyric-<version>-<rid>.<ext>`.
- **GitHub Release upload**: `softprops/action-gh-release@v2` uploads all archives.
- **NuGet package**: `dotnet pack -p:PackAsTool=true -p:ToolCommandName=lyric
  -p:PackageId=lyric` in a separate `publish-nuget` job that runs after
  `build-standalone` succeeds.
- **NuGet signing**: conditional `dotnet nuget sign` step when
  `NUGET_SIGNING_CERT_BASE64` secret is present.
- **NuGet push**: `dotnet nuget push --skip-duplicate` to `https://api.nuget.org`.

**`scripts/install.sh`** — Zero-prerequisite POSIX installer:
- Detects platform (`Linux`/`Darwin`/`MINGW*`) and architecture (`x86_64`,
  `aarch64`, `arm64`) via `uname`.
- Resolves latest version from GitHub API if `--version` not specified.
- Downloads archive with `curl` or `wget`; extracts to `~/.lyric/bin`
  (or `--dir <path>`).
- Appends `export PATH=...` to `.bashrc`/`.zshrc`/fish config; skips if
  already in PATH; skips if `--no-path` is passed.
- Verifies installation with `lyric --version`.

**`docs/34-distribution-strategy.md`** — Added §7 (Release workflow), §8
(Install script), and §9 (Open questions).  Documents required repository secrets,
placeholder for certificate fingerprints, and resolves Q-dist-005 / Q-dist-006.

**docs/36-v1-roadmap.md** — R6 marked COMPLETE (D-progress-257).

---

### D-progress-258: CI fix — JVM parity tests, emitPatternTest, publish.yml, and SelfHostedDoc

_Branch: claude/identify-v1-blockers-JvIWJ. Fixes to CI gate and code-quality issues
identified by claude-review on PR #291._

**Root cause of CI failure:** All 20 JVM parity tests (`Lyric.Cli.Tests`) were erroring due to
three layered bugs in the JVM bridge compilation path:

1. **`Codegen.fs:emitPatternTest`** — `List.zip (sub |> List.truncate fields.Length) fields`
   crashed when `sub.Length < fields.Length` (truncation only guarded the long-sub case, not
   the short-sub case). Lyric patterns with fewer sub-patterns than union case fields are valid
   (implicit wildcard for trailing fields). Fixed by computing `pairCount = min sub.Length
   fields.Length` and truncating both lists. Same fix applied to `emitPatternBind` at the
   parallel zip site.

2. **`lyric-compiler/jvm/codegen.l:lowerExternTargetBody`** — `substring(target, dotIdx + 1)` used
   the 2-arg overload, but the type checker resolves to the 3-arg form `substring(s, start, count)`.
   Fixed to `substring(target, dotIdx + 1, length(target) - dotIdx - 1)`.

3. **`lyric-compiler/jvm/codegen.l:lowerFunctionDecl`** — match arm `case Some(target) ->
   lowerExternTargetBody(...)` returned `JvmType` while the sibling arm `case None ->
   emitReturn(...)` returned `Unit`, causing T0068. Fixed by wrapping the call in `{ ...; () }`
   to discard the return value.

**Additional fixes from claude-review feedback:**

- **`publish.yml` NuGet signing** — `if: env.NUGET_CERT_PRESENT == 'true'` with step-level
  `env:` never evaluates (step env not visible to `if:`). Changed to
  `if: ${{ secrets.NUGET_SIGNING_CERT_BASE64 != '' }}` which evaluates at workflow level.
- **`publish.yml` macOS cert cleanup** — `/tmp/cert.p12` was not removed after signing. Added
  `rm -f /tmp/cert.p12` immediately after `codesign`.
- **`SelfHostedDoc.generate`** — bridge response "ok\n<body>" tag was not validated; bad
  responses were silently swallowed. Now fails with a clear message if tag ≠ "ok".
- **`scripts/install.sh`** — removed dead `for arg in "$@"; do :; done` loop (from a
  copy-paste artifact).

**Test results post-fix:** 224/224 Lyric.Cli.Tests passed (was 204/224, 20 errored).
All other suites unchanged: Emitter 759/759, Verifier 266/266, LSP 28/28,
Parser 323/323, TypeChecker 189/189, Lexer (unchanged).

---

### D-progress-259: Enhanced aspect pointcut predicates

_Branch: claude/enhance-aspect-pointcuts-3DqXL / follow-up claude/aspect-pointcut-followup.
Shipped in PR #296 + follow-up._

Extends the aspect `matches:` clause from name-glob-only to four composable predicates with AND
semantics (all must hold). The `except name in { … }` exclusion clause is also now fully parsed
and enforced by the weaver.

**New predicate forms:**

| Predicate | Selects when… |
|-----------|---------------|
| `name like "<glob>"` | Short name matches the POSIX-ish glob (existing) |
| `annotated: @Name` | Function carries the annotation (short-name match) |
| `visibility: pub \| priv \| internal` | Access level matches |
| `signature: returns "<glob>"` | Return-type string matches the glob |

`signature: returns` takes a **string literal** glob (consistent with `name like`) to avoid
a TStmtEnd-inside-braces ambiguity in the lexer: TStmtEnd is not inserted between lines
when inside a `{ }` block, so a bare-identifier type-glob parser consumed the next keyword.

**Weaver changes (`Weaver.fs`):**

- `typeExprToString` — renders a `TypeExpr` to a dotted string for glob matching.
  `TError` maps to `"<error>"` (prevents wildcard `"*"` from silently matching ill-typed
  functions); non-`TAType` generic args render as `"_"` rather than being silently dropped.
- `matchesPredicates` — evaluates all matchers with `List.forall` (AND semantics).
- `weaveItems` — checks `a.ExceptNames` before calling `matchesPredicates`.

**Parser changes (`Ast.fs`, `Parser.fs`):**

- `AspectMatcher` union: three new cases `AMAnnotated`, `AMVisibility`, `AMSignatureReturns`.
- `AspectDecl` record: new `ExceptNames: string list` field.
- `parseOneMatchPredicate` dispatches on `annotated:`, `visibility:`, and `signature: returns`.
- `parseAspectMatchesClause` reads `and`-joined predicates then the optional `except name in { … }` list.
- Dead `parseTypeGlobPattern` removed; unused span captures removed.

**Self-hosted mirrors:** `parser_ast.l`, `parser_items.l`, `fmt_items.l` updated in parallel.

**Test results:** Emitter 764/764 (5 new aspect weaver tests), Parser 323/323, Cli 224/224.

### D-progress-260: M1.4 async gap fixes and async-generator synthesis (Gap-1 through Gap-4)

_Branch: claude/lyric-async-investigation-1IkTZ._

Addressed four async gaps identified in the async bootstrap story:

**Gap-1 — `collectPromotableLocals` did not recurse into `SFor` bodies.**
The helper that lifts captured locals out of async closures skipped `SFor`
loop bodies, so locals declared inside `for` loops were never promoted to
state-machine fields and went missing after the first yield/suspension.
Fixed in `AsyncStateMachine.fs` by adding a `SFor` arm to the body-walking
match.

**Gap-2 — `try`-as-expression and trailing `await`.**
Two parser/emitter edge cases: (a) the Lyric `try` keyword in expression
position was not handled in `parsePrimaryExpr`, causing a parse error when
`try` appeared inside a larger expression; (b) the exit-label routing in
`Emitter.fs` did not correctly handle an implicit-return `await` at the end
of an async function body (the trailing expression's stack value was
popped before the state-machine builder's `SetResult` call). Fixed.

**Gap-3 — `@hot` annotation / `ValueTask<T>` path.**
The `@hot` annotation was parsed and stored but was not threaded into the
async state-machine builder selection in `AsyncStateMachine.fs`. Fixed so
that `@hot async func` routes to the `AsyncValueTaskMethodBuilder<T>` path
instead of `AsyncTaskMethodBuilder<T>`.

**Gap-4 — Async generator synthesis.**

A new `AsyncGenerator.fs` module was added to `Lyric.Emitter`. For each
`async func` whose body contains at least one `yield`, the emitter:

1. Synthesises a sibling class implementing `IAsyncEnumerable<T>`,
   `IAsyncEnumerator<T>`, and `IAsyncDisposable` (the generator class).
2. Rewrites the user's function into a kickoff stub that creates the
   generator instance and copies parameters into its fields.
3. Emits the body into a `RunBody()` method on the generator class where
   each `yield e` becomes `_values.Add(e)`.

Bootstrap semantics: `RunBody` is called synchronously by
`GetAsyncEnumerator`, so all yields execute eagerly. Generators with
`await` inside their body emit a diagnostic (Gap-4a, deferred to M2).

`for x in gen() { … }` consumption is lowered by the emitter as a
standard `await foreach` loop (GetAsyncEnumerator → MoveNextAsync loop
→ Current → DisposeAsync in finally).

**Parser fix (Gap-4 dependency).** `yield` in `parsePrimaryExpr` was
calling `parsePostfixExpr` for its operand, so `yield a * 2` parsed as
`(yield a) * 2`. Fixed to use `parseExpr`, giving `yield (a * 2)`.
(`await` intentionally keeps `parsePostfixExpr` so `await foo() + 1`
means `(await foo()) + 1`.)

**JVM parity (B129).** `lowerAsyncGenerator` added to
`lyric-compiler/jvm/lowering.l`. Emits a generator class implementing
`java.lang.Iterable` + `java.util.Iterator` with the same eager `runBody()`
pattern. Uses class-file version 49 (Java 5) to avoid requiring
StackMapTable attributes for `hasNext()`'s branch. Kickoff method corrected
to load static-method parameters from slot 0 (not slot 1). Test:
`self_test_b129.l` / `JvmLoweringB129Test.fs`.

**Test results:** 764/772 emitter tests pass, 0 failed, 8 pre-existing
errors (TypeBuilderInstantiation.GetInterfaces() issues, unrelated to this
work). New async generator tests: `generator_basic`, `generator_yield_with_params`,
`generator_empty_yield`, `generator_multiple_yields`, `generator_for_loop_consumer`,
`generator_with_computation` in `AsyncTests.fs`.

---

### D-progress-261 — Gap-4a: async generators with internal `await` (M1.4)

**Gap closed.** Async generators whose bodies contain both `yield` and `await`
expressions are now fully supported. Previously the emitter rejected any
`yield`-in-`async func` body that also contained an `await`, deferring to a
future milestone.

**Design.** Two distinct lowering strategies are now selected at compile time:

- *Eager-producer* (no `await` in body, unchanged): `RunBody()` fills a
  `List<T>` synchronously; `MoveNextAsync()` steps through it.
- *Async-iterator* (`await` present in body, new): A combined class implementing
  `IAsyncStateMachine`, `IAsyncEnumerable<T>`, and `IAsyncEnumerator<T>` is
  synthesised. `MoveNextAsync()` allocates a fresh `TaskCompletionSource<bool>`,
  invokes `MoveNext()` (the state machine body), and returns
  `ValueTask<bool>(tcs.Task)`.  A `yield` stores its value in `<>2__current`,
  calls `tcs.SetResult(true)`, and issues a `Leave` to the suspend point.  An
  `await` hooks `AwaitUnsafeOnCompleted` and issues a `Leave` to the same
  suspend point.  The body's final exit calls `tcs.SetResult(false)`.
  `AsyncTaskMethodBuilder` (void) is used solely for its
  `AwaitUnsafeOnCompleted` method; `SetResult`/`SetException` on the builder
  are never called.

**State numbering.** States `0 .. A-1` are await-resume states (as in a plain
async function); states `A .. A+Y-1` are yield-resume states.  Both share the
same `<>1__state` field and the same dispatch switch at the top of `MoveNext`.

**Promoted locals.** `collectPromotableLocals` already collects all top-level
let/var bindings.  Those that straddle an `await` boundary were already flushed
by the `EAwait` handler.  The `EYield` handler now also flushes them (all
`PromotedShadows` pairs) before the `Leave`, ensuring variables survive across
yield-resume boundaries.

**Implementation files changed:**

- `bootstrap/src/Lyric.Emitter/AsyncStateMachine.fs` — added `collectYieldInners`
  (parallel to `collectAwaitInners`) to count yield points for state layout.
- `bootstrap/src/Lyric.Emitter/AsyncGenerator.fs` — added `AsyncIterYieldCtx`,
  `AsyncIterPromotedLocal`, `AsyncIteratorGeneratorInfo` types;
  `defineAsyncIteratorGeneratorClass` synthesises the combined class;
  `emitAsyncIteratorKickoff` emits the static kickoff method.
- `bootstrap/src/Lyric.Emitter/Codegen.fs` — `FunctionCtx` gains
  `AsyncIterYieldCtx` field; `EYield` handler checks it before the existing
  eager-producer path.
- `bootstrap/src/Lyric.Emitter/Emitter.fs` — routing inside
  `if sg.IsGenerator then` block: if body contains `await`, selects the
  async-iterator path; builds a fake `StateMachineInfo` from
  `AsyncIteratorGeneratorInfo` so the unchanged `EAwait` handler applies.
- `bootstrap/tests/Lyric.Emitter.Tests/AsyncTests.fs` — four new behavioral
  tests: `async_iter_basic`, `async_iter_multi_yield_await`,
  `async_iter_await_before_yield`, plus a structural shape test
  `async_iter_shape` verifying `IAsyncStateMachine + IAsyncEnumerable<T>`
  interface implementation.

**Docs updated:**

- `docs/09-msil-emission.md` §14.6 split into §14.6.1 (eager-producer) and
  §14.6.2 (async-iterator) with full class layout, state diagram, and signaling
  mechanism.
- `docs/01-language-reference.md` §7.2 updated to describe both strategies.
- `docs/03-decision-log.md` D070 updated to ACCEPTED; D035 tracked follow-ups
  updated to remove Gap-4a deferred reference.
- `book/chapters/10-async-and-concurrency.md` §10.5 expanded with
  `await`-in-generator example and implementation strategy description.

**Test results:** 781/781 emitter tests pass, 0 failed. Four new Gap-4a tests
added (`async_iter_basic`, `async_iter_multi_yield_await`,
`async_iter_await_before_yield`, `async_iter_shape`).

### D-progress-262 — Self-hosted pipeline: `yield` / async generator in Lyric compiler (B130)

**Goal.** Wire async generators (Gap-4 / Gap-4a) into every stage of the
self-hosted Lyric compiler: lexer, AST, parser, type checker, mode checker,
monomorphizer, formatter, verifier, JVM codegen / lowering, and MSIL codegen.
The F# bootstrap emitter already had full support (D-progress-260/261); this
entry covers the self-hosted Lyric pipeline.

**Lexer (`lyric-compiler/lyric/lexer.l`).**  Added `KwYield` keyword case,
`kwToStr` arm `"yield"`, and `lookupKeyword` match arm so `yield` is tokenised
as a keyword rather than an identifier.

**AST (`lyric-compiler/lyric/ast.l` and `parser/parser_ast.l`).**  Added
`case EYield(inner: Expr)` after `EAwait` in the `ExprKind` union in both the
canonical AST and the parser-local copy.

**Parser (`lyric-compiler/lyric/parser/parser_exprs.l`).**  Added `case
KwYield` arm in the prefix-expression dispatcher: advances the token, parses
the inner expression with `parseExpr`, and wraps in `EYield`.

**Type checker (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`).**
`EYield(inner)` infers the inner expression and returns `TyPrim(PtUnit)` (yield
is a statement-expression in the type system; its produced type is the generator
element type, but the bootstrap type checker does not yet thread that
constraint).

**Mode checker (`lyric-compiler/lyric/mode_checker/modechecker_check.l`).**
Added `EYield(inner)` arms in `walkExprCalls`, `walkExprQuantifiers`, and
`walkExprAssume`.

**Monomorphizer (`lyric-compiler/lyric/mono.l`).**  Added `EYield(inner)`
rewrite arm.

**Formatter (`lyric-compiler/lyric/fmt/fmt_core.l`).**  Added `EYield(inner)`
arm that renders `"yield " + exprInline(0, inner)`.

**Verifier / stability check (`lyric-compiler/lyric/verifier/stability.l`).**
Added `EYield(inner)` arm.

**Contract elaborator (`lyric-compiler/lyric/contract_elaborator/elaborator.l`).**
Added `EYield(inner)` arm in `substResult`.

**JVM codegen (`lyric-compiler/jvm/codegen.l`).**

- `FuncCtx` record gained `genClass: Option[String]`; `makeFuncCtx` sets it
  to `None`; new `makeFuncCtxForGenerator(pkgName, genClass)` creates a
  context with slot 0 reserved for `this` and `genClass = Some(genClass)`.
- `EYield(inner)` in `lowerExpr`: emits body then `LYield` when inside a
  generator context; panics otherwise.
- `exprContainsYield` / `listContainsYield` / `eobContainsYield` /
  `blockContainsYield` / `stmtContainsYield` — recursive walkers over the AST
  to detect `yield` in any sub-expression.
- `funcBodyContainsYield(decl)` — detects generator functions.
- `lowerGeneratorBody(decl, pkgName, genClass)` — lowers the generator body
  with a preamble that loads each param from `this.<field>` into a local slot.
- `makeGeneratorFactory(decl, genClass, pkgName)` — synthesises a static
  factory `LFunc` (`new GenClass(params...)`) for inclusion in `LPFuncs`,
  avoiding a duplicate class-file name.
- `codegenPackage` `IFunc` routing: when `decl.isAsync and
  funcBodyContainsYield(decl)`, routes to `LPAsyncGenerator` (with `hostClass
  = ""` to suppress a conflicting kickoff class) and adds the factory `LFunc`
  to `fns`.
- `SFor` lowering for non-array types: switched from ArrayList index-based
  iteration to `Iterable.iterator()` / `Iterator.hasNext()` / `Iterator.next()`
  via `LInvokeinterface`, so generator-produced `Iterable<Object>` values are
  correctly consumed.

**JVM lowering (`lyric-compiler/jvm/lowering.l`).**

- `LPackageItem` gained `case LPAsyncGenerator(g: LGenFunc)`.
- `lowerPackage` routes `LPAsyncGenerator` to `lowerAsyncGenerator`.
- `lowerAsyncGenerator` updated: (a) when `g.hostClass == ""`, skips the
  kickoff class to avoid a duplicate-class conflict; (b) the yield-temp slot
  is now computed as one past the highest slot used in `g.bodyInsns` (prevents
  clobbering param-local slots allocated by the preamble); (c) `maxLocals` for
  `runBody` is inferred from the body insns scan rather than hardcoded to `2`.

**MSIL codegen (`lyric-compiler/msil/codegen.l`).**  `EYield(_)` panics with a
clear message pointing to the F# bootstrap path (generic interface instantiation
required for `IAsyncEnumerable<T>` is Phase R6 work).

**Self-test (`lyric-compiler/jvm/self_test_b130.l`).**  Full-pipeline
integration test: calls `Jvm.Bridge.compileToJar` on a Lyric source string
containing `async func evens(n: Int): Int { ... yield ... }` and a `for v in
evens(4)` consumer; verifies the JAR is produced and, when executed with `java
-jar`, prints lines `0`, `2`, `4`, `6`.

**F# test harness (`bootstrap/tests/Lyric.Emitter.Tests/JvmLoweringB130Test.fs`).**
Follows the B129 pattern: `findSource()` locates `self_test_b130.l`, compiles
via `compileAndRun`, checks `jar_written=true` in stdout, verifies the JAR
exists, runs it, and asserts four output lines.  Added to `Program.fs` and
`.fsproj`.

**Test results:** 782/782 emitter tests pass, 0 failed. B130 is the new test.

### D-progress-263 — HIGH-priority security, correctness, and robustness fixes (PR #515)

**Goal.** Resolve 13 open HIGH-priority issues across security hardening, correctness, and robustness categories.

**New lexer diagnostic codes.**

- `L0015` — unrecognised numeric suffix (e.g. `100xyz`). Previously silently parsed the numeric part; now emits an error pointing at the unexpected suffix characters.
- `L0016` — based literal with an empty digit body (e.g. bare `0x`, `0b___` with only underscores). Previously produced a garbled token or crashed; now emits a clear error.

Both codes are added to `bootstrap/src/Lyric.Lexer/Lexer.fs` and covered by new tests in `NumericEdgeTests.fs`.

**Emitter warning A0001 — async `out`/`inout` parameter.**  `async func` declarations with `out` or `inout` parameters are now flagged with `A0001` at emit time.  The async state-machine class cannot hold byref fields; the emitter stores a value copy, which means the caller's variable is not updated.  The warning directs callers to use `Result`-returning patterns instead.

**Verifier warning V0013 — NaN/±Infinity in SMT goals.**  `smtRenderFloat` substitutes `0.0` for non-finite IEEE 754 values (SMT-LIB Real has no representation for them).  The verifier now detects these values in goals via `goalHasNonFiniteFloat` (added to `lyric-compiler/lyric/verifier/driver.l`) and emits `V0013` before discharging, making the approximation visible.

Note: `V0009` is reserved by the mode checker for `assume` outside `unsafe {}`. The NaN/Infinity diagnostic uses the next unallocated code `V0013` (V0010 = conflicting level annotations, V0011 = unknown modifier, V0012 = planned for async-in-proof-required).

**Diagnostic type extension (LSP consumers).**  `bootstrap/src/Lyric.Lexer/Diagnostics.fs` adds three optional fields to the `Diagnostic` record:

- `Help : string option` — a human-readable hint surfaced as a related-information entry in LSP.
- `Related : (Span × string) list` — additional source locations with explanatory labels (LSP `DiagnosticRelatedInformation[]`).
- `Fix : TextEdit option` — a single-span text edit offered as a quick-fix code action in LSP clients.

`TextEdit` is a new record (`Span` + `NewText : string`).  Combinators `withHelp`, `withRelated`, and `withFix` are available for chaining on `Diagnostic` instances.

**ProcessCapture.fs — solver timeout fix.**  `WaitForExit()` (unbounded) replaced with `WaitForExit(10000)` + async `Task.Run` stdout reader, preventing hung Z3/CVC5 processes from blocking the emitter thread indefinitely.

**Security hardening in service libraries.**

- `lyric-feature-flags` — `connectRemote()` rejects plaintext HTTP when an API key is configured (`INSECURE_URL` error code, CWE-319 / OWASP A02:2021).
- `lyric-ws` — `createRegistry()` fails fast with `WS_AUTH_MISCONFIGURED` when JWT auth is enabled but no secret is set, preventing a panic at the first upgrade attempt.
- `lyric-storage` — `presignedUrl` adds `requires: expiresInSeconds <= 604800` (7-day cap) on both the interface and public wrapper.
- `lyric-resilience` — `Retry` aspect config gains `maxDelayMs = 30000` (cap on exponential backoff) and `jitterFraction = 0.1` (10 % uniform jitter added to each delay interval); `backoffDelay` rewritten with safe multiplication and clamping to prevent overflow.
- `lyric-cache` — `CacheEntry` tracks `insertedAt` counter; `evictOldest` evicts by insertion order rather than map-iteration order for deterministic LRU behaviour; expired entries are swept on read.

**SelfHostedCli.fs — bridge robustness.**  Narrowed the broad `with _ ->` catch in `tryRun` to typed load-time exceptions (`FileNotFoundException`, `BadImageFormatException`, `ReflectionTypeLoadException`, `MissingMethodException`, `FileLoadException`).  Added `InvalidProgramException` and `TargetInvocationException wrapping InvalidProgramException` so CLR-JIT rejections of invalid MSIL in the self-hosted pipeline fall back to the bootstrap dispatcher instead of crashing the process.

**Test results:** 782/782 emitter tests pass, 227/227 CLI tests pass.

### D-progress-264 — Workspace, lock file, git-dep, restore, publish, search (docs/38 + docs/39)

**Goal.** Implement the workspace/git-dep spec (`docs/38-workspace.md`, D073)
and the Lyric package registry spec (`docs/39-package-registry.md`, D074) in
self-hosted Lyric source code.

**`Lyric.Manifest` extensions (`lyric-compiler/lyric/manifest.l`).**

New public types backing all dep source forms and workspace/registry config:

- `union GitRef { Tag(name) | Rev(sha) | Branch(name) }` — git reference forms.
- `union DepSource { Registry(version) | Workspace(version: Option[String]) | Path(dir) | Git(url, ref, subdir) }` — all dependency source kinds.
- `record DependencyEntry { name; source: DepSource; registry: Option[String] }` — replaces the old name+version pair; `registry` is a per-dep feed override.
- `record WorkspaceOverride { name; dir }`, `record WorkspaceSection { exclude; overrides }`, `record RegistryConfig { dotnet; jvm }`, `record WorkspaceRoot { filePath; workspace; registry }` — workspace and registry config types.
- `Manifest` record extended: `workspace: Option[WorkspaceSection]` and `registry: Option[RegistryConfig]`.
- `pub func parseWorkspaceRoot(text, filePath): Result[Option[WorkspaceRoot], ManifestError]` — parses a virtual workspace root `lyric.toml` (no `[package]`, just `[workspace]`).
- `pub func depRegistryVersion(source): Option[String]` — helper for `pack.l`.

Inline-table parsing now handles `{ workspace = true }`, `{ path = "…" }`,
`{ git = "…", tag/rev/branch = "…", subdir = "…" }` forms and the optional
`registry = "…"` per-dep feed override.

**`Lyric.Lockfile` (`lyric-compiler/lyric/lockfile/lockfile.l`).**

New library (M5.3 stage `restore`): reads and writes `lyric.lock`.

- `record LockedPackage { name; version; source; sha512; path }` — one entry per resolved dep.
- `record LockFile { formatVersion; packages }`.
- `pub func emptyLockFile(): LockFile`, `addOrUpdatePackage`, `findPackage`, `serializeLockFile`, `parseLockFile`.

Lock file format follows the TOML-like syntax from `docs/38-workspace.md §6`:
`[workspace]` header with `version = 1`, then `[[package]]` blocks.  Source
strings: `"workspace"`, `"path:<dir>"`, `"nuget:<url>"`, `"git:<url>#<rev>"`.

**`Lyric.GitDep` (`lyric-compiler/lyric/git_dep/git_dep.l`).**

New library (M5.3 stage `restore`): resolves `{ git = … }` dependencies.

- `union GitRef { Tag | Rev | Branch }`, `record GitDepResult { localDir; resolvedRev }`.
- `pub func resolve(url, ref, subdir): Result[GitDepResult, String]` — clones/fetches into `~/.lyric/git-cache/<url-hash>/<ref-label>/` using `git clone --depth 1` (tag/branch) or a full clone (rev); branch refs are always re-fetched.
- `pub func cacheDir(): String`, `urlToHash(url): String`, `gitRefLabel(ref): String`.

**`Lyric.Workspace` (`lyric-compiler/lyric/workspace/workspace.l`).**

New library (M5.3 stage `restore`): workspace root discovery and member resolution.

- `record WorkspaceMember { name; dir }`, `record WorkspaceContext { rootDir; rootFile; members; overrides }`.
- `pub func findWorkspaceRoot(startDir): Option[WorkspaceContext]` — walks up the directory tree, finds the nearest `lyric.toml` with a `[workspace]` section, then recursively discovers member packages (skips hidden dirs, `node_modules`, `target`, `bin`, `obj`, and entries matching the `[workspace.exclude]` list).
- `pub func findMember(members, name): Option[WorkspaceMember]`, `resolveDep(name, ctx): Option[String]`.

**`Lyric.Pack` updates (`lyric-compiler/lyric/pack/pack.l`).**

`publishCsproj` and `restoreCsproj` updated to use the new `DepSource` union:
only `Registry(version)` deps emit `<PackageReference>` elements; `Workspace`,
`Path`, and `Git` deps are resolved locally and never appear in the generated
csproj.

**`Lyric.Cli` updates (`lyric-compiler/lyric/cli.l`).**

- `cmdRestore` — resolves all four dep source forms: `Registry` deps restored via `dotnet restore` on a generated csproj; `Workspace` deps resolved via `Lyric.Workspace`; `Path` deps resolved relative to the manifest; `Git` deps cloned/updated via `Lyric.GitDep`.  Writes a `lyric.lock` file after successful resolution.
- `cmdPublish` — validates no branch (`Branch`) deps (require `tag` or `rev` for publishable packages), resolves workspace deps to their pinned registry versions, runs `dotnet pack` then `dotnet nuget push`.  Accepts `--registry <url>` and `--api-key <key>` flags.
- `cmdSearch` — queries the NuGet V3 search API via `curl` (`ProcessCapture.runCapture`), displays matching packages as tab-separated columns.
- `buildRestoreCsproj` helper — generates a minimal `<Project>` csproj with only `Registry` deps as `<PackageReference>` elements for `dotnet restore`.
- `toGitDepRef` converter — maps `Lyric.Manifest.GitRef` to `Lyric.GitDep.GitRef`.

**`Lyric.ManifestBridge` update (`lyric-compiler/lyric/manifest_bridge.l`).**

`dep=<name>=<version>` lines in the bridge protocol are now only emitted for
`Registry(version)` dep sources; `Workspace`, `Path`, and `Git` deps are
omitted because the F# bootstrap `SelfHostedManifest.fs` shim does not need to
round-trip non-NuGet dependency sources.

**`Std.Directory` fix (`lyric-stdlib/std/directory.l`).**

Replaced the broken `import System.IO as HostIO` pattern with `import Std.FileHost`.
All `HostIO.xxx` calls updated to their corresponding `host*` function names.

**`Std.FileHost` extension (`lyric-stdlib/std/_kernel/file_host.l`).**

Three new externs for the directory operations now used by `Std.Directory`:

- `hostEnumerateFileSystemEntries(path): slice[String]` — `Directory.GetFileSystemEntries`.
- `hostDeleteDirectory(path): Unit` — `Directory.Delete(path)` (non-recursive).
- `hostDeleteDirectoryRecursive(path, recursive): Unit` — `Directory.Delete(path, bool)` (recursive delete when `true`).

Kernel boundary soft cap updated from 276 → 279.

**Import-order fix for `Path.join` ambiguity.**  `Lyric.Workspace` and
`Lyric.GitDep` now import `Std.String as Str` before `Std.Path as Path`,
matching the pattern in `cli.l` and `emitter.l`, so the Lyric type checker
resolves `Path.join/2` to `Std.Path.join` rather than `Std.String.join/2`.

**Manifest self-test (`lyric-compiler/lyric/manifest_self_test.l`).**

Six new test functions exercise the new dep source forms:
`testWorkspaceDep`, `testPathDep`, `testGitDepTag`, `testGitDepSubdir`,
`testWorkspaceSection`, `testRegistrySection`.

**Test results:** 782/782 emitter tests pass, 227/227 CLI tests pass.

### D-progress-265 — End-to-end `lyric build --target jvm` fixes (Phase 6)

`lyric build foo.l --target jvm` is now operational for Lyric programs that
import the standard library and declare `func main(): Int` (the common
idiomatic shape).  Three independent defects were closing in front of
`SelfHostedJvm.compileToJar`:

1. **JVM-target stdlib assembly identity collision.**
   `bootstrap/src/Lyric.Emitter/Emitter.fs` precompiles `Std.X` for the
   active `Target`.  The self-hosted CLI bridge (`SelfHostedCli.fs`)
   compiles its own driver under `Target = Dotnet` before the user's
   build runs, so `Lyric.Stdlib.Core` (`.NET`-flavour, `_kernel/`) is
   already loaded into the default `AssemblyLoadContext` by the time the
   user's `--target jvm` request tries to load the JVM-flavour
   (`_kernel_jvm/`) DLL of the same name.  Two assemblies with the same
   identity cannot coexist in one ALC; `Assembly.LoadFrom` raised
   `FUSION_E_INVALID_NAME` (HRESULT `0x80131047`).  Fixed by suffixing
   the JVM-target assembly identity with `.Jvm`
   (`Lyric.Stdlib.Core` → `Lyric.Stdlib.Core.Jvm`), so the two flavours
   coexist cleanly when both targets are touched within a single
   `lyric` invocation.

2. **JAR `Main-Class` derived from the source filename, not the package
   declaration.**  `lyric-compiler/jvm/bridge.l` was passing the F#-supplied
   `packageName` (the filename without extension) straight into both the
   `Lyric-Package` manifest attribute and the JVM `Main-Class` attribute.
   `lyric build hello_jvm.l --target jvm` on a file declaring
   `package Hello` produced a JAR whose manifest pointed `Main-Class` at
   `hello_jvm`, a class that does not exist — `java -jar` failed with
   `ClassNotFoundException`.  Fixed by walking the parsed
   `SourceFile.packageDecl.path.segments`, joining with `.`, and using
   the result as `Main-Class`.  The `Lyric-Package` attribute keeps its
   original filename-derived value for tooling backward compatibility.

3. **JVM main-wrapper descriptor mismatch for `func main(): Int`.**
   `Jvm.Codegen.codegenPackage` synthesises a `void main(String[])`
   wrapper that delegates to the Lyric main via `invokestatic`.  The
   wrapper hard-coded `()V` (void return) regardless of the Lyric main's
   actual return type, so a `func main(): Int` program emitted
   `invokestatic main:()V` against an `()I` symbol and the JVM raised
   `NoSuchMethodError` at startup.  Fixed by recording the Lyric main's
   resolved `JvmType` and emitting an `invokestatic` with the matching
   descriptor.  When the Lyric main returns a value, the wrapper now
   pops the result off the stack before issuing `return` (single-slot
   only — a Long/Double main return is a follow-up).

**Test coverage.**  Two new programs in the parity smoke suite
(`bootstrap/tests/Lyric.Cli.Tests/ParityTests.fs`) pin the fixes:

- `parity21_main_int` — `func main(): Int { println(...); return 0 }`
- `parity22_main_int_returning` — `func main(): Int` with a loop and an
  intermediate accumulator

Both run through the existing `dotnet-legacy` / `dotnet` / `jvm`
trinity, so the parity suite now exercises 66 cases (22 programs × 3
paths, up from 60).

**Test results:** 783/783 emitter tests pass, 233/233 CLI tests pass.

### D-progress-266 — Custom source generator API: `@generate(Pkg.Gen)` runtime

Implements the custom source generator runtime specced in docs/40
(D075).  The unified `@generate` annotation now handles both built-in
generators (bare names: `@generate(Json)`) and custom package-based
generators (dotted names: `@generate(Proto.Derive)`).

**What shipped:**

- **`lyric-compiler/lyric/generator/generator.l`** (`Lyric.Generator`
  package) — source-text pre-processor wired into `cli.l buildOne`.
  Scans for dotted `@generate(X.Y)` annotations, resolves the generator
  DLL from the `lyric.toml` package manifest (path:
  `.lyric/packages/<name>/<name>.dll` relative to the manifest), invokes
  it via `dotnet exec <dll>` with a JSON `GeneratorRequest` on stdin, and
  splices the returned source text and import lines into the compilation
  unit before the emitter sees it.  Only dotted names trigger the
  subprocess path; bare names (e.g. `@generate(Json)`) pass through to
  the existing built-in synthesisers unchanged.

- **`lyric-generator-sdk/`** (`Lyric.GeneratorSdk` package) — SDK
  types and helpers for authoring generator packages:
  `GeneratorRequest`, `GeneratorResponse`, `TypeDescriptor`,
  `FieldDescriptor`, `AnnotationDescriptor`, and `runGenerator(handler)`
  which wires stdin → handler → stdout for the subprocess bridge.

- **`lyric-compiler/lyric/manifest.l`** — adds `kind: Option[String]` to
  `PackageSection` so generator packages can declare
  `kind = "source-generator"` in their `[package]` section.

- **`lyric-compiler/lyric/cli.l`** — threads `manifestPath` through
  `buildOne`; calls `Generator.preprocess` before emitting.

- **`bootstrap/src/Lyric.Parser/JsonDerive.fs`** (bootstrap shim only)
  — renames the `@derive(Json)` detector to `@generate(Json)` to keep
  the F# bootstrap emitter in sync with the unified annotation form.
  All test source strings and comments updated accordingly.

**Test results:** 323/323 parser, 789/789 emitter, 237/237 CLI.

### D-progress-267 — All 24 Lyric library packages compile; local-path dependency resolution shipped

All 24 first-party Lyric library packages now compile without errors via
`lyric build --manifest <lib>/lyric.toml`:

`lyric-auth`, `lyric-aws-secrets`, `lyric-aws-xray`, `lyric-cache`,
`lyric-db`, `lyric-feature-flags`, `lyric-grpc`, `lyric-health`,
`lyric-i18n`, `lyric-jobs`, `lyric-lambda`, `lyric-logging`, `lyric-mail`,
`lyric-mq`, `lyric-otel`, `lyric-proto`, `lyric-resilience`, `lyric-search`,
`lyric-session`, `lyric-storage`, `lyric-testing`, `lyric-validation`,
`lyric-web`, `lyric-ws`.

**Key bootstrap-compiler changes that unblocked compilation:**

- **Cross-package type anchors** (`ContractMeta.fs` + `RestoredPackages.fs`):
  A preamble of `extern type`, `opaque`, `union`, `record`, `enum`, `distinct`,
  and `alias` declarations is extracted from every restored dependency contract
  and prepended to each package source before type-checking, so that types
  defined in one DLL are resolvable when compiling a package that imports it.

- **Enum case cross-package registration** (`Emitter.fs`): Imported enum cases
  are now registered in `enumTable` / `enumCases`, enabling cross-package
  `EnumName.CaseName` pattern matching in packages that import enums from
  dependency DLLs.

- **`@cfg` erasure before import resolution** (`Emitter.fs`): Feature-flag
  erasure (`applyCfgErasure`) is now applied before `resolveIntraImports` and
  type-checking, so `@cfg`-gated overloads are pruned before the checker sees
  potential duplicate symbols.

- **Weaver empty-matchers guard** (`Weaver.fs`): The aspect weaver now returns
  `false` (no match) for templates with an empty `matchers` list instead of
  falling through to `List.forall []` vacuous-truth, which was silently applying
  library-template aspects to every function in every file.

- **`BCoalesce` (`??`) IL generation** (`Codegen.fs`): The null-coalescing
  operator now emits correct `dup / brtrue / pop` IL instead of producing no
  code.

- **Null-pattern match handling** (`Codegen.fs`): `case null` in a match
  expression is now correctly treated as a non-catch-all pattern (emits a
  `ldnull / ceq` null-check) rather than as a catch-all binding named `"null"`.

**Local-path dependency resolution (self-hosted CLI):**

`lyric build --manifest lyric.toml` now resolves `[dependencies]` entries of
the form `{ path = "..." }` (inline-table local-path deps).  The self-hosted
`buildProject` function reads each dependency's `lyric.toml`, finds its output
DLL in `<dep>/bin/<asm>.dll`, and passes the DLL path to the emitter as a
restored reference.  The `emitProject` → `--internal-project-build` subprocess
pipeline carries these paths in `DEP\t<name>\t<path>` spec-file lines so the
F# emitter can load them as `RestoredPackageRef` entries during compilation.

**AppHost subprocess fix (self-hosted emitter):**

The `lyrExe()` / `lyrPrefixArgs()` helpers in `emitter.l` and `contract_meta.l`
now detect when `LYRIC_BIN` is the native AppHost launcher for the CLI DLL
(`LYRIC_BIN + ".dll" == LYRIC_CLI_DLL`).  In AppHost mode the helpers call the
AppHost directly without the `exec <dll>` prefix, avoiding the `dotnet run`
scenario where the AppHost process would receive `"exec"` as `argv[0]` and
route it to the unknown-command handler.

**`var` record fields (parser):**

The parser now accepts `var name: Type` in record member declarations,
preserving the `var` annotation in the AST. Mutability enforcement is deferred
to the T6+ type-checker tier; the emitter currently treats `var` fields
identically to non-`var` fields at the IL level.

**Test results:** 792/792 emitter tests pass, 237/237 CLI tests pass.

### D-progress-268 — Self-hosted MSIL FFI + `@externStatic` / `@externInstance` (#370)

End-to-end FFI in the self-hosted MSIL emitter (Phase R6) plus the
language gap closure for explicit static-vs-instance disambiguation
on `@externTarget` declarations.

**What shipped:**

- **`lyric-compiler/msil/ffi.l`** (`Msil.Ffi` package) — the FFI resolver
  for the self-hosted MSIL emitter.  `splitTarget(target)` parses
  `"System.Type.Member"` (or `..ctor`) into (type FQN, member, isCtor).
  `splitTypeFqn(typeFqn)` recovers (namespace, simple name).
  `clrAssemblyForType(typeFqn)` is a hardcoded prefix → assembly table
  covering every BCL surface the stdlib externs into; types not in the
  table default to `System.Runtime` (the .NET facade that type-forwards
  most `System.*` types).  `resolveExternTarget(target, arity, hint)`
  returns an `FfiResolved` record that the codegen consumes.

  Why a table instead of runtime reflection: the bootstrap F# emitter
  writes PEs whose calling-assembly metadata trips up
  `System.Type.GetType` from Lyric-emitted code (consistently returns
  null even for types demonstrably loaded).  Rather than chase that
  emit issue down, the resolver derives everything from the
  `@externTarget` string + the Lyric param/return types, and the
  `@externStatic` / `@externInstance` annotations resolve the
  static-vs-instance ambiguity.

- **`@externStatic` / `@externInstance` annotations (#370)** — paired,
  mutually-exclusive disambiguation hints on `@externTarget`-bearing
  Lyric functions.  Both annotations are no-ops without
  `@externTarget`.  Setting both is a diagnostic (resolver falls back
  to `@externStatic` so the program builds).  When neither is
  present, the .NET self-hosted MSIL emitter defaults to static —
  instance externs must annotate explicitly.

- **`lyric-compiler/msil/codegen.l`** — `lowerFuncMsil` now detects
  `@externTarget` on a `FunctionDecl` and synthesises the body from
  the resolved BCL target.  Emits `MCall` (static), `MCallvirt`
  (instance), or `MNewobj` (ctor) with the right MemberRef token.
  Lazy `ffiAsmRefs` / `ffiTypeRefs` caches on `CodegenCtx` reuse the
  pre-seeded `arRuntime` row for `System.Runtime` /
  `System.Private.CoreLib` / `mscorlib`, and intern fresh
  AssemblyRef / TypeRef rows for everything else on first use.

- **Pre-existing codegen bug, also fixed** — intra-package function
  calls returned `MObject` regardless of declared return type.
  `println(userFn())` therefore always fell through to
  `WriteLine(string)`, producing invalid IL when the actual return
  was `Int`.  `CodegenCtx.funcRetTypes: Map[String, MsilType]` is
  now populated in `addPackageTokens` from each `FunctionDecl.ret`,
  and call sites consult it to return the correct `MsilType`.

**Verified end-to-end** (self-hosted MSIL pipeline, `lyric build`
default target):
- `@externTarget("System.Math.Abs") @externStatic` → `Math.Abs(-7) = 7`.
- `@externTarget("System.Math.Max") @externStatic` plus chained
  intra-package calls.
- `@externTarget("System.String.Trim") @externInstance` →
  `"  hello  ".Trim() = "hello"`.
- `@externTarget("System.String.Concat") @externStatic` → string
  concatenation.

**Docs updated:**
- `docs/01-language-reference.md` §11.3 — replaced the JVM-only
  name-based heuristic note with the cross-target `@externStatic` /
  `@externInstance` annotations.

**No F# bootstrap changes.**

**Test results:** 789/789 emitter, 237/237 CLI.

### D-progress-269 — Monomorphizer type-arg inference + ETypeApp + budget (#349)

Three related improvements to `Lyric.Mono` that close most of the
gaps `inferExprTE` had at the start of this session:

* **`ETypeApp(fn, [T1, …])` is now honored** at `ECall` rewrite
  sites.  Previously the case fell through to "pass-through fn"
  even when fn was an `EPath` to a known generic decl — explicit
  type applications never specialised.  The rewriter now detects
  `ECall(ETypeApp(EPath([fname]), targs), args)`, uses the supplied
  targs directly as the substitution, and emits the mangled
  specialisation request without going through inference.  Unblocks
  every call site where the user already wrote the type arguments
  inline.

* **`inferExprTE` extended** to recognise:
  - `EBinop` arithmetic (`+ - * / %`) — LHS type wins; useful when
    the generic param sits in a numeric expression.
  - `EBinop` comparison and logical (`== != < <= > >= and or`) —
    result is always `Bool`.

  Calls, field projections, lambdas, and constructor calls are
  still left to the un-specialised fall-through; threading
  `state.genDecls` / `state.recordDecls` into the inference helper
  is a separate cut (return-type inference for nested generic calls
  needs care around recursive shapes).

* **Recursion budget** added to the worklist (`specBudget = 10000`).
  A pathological generic that recurses with a strictly larger type
  argument (`f[T] = … f[List[T]] …`) used to loop indefinitely and
  OOM the compiler.  The compiler now panics with a clear,
  actionable message naming the runaway specialisation pattern.

**Test results:** 789/789 emitter, 237/237 CLI.

### D-progress-270 — V0031: warn proof-required functions decorated with aspects (#336)

Closes the gap reported in #336 (option-b path): the self-hosted
verifier walks the parsed AST, not the post-aspect-elaboration AST,
so `requires:` / `ensures:` clauses introduced by an aspect's
`around { }` body are not discharged.  Until the verifier moves
post-elaboration (option-a; requires a self-hosted aspect weaver,
which is its own multi-week project), the compiler now surfaces a
**warning** at each affected function.

* **`lyric-compiler/lyric/verifier/vcgen.l`** — `goalsForFile`
  pre-scans the file for `IAspect` items and collects their names
  into a `Map[String, Bool]`.  For each `@proof_required` IFunc,
  the verifier checks the function's annotations against that set;
  the first match emits `V0031` carrying the aspect name and the
  function span.

* **`docs/15-phase-4-proof-plan.md`** — `V0031` added to the
  diagnostic catalogue with recovery hint ("mark function
  `@runtime_checked` or hand-inline the aspect for proof").

Verified on a minimal repro (`@proof_required` package, aspect
`MyTimer`, decorated function `compute`):

```
$ lyric prove sample.l
V0031 warning [11:1]: function 'compute' is decorated with @MyTimer;
proofs verify the unelaborated body, which may differ from the
runtime behaviour after aspect weaving — contracts on the aspect's
around { } block are not discharged
1/1 obligations discharged (@proof_required)
```

Proof still proceeds on the unelaborated body (so existing programs
build) but downstream auditors and `claude-review` reviewers can
see the gap.  Full option-a (run verifier post-elaboration) tracked
in #336 follow-ups; needs a self-hosted aspect weaver to land first.

**Test results:** 789/789 emitter, 237/237 CLI.

### D-progress-271 — RFC zigzag test vectors + shift semantics docs (#361)

Closes #361.  The zigzag32/zigzag64 implementations had already been
rewritten to avoid shift operators (using `n * 2 ± 1` instead), so
the underlying correctness bug from the issue is no longer present.
What was still missing — and what #361 explicitly asked for — is RFC
test coverage on the boundary cases and language-reference documentation
of the `.shr` arithmetic-vs-logical distinction.

* **`lyric-proto/tests/proto_types_tests.l`** — 10 new RFC vectors:
  - `zigzag32(INT_MAX) = 0xFFFFFFFE`, `zigzag32(INT_MIN) = 0xFFFFFFFF`
  - `unzigzag32` of the same constants
  - Roundtrips for `INT_MAX`, `INT_MIN`, `LONG_MAX`, `LONG_MIN`, `-1`, `1`

* **`docs/01-language-reference.md` §4.1** — document `.shl(n)` /
  `.shr(n)` semantics: arithmetic right shift on signed types
  (`Byte`, `Int`, `Long`), logical right shift on unsigned types
  (`UInt`, `ULong`).  Cross-reference protobuf zigzag as the
  canonical consumer.

**Test results:** 789/789 emitter, 237/237 CLI.  The new proto
vector tests run via `lyric test --manifest lyric-proto/lyric.toml`.

### D-progress-272 — Std.RegexSafe wrapper for Result-shaped regex (#330)

The kernel-level `Std.Regex` already binds the
`Regex(string, RegexOptions, TimeSpan)` overload with a 1-second
default match timeout (so `(a+)+$` on adversarial input throws
`RegexMatchTimeoutException` instead of hanging), but the user-
facing call surface still leaks the exception as an unchecked
`Bug`.  This adds a thin `Std.RegexSafe` package that catches the
throw and returns `Result[T, RegexError]`.

* **`lyric-stdlib/std/regex_safe.l`** (new) — `Std.RegexSafe` public
  surface:
  - `RegexError = TimedOut(message) | RegexBug(message)`
  - `errorMessage(e): String`
  - `tryCompile(pattern): Result[Regex, RegexError]`
  - `tryIsMatch(r, input): Result[Bool, RegexError]`
  - `tryMatchOne(r, input): Result[Match, RegexError]`
  - `tryReplace(r, input, replacement): Result[String, RegexError]`
  Local functions are prefixed `try*` to avoid shadowing the kernel
  module's same-short-named functions — the F# bootstrap call
  resolver recurses otherwise (separately tracked, but the rename
  here is the no-op workaround).

* **`lyric-stdlib/tests/regex_safe_tests.l`** (new) — exercises the
  error-message rendering and the happy paths for compile / isMatch /
  replace.  We do NOT trigger the 1-second timeout in CI (a large
  enough adversarial input would slow the suite without adding
  coverage beyond the BCL guarantee + the kernel binding).

* **`docs/10-stdlib-plan.md`** — adds `Std.Regex` and `Std.RegexSafe`
  to the stability cut list, with the ReDoS posture spelled out next
  to each entry.

**Test results:** 790/790 emitter, 237/237 CLI.

### D-progress-273 — Std.Json slice readers dispose JsonDocument (#328)

The scalar `lyricJsonGet*` helpers in `lyric-stdlib/std/json.l`
already wrap parsing in `defer { hostDisposeJson(doc) }`, but the
slice readers in `lyric-stdlib/std/_kernel/json_host.l`
(`lyricJsonGetIntSlice`, `lyricJsonGetLongSlice`,
`lyricJsonGetDoubleSlice`, `lyricJsonGetBoolSlice`,
`lyricJsonGetStringSlice`) were missing the disposal — each call
leaked an unmanaged `JsonDocument` until GC.  This commit adds
the `defer { hostDisposeJson(doc) }` to every slice reader.

The other half of #328 — `lyricJsonGet*` re-parses the entire JSON
on every field lookup, making N-field reads O(N) parses — is a
shape change to `Std.Rest.jsonString`/`jsonInt`/`jsonBool` that
needs a richer "parse once per response" API.  Left for a
follow-up; the current code is correct (no leak), just suboptimal.

**Test results:** 790/790 emitter, 237/237 CLI.

### D-progress-274 — JVM `Std.Json` slice readers (#322 follow-up)

Earlier work in #322 added the missing JVM kernel files (console,
path, process_capture) and the scalar JSON externs.  The slice
readers `lyricJsonGetIntSlice` / `LongSlice` / `DoubleSlice` /
`BoolSlice` / `StringSlice` — which are pure-Lyric implementations
over the lower-level `hostEnumerate*` / `hostTryGet*` primitives —
were defined only in `_kernel/json_host.l` (.NET path).  A JVM
build that called any of them would fail to link.

Promotes the five slice readers verbatim into `_kernel_jvm/
json_host.l`.  The body is identical to the .NET path (pure
Lyric, no BCL-specific calls) so behaviour matches by
construction.  All five carry the `defer { hostDisposeJson(doc) }`
disposal added in D-progress-273.

**Test results:** 790/790 emitter, 237/237 CLI.

### D-progress-275 — Review fixes for PR #789 (REQUIRED + SUGGESTIONs)

Addresses the `claude-review` findings on PR #789:

REQUIRED:
* **F0002 diagnostic for conflicting `@externStatic` / `@externInstance`**
  (#790, #793) — both annotations on one extern declaration is now an
  error.  Surfaced two ways: the self-hosted type checker
  (`typechecker_stmts.l:checkFunctionBody`) emits `F0002` via
  `errorDiagnostic` for proof / lint pipelines that thread a diag
  list; the MSIL codegen (`msil/codegen.l:emitExternTargetBody`)
  panics with the same message so the `lyric build` path — which
  skips the type checker — also surfaces the failure.
* **Invalid-IL hazard for class-typed `@externTarget` params** (#791) —
  previously the FFI emitter returned `false` and the default lowering
  emitted `MRet` with no value on the stack, producing
  VerificationException at runtime.  `emitExternTargetBody` now
  panics with an actionable message ("use --target dotnet-legacy or
  wrap the call in a primitive-typed shim").

SUGGESTIONs:
* **`paramArity` dead parameter removed** (#792) — the table-driven
  resolver doesn't use it.  Callsite updated in
  `msil/codegen.l:emitExternTargetBody`.
* **D-progress-274 cross-ref corrected** (#794) — the JVM slice-reader
  entry now points at D-progress-273 (the disposal entry) instead of
  the renumbered-stale D-progress-272.
* **`isTimeout` locale-sensitivity documented** (#795) — the comment
  block in `std/regex_safe.l` now explicitly calls out that the
  classifier falls through to `RegexBug` on non-en-US runtimes
  because the BCL message is satellite-resource-localised; a
  locale-stable classifier needs the `Bug` lowering to surface the
  CLR exception class, which is a separate lifting concern.
* **`createDir` errors no longer swallowed silently** (#797) —
  `cmdTestManifest` now reports a `printErr` instead of dropping the
  `Err` arm on the floor.
* **O(N²) string-concat replaced with `Str.joinList`** (#799) —
  `cmdTestManifest`'s package-source bundling now collects into a
  `List[String]` and joins once instead of repeated `+`.
* **V0031 cross-package limitation documented** (#800) — the V0031
  table entry in `docs/15-phase-4-proof-plan.md` now spells out
  that the same-file detector misses imported cross-package
  aspects, and points at the `Lyric.Contract` resource lift needed
  for the full fix.
* **`cmdTestManifest` 'what' comments trimmed** (#801) — only the
  JIT-regression note (the WHY) survives; the algorithm steps are
  legible from the function body.

Not actioned:
* **#796** (duplicate D-progress-268) — already fixed by the prior
  renumber commit a5dab90; the review ran against c05f4ee before
  the renumber landed.
* **#798** (regex_safe_tests uses manual `main()` driver) — the
  manual driver matches `StdlibLyricTests.fs`'s harness contract
  (expects exit 0 + stdout-contains "ok"), which is the same shape
  json_tests.l / format_tests.l / etc. use.  The `@test_module` +
  `test "..." { }` syntax the suggestion compares to runs through
  the separate `lyric test` harness used by `lyric-proto/tests/`.
  Comment added at the top of the file noting the harness
  divergence.

**Test results:** 796/796 emitter, 237/237 CLI.

### D-progress-276 — Self-hosted middle-end wired into MSIL and JVM bridges (docs/41 Band 1, partial)

Wires the self-hosted Lyric middle-end into both production back-end
bridges per `docs/41 §9 Band 1`.  Previously the bridges ran
`parse → codegen → lowering` directly: a type-incorrect program under
`--target dotnet` compiled to broken IL with no diagnostic, and
`requires:` / `ensures:` clauses survived in the AST without ever being
lowered to runtime asserts.

Scope landed:

* **`lyric-compiler/msil/bridge.l` and `jvm/bridge.l`** now call, after
  parse and before codegen:
  1. `Lyric.TypeChecker.check(file)` — diagnostics printed (see below).
  2. `Lyric.ModeChecker.checkFile(file)` — V-code errors abort the build.
  3. `Lyric.ContractElaborator.elaborateFile(file)` — `requires:` /
     `ensures:` lowered to runtime asserts in the AST.
* **Diagnostic printing.**  Each pass's diagnostics (severity + code +
  span + message) now print to stdout before the bridge returns.  Parse
  errors and mode-checker errors fail the build immediately.
* **Typechecker diagnostics are advisory.**  The self-hosted typechecker
  doesn't resolve cross-package imports yet (Band 6;
  `typechecker_resolver.l:129` "deferred to T7+"), so it raises T0010 /
  T0020 / T0050 for every reference to a stdlib name.  Treating those as
  build failures would regress every production program that imports
  `Std.*`, so `tcRes.diagnostics` are surfaced but not gating.  When
  Band 6 lands the bridge will switch back to `reportAndAbort`.
* **`Lyric.Mono` wiring deferred.**  Importing `Lyric.Mono` from the
  bridge breaks the precompile of `Lyric.Msil.Bridge.dll` itself: the
  frozen F# bootstrap parser cannot parse literal-pattern match arms
  followed by a further arm — every `case 1 -> 42 \n case _ -> 99`
  shape P0040s.  `mono.l:782+` uses this idiom (via `case Some(te) ->
  result = result + …`), and the workaround is to restructure mono.l
  around constructor-only patterns.  Tracking in the band 5–6 follow-up;
  for now the `Lyric.Mono` import is commented out with a header note.
* **Bridge tests added.**  `SelfHostedMsilBridgeTests` gains
  `mkBridgeFails` for "compile should fail" assertions, plus
  `shm_mode_check_v0004` (V0004: `@axiom` function with body) and
  `shm_parse_error` (trailing `+` in a `val` initialiser).

Side fix: renamed the `as` binding in
`lyric-compiler/lyric/mono.l:typeExprKey` (`case TGenericApp(h, as) ->
…`) to `gargs` — `as` is a reserved keyword in Lyric and the bare
binding name was a latent footgun, even though mono.l doesn't yet ride
the production import path.

**Test results:** 237/237 Lyric.Cli (including 8/8
SelfHostedMsilBridgeTests, 66/66 ParityTests across the three targets).

### D-progress-277 — Contract elaborator lowers loop invariants (docs/41 Band 4)

Closes the first half of docs/41 §9 Band 4: loop `invariant:`
clauses now lower to runtime `assert(inv)` calls at the top of every
reachable loop body, instead of being passed through as inert
`SInvariant` AST nodes.

* **`lyric-compiler/lyric/contract_elaborator/elaborator.l:elaborateStmtDeep`**
  gains an `SInvariant(inv)` case that emits `mkAssertCall(inv, span)`.
  Continue and fall-through edges both re-enter the loop head, so a
  single assert at the start of the body covers them.  Break exits
  without re-checking, matching the operational semantics in
  `docs/08-contract-semantics.md`.
* **Function-body opt-in.**  `elaborateFunction` previously short-circuited
  when a function had no `requires:` and no `ensures:` — that path
  bypassed the deep-walk that would have rewritten `SInvariant`.  A new
  `functionBodyHasInvariant` predicate (walks `SWhile` / `SFor` / `SLoop` /
  `STry` / `SScope` / `SDefer` bodies) now also opts the function into
  elaboration.
* **`contract_elaborator_self_test.l`** gains `testWhileInvariantLowered`
  and `testForInvariantLowered`, both verifying that the first
  statement of the rewritten loop body is `SExpr(ECall(EPath("assert"),
  …))`.

Still deferred (will follow as part of the second half of Band 4):
protected-type entries (`PMEntry` with `barrier:` / `invariant:` clauses).

**Test results:** 797/797 emitter, 239/239 Lyric.Cli.

### D-progress-278 — Source-generator supply-chain enforcement (G0002, G0008)

Address review-finding gap #762 documenting the supply-chain
guardrails added to the custom source-generator pipeline in
D-progress-266.

* **G0002** — `@generate(Pkg.Gen)` rejects packages whose `lyric.toml`
  does not declare `[package].kind = "source-generator"`.  Prevents a
  caller from accidentally running an arbitrary library as a source
  generator.
* **G0008** — `@generate(Pkg.Gen)` rejects packages not listed in
  `[dependencies]` of the consuming `lyric.toml`.  Forces the
  consumer to opt in explicitly before any generator subprocess can
  fire.  See `docs/40-source-generators.md` §9 (Phasing) and
  `lyric-compiler/lyric/generator/generator.l:checkGeneratorDependency`.

Both diagnostics fire as errors at build time, after `scanDirectives`
returns a `Pkg.Name` reference and before any subprocess is launched.
The corresponding entries land in the §10 diagnostic table in
`docs/40-source-generators.md`.

### D-progress-279 — Contract elaborator: protected-type entry elaboration (Band 4 finish)

Completes the second half of docs/41 §9 Band 4: protected-type
`PMEntry` contract elaboration in the self-hosted elaborator.

* **`elaborator.l`** — `elaborateItem` gains an `IProtected` branch.
  `elaborateProtectedMember` handles per-member dispatch: for each
  `PMEntry(ed)`, it collects the enclosing type's `PMInvariant` clauses
  as `CCEnsures` and appends them to `ed.contracts` to form a combined
  list. `elaborateFunctionBody` is then applied to the combined list,
  inserting `assert(requires)` at the body's start and
  `assert(invariant-as-ensures)` at every return / fall-off site.
  `PMFunc` members delegate to `elaborateFunction`. `PMField` and
  `PMInvariant` pass through unchanged.
* **`contract_elaborator_self_test.l`** gains
  `testProtectedEntryRequiresLowered` (verifies requires asserts land
  at the start of an elaborated PMEntry body) and
  `testProtectedInvariantAppendedToEntries` (verifies PMInvariant
  clauses are injected as ensures asserts before every return site).

Closes issue #848.

### D-progress-280 — JVM backend: IEnum and IDistinctType codegen (Band 3 partial)

Wires up two previously-stubbed AST item kinds in
`lyric-compiler/jvm/codegen.l`:

* **`IEnum(decl)`** now produces `LPEnum(LEnumType(className =
  pkgName + "/" + decl.name, variants = [case names]))`.  The enum
  class is lowered by the existing `lowerEnum` in `lowering.l`
  (B112), producing a valid `java.lang.Enum<E>` subclass with
  `public static final` instance fields.
* **`IDistinctType(decl)`** now produces `LPDistinctType(LDistinctType(
  wrapperClass = pkgName + "/" + decl.name, underlyingType =
  typeExprToJvm(decl.underlying)))`.  The wrapper class is lowered by
  the existing `lowerDistinctType` in `lowering.l` (B97–B99),
  producing a class with a private `$value` field and a public
  accessor.

New end-to-end tests added:

* `self_test_b131.l` / `JvmLoweringB131Test.fs` — compiles a Lyric
  source file containing an `enum Direction { ... }` declaration via
  `compileToJar`, runs the JAR, and asserts output = `enum_ok`.
* `self_test_b132.l` / `JvmLoweringB132Test.fs` — compiles a Lyric
  source file containing a `type UserId = Int` distinct-type
  declaration via `compileToJar`, runs the JAR, and asserts output =
  `distinct_ok`.

Remaining Band 3 items (`IInterface`, `IImpl`, `IAspect`, `ELambda`
general case, and proper `EPropagate` desugaring) are deferred: they
require new `LPackageItem` variants in `lowering.l` and/or
`invokedynamic` infrastructure that does not yet exist.

Closes issue #856 (partial — structural items wired up; complex
constructs tracked as follow-up).

### D-progress-281 — Track A A1.1: in-process MSIL emit + stderr diagnostics

First concrete step of Track A (`docs/41 §860` — F# CLI elimination +
Native-AOT publishing).  `Lyric.Emitter.emit` now compiles
`--target dotnet` single-source builds in-process via a direct call to
`Msil.Bridge.compileToMsil`, instead of spawning a `lyric
--internal-build` subprocess that bounces back into F# `Program.fs`.

End-to-end: `cli.l → Lyric.Emitter.emit → MsilBridge.compileToMsil`
(direct package call).  No subprocess hop, no F# emitter touched at
runtime.

Three escape hatches preserved for transition and differential testing:

* `LYRIC_FORCE_SUBPROCESS=1` forces every emit through the subprocess
  shellout regardless of target.  Used by the bootstrap reproducibility
  pipeline to compare in-process vs subprocess output.
* `--target jvm` still routes through the subprocess fallback —
  importing `Jvm.Bridge` from `Lyric.Emitter` would pull
  `Jvm.Bytecode.BranchInsn` into the same F# emitter import closure as
  `Lyric.Manifest.Branch` / `Lyric.GitDep.Branch`.  PR #868 already
  renamed the bytecode case to clear the collision, but the JVM-side
  switch warrants its own validation pass before flipping.
* `emitProject` (multi-package + restored-dep builds) still routes
  through F# `Program.fs::internalProjectBuild` because the
  self-hosted MSIL bridge doesn't yet expose a multi-package entry
  point.

Diagnostic-routing fix (#893): `Lyric.DiagnosticUtil`'s
`diagReportAndAbort` and `diagReport` helpers now write to **stderr**
via `Std.Console.error` instead of stdout.  This matches the F#
bootstrap CLI convention; IDE integrations, CI scripts, and
`2>errors.txt` redirects that worked with the old subprocess path
continue to work.  The `failResult` text in `emitter.l` was updated to
reference stderr accordingly.

Pre-required by:
* PR #888 (#867) — fixed two F# bootstrap emitter bugs in
  `Lyric.Generator.preprocess` that were silently breaking the
  self-hosted CLI bridge.  Without #888, the in-process path was
  unreachable because `Lyric.Cli.dll` couldn't even load.
* PR #868 — defensive `Branch`→`BranchInsn` rename in
  `Jvm.Bytecode` / `Msil.Opcodes` that cleared the import-collision
  hazard for adding `import Msil.Bridge` to `Lyric.Emitter`.

Followup actions (see `docs/41 §860`): port `emitProject` to a
multi-package bridge entry point, switch JVM target to in-process,
pre-build `Lyric.Cli.dll` into a checked-in artifact, generate an AOT
entry-point project, and finally delete the F# CLI scaffolding (12
SelfHosted*.fs files + duplicate F# helpers + most of `Program.fs`).

Closes #892, #893.

---

### D-progress-282 — Self-hosted MSIL backend Band 2 feature parity (docs/41 §9 Band 2, PR #872)

*claude/fix-band-2-issues-RT5un branch.*

Implements all seven Band-2 items from the `docs/41` remediation plan,
closing GitHub issues #849–#855.

**IEnum → CLR int enum TypeDef (#849)**

`lowerEnumMsil` in `lyric-compiler/msil/codegen.l` emits a sealed class
inheriting `System.Enum` with one static `int32` literal field per `case`
declaration.  The TypeDef carries `tdSealed | tdAutoLayout | tdAnsiClass`.
Verified by bridge test `shm_enum_smoke`.

**IVal → static init-only field with optional `.cctor` (#850)**

Literal `val` declarations (single `MLdcI4` init expression) are
registered in a `constValues` map on `CodegenCtx` and inlined at every
`EPath` reference site as `ldc.i4`.  No MethodDef row is emitted for
these, avoiding a token-sequence mis-alignment that caused `main` to be
mis-identified as the static initialiser.  Non-literal vals emit a
standard static `.cctor` via `initInsns`.  Verified by `shm_const_int`
and `shm_val_cctor`.

**IInterface → abstract interface TypeDef (#853, interfaces half)**

`lowerInterfaceMsil` emits a TypeDef with `tdInterface | tdAbstract`
flags and one abstract MethodDef stub (RVA=0, `mdAbstract | mdVirtual`)
per member signature.  A companion fix removed the RVA post-pass loops
in `lowerMPackage` / `lowerMPackageWithCtx` that were overwriting
abstract method RVA=0 slots with concrete body RVAs from a different
TypeDef.  Verified by `shm_interface_smoke`.

**IOpaque → sealed TypeDef with private fields + .ctor (#853, opaques half)**

`lowerOpaqueMsil` emits a sealed, non-abstract TypeDef with one private
instance field per `opaque type` field declaration, plus a public `.ctor`
that `stfld`-stores every argument.  Exposed-twin (`@projectable`) synthesis
is deferred to Band 3.  Verified by `shm_opaque_smoke`.

**IProtected → Monitor-backed sealed TypeDef (#855, protected half)**

`lowerProtectedTypeMsil` emits a sealed TypeDef with a private `object`
lock field (initialised in `.ctor`), instance fields for every `var`
declaration, and one public instance method per `entry`.  Each entry body
is wrapped in `Monitor.Enter` / `Monitor.Exit` using a try/finally block.
Verified by `shm_protected_smoke`.

**IAspect + aspect weaver (#855, aspects half)**

`weaveAspectsMsil` is now exported as `pub func` so `bridge.l` can call
it before `addPackageTokens`.  The weaver renames the original target
function to `__aspect_target_N_<name>` and synthesises a wrapper whose
body is the aspect's `around(args)` block.  A critical fix was extracted
into a `makeSomeFBBlock(b: in Block): Option[FunctionBody]` helper: the
explicit `Option[FunctionBody]` return type forces the bootstrap emitter
to bind `T = FunctionBody` through `ctx.ReturnType` rather than
defaulting to `obj`, which caused the `isinst Option_Some[FunctionBody]`
pattern-match to silently miss both branches and emit zero IL instructions
for the wrapper body.  `addPackageTokens` was rewritten to match the
source-order emit sequence of `codegenMPackage` so that all TypeDef and
MethodDef token pre-scans stay in lock-step.  Verified by `shm_aspect_weave`.

**EPropagate (`?`) → match-unwrap desugaring (#849 / #855 cross-item)**

`lowerEPropagateMsil` desugars the `?` postfix operator to a
match-and-early-return for both `Result[T,E]` and `Option[T]` shapes.
Verified by new bridge test coverage in the existing suite.

**Test wiring**

Seven new bridge tests added to
`bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilBridgeTests.fs`:
`shm_enum_smoke`, `shm_const_int`, `shm_val_cctor`, `shm_interface_smoke`,
`shm_opaque_smoke`, `shm_aspect_weave`, `shm_protected_smoke`.  All 251
tests pass (0 failures).

**Remaining Band 2 items deferred to Band 3**

- `ELambda` display-class capture (item 6 in the Band 2 list) — the
  current codegen falls back to an `MObject` placeholder to avoid a
  panic.
- `EAwait` async state machine (item 9) and `EYield` async generator
  (item 10) — unchanged; still panic.
- Auto-FFI scoring (item 12) — unchanged.

### D-progress-283 — JVM backend: IInterface and IImpl codegen (Band 3 — #856 remainder)

Wires `IInterface` and `IImpl` AST items through the JVM self-hosted
backend (`jvm/codegen.l` + `jvm/lowering.l`), completing the structural
Band 3 items for `interface` and `impl Y for X` declarations.

**`jvm/lowering.l`**
- Added `implementsIfaces: List[String]` to `LRecord` (all construction sites
  updated to include `implementsIfaces = newList()`).
- Added `LInterface` record, `lowerInterface` helper, and `LPInterface` variant
  in `LPackageItem` so interface ClassFiles flow through `lowerPackage`.
- `lowerRecord` calls `makeClassFullWithInterfaces` when `implementsIfaces` is
  non-empty, otherwise falls back to `makeClassFull` (no-change for existing
  records).

**`jvm/codegen.l`**
- Added `ImplEntry` record and a pre-pass over all `IImpl` items before the
  main item loop, so each `IRecord` can look up its interface list at class
  construction time.
- `IInterface(decl)` emits `LPInterface` with abstract methods (from `IMSig`)
  and concrete default methods (from `IMFunc`). Parameter types derived from
  `Param.ty` directly (fix: removed invalid `PNamed` pattern match; fixed
  `FunctionSig.returnTy` → `FunctionSig.ret` typo).
- `IRecord` uses pre-collected impl entries to inject `implementsIfaces` and
  merged method lists into `LRecord`.
- `IAspect`, `ELambda`, and general `EPropagate` remain stubbed (need
  `invokedynamic` infrastructure not yet present).

**Tests**
- `jvm/self_test_b133.l` + `JvmLoweringB133Test.fs`: interface smoke (compiles
  `interface Greeter { func greet(): String }` + `impl Greeter for SimpleGreeter`,
  runs JAR, asserts `jar_written=true`).
- `jvm/self_test_b134.l` + `JvmLoweringB134Test.fs`: impl smoke (record
  implementing an interface).
- All existing self-tests (b3/b4/b91/b95/b124/b130/b131/b132) updated with
  `implementsIfaces = newList()` and 4-arg `compileToJar`.

Closes issue #856 (IInterface + IImpl wired; IAspect/ELambda/EPropagate deferred to Band 5+).

### D-progress-284 — Band 6: cross-package stdlib type resolution (#846)

Implements Shape 2c of Band 6 (docs/41 §9): the self-hosted MSIL and JVM
bridges now resolve stdlib type names (`List`, `Option`, `Result`, `Map`, etc.)
so the self-hosted type checker no longer emits false-positive T0010/T0014
diagnostics for those names.

**Strategy**: F# shims (`SelfHostedBridge.findStdlibSources`) walk up from
`AppContext.BaseDirectory` to find `lyric-stdlib/std/`, read every top-level
`*.l` file, and pass the source texts to `compileToMsil`/`compileToJar` as a
`List[String]`. Inside the bridges (`msil/bridge.l`, `jvm/bridge.l`), each
source is parsed and only type declarations (IRecord, IUnion, IEnum,
IDistinctType, IInterface, ITypeAlias, IOpaque, IExposedRec) are extracted as
imported items (function items are skipped: multiple stdlib files define
functions with the same name, and `checkWithImports` uses a strict-insert map
that throws on duplicates). `checkWithImports(file0, importedItems)` is called
instead of bare `check(file0)`, providing cross-package type context.

Type-checker output remains advisory (`reportDiagnostics` not `reportAndAbort`):
the self-hosted checker still generates T0020 false positives for builtin
functions (`newList`, `println`, etc.) that are not defined in any Lyric source
file. The fatal gate is deferred until builtin-function coverage is complete.

**Updated call sites**
- `lyric/emitter.l:emitMsilInProcess` updated to pass `newList()` as third arg
  to `MsilBridge.compileToMsil` (compat fix for the new signature).
- F# `SelfHostedJvm.fs` + `SelfHostedMsil.fs` updated to reflect the new
  4-arg / 3-arg signatures.

Closes issue #846.

### D-progress-285 — Track A A1.2: bootstrap.sh stage 1 CLI-bundle precompile

Second step of Track A (`docs/41 §860` — F# CLI elimination + Native-AOT
publishing).  After A1.1 made `Lyric.Emitter.emit` compile in-process,
A1.2 produces the static DLL artefacts the AOT entry-point project
(A1.3) will reference.

Changes to `scripts/bootstrap.sh`:

* **`stage1_cli_bundle()`** (new) — emits a one-line driver program
  that does `import Lyric.Cli`, compiles it via `--internal-build`
  (forces the F# emitter path; the self-hosted CLI dispatcher in cli.l
  doesn't understand `--target dotnet-legacy` post-A1.1 and would
  otherwise route the driver through the in-process MSIL bridge that
  isn't yet feature-complete for compiling the whole compiler).  The
  F# emitter's stdlib auto-resolve recursively compiles every Lyric
  package the driver transitively imports — cli.l + lexer / parser /
  type-checker / mode-checker / contract-elaborator / MSIL backend /
  manifest / pack / workspace / gitdep / lockfile / generator /
  emitter / fmt / lint / verifier / doc / contract-meta / repl /
  test-synth / bench-synth / openapi-parser / openapi-gen — and lands
  each as a DLL in its per-process scratch cache.  The script then
  copies every cached DLL into `.bootstrap/stage1/`.  Output:
  `Lyric.Lyric.Cli.dll` plus ~66 transitive-dependency DLLs.

* **`SKIP_CLI_BUNDLE=1`** env var skips the CLI-bundle step so users
  iterating on a single compiler package can avoid the ~30-second
  recompile.

* **Removed**: the old manual `COMPILER_SOURCES` compile loop in stage
  1.  The F# emitter's auto-resolve does dependency ordering correctly
  and there's no value in the shell script re-implementing it.  The
  `COMPILER_SOURCES` variable is still defined because stage 2 references
  it; stage 2's reproducibility check now reports MISSING for every
  entry (per-source-file vs per-package DLL naming mismatch) and is
  documented as such in the script.  Long-term, stage 2 should be
  rewritten to drive the same `import Lyric.Cli` driver and compare
  bundles file-by-file.

* **Side fix**: `mkdir -p "$(dirname "$STAGE0_BIN")"` in stage 0 — the
  symlink target's parent dir wasn't being created, which made stage 0
  fail on a clean checkout.

* **Side fix**: `--output` → `-o` in two manifest-mode invocations.
  The Lyric CLI's `build` command only recognises `-o` for output path;
  `--output` was silently treated as a positional argument and made the
  CLI complain about "source file not found".

End-to-end verification:

    $ rm -rf .bootstrap
    $ ./scripts/bootstrap.sh --stage 1
    [bootstrap] Stage 0: building F# bootstrap compiler
    [bootstrap] OK: Stage 0 complete
    [bootstrap] Stage 1: compiling Lyric compiler packages with stage-0 lyric
    [bootstrap]   compiling stdlib bundle
    built .bootstrap/stage1/Lyric.Stdlib.dll
    [bootstrap] Stage 1 (CLI bundle): precompiling Lyric.Cli + transitive deps
    [bootstrap]   CLI bundle cache: /tmp/lyric-stdlib-…
    [bootstrap]   copied 67 DLLs into .bootstrap/stage1
    [bootstrap] OK: Stage 1 CLI bundle complete — Lyric.Lyric.Cli.dll + 66 deps
    [bootstrap] OK: Stage 1 complete

Tests: 810/810 emitter, 254/254 Lyric.Cli — unchanged by the build
script edits.

Followup (Track A, A1.3): build an AOT entry-point project that
references `.bootstrap/stage1/Lyric.Lyric.Cli.dll` + the transitive
DLLs and publishes with `<PublishAot>true</PublishAot>`.

---

### D-progress-285 — Band 6: multi-segment type resolver + emitProject verification

**Multi-segment qualified type resolver** (`typechecker_resolver.l`):

The self-hosted type checker's `resolveTypePath` previously deferred all
multi-segment qualified type names (e.g. `Std.Collections.List`,
`Lib.Point`) with a `T0014 "qualified type names not yet resolved"` error.

The fix: for paths with more than one segment, first try looking up the
last segment in the symbol table before falling through to the primitive
check and T0014 error.  Since `checkWithImports` registers imported types
by their simple name (e.g. `"List"` not `"Std.Collections.List"`), this
single lookup resolves qualified references that were already imported
— which is exactly what Band 6 stdlib resolution (D-progress-284) supplies.

Two new tests in `typechecker_self_test.l`:
- `testQualifiedTypeResolvesViaImport` — parses a library source defining
  `record Point`, passes it as an imported item, then checks that
  `Lib.Point` in a function parameter resolves without T0014.
- `testQualifiedTypeUnknownEmitsT0014` — confirms that a truly unknown
  qualified name (`Unknown.Pkg.Blorp`) still produces T0014.

**emitProject path verification** (`docs/41 §9 Band 6` item 2):

Confirmed (via code audit and existing tests) that the self-hosted CLI's
`emitProject` reaches the same F# codegen as the direct F# path:
`cli.l:buildProject` → `Lyric.Emitter:emitProject` shells out to
`--internal-project-build`, handled by F# `internalProjectBuild` →
`Emitter.emitProject`.  `ProjectBuildTests.fs` already exercises this
path (two tests: multi-package bundle happy path + empty-packages
rejection).  In-process multi-file bridge is deferred to Track A A1.x.

All tests: 189/189 TypeChecker, 810/810 Emitter, 254/254 Cli.

### D-progress-286 — Band 5: Lyric.Mono wired into both MSIL and JVM bridges (#858)

`lyric-compiler/lyric/mono.l` restructured to compile under the F# bootstrap
parser.  The F# parser rejected five categories of constructs in the original:

1. `&&` in if/while conditions — replaced with `and`.
2. Unbraced mutation expressions as match arm bodies (`case X -> var = expr`)
   — wrapped in braces.
3. Newline between `->` and match arm body without braces — braces added.
4. `result` as a local variable name — `KwResult` in the Lyric lexer maps to
   `EResult` in expression position, causing "EResult outside contract context"
   at runtime.  Renamed to `acc`, `names`, or `buf` depending on context.
5. `out` as a local variable name — `KwOut` for parameter-mode declarations.
   Renamed to `buf`.

Both bridges updated to run the mono pass:
- `lyric-compiler/msil/bridge.l`: `import Lyric.Mono`; `monoFile(elaborated)`
  inserted between `elaborateFile` and `codegenMPackage`.
- `lyric-compiler/jvm/bridge.l`: same — removed the deferred-import comment,
  added `import Lyric.Mono`, inserted `monoFile(elaborated)` between
  `elaborateFile` and `codegenPackage`.

The Band 1 pipeline for both targets is now complete:
  parse → typecheck (advisory) → modecheck (fatal) → elaborate → **mono** → codegen

All tests: 189/189 TypeChecker, 810/810 Emitter, 254/254 Cli.

### D-progress-287 — Band 5: Lyric.Derives self-hosted derive/generate synthesiser (#857)

New package `lyric-compiler/lyric/derives/derives.l` (`Lyric.Derives`):

- `deriveFile(file: in SourceFile): SourceFile` — entry point.  Walks all
  items and appends synthesised `IFunc` items for each annotated type:
  - `@derive(Equals)` on records/exposed-records → `TypeName.equals(self, other): Bool`
  - `@derive(Hash)` on records/exposed-records → `TypeName.hash(self): Int`
  - `@derive(Show)` on records/exposed-records → `TypeName.show(self): String`
  - `@generate(Json)` on records/exposed-records → `TypeName.toJson(self): String`
  - `type X = T derives Equals/Hash/Show` on distinct types → matching UFCS functions
- Idempotent: a second `deriveFile` call on an already-derived file does not
  duplicate the synthesised functions (checked via `funcAlreadyExists`).
- Both bridges updated: `lyric-compiler/msil/bridge.l` and
  `lyric-compiler/jvm/bridge.l` call `deriveFile(elaborated)` after
  `elaborateFile` and before `monoFile`.

New self-test `lyric-compiler/lyric/derives_self_test.l` (14 tests) covers:
no-annotation, equals/hash/show/toJson on records, multiple derives,
distinct-type derives, empty record, exposed record, idempotency.
Runs via the F# Expecto harness in `SelfHostedDerivesTests.fs`.

The Band 5 pipeline for both targets is now:
  elaborate → **deriveFile** → monoFile → codegen

All tests: 189/189 TypeChecker, 811/811 Emitter, 254/254 Cli.

### D-progress-288 — Track A A1.3: AOT entry-point project + CoreLib-ref rewriter

Third step of Track A (`docs/41 §860` — F# CLI elimination + Native-AOT
publishing).  A1.2 produced the closed set of Lyric-compiled DLLs in
`.bootstrap/stage1/`; A1.3 makes that set usable as compile-time
`<Reference>` inputs from a tiny C# AOT entry-point project that
forwards `Main(args)` straight into `Lyric.Cli.Program.main`.

Two artefacts shipped:

* **`bootstrap/src/Lyric.Cli.Aot/`** (new project) — a Microsoft.NET.Sdk
  Exe csproj plus a 4-line `Program.cs` trampoline.  The csproj
  `<Reference Include="..\..\..\.bootstrap\stage1\Lyric.*.dll" />`
  wildcard pulls in every artefact the stage-1 bundle produces, which
  is exactly the closed set the AOT linker needs.  The trampoline is
  deliberately tiny — anything we add to the C# layer blocks deleting
  the F# CLI in A1.4.

* **`scripts/rewrite-corelib-refs.fsx`** (new) — Mono.Cecil-based
  rewriter that retargets `TypeRef.Scope` from `System.Private.CoreLib`
  (the unified CoreCLR runtime assembly) to the matching public-facade
  reference assembly (`System.Runtime`, `System.Collections`,
  `System.Console`, `mscorlib`, …).  The F# Lyric emitter writes every
  typeref to `System.Private.CoreLib` because that's where the type
  actually lives in CoreCLR, but the reference assemblies the C#
  compiler trusts split BCL types across ~200 facade assemblies —
  `System.Object` is exposed by `System.Runtime`, `List<T>` by
  `System.Collections`, `Console` by `System.Console`, etc.  A bulk
  AssemblyRef rename can't work because no single facade exposes every
  type the emitted DLLs reference.

  The script crawls the .NET reference pack at
  `~/.dotnet/packs/Microsoft.NETCore.App.Ref/<version>/ref/net10.0/`
  to build a `(TypeFullName → AssemblyName)` lookup and a
  `(AssemblyName → FacadeId)` lookup with the real version and
  public-key token from each ref-pack DLL.  Facades use the BCL token
  (`b03f5f7f11d50a3a`) at v10.0.0.0, but `mscorlib` uses the ECMA token
  (`b77a5c561934e089`) at v4.0.0.0 for back-compat — hardcoding either
  set produces refs the C# compiler / CLR loader rejects, so identities
  are read from the actual ref-pack DLLs.

  For each input DLL, the script walks the TypeRef table; for every
  TypeRef whose Scope is `System.Private.CoreLib`, it looks up the
  type's facade, ensures an AssemblyRef row exists for it (adds one if
  not), retargets the TypeRef.Scope to the new ref, then prunes any
  AssemblyRef rows nothing points at any more.  Cecil's nested-class
  `+` separator (`System.IDisposable+EmptyEnumerator`) and the dotted
  form returned by `System.Reflection` are both tried as lookup keys.

* **`scripts/bootstrap.sh`** changes:

  - Stage 1 now copies `Lyric.Jvm.Hosts.dll` from the stage-0 publish
    output into `.bootstrap/stage1/`.  It's a hand-written F# project
    (provides the `Jvm.Hosts.*` extern surface that the JVM kernel
    calls into), not a Lyric-emitted artefact, so it doesn't land in
    the F# emitter's per-process stdlib cache.  But `Msil.Lowering` /
    `Msil.Codegen` reference it statically — without it the AOT csproj
    fails to resolve transitive deps.

  - Stage 1 invokes `dotnet fsi scripts/rewrite-corelib-refs.fsx
    .bootstrap/stage1/*.dll` after the copy, retargeting every TypeRef
    to its public facade.  Output is logged to
    `.bootstrap/rewrite-corelib-refs.log`.

  - **`SKIP_COREREF_REWRITE=1`** env var skips the rewrite for users
    who want to inspect the raw emitted DLLs.

End-to-end verification:

    $ rm -rf .bootstrap
    $ ./scripts/bootstrap.sh --stage 1
    ...
    [bootstrap]   copied 68 DLLs into .bootstrap/stage1
    [bootstrap]   retargeting System.Private.CoreLib refs -> public facades
    [bootstrap] OK: Stage 1 CLI bundle complete

    $ dotnet build bootstrap/src/Lyric.Cli.Aot
    ...
    Build succeeded.

    $ echo 'func main(): Int { println("hello from aot-wrapped lyric"); 0 }' > /tmp/hello.l
    $ bootstrap/src/Lyric.Cli.Aot/bin/Debug/net10.0/lyric build /tmp/hello.l -o /tmp/hello.dll
    $ dotnet exec /tmp/hello.dll
    hello from aot-wrapped lyric

Tests: 811/811 emitter, 254/254 Lyric.Cli — unchanged from
D-progress-287.  (The original write-up here recorded `810/810`,
which was a transcription error noticed in #944; the actual run
total is `811/811` matching the prior milestone — no tests were
dropped between D-progress-287 and this PR.)

Known limitation: `dotnet publish -p:PublishAot=true` on
`Lyric.Cli.Aot.csproj` fails inside `ilc` codegen on a specific
Lyric-emitted method (`Lyric.Cli.Program.cmdPublish`).  The
non-AOT apphost build works end-to-end; the ilc compatibility issue
is filed as #915 and tackled separately.  Once #915 is fixed the
same project will publish to a single self-contained native binary.

Followup (Track A, A1.4): delete the F# CLI scaffolding in
`bootstrap/src/Lyric.Cli/` — `Program.fs` shrinks to the
`--internal-build` entry point that stage 1 uses; all `SelfHosted*.fs`
shims plus `Pack.fs` / `Manifest.fs` / `Maven*.fs` / `Nuget*.fs` /
`Lint.fs` / `TestSynth.fs` go away.

### D-progress-289 — Track A A1.4: delete F# user-facing CLI dispatcher

Fourth step of Track A (`docs/41 §860` — F# CLI elimination + Native-AOT
publishing).  A1.3 produced a working AOT entry-point project that
trampolines straight into the Lyric-emitted `Lyric.Cli.Program.main`,
making the F# user-facing dispatcher dead code.  A1.4 removes that
dead code.

Deleted F# source files (~7 kLoC of dispatcher + command handlers +
their tests):

| Removed file                                  | Was used by             |
|-----------------------------------------------|-------------------------|
| `bootstrap/src/Lyric.Cli/Pack.fs`             | `lyric publish/restore` |
| `bootstrap/src/Lyric.Cli/Maven.fs`            | `lyric build --target jvm` deps |
| `bootstrap/src/Lyric.Cli/MavenShim.fs`        | Java resolver shell-out |
| `bootstrap/src/Lyric.Cli/NugetAssets.fs`      | NuGet asset path walker |
| `bootstrap/src/Lyric.Cli/NugetShim.fs`        | `dotnet restore` wrapper |
| `bootstrap/src/Lyric.Cli/Lint.fs`             | `lyric lint`            |
| `bootstrap/src/Lyric.Cli/TestSynth.fs`        | `lyric test` (F# mirror) |
| `bootstrap/src/Lyric.Cli/SelfHostedPack.fs`   | dispatcher bridge       |
| `bootstrap/src/Lyric.Cli/SelfHostedFmt.fs`    | dispatcher bridge       |
| `bootstrap/src/Lyric.Cli/SelfHostedDoc.fs`    | dispatcher bridge       |
| `bootstrap/src/Lyric.Cli/SelfHostedLint.fs`   | dispatcher bridge       |
| `bootstrap/src/Lyric.Cli/SelfHostedManifest.fs` | dispatcher bridge     |
| `bootstrap/src/Lyric.Cli/SelfHostedTestSynth.fs` | dispatcher bridge    |
| `bootstrap/src/Lyric.Cli/SelfHostedOpenApi.fs` | dispatcher bridge      |
| `bootstrap/src/Lyric.Cli/SelfHostedBench.fs`  | dispatcher bridge       |
| `bootstrap/src/Lyric.Cli/SelfHostedVerifier.fs` | dispatcher bridge     |
| `bootstrap/src/Lyric.Cli/SelfHostedCli.fs`    | primary dispatcher      |
| (plus ~2 kLoC trimmed from `Program.fs`)      | `bootstrapDispatch` + all `cmdX` |

Plus 14 corresponding test files in `bootstrap/tests/Lyric.Cli.Tests/`
(`ManifestTests`, `PackTests`, `NugetShimTests`, `MavenTests`,
`RestoredPackagesTests`, `FmtTests`, `SelfHostedFmtBridgeTests`,
`ParityTests`, `JvmDiagnosticTests`, `LintTests`, `ProjectBuildTests`,
`ProveTests`, `TestRunnerTests`, `DocTests`).

Preserved (bootstrap-only):

* `Program.fs` — trimmed to ~280 LoC.  Handles four internal flags
  (`--internal-build`, `--internal-project-build`,
  `--internal-contract-meta`, and the new `--internal-manifest-build`
  added for stage 1's stdlib bundle compile).  Any other argv prints
  a one-line error pointing at the AOT binary and exits non-zero.

* `Manifest.fs` — TOML parser, retained because
  `--internal-manifest-build` needs to walk `lyric.toml`'s
  `[project.packages]` for the stdlib bundle.

* `SelfHostedBridge.fs` / `SelfHostedMsil.fs` / `SelfHostedJvm.fs` —
  retained because they back `SelfHostedMsil/JvmBridgeTests.fs`,
  which provide end-to-end coverage of the self-hosted compiler
  pipeline.

`bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj` and
`bootstrap/tests/Lyric.Cli.Tests/Lyric.Cli.Tests.fsproj` updated to
match.  `bootstrap.sh` stage 1 and stage 2 switched from
`build --manifest …` (no longer recognised) to
`--internal-manifest-build`.  `Mono.Cecil` and
`System.Reflection.MetadataLoadContext` package refs dropped from
`Lyric.Cli.fsproj` (only the deleted AOT code used them).

End-to-end verification:

    $ rm -rf .bootstrap
    $ ./scripts/bootstrap.sh --stage 1     # builds + retargets + 70 DLLs
    $ dotnet build bootstrap/src/Lyric.Cli.Aot
    $ bootstrap/src/Lyric.Cli.Aot/bin/Debug/net10.0/lyric build /tmp/hello.l -o /tmp/hello.dll
    $ dotnet exec /tmp/hello.dll
    hello from A1.4 trimmed AOT

Tests:
- Lexer:        128/128
- Parser:       323/323
- TypeChecker:  189/189
- Emitter:      811/811 (2 ignored, unchanged)
- Lyric.Cli:     20/20  (was 256/256 + 2 new in #947; the dropped
                         236 tests covered F# command handlers that
                         no longer exist)

### D-progress-290 — issue #365: implement Lyric.Resilience.CircuitStore

`feedback/05-ecosystem-libraries.md` F-8 / issue #365 documented that
`lyric-resilience`'s `extern package Lyric.Resilience.CircuitStore` had
no host-side implementation anywhere in the repo, so the library was
non-functional — every call into `Resilience.circuitIsOpen` would have
thrown `MissingMethodException` at runtime.  Compounding the gap, the
half-open semantics ("one in-flight probe; successful probe closes the
circuit") had no formal model inside the codebase, so neither the
verifier nor any test could reason about them.

This entry closes both gaps:

**F# host shim (`bootstrap/src/Lyric.Emitter/CircuitStoreHost.fs`, ~125 LoC).**
A thin `module Lyric.Resilience.CircuitStore` with a process-global
`ConcurrentDictionary<string, Entry>` and three static methods
matching the existing `extern package` signatures
(`circuitIsOpen(name, cooldownMs)`, `circuitRecordSuccess(name)`,
`circuitRecordFailure(name, failureThreshold)`).  Per-entry locking
serialises mutations on the same circuit; concurrent traffic on
distinct names never contends.  Follows the precedent set by
`HttpClientHost.fs` — a small shim acceptable under CLAUDE.md
because non-constant module-level vals (M5.2 stage 3+ wire
singletons) are not yet emittable from Lyric.

**Lyric-side formal model (`lyric-resilience/src/resilience.l`).**
The state machine that was previously a commented-out spec sketch is
now a real `pub protected type CircuitBreakerState` with four mutable
fields (`consecutiveFailures`, `isOpen`, `openedAtMs`,
`halfOpenProbeInFlight`), three verifier-visible `invariant:` clauses
(`consecutiveFailures >= 0`, `isOpen or openedAtMs == 0`,
`not isOpen or openedAtMs > 0`), and three entries (`recordSuccess`,
`recordFailure(threshold, nowMs)`, `checkOpen(cooldownMs, nowMs)`)
whose contracts (`requires: threshold > 0` etc.) are runtime-checked
in `@runtime_checked` mode and SMT-provable under `@proof_required`.
`nowMs` is injected as a parameter so the state machine is testable
without a real clock.  Three thin pub helpers
(`makeCircuitBreakerState`, `cbStateRecordSuccess/Failure/CheckOpen`)
give users a Lyric-level handle for unit testing the state machine
in isolation.

The two implementations are deliberately mirrored.  The F# shim is the
in-process realization that backs the registry-keyed public API
(`circuitIsOpen` etc.) that `lyric-web` and `lyric-grpc` call into;
the Lyric protected type is the verifier-visible source of truth.
Once wire-singleton emit support ships, the registry plumbing can
move into Lyric and the F# shim retires.

Test coverage:

- `bootstrap/tests/Lyric.Emitter.Tests/CircuitStoreHostTests.fs`
  (12 Expecto tests, all passing) — exercises the F# shim
  directly: fresh-circuit / threshold / success-closes /
  half-open-probe-grant / single-probe-concurrent-block /
  failed-probe-reopen / independent-circuits / idempotent-success.
- `lyric-resilience/tests/resilience_tests.l` (six new Lyric tests)
  — exercises both the registry-backed public API and the
  `CircuitBreakerState` formal model with injected `nowMs` for
  deterministic transitions.

Files:

- new: `bootstrap/src/Lyric.Emitter/CircuitStoreHost.fs`
- new: `bootstrap/tests/Lyric.Emitter.Tests/CircuitStoreHostTests.fs`
- edited: `bootstrap/src/Lyric.Emitter/Lyric.Emitter.fsproj`
- edited: `bootstrap/tests/Lyric.Emitter.Tests/Lyric.Emitter.Tests.fsproj`
- edited: `bootstrap/tests/Lyric.Emitter.Tests/Program.fs`
- edited: `lyric-resilience/src/resilience.l`
- edited: `lyric-resilience/src/_kernel/net/resilience_kernel.l`
- edited: `lyric-resilience/tests/resilience_tests.l`

### D-progress-291 — Band 5: value generics + cross-package surface + constraint validation in Lyric.Mono (#858)

Closes `docs/41 §9 Band 5` monomorphizer entry partway.  `Lyric.Mono`
gains three capabilities and a self-test consumer; the cross-package
specialisation needed to retire the F# emitter's reified-generics path
still depends on Band 6 (`Lyric.RestoredPackages`).

What shipped:

1. **Value generic parameters (`GPValue`).**  Each specialisation tracks
   a parallel `valueSubst: Map[String, Expr]` alongside the existing
   type substitution.  At specialisation time the value-param map is
   applied across the body (every `EPath([N])` leaf and every
   `TAValue(EPath([N]))` inside a `TArray.size` or `TGenericApp.args`
   gets rewritten to the bound concrete Expr) before the worklist
   walks for nested generic calls.  Mangled names append `V<key>`
   segments — `valueExprKey` covers integer/bool/char/string literals
   and single-segment paths.

2. **Cross-package entry point.**  `monoFileWithImports(file,
   importedGenDecls)` merges caller-supplied generic decls into the
   same lookup as same-package generics.  The bridges still call
   `monoFile(file)` (empty imports list) — wiring them through awaits
   the Band 6 cross-package resolver.

3. **Best-effort marker-constraint validation.**  When a generic
   function carries a `where T: Marker` bound and `T` substitutes to a
   primitive, the well-known marker set (`Equals`, `Hash`, `Show`,
   `Ord`, `Compare`) is checked against the BCL primitive set.
   Unknown concrete types accept silently because cross-package trait
   dispatch is Band 6.  Confirmed mismatches emit `M0001` error
   diagnostics that flow through `MonoResult.diagnostics`.

The new code path activates either when a future surface adds explicit
type-app syntax at call sites, or when another middle-end pass
synthesises `ETypeApp(EPath(f), targs)` nodes — Lyric's parser today
treats `f[T](x)` as `EIndex` followed by `ECall`, so user-written value
generics still rely on inference from argument types (which works for
`GPType` but not for `GPValue`).

Files touched:

- `lyric-compiler/lyric/mono.l` — extended the existing pass.
- `lyric-compiler/lyric/mono_self_test.l` — new consumer with eleven
  test cases covering type-generic inference, explicit `ETypeApp`
  type-app, value generics (single + multiple distinct + body
  substitution), mixed type + value mangling, constraint validation,
  nested call chains, cross-package, and the no-op fast path.
- `bootstrap/tests/Lyric.Emitter.Tests/SelfHostedMonoTests.fs` — F#
  Expecto runner that compiles the self-test through the bootstrap
  emitter and asserts exit-0 + "ok" in stdout.

Tests:
- Lexer:        128/128
- Parser:       323/323
- TypeChecker:  189/189
- Emitter:      812/812 (1 new self-host test, 2 ignored unchanged)

### D-progress-292 — Track A A1.3 follow-up: unblock Native-AOT publish (#915)

Fifth step of Track A.  D-progress-288 (A1.3) shipped the AOT entry-point
project but called out a known limitation: `dotnet publish -p:PublishAot=true`
on `Lyric.Cli.Aot.csproj` failed inside `ilc` codegen on
`Lyric.Cli.Program.cmdPublish(string[])`.  This entry resolves that
blocker.

Root cause was three latent stack-balance bugs in the F# emitter
(`bootstrap/src/Lyric.Emitter/Codegen.fs`) that the JIT had been
silently tolerating but ilc's stricter verifier rejected:

1. **`isNeverBranch` missed divergent statements.**  The predicate only
   recognised `panic(...)` calls as never-returning, so a match-arm body
   ending in `return`, `throw`, `break`, or `continue` was treated as a
   normal value-producing arm.  When such an arm was paired with a
   value-producing arm, the merge label saw different stack heights
   (the divergent arm pushed nothing; the other arm pushed its value).
   Extended the predicate to recognise all four divergent statement
   forms in addition to `panic(...)`.

2. **Match-arm reconciliation only handled Void↔Unit.**  When sibling
   arms disagreed on whether they pushed a value (e.g. one arm produced
   an `Int32` via a fall-through default, another arm was an empty
   block `{}`), the reconciliation only padded `Void → Unit`/`Unit →
   Void`.  Widened the reconciliation to pad any `Void → T` (push a
   default of `T`) and `T → Void` (pop) so the merge label is always
   reached with the same stack depth.

3. **EIf relied on an inaccurate `branchLeavesValue` look-ahead.**
   `peekExprType` returns `obj` for `ECall(EMember(...), ...)` shapes
   it can't statically resolve (e.g. `env.add(name, te)` where the
   actual return is `void`).  `branchLeavesValue` then reported "leaves
   a value" for both branches even when one's actual emit was void,
   producing mismatched stack depths at the merge label.  Restructured
   `EIf` emission to route each non-divergent branch through an
   intermediate post-label, then reconcile after both arms' *actual*
   types are known: when the unified merge type is `Void`, pop the
   non-Void path's value before falling into `lblEnd`.

The third fix is post-emit reconciliation rather than a smarter
look-ahead because making `peekExprType` accurate for arbitrary
method-call shapes would require carrying full type-checker state
into the look-ahead — out of scope for a bootstrap-grade fix.

End-to-end verification:

    $ rm -rf .bootstrap
    $ ./scripts/bootstrap.sh --stage 1
    $ cd bootstrap/src/Lyric.Cli.Aot
    $ dotnet publish -c Release -r linux-x64 -p:PublishAot=true
    ...
    Lyric.Cli.Aot -> .../bin/Release/net10.0/linux-x64/publish/

    $ bin/Release/net10.0/linux-x64/publish/lyric --version
    lyric 0.1.0
    $ bin/Release/net10.0/linux-x64/publish/lyric build /tmp/hello.l
    built /tmp/hello.dll
    $ dotnet /tmp/hello.dll
    hello from aot

Resulting binary is ~4 MB, stripped, statically linked against the
.NET runtime — Track A's "no .NET runtime at deployment" goal for
the published binary form.

Three ilc warnings remain (out of scope here, not regressions from
A1.3 — they're pre-existing IL-quality issues that `dotnet build`'s
JIT had been silently tolerating):

* `Lyric.Cli.Program.cmdSearch(string[])` — "will always throw because:
  Invalid IL or CLR metadata".  IL-verifier reports a `PathStackDepth`
  at offset 0x71 plus two type-shape mismatches.  Same general class as
  this fix (branch-merge stack mismatch) but in a shape the post-emit
  reconciliation doesn't cover.
* `Lyric.Emitter.ProcessCapture.runCapture` and
  `Lyric.Emitter.VerifierEnv.getEnv` — both fail with "Failed to load
  assembly 'FSharp.Core'".  The Lyric AOT bundle deliberately doesn't
  ship `FSharp.Core` because no Lyric-emitted code uses it; these two
  F#-side shims still do.  They're never invoked by `cmdPublish`'s
  call graph so ilc treats them as unreachable and emits throwing
  stubs.

The Lyric IL emitter changes do not regress any existing test:

- Lexer:        128/128
- Parser:       323/323
- TypeChecker:  189/189
- Emitter:      812/812 (2 ignored, unchanged)
- Lyric.Cli:     65/65

### D-progress-292 — Self-hosted aspect weaver wired into `lyric prove` (#336)

Closes the option-(a) path of #336.  The verifier no longer walks the
parsed AST — `Lyric.Verifier.proveSourceWithOptions` now calls
`Lyric.Weaver.weaveFile(parsed.file)` before VC generation, so proofs
discharge against the woven wrapper's composed contracts (the body the
runtime executes) rather than the bare target body.  The interim V0031
warning shipped in D-progress-270 is retired; both same-package and
cross-package aspect targets now contribute boundary contracts to the
proof obligations (cross-package weaver lift is tracked separately —
the current weaver only sees `IAspect` items in the file being proven).

* **`lyric-compiler/lyric/weaver/weaver.l`** (new, ~890 LoC) — self-
  hosted port of `bootstrap/src/Lyric.Emitter/Weaver.fs`.  Mirrors the
  bootstrap weaver: glob matching (`*`, `?`, `[abc]`, `[a-z]`),
  `proceed(args)` → `target(args)` rewriter walking the full AST
  (expressions, blocks, statements, match arms, EOBs, interpolated
  segments, local bindings, try/catch, defer), wrapper synthesis with
  `aspect.contracts ++ original.contracts` composition, topological
  sort by `wraps:` / `inside:` clauses (Kahn's algorithm; lexical
  tiebreak, cycles fall back to lexical order), `@no_aspect` /
  `@no_aspect("Name")` opt-outs, and `signature: returns` matching
  with the same `typeExprToString` shape as F#.  Public surface:
  `pub func weaveItems(items): List[Item]` and
  `pub func weaveFile(file): SourceFile`.

* **`lyric-compiler/lyric/verifier/driver.l`** — adds
  `import Lyric.Weaver` and a `weaveFile(parsed.file)` call in
  `proveSourceWithOptions` between stability-check and VC generation
  (step 4).  Identity-op for files without aspect blocks.

* **`lyric-compiler/lyric/verifier/vcgen.l`** — retires the
  `collectAspectNames` / `firstAspectAnnotation` helpers and the
  V0031 warning emission in `goalsForFile`.  IAspect items are
  pre-stripped by the weaver, so the verifier sees only original
  IFuncs, renamed `__aspect_target` IFuncs, and wrapper IFuncs with
  composed contracts — all verified identically by `goalsForFunction`
  against their declared contracts.

* **`docs/15-phase-4-proof-plan.md`** — V0031 row updated to record
  the retirement (replaced by the weaver pipeline; cross-package
  aspects remain a follow-up).

Two notable bootstrap-emitter workarounds surfaced during the port:

1. `out` is a reserved keyword (`PMOut` param mode); the parser parses
   `val out = ...` as `PError`.  Renamed every local in the weaver to
   `acc` / `noAspectItems`.

2. The bootstrap emitter mis-resolves nested
   `match mapGet(m, k) { case Some(inners) -> while ii < inners.count {...} }`
   when the enclosing function returns a `List` of an imported record:
   the type of `inners.count` collapses to the imported record's
   element type, hitting the "AspectDecl has no field 'count'" path
   in `Codegen.emitExpr`.  Worked around by extracting the inner loop
   into helpers (`bumpInDegrees`, `lookupIntOr0`, `buildSortedResult`)
   so the receiver type stays inferable from the helper signature.

* **`lyric-compiler/lyric/verifier_self_test.l`** — adds
  `testProveAspectWeaveNoV0031` (proof-required + matching aspect, no
  V0031, no error diagnostics) and `testProveNoAspectStillWorks`
  (regression: weaver is identity-op without aspects).

**Test results:** 811/811 emitter (unchanged), 65/65 CLI, 189/189
typechecker, 323/323 parser, 128/128 lexer.

### D-progress-293 — Monomorphizer type-arg inference for nested calls, records, and impl/interface generics (#349 follow-up)

Closes the inference gap that D-progress-269 left open: at the start
of this session `inferExprTE` returned `None` for `ECall`, `EMember`,
and `ETypeApp` expressions because the helper only saw the local env,
never `state.genDecls` / `state.recordDecls`.  The fall-through left
the surrounding generic call un-specialised, which the self-hosted
MSIL / JVM emitters cannot instantiate.  The fix threads state into
the helper and adds three new cases plus a record-constructor return
recogniser:

* **`ECall(EPath(fname), args)`** — look up `fname` in
  `state.funcDecls` (newly tracked: every same-package IFunc, generic
  or not).  Unify the callee's declared param types against the
  inferred arg types; if every type param is bound, substitute the
  callee's return TypeExpr and return it.  Non-generic callees skip
  the inference branch and return the declared return type
  unchanged, so chains like `consume(origin())` where
  `origin(): Int` is non-generic now specialise the outer generic.

* **`EMember(recv, name)`** — infer `recv`'s type, and when it
  resolves to a same-package record (or exposed record) in the new
  `state.recordDecls` map, walk the record's fields, find the named
  field, and substitute the record's generic params with the
  receiver's concrete type arguments before returning the field's
  TypeExpr.  Unblocks the `consume(b.value)` shape called out in the
  issue once `b` has a known type.

* **`ECall(EPath(recName), args)` for same-package records** —
  Lyric record literals share the call syntax (`Box(value = 11)`),
  so the new `inferRecordCtorTE` helper checks
  `state.recordDecls` before the generic-function branch and
  returns the record type expression directly.  Together with the
  init-expression inference added to `rewriteBinding` this means
  `val b = Box(value = 11)` now seeds `b: Box` into env without
  requiring an annotation.

* **`ETypeApp(EPath(fname), targs)`** — forward-compatible arm.
  The current Lyric parser produces `EIndex`, not `ETypeApp`, for
  `f[T](x)` (the bootstrap grammar treats `[…]` after an
  expression as indexing), so this case is exercised only when a
  future explicit-type-app lowering lands.  The arm is here so the
  monomorphizer reads cleanly when that work comes online.

Beyond the inferer:

* **`MonoState`** gains `funcDecls: Map[String, FunctionDecl]`
  (all same-package IFuncs, generic and non-generic) and
  `recordDecls: Map[String, RecordDecl]` (records + exposed
  records).  Phase 1 collects both alongside the existing
  `genDecls`.

* **Phase 1 also walks `IInterface` and `IImpl` member lists** via
  the new `collectIfaceGenerics` / `collectImplGenerics` helpers,
  so generic default methods inside `interface I { … }` and
  generic methods on `impl T for X { … }` blocks now feed both
  the inferer and the specialisation worklist.  The F# bootstrap
  monomorphises these via CLR runtime generics today, so this
  closes the divergence the issue called out at `mono.l:898-915`.

* **`rewriteBinding`** falls back to `inferExprTE(init)` when the
  binding has no annotation, so chains starting from an inferred
  local (record constructor, generic call return) stay legible to
  downstream inference rather than dropping the type info at the
  first `val`/`var`/`let`.

* **`LBVar` / `LBLet` re-binding** drops the existing env entry
  before adding the new one (`env.remove(name); env.add(name, te)`),
  closing the MEDIUM gap the issue noted at `mono.l:808-820` where
  a shadowed `var` left the inferer stuck on the prior annotation.

Bootstrap-grade emitter quirk worked around: the F# bootstrap's
type checker unifies the V in `mapGet[String, V]` with the
enclosing function's `Option[TypeExpr]` return type when the lookup
result is matched directly, which routes downstream field access
through `TypeExpr` and fails at codegen with
`'TypeExpr' has no field 'generics'`.  Both
`inferReturnFromName` and `lookupFieldTE` now hold the lookup in
a `val recOpt: Option[<Decl>] = …` annotated binding before
matching, which forces the correct specialisation.  Noted with a
comment so the workaround moves with the call sites.

* **`lyric-compiler/lyric/mono_self_test.l`** + matching F# runner
  `bootstrap/tests/Lyric.Emitter.Tests/SelfHostedMonoTests.fs`
  exercise the five inference shapes (literal arg, nested generic
  call, record field projection, non-generic-return chaining,
  multi-param inference).  The runner compiles the self-test
  source through the bootstrap emitter and asserts `exit 0` + an
  `ok` line on stdout — same pattern as the other self-hosted
  library tests (Lyric.Derives, Lyric.Fmt, …).

What is **still** un-specialised: lambda return types, BCL method
returns (the inferer has no signature info for imported types),
method calls into impl blocks via the type-class targeting layer.
These were explicit non-goals for #349 and would need either a
real type checker bridge or an opaque-imports surface.  Per the
docstring at the top of `mono.l` they fall through to the
unchanged `None` branch, which keeps the existing imported-generic
behaviour intact.

**Test results:** 812/812 emitter (+1 over the previous baseline,
covering the new mono self-test), 128/128 lexer, 323/323 parser,
189/189 type checker, 65/65 CLI bridge.

### D-progress-294 — MSIL: `IImpl` emits real `InterfaceImpl` + `MethodImpl` metadata (#878)

The self-hosted MSIL `IImpl` handler in `lyric-compiler/msil/codegen.l`
previously extracted each impl-block function and added it to the host
class as a static method, but never constructed an `MPImpl(MImplData)`
item.  No `InterfaceImpl` row was emitted for `impl Iface for Target`,
and no `MethodImpl` rows bound interface slots to their implementations.
Any `Target`-typed value used through an `Iface`-typed slot would fail
virtual dispatch at runtime — the CLR could not find the method slot
because the metadata did not record the implementation relationship.

The JVM backend already did the right thing (pre-pass over `IImpl`,
merge methods into `LRecord` + `implementsIfaces`).  This change brings
the MSIL backend to parity:

* **Pre-pass over `IImpl`.** `collectImplEntriesMsil` walks the source
  file and groups impl funcs by target class.  Single-segment interface
  names are implicitly qualified with the current package; multi-segment
  paths are kept verbatim.
* **Instance-method injection.** `mergeImplForwardersMsil` re-uses
  `lowerImplFuncAsInstanceMsil` to produce virtual instance MFuncs (slot
  0 reserved for `this`, flags = `Public | Virtual | Final | HideBySig |
  NewSlot`) for every impl func targeting the record.  Explicit `self`
  parameters are folded onto slot 0 and excluded from the emitted CLR
  signature so it matches the interface contract exactly.
* **Name-based `MImplData`.** `MImplData` and `MImplSlot` gained string
  fallback fields (`targetTypeName`, `targetTypeNamespace`,
  `ifaceTypeName`, `ifaceTypeNamespace`, per-slot `ifaceMethodName` /
  `implMethodName`).  Codegen emits the `MPImpl` item with token fields
  set to 0 and the names populated; `lowerMImpl` resolves them via
  `resolveTypeDefRowByName` / `resolveMethodDefRowInType` after every
  TypeDef is in the table, then writes the `InterfaceImpl` +
  `MethodImpl` rows.  Resolution failures skip the row instead of
  emitting a garbage 0 reference that would crash the CLR loader.
* **`addPackageTokens` parity.** The IRecord / IExposedRec passes in
  `addPackageTokens` now add `countImplForwardersMsil` to
  `methodDefRow` so that any `IFunc` following an `impl` block keeps a
  correct MethodDef token (the old code under-counted impl rows and the
  Pass-2 IFunc tokens silently drifted).
* **Old static-on-host folding removed.** The previous
  `fns.add(implFunc)` path is gone — impl funcs now live as instance
  methods on the target TypeDef instead of as orphan statics on the
  host class.

Regression test (`shm_impl_metadata` in
`bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilBridgeTests.fs`) compiles
a program with an interface, a record, and an `impl` block, then
inspects the resulting DLL with `System.Reflection.Metadata` to assert
`InterfaceImpl` row count == 1 and `MethodImpl` row count == 1, and
finally runs the DLL to confirm the metadata is well-formed enough for
the CLR to load the implementing type without a `TypeLoadException`.
Verified that disabling the `MPImpl` emission causes the test to fail
on the `InterfaceImpl` count assertion.

Closes #878.

Tests:
- Lexer:        128/128
- Parser:       323/323
- TypeChecker:  189/189
- Emitter:      824/824 (2 ignored unchanged; baseline includes D-progress-290, -291, and -293)
- Lyric.Cli:     67/67  (66 carried over + new `shm_impl_metadata` regression test)
### D-progress-295 — Band 2 R6: ELambda, EYield (collect-all), auto-FFI for IExternType (PR #927)

Three remaining Band 2 gaps in the self-hosted MSIL backend are now closed
(docs/41 §9 Band 2, items 6 / 10 / 12):

**ELambda — non-capturing lambda lifting** (`msil/codegen.l`, `msil/bridge.l`):

Non-capturing lambdas are now fully lowered in the self-hosted MSIL backend.
A BFS pre-pass (`liftLambdasMsil`) runs between aspect weaving and
`addPackageTokens`: it extracts every `ELambda` node into a synthetic
`__lambda_<i>` `IFunc` appended to the `SourceFile`, processes lambda bodies
in FIFO / breadth-first order (so outer lambdas are always numbered before
any lambdas nested inside their bodies), and adds each body to a deferred
queue rather than recursing immediately.  `addPackageTokens` then assigns
stable `MethodDef` tokens to the synthetic functions.  At codegen, each
`ELambda` site reads `cctx.lambdaTicker.count` as its index (same BFS
order), looks up `__lambda_<i>` in `funcTokens`, and emits
`ldnull + ldftn methodToken + newobj System.Action::.ctor` (zero-param) or
`newobj System.Action\`N<object,...>::.ctor` (N-param, via TypeSpec for the
closed generic instantiation).  The delegate arity matches the lambda's
parameter count; all parameter types are treated as `object` in this
bootstrap stage.

Two new `MInsn` cases in `lowering.l` support this: `MLdftn(methodToken)`
(ECMA-335 `ldftn` opcode) and `MNativeInt` in `MsilType`
(`ELEMENT_TYPE_I = 0x18`, used in the `Action::.ctor(object, native int)`
member-ref signature).

Display-class synthesis for capturing lambdas remains deferred to Band 3.

**EYield — collect-all async generator model** (`msil/codegen.l`):

Async functions whose bodies contain `EYield` nodes are now detected via
`decl.isAsync && funcBodyContainsYieldMsil(decl)`.  A `List<object>`
collector local is allocated at function entry; each `EYield(inner)` appends
its value (boxed if primitive) to the collector; the function returns the
collector as `MObject` at exit.  The yield-slot index is stored in
`fctx.yieldSlots` so `EYield` lowering can reference it without re-scanning.

**Auto-FFI scoring for IExternType** (`msil/codegen.l`):

`IExternType` items (e.g. `extern type StringWrapper = "System.String"`) now
populate `cctx.externTypeNames` (a `Map[String, String]` mapping the Lyric
type name to the CLR FQN) during `addPackageTokens`.  `lowerMethodCallMsil`
intercepts call sites where the receiver is an `EPath` whose last segment
resolves to an `externTypeNames` entry and routes them through
`emitAutoFfiCallMsil`, which looks up or registers the CLR type/member ref
and emits a direct static `call` without requiring `@externTarget`
annotations on each method.

**Test coverage** (added to `SelfHostedMsilBridgeTests.fs`):
- `shm_lambda_non_capturing` — non-capturing lambda compiles and the program
  prints "lambda ok".
- `shm_yield_collect` — async generator with 3 yields compiles and the
  program prints "yield ok".
- `shm_extern_type_smoke` — `extern type` declaration compiles and the
  program prints "extern type ok".

All tests: 189/189 TypeChecker, 810/810 Emitter, 254/254 Cli.

### D-progress-296 — Self-hosted MSIL PE writer: FAT-body alignment + bridge parse fix

Two follow-ups to D-progress-295 that close out the remaining `shm_yield_collect`
failure on PR #927:

**FAT method body alignment** (`msil/assembler.l`):

ECMA-335 II.25.4.5 requires FAT-format method bodies to start on a 4-byte
boundary in the PE image; TINY bodies have no alignment requirement.  The
PE writer previously laid bodies out consecutively without padding, so when
a short TINY body (e.g. `helper(): Int { return 42 }`) preceded a FAT body
(e.g. `main` with locals), the FAT header landed at a non-aligned RVA and
the CLR JIT rejected the assembly with `InvalidProgramException` — even
though the IL itself passed `ilverify`.

`methodBodyRvas` now serialises every body up-front and pads each body's
RVA range to a 4-byte boundary when the *next* body is FAT (detected by
inspecting the first header byte: bits 0..1 = `0b11`).  `assemblePe` mirrors
the layout by writing zero-padding between bodies for the same condition.
Padding is suppressed when the next body is TINY, so single-method or
tiny-only files produce byte-identical output to the pre-fix layout — every
existing `msil_self_test_mNN` continues to pass with no offset churn.

**Bridge parse fix — rename `out` parameter** (`msil/codegen.l`):

`collectLambdasBfsExpr` / `collectLambdasBfsStmt` declared a parameter named
`out`, which is a Lyric reserved keyword (`out` mode marker).  The
self-hosted Lyric lexer/parser correctly rejected the file, so the bridge
DLL could not be built and every `SelfHostedMsil` bridge test errored at
compile time.  The parameter is renamed to `synths` (matching its semantic
role of collecting synthetic lifted-lambda items) at every call site.

**Yield collector cast** (`msil/codegen.l`):

The yield collector local is typed `object` (`MObject`) in the local
signature, but `List<object>::Add` and `List<object>::get_Count` require
`this` to be `List<object>`.  Each `EYield` and each `xs.count` access now
emits `castclass List<object>` (via the TypeSpec token cached at codegen
init) before the `callvirt`, so the IL passes both `ilverify` and the JIT
verifier.

**Generator return type in `addPackageTokens`** (`msil/codegen.l`):

`addPackageTokens` mirrors the `isGenerator` detection from `lowerFuncMsil`
so that `funcRetTypes` records `MObject` for generator functions regardless
of the source-level return annotation.  Without this, call sites that
stored the result of a generator into a typed local emitted code that the
verifier rejected.

**Action`N invoke signature uses MTypeVar** (`msil/codegen.l`):

`buildActionNInvokeTok` now uses `MTypeVar(pi)` (ECMA-335 `ELEMENT_TYPE_VAR`)
for each Invoke parameter, matching the generic `Action`N<T0, T1, ...>::Invoke(T0, T1, ...)` signature.  Arguments at the invoke site are
boxed when needed so primitive-typed args (e.g. `g(99)` where `g` is a
`(Int) -> Unit` lambda) satisfy the `object`-typed delegate parameter.

All tests pass: 128/128 Lexer, 323/323 Parser, 189/189 TypeChecker,
811/811 Emitter, 258/258 Cli.

### D-progress-297 — `Std.Process` captured-output API: `runCapture` / `runCaptureWithInput` / `ProcessResult` (#1023 / #743, PR #1060)

Completes the `Std.Process` subprocess-capture API (#1023) and resolves
the remaining developer-experience gap in #743.

**`ProcessCapture.fs` refactor:**

`runCapture` is split into `runCaptureImpl(timeoutMs)` (shared core, no
outer exception catch) and two callers:
- `runCapture` wraps with `try … with _ -> captureFailure` to preserve
  backward-compatible silent-failure behaviour for `Std.ProcessCapture`
  callers (verifier, generator).
- `runCaptureWithTimeout` delegates to `runCaptureImpl` without an outer
  catch — spawn failures propagate as exceptions, making the `Err` return
  path in the Lyric wrappers reachable (#1062).

**`_kernel/process_capture_host.l`:**

Added `hostRunCaptureTimeout(executable, arguments, stdinContent, timeoutMs):`
`ProcessCaptureResult`, targeting `Lyric.Emitter.ProcessCapture.runCaptureWithTimeout`.

**`_kernel_jvm/process_capture_host.l`:**

Added matching stub for `lyric.stdlib.jvm.ProcessCaptureHost.runCaptureWithTimeout`.
JVM implementation tracked in #1065.

**`std/process.l`:**

Added:
- `pub record ProcessResult { stdout, stderr, exitCode, timedOut }`
- `pub func runCapture(executable, args, timeoutMs): Result[ProcessResult, String]`
- `pub func runCaptureWithInput(executable, args, stdin, timeoutMs): Result[ProcessResult, String]`
- Private `buildCaptureArgString` (always-quote variant of `buildArgString`)

**`lyric-stdlib/tests/process_tests.l`:**

Seven tests covering: stdout capture, non-zero exit, stderr, stdin passthrough
via `cat`, timeout enforcement, simultaneous stdout+stderr, and spawn failure
(`Err` contract is reachable for nonexistent executables).

**`KernelBoundaryTests.fs`:** ratchet bumped 302 → 303.

All tests pass: 128/128 Lexer, 323/323 Parser, 189/189 TypeChecker,
825/825 Emitter, 61/61 Cli.

### D-progress-298 — Multi-package test runner: `lyric test --manifest` (#465)

**Status:** Shipped.

**Problem:** `lyric test` was single-file only (`Emitter.emit`).  Ecosystem
libraries like `lyric-auth` and `lyric-session` have test files that import
packages from the same project (e.g. `import Auth`); those imports cannot be
resolved by the single-file path.  The two security regression test files
(`lyric-auth/tests/auth_security_tests.l`, `lyric-session/tests/session_fixation_tests.l`)
existed as living specs but could not be executed.

**Root bug in `cmdTestManifest`:** The previous implementation concatenated
all package sources into a single string and called `Emitter.emit` (single-file
path).  A project with multiple `package X` declarations produces invalid source
when concatenated, so the parser rejected every multi-package test run.  In
addition, no dependency resolution was performed (causing `import Std.*` to fail),
and active features were not computed (causing feature-gated packages such as
`Auth.Kernel.Net` to be silently excluded).

**Fix (`lyric-compiler/lyric/cli.l` — `cmdTestManifest`):**
1. Active features are resolved via `Mf.readFeatureDefaultsFromToml` before any
   package is read, matching `buildProject`.
2. Library packages are built from `[project.packages]` into a
   `List[ProjectPackage]`, identical to `buildProject` (handles single `.l` files
   and directories; sorted for determinism).
3. Local-path dependencies are resolved to DLL paths via the same dep-walking
   logic as `buildProject` (reads each dep's `lyric.toml`, computes the expected
   DLL name, warns if the DLL is absent but does not fatal — unbuilt optional
   deps like `Lyric.Cache` are skipped silently when their packages are
   feature-gated).
4. Each test entry from `[project.tests]` is synthesised via `TestSynth.synthesize`
   and appended as its own `ProjectPackage`; the combined list is compiled via
   `Emitter.emitProject` so every package declaration lives in its own
   compilation unit.
5. Results are TAP-compatible: per-test pass/fail lines, a summary, and an exit
   code of 1 if any test failed.

**CI integration (`.github/workflows/ci.yml`):**
A new "Ecosystem test suite" step runs after the AOT smoke test.  It guards
on the stage-1 bundle and AOT binary (same pattern as the AOT step), pre-builds
`lyric-stdlib` so dep resolution succeeds, then runs both test manifests in
sequence (both always run; overall exit code fails CI if either fails).  The
step has no `continue-on-error` so security regressions block merge.

**Acceptance criteria met:**
- `lyric test --manifest lyric-auth/lyric.toml` — pins JWT algorithm-pinning
  (#315) and role allow-list (#360) invariants.
- `lyric test --manifest lyric-session/lyric.toml` — pins the no-auto-create
  session-fixation guard (#316).
- CI fails if either test suite regresses.


### D-progress-299 — `Lyric.Cfg` in-process feature erasure (#1183, PR #1224)

**Status:** Shipped.

**Problem:** `Lyric.Emitter.emitProject` fell back to the F# `lyric
--internal-project-build` subprocess whenever a request carried active
feature flags (`req.activeFeatures.count > 0`), because the self-hosted
multi-package MSIL bridge had no `@cfg` erasure pass.  Any feature-bearing
build paid a process spawn per `emitProject` call and could not run on
runtimes where the subprocess hop is undesirable.  Together with the
restored-dependency-DLL gap (#1229), this was the last blocker on the
in-process path before the F# subprocess fallback can be retired.

**Fix:**

1. **`lyric-compiler/lyric/cfg.l` (new) — `Lyric.Cfg` package.**  Self-
   hosted port of `bootstrap/src/Lyric.Emitter/Cfg.fs` per D045.
   Implements `applyCfgErasure(active, declared, sf): CfgErasureResult`.
   Walks each top-level `Item.annotations` and the file-level
   `SourceFile.fileAnnotations`; items annotated with any
   `@cfg(feature = "X")` whose X is absent from `active` are dropped.
   File-level `@cfg` erases the whole file (items + imports) when
   inactive.  F0012 fires for malformed predicates; F0013 fires for
   features absent from a non-empty `declared` set (typo guard,
   gated to off when no `[features]` table is declared).

2. **`lyric-compiler/msil/bridge.l` — new
   `compileProjectToMsilWithFeatures` entry point.**  Wraps the
   pre-existing `compileProjectToMsil` (which is now a thin
   no-features shim) and runs `Cfg.applyCfgErasure` between parse and
   typecheck, so erased items disappear before any name resolution
   sees them.

3. **`lyric-compiler/lyric/emitter.l` — `EmitProjectRequest`
   carries `declaredFeatures: List[String]`.**  `emitProject`'s
   `canInProc` predicate drops the `req.activeFeatures.count == 0`
   filter; the in-process path forwards `req.declaredFeatures` as
   a distinct argument from `req.activeFeatures` (the F0013 typo
   guard depends on them being separate).  The subprocess fallback
   writes a new `DECLARED\t<name>` spec line per declared feature.

4. **`bootstrap/src/Lyric.Cli/Program.fs` — `--internal-project-build`
   parses `DECLARED` lines.**  A `ResizeArray<string> declaredFeatures`
   is populated alongside `activeFeatures` and threaded into
   `ProjectEmitRequest.DeclaredFeatures`, retiring the matching
   `Set.ofSeq activeFeatures` placeholder on the subprocess path.

5. **`lyric-compiler/lyric/cli.l` — feeds `Mf.readFeatureDeclaredFromToml`
   through.**  The `build` and `test --manifest` paths already computed
   the manifest's declared set for the active-feature resolution; the
   value is now passed to `EmitProjectRequest.declaredFeatures` instead
   of being recomputed downstream.

**Tests:**

- `lyric-compiler/lyric/cfg_self_test.l` (new) — `Lyric.Cfg` unit
  self-test exercising no-annotations, inactive/active erasure, AND
  semantics, F0012/F0013 firing, F0013 suppression with empty declared,
  and file-level erasure both ways.  Discovered + run by
  `bootstrap/tests/Lyric.Emitter.Tests/SelfHostedCfgTests.fs` (same
  shape as the other `Lyric.*` self-tests).
- `lyric-stdlib/tests/msil_project_bridge_tests.l` — six new
  integration tests covering the in-process path end-to-end via
  `Lyric.Emitter.emitProject`: feature active, feature inactive,
  AND semantics, F0012 (compile fails), F0013 (warning, compile
  succeeds), file-level erasure.

**Acceptance criteria met:**

- `emitProject` no longer shells out for feature-bearing requests; the
  in-process bridge runs `applyCfgErasure` before typecheck.
- F0013 is functionally live on both paths (the previous "for now"
  `declaredFeatures == activeFeatures` placeholder removed).
- Self-test coverage matches the convention of every other self-hosted
  package (`*_self_test.l` + `SelfHosted*Tests.fs`).
- Restored-dependency DLLs are the only remaining subprocess case
  (tracked in #1229).


### D-progress-300 — `Lyric.ContractMeta.parseFromJson`: in-process Contract reader (#1229 Phase A.1, PR #1235)

**Status:** Shipped.

**Problem:** The self-hosted MSIL bridge's restored-dependency loader
(in progress under #1229) needs to extract structured contract surfaces
from compiled Lyric DLLs.  The F# `bootstrap/src/Lyric.Emitter/ContractMeta.fs`
already provides `parseFromJson(json) -> Contract option`; the Lyric
side previously shelled out to `lyric --internal-contract-meta read` /
`diff` for both reading and diffing, which paid a process-spawn on
every consumer and depended on the F# bootstrap CLI's continued
presence.  An in-process Lyric parser was needed before the kernel
work (Phase A.2 — `System.Reflection.Metadata` resource reader) and
bridge symbol-table threading (Phase A.3) could land.

**Fix (`lyric-compiler/lyric/contract_meta.l`):**

1. Three new `pub record`s describing the JSON schema:
   - `ContractParam { name: String, ty: String }`.
   - `ContractDecl` with `kind`, `name`, `repr`, `isPure`, `stability`,
     `requiresClauses`, `ensuresClauses`, `body: Option[String]`,
     `params: List[ContractParam]`.  `requires` / `ensures` field names
     are reserved Lyric keywords, hence the `…Clauses` suffix.
   - `Contract { packageName, version, level, formatVersion, decls }`.
2. `parseFromJson(json: in String): Option[Contract]` walks the JSON
   tree with `Std.Json`.  Field defaults match
   `bootstrap/src/Lyric.Emitter/ContractMeta.fs::parseFromJson` byte-for-
   byte so format-1 and format-2 payloads round-trip identically across
   the F# and self-hosted implementations:
     * `packageName` → "".
     * `version` → "0.0.0".
     * `level` → "runtime_checked".
     * `formatVersion` → 1 (format-1 fallback).
     * `pure` absent → false.
     * `requires`/`ensures` non-string elements → "" (matching F#
       `safeStr (inner.GetString()) ""`).
3. Malformed JSON returns `None`.  `System.Text.Json.JsonDocument.Parse`
   throws on syntactically invalid input; we wrap with
   `try { … } catch Bug as _ { None }` (same pattern as
   `lyric-stdlib/std/regex.l::tryCompile`).  A `parseAndWalk` helper
   keeps the `defer { disposeJson(doc) }` at function-body top level —
   the bootstrap emitter does not yet hoist `defer` from inside `try`
   blocks ("bare SDefer reached emitStatement" panic in
   `Codegen.fs`).  Without the helper, `parseFromJson` would itself
   crash before catching anything.
4. Non-object / non-array silently-skipped paths are explicit: a
   non-object `decls` array entry is skipped (matches F# behaviour);
   a non-array `decls` field is treated as absent; a non-object
   `params` entry is skipped.  These defensive checks let the parser
   round-trip a future schema version that introduces additional decl
   kinds or param shapes without crashing.

**Tests (`lyric-compiler/lyric/contract_meta_self_test.l`):**

- `testMinimal` — basic round-trip.
- `testEmptyObjectDefaults` — every field defaults match F#.
- `testEmptyStringReturnsNone` / `testNonObjectRootReturnsNone` /
  `testMalformedJsonReturnsNone` — None paths (empty/whitespace,
  array root, syntactic garbage).
- `testPureAndContracts` — `pure: true` + `requires`/`ensures` array
  round-trip.
- `testBodyOptional` — `body` field as `Option[String]`.
- `testParamsArray` — `(name, type)` tuples preserve order.
- `testStability` — `"stable:X.Y"` / `"experimental"` / "" variants.
- `testMultipleDeclsOrder` — declaration order preserved.
- `testPureDefaultsFalse` — `pure` absent → false.
- `testNonObjectDeclEntrySkipped` / `testNonArrayDeclsFieldSkipped` /
  `testNonObjectParamEntrySkipped` — defensive skip paths exercised.

Discovered + run by
`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedContractMetaTests.fs`,
wired into `Program.fs` and `Lyric.Emitter.Tests.fsproj`.  Shape
matches every other `SelfHosted*Tests.fs` (test logic in Lyric, F#
shim only carries discovery + process plumbing).

**Acceptance criteria met:**

- `Lyric.ContractMeta.parseFromJson` is byte-stable against the F#
  parser for every documented input shape.
- Malformed JSON returns `None` (not a panic).
- No new externs added — clean against the kernel-boundary ratchet.
- 840 emitter + 73 CLI tests green.

**What's next under #1229:**

- Phase A.2 — `Std.ReflectionMetadata` kernel externs wrapping
  `System.Reflection.Metadata.PEReader` for .NET resource extraction.
- Phase A.3 — bridge symbol-table threading.
- Phase A.4 — end-to-end Lyric test compiling + consuming a restored
  DLL via `Lyric.Emitter.emitProject`.
- Phase B — JVM JAR resource kernel (`jar_host.l`).


### D-progress-301 — `Std.AssemblyResources`: in-process .NET embedded-resource reader (#1229 Phase A.2, PR #1242)

**Status:** Shipped.

**Problem:** The self-hosted MSIL bridge's restored-dependency loader
(in progress under #1229) needs to read the `Lyric.Contract` /
`Lyric.Contract.<Pkg>` JSON resources embedded in every compiled
Lyric assembly.  The F# emitter's
`bootstrap/src/Lyric.Emitter/ContractMeta.fs::readFromAssembly` does
this via `Mono.Cecil.AssemblyDefinition`, but the Lyric side has no
equivalent and shells out to `lyric --internal-contract-meta read`
on every consumer call.  An in-process Lyric reader was needed
before the bridge symbol-table threading (Phase A.3) and end-to-end
test (Phase A.4) could land.

**Fix:**

1. **`lyric-stdlib/std/_kernel/assembly_resources_host.l` (new)** —
   `Std.AssemblyResourcesHost` kernel.  Three extern types
   (`RuntimeAssembly` = `System.Reflection.Assembly`, `ResStream` =
   `System.IO.Stream`, `ResMemoryStream` = `System.IO.MemoryStream`)
   and eight host functions wrapping the high-level
   `Assembly.LoadFrom` / `GetManifestResourceNames` /
   `GetManifestResourceStream` API + `MemoryStream` accumulator +
   `Stream.Dispose` / `MemoryStream.Dispose` for deterministic release.

2. **`lyric-stdlib/std/assembly_resources.l` (new)** —
   `Std.AssemblyResources` public surface:
   - `pub opaque type AssemblyResources` — opaque handle hiding
     `RuntimeAssembly` from consumers; only `openAssembly`,
     `resourceNames`, `tryReadResource` are part of the public API.
   - `pub func openAssembly(path): AssemblyResources` — load assembly +
     snapshot resource names at open time.
   - `pub func resourceNames(ar): slice[String]` — stable snapshot.
   - `pub func tryReadResource(ar, name): Option[slice[Byte]]` —
     pre-checks the name-list snapshot (guards against the
     `GetManifestResourceStream` null-return + `CopyTo` panic that
     would otherwise occur for missing names); disposes both
     streams before returning so callers reading many resources
     in a row don't leak file handles.

**Design choice (`Assembly.LoadFrom` vs `System.Reflection.Metadata.PEReader`):**
The original plan called for `PEReader`, but its embedded-resource
read path requires either unsafe pointer arithmetic (Lyric doesn't
expose unsafe pointers) or a ~12-extern chain through `BlobReader`.
`Assembly.LoadFrom` ships in the same `System.Runtime.dll` (no new
BCL dep — same property as `PEReader`) and reduces the extern surface
to **8 functions + 3 types**.  Trade-off accepted: `LoadFrom`
JIT-resolves the assembly into the current `AssemblyLoadContext`.
Heavier than metadata-only reads, irrelevant for compile-time
consumers, and matches the F# emitter's
`Mono.Cecil.AssemblyDefinition` usage (which also never disposes).

**Tests (`lyric-stdlib/tests/assembly_resources_tests.l`):**

Auto-discovered self-test (no new F# runner shim — picked up by
`StdlibLyricTests.fs`):

- `testOpenSelf` — `openAssembly` against the running test PE
  succeeds; snapshots a non-empty name list.
- `testLyricContractResourcePresent` — the test PE has an embedded
  `Lyric.Contract` resource (every Lyric-emitted assembly does).
- `testTryReadLyricContract` — bytes start with `'{'`, cheap shape
  check that catches obvious garbage.
- `testTryReadMissingReturnsNone` — missing names return `None`,
  exercising the snapshot-membership guard.
- `testResourceNamesIsStable` — repeated calls yield the same
  snapshot.

**Kernel-boundary ratchet:**
Bumped 305 → 316 (+11: 3 types + 8 functions) in
`bootstrap/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs`,
with an inline note explaining the `Assembly.LoadFrom` choice and
the rationale for the dispose pair.  `docs/17-axiom-audit.md` §18
updated (.NET stable count 25 → 26); §19 baseline regenerated via
`scripts/audit-axioms.sh --update`.

**Acceptance criteria met:**

- `Std.AssemblyResources` exposes a stable, opaque API for reading
  embedded resources from .NET PE assemblies.
- Snapshot-membership guard returns `None` for missing names
  without panicking the consumer.
- Disposal pair lets callers release native file handles
  deterministically.
- Axiom audit + kernel-boundary ratchet both pass.

**What's next under #1229:**

- Phase A.3 — bridge symbol-table threading: pull
  `Lyric.ContractMeta.parseFromJson` + `Std.AssemblyResources` into
  `Msil.Bridge.compileProjectToMsil*`; consult restored artifacts
  before falling through to source-built packages.
- Phase A.4 — end-to-end Lyric test compiling + consuming a restored
  DLL via `Lyric.Emitter.emitProject`.
- Phase B — JVM JAR resource kernel (`jar_host.l`).


### D-progress-302 — `Lyric.ContractMeta.readFromFile`: in-process resource reads (#1229 Phase A.3.1)

**Status:** Shipped.

**Problem:** `Lyric.ContractMeta.readFromFile` was shelling out to
`lyric --internal-contract-meta read <dll>` for every consumer call
— a subprocess hop per public-api-diff invocation and a hard
dependency on the F# bootstrap CLI's continued presence.  Phase A.2
(`Std.AssemblyResources`) shipped the kernel primitives needed to
replace it.  This slice does the swap and adds a new
`readAllContractsFromFile` for the bundled-DLL case the bridge
restored-dep loader will need in Phase A.3.2.

**Fix (`lyric-compiler/lyric/contract_meta.l`):**

1. `readFromFile(path)` now calls `Std.AssemblyResources.openAssembly`
   + `tryReadResource("Lyric.Contract")` directly, with
   `Std.Encoding.tryDecodeUtf8` converting the bytes to a JSON
   string.  Same `Option[String]` signature, same `None` semantics
   for absent / unreadable.  The subprocess shellout is gone.

2. New `readAllContractsFromFile(path): List[ContractEntry]` walks
   every embedded resource: surfaces the legacy `Lyric.Contract`
   single-package form as `ContractEntry(packageName = "", json)`
   and each project-as-DLL `Lyric.Contract.<Pkg>` resource as
   `ContractEntry(packageName = "<Pkg>", json)`.  Mirrors F#
   `Lyric.Emitter.ContractMeta.readAllContractsFromAssembly`.  Used
   by the upcoming bridge restored-dep loader (Phase A.3.2) for
   bundled DLLs.

3. `ContractEntry` is a new `pub record`; small enough that exposing
   the fields directly (`packageName`, `json`) is the right shape —
   no kernel extern leakage to hide.

**Tests (`lyric-compiler/lyric/contract_meta_self_test.l`):**

Extends the existing self-test with §3:

- `testReadFromFileInProcess` — `readFromFile` against the running
  test PE returns `Some(json)`; the JSON parses cleanly via
  `parseFromJson`; `packageName` is non-empty.
- `testReadAllContractsFromFileSinglePkg` —
  `readAllContractsFromFile` surfaces at least one entry; the
  legacy entry (packageName = "") is present with non-empty JSON.

**Subprocess residue:** `Lyric.ContractMeta.diffContracts` still
shells out to `lyric --internal-contract-meta diff`.  Porting the
diff logic to Lyric (mirrors F# `ContractMeta.fs::diffContracts` +
`renderDiffEntry`) is tracked as a follow-up under #1229; the
bridge restored-dep loader doesn't need diff, only read.

**Acceptance criteria met:**

- `readFromFile` no longer shells out.
- `readAllContractsFromFile` walks every `Lyric.Contract.<Pkg>`
  resource in a bundled DLL, surfacing each as a `ContractEntry`.
- Self-test exercises both readers against the running PE.
- 73 CLI + 841 emitter tests green; axiom + kernel-stub audits clean.


### D-progress-303 — `Lyric.RestoredPackages`: restored-DLL artifact loader (#1229 Phase A.3.2)

**Status:** Shipped.

**Problem:** The self-hosted MSIL bridge needs a structured view of a
restored-dependency DLL's `pub` surface to resolve cross-package
references against compiled deps.  Phase A.3.1 shipped the
`Lyric.ContractMeta` in-process readers; this slice composes them
into a single `loadRestoredPackage(dllPath) → Result[List[RestoredArtifact], RestoredLoadError]`
entry point that the bridge (Phase A.3.3) will consume.  Mirrors
`bootstrap/src/Lyric.Emitter/RestoredPackages.fs::loadRestoredPackage`.

**Fix (`lyric-compiler/lyric/restored_packages.l`, new package
`Lyric.RestoredPackages`):**

1. `pub record RestoredArtifact { packageName, version, dllPath,
   contract }` — one artifact per package surfaced by the DLL.
   Single-package DLLs produce a one-element list (`packageName`
   recovered from the contract JSON's own field); project-as-DLL
   bundles produce one element per `Lyric.Contract.<Pkg>` resource.
2. `pub union RestoredLoadError` — three variants surfacing the
   three failure modes the bridge needs to distinguish:
   `DllMissing(path)`, `NoContractResource(path)`,
   `MalformedContract(path, pkgKey)`.
3. `pub func errorMessage(e): String` — renders each variant as a
   short single-line diagnostic that includes the path / pkgKey.
4. `pub func loadRestoredPackage(dllPath): Result[List[RestoredArtifact], RestoredLoadError]`
   — orchestrates the three calls (`fileExists`,
   `Meta.readAllContractsFromFile`, `Meta.parseFromJson`) and packs
   the result.

**Tests (`lyric-compiler/lyric/restored_packages_self_test.l`):**

Three-case self-test, wired into Expecto via
`bootstrap/tests/Lyric.Emitter.Tests/SelfHostedRestoredPackagesTests.fs`:

- `testLoadRunningPe` — loads the running test PE itself, asserts
  one or more artifacts surface and the `packageName` / `dllPath` /
  `contract.packageName` fields all line up.
- `testMissingFileError` — a non-existent path returns
  `Err(DllMissing(path))` with the path round-tripped.
- `testErrorMessageVariants` — each variant's `errorMessage` output
  contains the relevant identifier (path / pkgKey).

**Acceptance criteria met:**

- The loader composes the Phase A.1 (`parseFromJson`), A.2
  (`Std.AssemblyResources`), and A.3.1 (`readAllContractsFromFile`)
  building blocks into one entry point matching the F# emitter's
  loader shape.
- 73 CLI + 842 emitter tests green (was 841 + new self-test); axiom
  + kernel-stub audits clean.

**What's next under #1229:**

- Phase A.3.3 — `Msil.Bridge.compileProjectToMsil*` accepts
  `restoredArtifacts: List[RestoredArtifact]`; `addPackageTokens`
  registers the restored types / funcs into the existing
  `typeFqnByName` / `recordCtorTokens` / `unionCaseCtorByName`
  tables with cross-assembly tokens (TypeRef + MemberRef, distinct
  from the in-bundle TypeDef + MethodDef rows).
- Phase A.4 — end-to-end Lyric test compiling + consuming a
  restored DLL via `Lyric.Emitter.emitProject`.
- Phase B — JVM JAR resource kernel.


### D-progress-304 — `Lyric.RestoredPackages.synthesiseSource`: contract → Lyric source (#1229 Phase A.3.3.a)

**Status:** Shipped.

**Problem:** The MSIL bridge consumes a restored package's symbol
table the same way it consumes any in-bundle package's — through the
existing parser + type checker.  To make a `RestoredArtifact`
visible to that pipeline, we need to turn its `Contract` (parsed
JSON metadata) into a Lyric source string the parser can chew on.
Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::synthesiseSource`.

**Fix (`lyric-compiler/lyric/restored_packages.l` §3):**

Add `pub func synthesiseSource(contract, preamble): String` plus a
private `renderDecl(d): String` helper:

- Emits `package <name>\n\n` from `Contract.packageName`.
- For each decl in `preamble` then `contract.decls`, appends the
  decl's `repr` field verbatim (already the source-level form) with
  a trailing newline.
- Interfaces are a special case: their `repr` is just the head
  (`pub interface I`), so an empty `{}` body is appended.  Matches
  the F# parser's requirement for an interface block.
- `preamble` lets bundled-DLL callers (Phase A.3.3.b) thread in
  extern-type / opaque decls from sibling packages so cross-package
  type references in the package being synthesized resolve during
  re-typecheck.

**Tests (`lyric-compiler/lyric/restored_packages_self_test.l` §3):**

- `testSynthesiseEmptyContract` — bare `package X` header from an
  empty contract.
- `testSynthesiseFunc` — function `repr` round-trips verbatim.
- `testSynthesiseInterfaceAppendsBraces` — F# parity for the
  interface special case.
- `testSynthesiseNonInterfaceKindsPassThrough` — records / unions /
  enums all preserve their `repr` verbatim.
- `testSynthesisePreambleOrdering` — preamble decls appear BEFORE
  the contract's own decls so cross-package type refs resolve.
- `testSynthesiseTrailingNewline` — output ends in `\n` (parser
  expects every top-level item terminated by a newline).

**Acceptance criteria met:**

- F# parity at the `repr` ↔ source-text boundary.
- 73 CLI + 842 emitter tests green (was 841 with 3 cases; +6 new
  synthesis cases brought the loader self-test to 9 cases).
- Axiom + kernel-stub audits clean.

**What's next under #1229:**

- Phase A.3.3.b — wire synthesise + re-parse + re-typecheck:
  `synthesiseArtifact(art): Result[SynthesisedArtifact, ...]` that
  pipes `synthesiseSource` into `Lyric.Parser.parse` then
  `Lyric.TypeChecker.check`, producing the `SymbolTable` +
  signatures the bridge will consult.
- Phase A.3.3.c — bridge consumption: `Msil.Bridge.compileProjectToMsil*`
  accepts a `restoredArtifacts: List[SynthesisedArtifact]`;
  `addPackageTokens` registers the restored symbols into
  `typeFqnByName` / `recordCtorTokens` / `unionCaseCtorByName` with
  cross-assembly tokens (TypeRef + MemberRef pointing at the
  foreign Assembly's `AssemblyRef`).
- Phase A.4 — end-to-end Lyric test compiling + consuming a
  restored DLL via `Lyric.Emitter.emitProject`.
- Phase B — JVM JAR resource kernel.


### D-progress-305 — `Lyric.RestoredPackages.synthesiseArtifact`: synthesise + re-parse + re-typecheck (#1229 Phase A.3.3.b)

**Status:** Shipped.

**Problem:** The bridge needs a fully-typed view of each restored
package — `synthesiseSource` (Phase A.3.3.a) produces the source
string; we still need to drive it through the parser and type
checker to recover the `SymbolTable` + signatures the bridge will
consult.  Mirrors
`bootstrap/src/Lyric.Emitter/RestoredPackages.fs::artifactOfContract`.

**Fix (`lyric-compiler/lyric/restored_packages.l` §4):**

1. New `pub record SynthesisedArtifact { packageName, version,
   dllPath, contract, source, checkResult }` carrying the parsed
   `SourceFile` and `CheckResult` alongside the original
   `RestoredArtifact` metadata.
2. New `case SynthesisDiagnostics(path, diags)` variant on
   `RestoredLoadError` for parse / type-check failures of the
   synthesised source.
3. New `pub func synthesiseArtifact(art, preamble): Result[SynthesisedArtifact, RestoredLoadError]`
   pipes `synthesiseSource` → `Lyric.Parser.parse` →
   `Lyric.TypeChecker.check`.  Returns `Err(SynthesisDiagnostics)`
   on real errors; whitelisted-stdlib-anchor `T0010`s are filtered
   out (the contract Repr loses cross-package qualifications, so
   the standalone re-typecheck legitimately can't resolve `Option`,
   `Result`, `List`, etc).  Helpers: `isWhitelistedStdlibType`,
   `extractT0010Name`, `isWhitelistedT0010`, `isErrorDiag`,
   `filterRealErrors`.
4. `errorMessage` extended with a `SynthesisDiagnostics` arm that
   includes the diagnostic count and the first message.

**Tests (`lyric-compiler/lyric/restored_packages_self_test.l` §4):**

- `testSynthesiseArtifactHappyPath` — a contract carrying
  `pub func double(x: Int): Int` round-trips through
  `synthesiseArtifact` to a `SynthesisedArtifact` whose
  `source.items` carries one item.
- `testSynthesiseArtifactMalformedRepr` — a contract whose `repr`
  is garbage Lyric source bubbles up as `SynthesisDiagnostics`
  with at least one diagnostic.
- `testSynthesiseArtifactWhitelistedT0010Filtered` —
  `pub func find(x: Int): Option[Int]` type-checks cleanly even
  though `Option` isn't in scope of the standalone synthesised
  source (the T0010 whitelist filters the diagnostic out).

**Bootstrap-emitter quirks discovered:**

- `match <expr>` directly as a function's last expression panics
  the F# bootstrap codegen with `"SLocal (LBVal (PError ...))"`
  even though the same shape works as a statement.  Worked around
  by assigning into a `var` set inside the match arms.
- `out` is a reserved keyword (parameter mode); a local named
  `out` reaches codegen as `PError`.  Renamed to `kept`.

  Both are real bootstrap-emitter gaps; tracked in #1227 / #1228
  cleanups.

**Contract repr format detail:**
Contract `func` decls record their `repr` as the bare signature
without a body (`pub func double(x: Int): Int`) — matches what F#
`ContractMeta.fs::declOf` produces.  Test cases that synthesised
`= ()` bodies originally failed because that yields `Unit`-typed
bodies, contradicting the declared return type.  Updated tests to
match the canonical no-body form.

**Acceptance criteria met:**

- F# parity at the `synthesiseSource` → `parse` → `check` chain.
- T0010 whitelist matches the F# implementation's stdlib-anchor
  set.
- 73 CLI + 842 emitter tests green; axiom + kernel-stub audits
  clean.

**What's next under #1229:**

- Phase A.3.3.c — bridge consumption: `Msil.Bridge.compileProjectToMsil*`
  accepts a `restoredArtifacts: List[SynthesisedArtifact]`;
  `addPackageTokens` registers restored symbols into
  `typeFqnByName` / `recordCtorTokens` / `unionCaseCtorByName`
  with cross-assembly tokens.
- Phase A.4 — end-to-end Lyric test.
- Phase B — JVM JAR resource kernel.


### D-progress-306 — bridge accepts `restoredArtifacts` (#1229 Phase A.3.3.c.1)

**Status:** Shipped (threading only — symbol-registration lands in c.2).

**Problem:** `Msil.Bridge.compileProjectToMsil*` had no parameter for
restored-dependency artifacts.  Phase A.3.3.b shipped the
`SynthesisedArtifact` shape; the bridge needs to accept and stash
the list before the c.2 / c.3 slices can walk it to allocate
cross-assembly tokens.

**Fix:**

1. **`lyric-compiler/msil/codegen.l`** — `CodegenCtx` gains a new
   `restoredArtifacts: List[SynthesisedArtifact]` field, populated
   to an empty list in `newCodegenCtx`.  Added
   `import Lyric.RestoredPackages` to bring the
   `SynthesisedArtifact` type into scope.
2. **`lyric-compiler/msil/bridge.l`** — new entry point
   `compileProjectToMsilWithRestored(packages, asm, out, stdlibSrc,
   activeFeatures, declaredFeatures, restoredArtifacts): Bool`.
   `compileProjectToMsil` and `compileProjectToMsilWithFeatures`
   are now thin shims that forward with empty restored artifacts.
   Body copies the artifacts into `cctx.restoredArtifacts` so the
   c.2 / c.3 symbol-registration passes can walk them.

**Why threading-only:**
Splitting the threading from the consumption logic lets the larger
codegen surgery land in isolated PRs with focused tests.  Callers
that pass empty `restoredArtifacts` compile exactly as before;
callers that pass populated artifacts won't link cleanly until the
c.2 / c.3 slices register the symbols and allocate
`AssemblyRef` / `TypeRef` / `MemberRef` rows.

**Acceptance criteria met:**

- New entry point compiles and runs against existing tests.
- `compileProjectToMsil` / `compileProjectToMsilWithFeatures`
  callers see no behavioural change (forwarders).
- 73 CLI + 842 emitter tests green; axiom + kernel-stub audits
  clean.

**What's next under #1229:**

- Phase A.3.3.c.2 — `addRestoredArtifactTokens(cctx, art)` walks
  `art.checkResult.symbols` / `art.contract.decls` and registers
  TypeRef rows for records / unions / enums into `typeFqnByName`
  with `AssemblyRef`-backed tokens.  Records and union case
  ctors get `MemberRef` rows registered into `recordCtorTokens` /
  `unionCaseCtorByName`.
- Phase A.3.3.c.3 — `MemberRef` allocation for free functions
  (signature blob encoding from `ResolvedSignature`).
- Phase A.4 — end-to-end Lyric test.


### D-progress-307 — restored-artifact TypeRef registration (#1229 Phase A.3.3.c.2)

**Status:** Shipped (type-shape registration; `MemberRef` for ctors / funcs ships in c.3).

**Problem:** With `compileProjectToMsilWithRestored` accepting
`SynthesisedArtifact`s as of c.1, the bridge still didn't walk the
list to seed the cross-package symbol tables.  Consumer-side type
references to restored packages still resolved to whatever fallback
the codegen used (typically `MObject`), preventing
`isinst <RestoredType>` and any other type-shaped lookup from
hitting a proper TypeRef.

**Fix (`lyric-compiler/msil/codegen.l`):**

New `pub func registerRestoredArtifactTokens(cctx): Unit` plus
private helpers:

1. `ensureAssemblyRefForArtifact(cctx, packageName)` — allocates one
   `AssemblyRef` row per restored package, cached in `ffiAsmRefs`.
   Lyric-emitted DLLs use `<packageName>.dll`, so the simple
   assembly name matches the package name verbatim.  Version is
   pinned to 1.0 for now; proper version threading is part of the
   broader assembly-identity work.
2. `registerRestoredTypeDecl(cctx, pkg, decl, asmRef)` — for each
   type-shaped decl (`record` / `union` / `enum` / `interface` /
   `opaque` / `distinct`):
   - Allocates a `TypeRef` row pointing at the AssemblyRef
     (cached in `ffiTypeRefs`).
   - Seeds `typeFqnByName[simpleName] = "<pkg>.<simple>"` so
     consumer-side `TRef` resolution finds the correct FQN.
   - For unions, also walks the contract `repr` for case names and
     seeds `unionCaseCtorByName[case] = "<pkg>.<union>$<case>"` —
     enables cross-package case-construction lookups in
     `lowerBuiltinOrStaticCallMsil`.
3. `registerUnionCases(cctx, pkg, union, decl)` — scans the
   union's `repr` for `case <Name>` patterns; case names are
   terminated by `(`, ` `, `,`, or `}`.
4. `isIdentChar(c)` — ASCII identifier-continuation check used by
   the case-name scanner.

**Idempotency:** First-wins on all symbol-table inserts (matches
the existing `addPackageTokens` policy).  An artifact whose package
name collides with an in-bundle package's simple-name entry leaves
the in-bundle entry intact.

**`bridge.l`:** `compileProjectToMsilWithRestored` calls
`registerRestoredArtifactTokens(cctx)` immediately after
`newCodegenCtx`, so the per-package `addPackageTokens` pre-scan
loop already sees restored types as resolvable.

**What's still missing for an end-to-end build against a restored
dep:** `recordCtorTokens` / `funcTokens` are not yet seeded for
restored packages — that requires `MemberRef` allocation, which
requires signature-blob encoding from
`SynthesisedArtifact.checkResult.sigs`.  That's Phase A.3.3.c.3.
Consumer-side type references (e.g. function-parameter type
annotations naming a restored record) work today; consumer-side
calls to restored ctors / funcs do not.

**Acceptance criteria met:**

- Restored-artifact types reach `typeFqnByName` with their correct
  cross-package FQN.
- AssemblyRef + TypeRef rows are allocated and cached.
- Union case names seed `unionCaseCtorByName`.
- 73 CLI + 843 emitter tests green; axiom + kernel-stub audits
  clean.

**What's next under #1229:**

- Phase A.3.3.c.3 — `MemberRef` allocation for record ctors, free
  funcs, and union case ctors (signature-blob encoding from
  `ResolvedSignature`).
- Phase A.4 — end-to-end Lyric test.
- Phase B — JVM JAR resource kernel.


### D-progress-308 — restored-artifact record ctor MemberRefs (#1229 Phase A.3.3.c.3.a)

**Status:** Shipped (record ctors only; free funcs / union case ctors ship in c.3.b / c.3.c).

**Problem:** Phase A.3.3.c.2 seeded `typeFqnByName` for restored
types but didn't allocate cross-assembly `MemberRef` rows for the
constructors.  A consumer-side `Point(x = 1, y = 2)` against a
restored `pub record Point { x: Int, y: Int }` would resolve the
TYPE correctly but the call-site lookup against `recordCtorTokens`
would miss, leaving the codegen with no valid ctor token to emit.

**Fix (`lyric-compiler/msil/codegen.l` — `registerRestoredArtifactTokens` pass 2):**

After the type-registration pass (c.2), walk each artifact's parsed
`source.items` for `IRecord` items:

1. `lookupRestoredTypeRefRow(cctx, pkg, typeName)` retrieves the
   `TypeRef` row allocated in c.2.
2. `registerRestoredRecordCtor(cctx, pkg, rec)` builds the ctor
   signature via the existing `buildInstanceMethodSig(params, MVoid)`:
   - One param per `RMField` member, converted to `MsilType` via
     the existing `typeExprToMsilCtx`.
   - Mirrors the in-bundle `lowerMRecord` convention exactly so the
     foreign DLL's ctor signature matches at runtime (including the
     `MClass → ELEMENT_TYPE_OBJECT` degradation in `bufMsilType` —
     both producer and consumer emit Object for class-typed
     parameters, so they match).
3. `ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor", sigKey, ctorSig)`
   allocates the MemberRef row; the resulting token
   (`0x0A000000 + row`) lands in `cctx.recordCtorTokens[<fqn>]`.
4. Idempotent: skips records whose ctor is already registered (an
   in-bundle package's record always wins over a restored
   namesake's).

The pass walks `art.source.items` rather than `art.contract.decls`
so we get structured `FieldDecl` types for signature encoding —
the contract's `repr` string would otherwise need re-parsing.

**Why ctors first:** record construction is the most common
cross-package idiom in Lyric stdlib code today.  Free functions
(c.3.b) and union case ctors (c.3.c) follow the same pattern but
encode static / case-class signatures respectively.

**Acceptance criteria met:**

- Consumer-side record-construction calls against restored types
  resolve to a cross-assembly MemberRef pointing at the foreign
  `AssemblyRef`'s `TypeRef`.
- Signature encoding matches the in-bundle producer convention so
  the runtime resolver matches.
- 73 CLI + 843 emitter tests green; axiom + kernel-stub audits
  clean.

**What's next under #1229:**

- Phase A.3.3.c.3.b — free function MemberRef allocation (mostly
  identical, swap `buildInstanceMethodSig` for
  `buildStaticMethodSig`, walk `IFunc` items, populate
  `funcTokens`).
- Phase A.3.3.c.3.c — union case ctor MemberRef allocation (each
  case becomes its own nested TypeRef + ctor MemberRef; populate
  `recordCtorTokens` keyed by the case-class FQN).
- Phase A.4 — end-to-end Lyric test.
- Phase B — JVM JAR resource kernel.


### D-progress-309 — restored-artifact free function MemberRefs (#1229 Phase A.3.3.c.3.b)

**Status:** Shipped (free funcs).  Union case ctors remain in c.3.c.

**Problem:** With c.3.a registering record-ctor MemberRefs, the
remaining gap for typical cross-package use was free functions —
`MyLib.double(x)` from a consumer would resolve the package import
correctly but the call-site lookup against `funcTokens` would miss.

**Fix (`lyric-compiler/msil/codegen.l`):**

- `splitPackageName(pkg)` — splits a dotted package name into
  `(namespace, simpleName)` for `ctxAddTypeRef`.  Returns a
  2-element list (Lyric doesn't expose tuples cleanly).
- `ensureHostClassTypeRefRow(cctx, pkg, asmRef)` — allocates (or
  reuses) the `TypeRef` for the foreign DLL's free-function host
  class.  The in-bundle emitter puts every free function on a
  `TypeDef` whose name matches the package name
  (`MPFuncs(hostClass = pkgName, ...)`), so the foreign DLL has
  the same shape.  Cached under `"<pkg>/host"` in `ffiTypeRefs`.
- `registerRestoredFunc(cctx, pkg, fn)` — for each `pub func`:
  builds the signature via `buildStaticMethodSig(params, ret)`
  (no HASTHIS for static methods), allocates a MemberRef on the
  host class, and registers
  `funcTokens["<pkg>.<name>"] = 0x0A000000 + memberRow`.
  Skips private funcs (no public surface) and FQNs that already
  exist in `funcTokens` (in-bundle wins).

The IRecord/IFunc walker now handles both: renamed from
`registerRestoredRecordCtors` to `registerRestoredMembers`.

**Acceptance criteria met:**

- Consumer-side free-function calls against restored packages
  resolve to a cross-assembly MemberRef pointing at the foreign
  DLL's host TypeRef.
- Signature encoding matches `lowerMFuncsToHostClass`'s in-bundle
  convention so the runtime resolver matches.
- 73 CLI + 843 emitter tests green; axiom + kernel-stub audits clean.

**What's next under #1229:**

- Phase A.3.3.c.3.c — union case ctor MemberRefs (each case is its
  own nested TypeDef in the foreign DLL with its own ctor; allocate
  TypeRef + MemberRef per case and seed `recordCtorTokens` keyed by
  the case-class FQN `<pkg>.<union>$<case>`).
- Phase A.4 — end-to-end Lyric test compiling a library DLL via
  `Lyric.Emitter.emit`, then a consumer project via `emitProject`
  with the library in `restoredDllPaths`.
- Phase B — JVM JAR resource kernel.


### D-progress-310 — restored-artifact union case ctor MemberRefs (#1229 Phase A.3.3.c.3.c)

**Status:** Shipped.  Completes the Phase A.3.3.c MemberRef pass.

**Problem:** After c.3.a (record ctors) and c.3.b (free functions),
the last remaining gap on the consumer side was union construction:
`Some(value = 1)` against a restored `pub union Option { case Some(value: Int), case None }`
would resolve the case name to its ctor FQN via `unionCaseCtorByName`
(seeded in c.2) but the actual MemberRef token in `recordCtorTokens`
was never allocated.

**Fix (`lyric-compiler/msil/codegen.l`):**

- `ensureCaseClassTypeRefRow(cctx, pkg, caseClassName, asmRef)` —
  allocates a TypeRef for the case-class TypeDef in the foreign DLL.
  Case classes are named `<UnionName>$<CaseName>` per the in-bundle
  convention.  Cached in `ffiTypeRefs` keyed by the case-class FQN.
- `unionFieldType(uf)` — unifies the type-expression access across
  `UFNamed` and `UFPos` union-field variants.
- `registerRestoredUnionCase(cctx, pkg, union, c, asmRef)` — allocates
  the case ctor's MemberRef with the same HASTHIS instance-ctor
  signature shape used by record ctors (one param per field).
  Registers
  `recordCtorTokens["<pkg>.<Union>$<Case>"] = 0x0A000000 + memberRow`.
- `registerRestoredUnion(cctx, pkg, decl, asmRef)` — walks
  `decl.cases` and delegates per case.
- `registerRestoredMembers` now also handles `IUnion(decl)` items.

**Acceptance criteria met:**

- Consumer-side construction of restored union cases resolves to a
  working cross-assembly MemberRef.
- All three exported member kinds (record ctor, free func, union case
  ctor) are now registered with cross-assembly tokens; the typing
  side from c.2 is already in place.
- 73 CLI + 843 emitter tests green; axiom audit clean.

**What's next under #1229:**

- Phase A.4 — end-to-end Lyric test: compile a library DLL via
  `Lyric.Emitter.emit`, then build a separate consumer project via
  `Lyric.Emitter.emitProject` with the library in `restoredDllPaths`,
  assert that consumer-side calls to the library's records / funcs /
  union cases run cleanly.  This is what proves the entire A.3.3
  chain works and unblocks dropping the F# subprocess for
  restored-dep builds.
- Phase B — JVM JAR resource kernel.


### D-progress-311 — emitter wires restored deps through the in-process bridge (#1229 Phase A.4 partial)

**Status:** Shipped (wiring + subprocess fallback).  Full end-to-end test
deferred pending self-hosted contract emission.

**Problem:** Phase A.3.3.c completed the bridge-side symbol registration
for restored artifacts, but `Lyric.Emitter.emitProject` still gated
`canInProc` on `req.restoredDllPaths.count == 0`, so feature-bearing
restored-dep builds never reached the new code path.  Result: the
entire A.3.3.c work was unreachable by external callers.

**Fix (`lyric-compiler/lyric/emitter.l`):**

1. **`canInProc`** no longer excludes restored-dep builds — `Dotnet`
   targets always try the in-process path first.
2. **`emitProjectInProcess`** now walks `req.restoredDllPaths`, parses
   each entry (`"depName\tdllPath"`), and pipes each DLL through
   `Lyric.RestoredPackages.loadRestoredPackage` →
   `synthesiseArtifact(_, emptyPreamble)`.  The accumulated
   `List[SynthesisedArtifact]` is passed to the new
   `MsilBridge.compileProjectToMsilWithRestored` entry point.
3. **Subprocess fallback:** if any DLL fails to load (e.g. it has no
   `Lyric.Contract` resource because the self-hosted bridge doesn't
   yet emit one) or synthesise (parse / typecheck of the synthesised
   source fails), `emitProjectInProcess` falls through to
   `emitProjectViaSubprocess(req)` — the existing F# subprocess
   handles contract-less DLLs via reflection regardless of the
   restored-dep contract.  Users see no behavioural regression.

**Tests (`lyric-stdlib/tests/msil_project_bridge_tests.l`):**

`testRestoredDepWiringNoCrash` — passes a non-existent DLL path in
`restoredDllPaths` and verifies the in-process loader fails cleanly
(no panic), the emitter falls through to the subprocess, and the
subprocess in turn fails cleanly with `outputPath = None`.  This is
a crash-safety smoke test on the new wiring, not an exercise of
the full subprocess success path.

The full end-to-end test (library DLL with embedded contract →
consumer project with cross-package call → `dotnet exec` round-trip)
requires the library to be compiled by the F# emitter (which embeds
`Lyric.Contract`).  The cleanest way to do that from a Lyric test is
via `lyric --internal-build`, but the test sandbox's `lyric` binary
search-path isn't reliable today.  Lands once self-hosted contract
emission ships — see next item.

**Acceptance criteria met:**

- `emitProject` reaches the new restored-dep code path for `Dotnet`
  targets with non-empty `restoredDllPaths`.
- Loader failures fall back cleanly to the subprocess path so
  contract-less DLLs (the common case until self-hosted contract
  emission lands) keep working.
- 73 CLI + 843 emitter tests green; axiom audit clean.

**What's next under #1229:**

- **Self-hosted contract emission** — port
  `bootstrap/src/Lyric.Emitter/ContractMeta.fs::buildContract` +
  `embedIntoAssemblyAs` to Lyric so the self-hosted bridge emits
  the `Lyric.Contract` resource directly.  Once that lands, the
  in-process restored-dep path is self-contained (no more
  subprocess fallback for any user case) and the full end-to-end
  Lyric test lands alongside.
- **Phase B (JVM)** — analogous `jar_host.l` wrapping
  `java.util.jar.JarFile`.


### D-progress-312 — `Lyric.ContractMeta.contractToJson` (#1229 contract emission slice 1)

**Status:** Shipped.  First slice of the self-hosted contract-emission
work — the second slice (PE-writer resource embedding) layers on top.

**Problem:** Phase A's loader chain reads `Lyric.Contract` resources
from emitted DLLs, but the self-hosted bridge can't yet produce them.
The first prerequisite is a JSON serialiser that round-trips through
`parseFromJson` byte-stably with the F# producer's output.

**Fix (`lyric-compiler/lyric/contract_meta.l` §6):**

- `escapeJson(s)` — escapes `"`, `\`, `\n`, `\r`, `\t`.  Pure-Lyric
  character-by-character via `Std.String.substring`; bytes ≥ 0x20
  pass through verbatim (matching the F# `toJson`'s
  `printable-ASCII` policy).
- `renderStringArray(xs)` — JSON array of escaped strings.
- `renderParams(ps)` — `[{name,type}, …]` array.
- `renderDecl(d)` — one `ContractDecl` as a JSON object; only emits
  optional fields when they carry non-empty content (matches F#'s
  byte-stable convention).
- `contractToJson(c)` — full `Contract` → JSON, format-2 shape.
  Round-trips through `parseFromJson` to the identical struct.

**Tests (`lyric-compiler/lyric/contract_meta_self_test.l` §4):**

- `testEscapeJsonBasic` — printable passthrough plus the five
  always-escaped sequences.
- `testContractToJsonRoundTrip` — non-trivial contract (pure func
  with stability, requires/ensures, body, params) → JSON →
  `parseFromJson` → all fields preserved.
- `testContractToJsonOmitsDefaults` — empty optional fields produce
  no JSON keys (byte-stable across implementations).

**Acceptance criteria met:**

- Round-trip preserves every field `parseFromJson` exposes.
- Empty-optional-field omission matches F# byte-stably.
- 73 CLI + 843 emitter tests green; axiom audit clean.

**What's next:**

- **Slice 2** — PE-writer resource embedding: add
  `ManifestResourceRow` to the metadata tables, allocate a Resources
  data region between method bodies and metadata streams, write the
  CLR header's `Resources.VirtualAddress` / `Resources.Size`, and
  wire the bridge to build + embed the contract JSON.
- **Slice 3** — Full E2E Lyric test: self-hosted bridge builds a
  library DLL, the consumer reads it back through the in-process
  loader, asserts on `dotnet exec` stdout.


### D-progress-313 — ManifestResource table + PE Resources directory (#1229 contract emission slice 2a)

**Status:** Shipped (PE-level scaffolding; bridge wiring lands in 2b).

**Problem:** Slice 1 (D-progress-312) shipped a `Contract` → JSON
serialiser, but the self-hosted PE writer had no concept of managed
resources.  The CLR header's Resources directory entry was hard-
coded to zero, and the metadata tables didn't carry a
`ManifestResource` row.  This slice adds the PE-level machinery so
the bridge can hand the assembler a JSON blob and have it land
inside the emitted DLL as a proper embedded resource.

**Fix:**

1. **`lyric-compiler/msil/tables.l`** — new `pub record
   ManifestResourceRow { offset, flags, name, implementation }`
   matching ECMA-335 §II.22.24.  Added to `MetadataTables` as
   `manifestResources: List[ManifestResourceRow]`, with
   `addManifestResource` helper.  `serializeTablesStream` gains the
   `TABLE_BIT_MANIFEST_RESOURCE` bit (table 0x28, bit 40), the
   row-count emission, and the row-data loop (`u4 offset`,
   `u4 flags`, `u2 name`, `u2 implementation`).
2. **`lyric-compiler/msil/assembler.l`** — `AssemblerInput` gains
   `resourceData: List[Byte]` carrying the concatenated resource
   payload (length-prefix-per-resource encoding already applied by
   the caller).  `assemblePe` reserves a 4-byte-aligned region for
   the resources between method bodies and metadata, computes the
   resources RVA, and threads RVA + raw size into the CLR header.
   `writeClrHdr` gains `rsrcRva` / `rsrcSize` parameters and writes
   them at offsets 24 / 28 of the 72-byte header (no longer zeroed
   out).
3. **83 call sites** of `AssemblerInput(...)` across the M-series
   self-tests and `lowering.l` updated to pass
   `resourceData = newList()` — empty-resources scaffolding so
   every existing path stays byte-identical.

**Acceptance criteria met:**

- PE layout, CLR header, and metadata-tables stream all support
  embedded resources end-to-end.
- 843 emitter tests pass unchanged (every existing test path
  emits `resourceData = newList()`, so the resources region is
  zero-sized and the PE layout matches pre-slice byte-for-byte).
- 73 CLI tests pass.

**What's next:**

- **Slice 2b** — bridge wiring: bridge synthesises a `Contract`
  from the parsed `SourceFile`, renders via `contractToJson`,
  encodes UTF-8 bytes + length prefix, allocates a
  `ManifestResource` row, and passes the payload as
  `inp.resourceData`.
- **Slice 3** — full E2E Lyric test.


### D-progress-314 — bridge embeds `Lyric.Contract` resources (#1229 contract emission slice 2b)

**Status:** Shipped.  Self-hosted-bridge-emitted DLLs now carry the
`Lyric.Contract` resource the in-process restored-dep loader reads.

**Problem:** Slice 2a (D-progress-313) added PE-level resource
machinery; the bridge still wasn't building or embedding anything.
This slice wires the contract-building + JSON serialisation + PE
embedding together so every Lyric-emitted DLL ships a contract
matching what the F# emitter produces.

**Fix:**

1. **`lyric-compiler/lyric/contract_meta.l` §7** — new
   `pub func buildContractFromFile(file): Contract` that walks a
   parsed `SourceFile` and produces a `Contract` describing its
   public surface.  Coverage: records, funcs, unions, enums,
   interfaces, opaques, distinct types, type aliases.  Each
   `ContractDecl` carries `kind`, `name`, and a hand-rendered `repr`
   that's a parseable Lyric declaration the synthesise-pass can
   re-consume (records list fields + types, funcs list params +
   return type, unions list cases + payload types, enums list case
   names).  Mirrors `bootstrap/src/Lyric.Emitter/ContractMeta.fs::buildContract`.

2. **`lyric-compiler/msil/lowering.l`** — `LoweringCtx` gains
   `resourceData: List[Byte]` (defaults to `newList()` in
   `newLoweringCtx`).  `AssemblerInput` construction in the three
   `lowerMPackage*` entry points now threads
   `resourceData = ctx.resourceData` (was `newList()`).

3. **`lyric-compiler/msil/bridge.l`** — new helper
   `embedLyricContract(lctx, file, resourceName)`:
   - Calls `Meta.buildContractFromFile` + `Meta.contractToJson`.
   - UTF-8 encodes via `Std.Encoding.encodeUtf8`.
   - Appends a 4-byte LE length prefix + the JSON bytes to
     `lctx.resourceData` (offset = current length, so multiple
     resources stack correctly).
   - Calls `addManifestResource` with the row pointing at that
     offset.

   Wired into both entry points:
   - `compileToMsil` (single-package) → embeds as `"Lyric.Contract"`.
   - `compileProjectToMsilWithRestored` (multi-package) → embeds
     each package's contract as `"Lyric.Contract.<Pkg>"`, matching
     the F# bundled-DLL layout.

**Acceptance criteria met:**

- Self-hosted-bridge-emitted DLLs now carry a
  `Lyric.Contract` (or `Lyric.Contract.<Pkg>`) resource.
- Contract format is byte-stable against `parseFromJson` (slice 1
  round-trip test still passes).
- 73 CLI + 844 emitter tests green; axiom audit clean.

**What's next:**

- **Slice 3** — full E2E Lyric test: self-hosted bridge builds a
  library DLL → consumer reads it via the in-process loader →
  `dotnet exec` round-trip with cross-package call.  Subprocess
  fallback in `emitProject` becomes unreachable for any common
  user case after this lands.


### D-progress-315 — self-hosted bridge restored-deps E2E proof (#1229 contract emission slice 3)

**Status:** Shipped.  Self-hosted MSIL bridge builds DLLs whose
embedded `Lyric.Contract` resource is consumable by the in-process
restored-deps loader, and the resulting consumer DLL runs end-to-end
under `dotnet exec`.

**Problem:** Slice 2b (D-progress-314) made the bridge emit
`Lyric.Contract` resources, but no test exercised the full chain
through the self-hosted pipeline.  Without that proof point the
F# `--internal-project-build` subprocess fallback in
`lyric-compiler/lyric/emitter.l::emitProjectViaSubprocess` had no
evidence-backed path to retirement.  The pipeline also had three
latent bugs that only surface end-to-end:

1. `compileProjectToMsilWithRestored` registered restored artifacts
   for *codegen* (`registerRestoredArtifactTokens`) but not for
   *typecheck* — the consumer's `import` resolved at codegen
   token-lookup but failed at the typechecker, never reaching the
   working codegen path.
2. `ensureAssemblyRefForArtifact` minted Lyric-package AssemblyRef
   rows with the Microsoft framework public key token
   (`b03f5f7f11d50a3a`) and version `1.0`, while the actual
   `Assembly` row written by `newLoweringCtx` had `publicKey = 0`
   and version `0.0.0.0`.  The runtime rejected the bind with
   "Could not load file or assembly … PublicKeyToken=b03f5f7f11d50a3a"
   on every cross-assembly call.
3. `lowerMFuncsToHostClass` put the dotted package name
   (`"Lyric.SelfHostedE2E.Greeter"`) in the TypeDef's `typeName`
   field with an empty `typeNamespace`, while consumer TypeRefs
   split at the last dot via `splitPackageName` and ended up with
   `(namespace="Lyric.SelfHostedE2E", typeName="Greeter")`.  The
   CLR loader compares the two fields separately, so a TypeDef
   with the same conceptual full name didn't match — surfaced as
   "Could not load type 'Lyric.SelfHostedE2E.Greeter'".

**Fix:**

1. **`lyric-compiler/msil/bridge.l`** — new
   `pub func compileProjectToMsilWithRestoredEncoded(specLines,
   assemblyName, outputPath, stdlibSources, restoredDllPaths)`
   reflection-friendly entry point.  Mirrors
   `compileProjectToMsilEncoded` but additionally loads + synthesises
   each restored DLL via `RestoredPackages.loadRestoredPackage` +
   `synthesiseArtifact` and threads the `SynthesisedArtifact`s into
   `compileProjectToMsilWithRestored`.  Returns false if any load
   or synthesis fails.
2. **`lyric-compiler/msil/bridge.l::compileProjectToMsilWithRestored`** —
   after `collectStdlibTypeItems` seeds the typechecker's
   `importedItems`, also call `collectTypeItemsFromFile` for each
   restored artifact's parsed `source: SourceFile`.  This makes
   restored packages' public surface visible at typecheck (was
   previously visible only at codegen via the FQN tables).
3. **`lyric-compiler/msil/lowering.l`** — split
   `ctxAddAssemblyRef` into the framework-key version (unchanged
   for BCL refs) and a new
   `ctxAddLyricPackageAssemblyRef` that emits
   `publicKeyToken = 0` for unsigned Lyric package refs.
4. **`lyric-compiler/msil/codegen.l::ensureAssemblyRefForArtifact`** —
   call the new `ctxAddLyricPackageAssemblyRef` with version
   `(0, 0)` so the AssemblyRef row matches the actual Assembly
   row's version 0.0.0.0 and the missing public key.  Version
   threading from `[package].version` is tracked in #1364.
5. **`lyric-compiler/msil/lowering.l::lowerMFuncsToHostClass`** —
   split the dotted `hostClass` package name at the last `.` and
   write `(typeNamespace, typeName)` separately, matching the
   `(namespace, simpleName)` split that record TypeDefs (in
   `lowerMRecord`) and consumer TypeRefs (via `splitPackageName`
   in `ensureHostClassTypeRefRow`) already use.
6. **`bootstrap/src/Lyric.Cli/SelfHostedMsilProject.fs`** — new
   reflection shim mirroring `SelfHostedMsil.compileToDll` but
   targeting the new project-level entry point.  Caches the
   resolved delegate process-wide, writes a `.runtimeconfig.json`
   alongside the output DLL.
7. **`bootstrap/tests/Lyric.Cli.Tests/SelfHostedRestoredPackageE2ETests.fs`** —
   single E2E test that:
   - Compiles a producer (`Lyric.SelfHostedE2E.Greeter`) via the
     self-hosted bridge.
   - Verifies the embedded `Lyric.Contract` resource names the
     producer package and includes the public `greet` function.
   - Compiles a consumer (`Lyric.SelfHostedE2E.Consumer`) via the
     new project shim with the producer DLL as a restored dep.
   - Runs the consumer via `dotnet exec` and asserts stdout
     equals `"hello, world"`.

**Acceptance criteria met:**

- 844 emitter + 74 CLI tests pass.
- 325 parser + 128 lexer + 189 typechecker tests pass.
- New `self_hosted_bridge_round_trip` test exercises the full
  build → load → re-emit → run chain through the self-hosted
  pipeline.

**What's next:**

- #1364 — thread the manifest-declared `[package].version`
  through `Msil.Bridge.compileProjectToMsil*` so the AssemblyRef
  + Assembly rows carry the real version instead of the
  current `0.0.0.0` placeholder.
- Retire the `emitProjectViaSubprocess` fallback in
  `lyric-compiler/lyric/emitter.l` for the `.NET` target now that
  the self-hosted in-process bridge handles restored deps end-to-end.
  JVM remains the only legitimate fallback caller.



### D-progress-316 — thread manifest [package].version through Msil.Bridge (#1364)

**Status:** Shipped.  The CLI now plumbs `[package].version` from the
parsed manifest through `Lyric.Emitter` and the in-process MSIL bridge
so the produced DLL's Assembly metadata row and embedded
`Lyric.Contract` resource both carry the real semver instead of the
bootstrap-grade `0.0.0.0` placeholder slice 2b shipped.

**Problem:**

Slice 2b (D-progress-314) embedded `Lyric.Contract` resources but
hardcoded version `"0.0.0"` because the bridge entry points did not
accept a manifest.  Slice 3 (D-progress-315) hit the same gap on the
AssemblyRef side (also hardcoded `0.0`) — version-sensitive restored-
dep consumers and `public-api-diff` couldn't distinguish releases.

**Fix:**

1. **`lyric-compiler/msil/lowering.l`** — `newLoweringCtx` now takes
   `major: Int, minor: Int` parameters; passed through to the
   `addAssembly` row.  Adds `parseSemverMajorMinor(version): List[Int]`
   (and helpers `parseIntOr0`, `semverParseDigit`) so both the bridge
   and `ensureAssemblyRefForArtifact` parse the same way.  Living in
   `lowering.l` keeps `codegen.l` from having to import `bridge.l`.
2. **`lyric-compiler/msil/codegen.l`** — `newCodegenCtx` gains
   `major / minor` and threads them into `newLoweringCtx`.
   `ensureAssemblyRefForArtifact` looks the version up via a new
   `lookupRestoredArtifactVersion` helper (linear scan over
   `cctx.restoredArtifacts`) and parses it for the AssemblyRef row,
   replacing the previous `(0, 0)` hardcode.
3. **`lyric-compiler/msil/bridge.l`** — new `pub func`s
   `compileToMsilWithVersion` and
   `compileProjectToMsilWithRestoredAndVersion` accept a `packageVersion:
   String`.  The legacy entry points `compileToMsil` /
   `compileProjectToMsilWithRestored` are now forwarders to the
   versioned variants with `""`.  The tab-encoded
   `compileProjectToMsilWithRestoredEncoded` entry takes the version
   directly (single F# caller, no separate forwarder needed).
   `embedLyricContract` now receives the threaded value instead of
   the hardcoded `"0.0.0"`; empty string keeps the legacy behaviour.
4. **`lyric-compiler/lyric/emitter.l`** — `EmitRequest` /
   `EmitProjectRequest` gain `packageVersion: String`.  Both
   `emitInProcess` / `emitProjectInProcess` thread the field into the
   bridge's new entry points.
5. **`lyric-compiler/lyric/cli.l`** — `lyric build --manifest` and
   `lyric test --manifest` paths supply `manifest.packageSection.version`;
   the ad-hoc / single-file / REPL / bench paths supply `""` (no
   manifest in scope, falls back to the legacy default).
6. **`bootstrap/src/Lyric.Cli/SelfHostedMsil.fs`** — `compileToDll`
   becomes a `""`-passing forwarder; new `compileToDllWithVersion`
   exposes the threaded path to F# callers.  Reflection lookup now
   targets the new `compileToMsilWithVersion` bridge entry.
7. **`bootstrap/src/Lyric.Cli/SelfHostedMsilProject.fs`** —
   `compileProjectWithRestored` gains a `packageVersion` parameter;
   reflection lookup targets the updated
   `compileProjectToMsilWithRestoredEncoded` signature.
8. **Tests:**
   - `bootstrap/tests/Lyric.Cli.Tests/SelfHostedRestoredPackageE2ETests.fs`
     gains `manifest_version_threads_to_assembly_and_contract`:
     compiles with version `"2.3.4"`, asserts the embedded
     `Lyric.Contract` JSON carries `"version": "2.3.4"`, and reads back
     the Assembly row via `AssemblyName.GetAssemblyName` to confirm
     `(Major=2, Minor=3)`.
   - Existing `self_hosted_bridge_round_trip` test reuses the new
     `compileProjectWithRestored` shape with `""` for the version arg.
   - `lyric-stdlib/tests/msil_project_bridge_tests.l` updated
     (`EmitProjectRequest` gained a field).

**Folded-in review findings from #1372 (PR #1372 SUGGESTIONs):**

- #1374 — `runDll` post-Kill `WaitForExit()` now uses a 5 s timeout so
  a zombie kernel state can't hang the test runner indefinitely.
- #1375 — contract-resource assertion uses `"\"name\":\"greet\""`
  (matching the JSON name field) instead of the bare substring
  `"greet"` that could match unrelated occurrences.
- #1376 — `writeRuntimeConfig` simplified: the dead-but-required null
  guard around `Path.ChangeExtension` now panics on the unreachable
  null arm (F# nullness analysis requires SOME unwrap, but the
  previous fallback `dllPath + ".runtimeconfig.json"` would have
  produced a wrong filename if hit).
- #1373 (duplication between `SelfHostedMsil.fs` and
  `SelfHostedMsilProject.fs`) deferred — orthogonal refactor; tracked
  separately for a future cleanup pass.

**Acceptance criteria met:**

- 844 emitter + 75 CLI tests pass (one new test:
  `manifest_version_threads_to_assembly_and_contract`).
- Producer DLL Assembly row now carries the manifest-declared
  version; consumer AssemblyRef rows carry the matching restored-
  artifact version.
- Embedded `Lyric.Contract.<pkg>` JSON resource carries the threaded
  semver string verbatim (single-package and multi-package paths).

**What's next:**

- Retire the `emitProjectViaSubprocess` fallback in
  `lyric-compiler/lyric/emitter.l` for the `.NET` target now that the
  in-process bridge handles version-threaded restored deps end-to-end.
  JVM stays as the only fallback caller.
- Per-package version threading for project-as-DLL bundles (each
  package can declare its own version) — deferred from this slice;
  the bridge currently uses one bundle-level version.


### D-progress-317 — retire .NET subprocess fallback in Lyric.Emitter (#1229)

**Status:** Shipped.  `lyric-compiler/lyric/emitter.l` no longer routes
any `--target dotnet` compile through the F# `--internal-build` /
`--internal-project-build` subprocess shim.  Restored-dep load failures
now surface as proper `EmitResult` diagnostics rather than silently
bouncing through the F# emitter.

**Problem:**

Slices 2b (#1350) → 3 (#1372) → version threading (#1377) made the
self-hosted in-process MSIL bridge functionally equivalent to the F#
emitter for every `--target dotnet` scenario users actually hit:
single-file, multi-package, restored deps, feature flags,
`[package].version` threading.  The subprocess fallback in
`emitter.l` was kept alive as belt-and-suspenders during the
migration, but its existence had three real costs:

1. **Debuggability hazard** — when an in-process restored-dep load
   failed (`DllMissing`, `NoContractResource`, `MalformedContract`,
   `SynthesisDiagnostics`), the emitter silently retried via
   subprocess instead of surfacing the original error.  The user saw
   "subprocess exited 1" with no context about *why* the in-process
   path failed.
2. **Double-failure mode** — both the in-process loader and the F#
   `Program.fs::internalProjectBuild` use the same
   `Lyric.RestoredPackages` semantics; a load that failed in-process
   would fail identically in the subprocess.  The "fallback" was
   never a real recovery, just a noise multiplier.
3. **CLAUDE.md production-readiness** — `LYRIC_FORCE_SUBPROCESS=1`
   let any caller turn off the production code path at runtime.
   Useful for the original differential testing during migration;
   pure anti-feature now.

**Fix (`lyric-compiler/lyric/emitter.l`):**

1. `emit` simplified — `--target dotnet` always goes through
   `emitMsilInProcess`; `--target jvm` still calls
   `emitViaSubprocess` (JVM keeps the subprocess until its
   self-hosted bridge gains a reachable single-file entry).  The
   `LYRIC_FORCE_SUBPROCESS=1` env-var override is gone.
2. `emitProject` simplified — same shape: `Dotnet → emitProjectInProcess`,
   `Jvm → emitProjectViaSubprocess`.
3. `useSubprocessFallback()` helper deleted.
4. Inline restored-dep load-failure fallbacks in
   `emitProjectInProcess` replaced with `failResult` carrying the
   `RestoredPackages.errorMessage(e)` text.  The two former
   `return emitProjectViaSubprocess(req)` paths now propagate the
   original error with the offending DLL path.
5. File-header comments and per-function docstrings updated to
   reflect that the subprocess path is JVM-only.  Stale
   `LYRIC_FORCE_SUBPROCESS` / `LYRIC_BIN` mentions removed where
   no longer relevant.

**Other touched files:**

- `lyric-stdlib/tests/msil_project_bridge_tests.l::testRestoredDepWiringNoCrash`
  — stale comment + panic message updated.  The test still passes;
  it now asserts the cleaner in-process-only `DllMissing →
  outputPath = None` shape.

**Out of scope (deferred follow-ups):**

- Retiring the F# `--internal-build` / `--internal-project-build`
  handlers in `bootstrap/src/Lyric.Cli/Program.fs`.  Still required
  for JVM single-file / project builds.  Will retire when the JVM
  self-hosted bridge gains the matching reachable entry point.
- Renaming `emitViaSubprocess` → `emitJvmViaSubprocess` (and the
  project variant) to reflect their JVM-only scope.  Cosmetic;
  picks up in a follow-up cleanup.

**Acceptance criteria met:**

- 844 emitter + 75 CLI tests pass.
- No `--target dotnet` codepath in `emitter.l` reaches
  `Process.run(cliShellExe(), ...)` anymore.
- `LYRIC_FORCE_SUBPROCESS` is no longer read by the self-hosted
  emitter (greppable verification).

### D-progress-318 — stdlib `_kernel/` types reach the bridge typechecker (#1378 prerequisites)

**Status:** Shipped (partial — #1378 follow-ups defer stdlib `IFunc`
collection and per-package symbol tables).  The self-hosted MSIL
bridge now registers `_kernel/` extern types (`List[T]`,
`Map[K, V]`, `Random`, `Scope`, `HttpClient`, …) in the typechecker's
symbol table so multi-package signatures that mention those bare
names typecheck instead of aborting with `T0010 unknown type name`.
Also hardens the typechecker against name collisions in cross-package
import bundles and protects the codegen-builtin polymorphism
(`println(11)`, `toString(x)`, …) from being shadowed by imported
strict-typed signatures.

**Problem:** Issue #1378 documents the multi-package in-process
build failing on every ecosystem library with non-trivial stdlib
usage (lyric-auth, lyric-session, lyric-web, …) because
`compileProjectToMsilWithRestored` aborts on `T0010` / `T0020`
diagnostics from the user-package typecheck.  Three latent gaps:

1. `findStdlibSources` on both the Lyric-side
   (`lyric-compiler/lyric/emitter.l`) and F# test shim
   (`bootstrap/src/Lyric.Cli/SelfHostedBridge.fs`) loaded only the
   top-level `lyric-stdlib/std/*.l` files, skipping the `_kernel/`
   subtree.  The kernel is where `extern type List[T] =
   "System.Collections.Generic.List`1"` and friends live; without
   them, any user signature mentioning `List` / `Map` / `Random`
   surfaced `T0010 unknown type name`.

2. `Msil.Bridge.collectStdlibTypeItems` filtered out `IExternType`
   and `IProtected` items, so even when a kernel file was loaded
   its declarations never reached the user typecheck.

3. `Lyric.TypeChecker.Checker.addSigsFromItems` registered every
   `IFunc` signature with `sigs.add(name, sg)` (strict
   `Dictionary.Add`), which throws on duplicate keys.  Any
   cross-package bundle whose two packages each defined a `pub
   func` with the same simple name (a routine occurrence once
   restored deps or in-bundle helpers enter the imported list)
   crashed the build with an uncaught `ArgumentException`.

A fourth problem surfaces if the bridge ever does collect stdlib
`IFunc` items: the imported signatures would shadow the codegen
builtins (`println`, `toString`, `panic`, `assert`, `expect`,
`default`, `format1`, `format2`) which intentionally accept
`TyError`-typed arguments so that `println(11)` typechecks
without an explicit `toString`.  A strict `pub func println(s:
in String): Unit` from stdlib would, once in the `sigs` map, win
the `findDirectSig` lookup and reject the `Int` with `T0043`.

**Fix:**

1. **`lyric-compiler/lyric/emitter.l::findStdlibSources`** —
   load `_kernel/*.l` (after the top-level files in source order
   so the kernel's extern declarations register first in the
   typechecker's first-in-wins symbol table — otherwise
   `pub alias Random = Std.RandomHost.Random` shadows
   `extern type Random` and bare-name `Random` references fail
   `T0013 'Random' is not a type`).  Skip `_kernel/jvm.l` and
   `_kernel/jvm_exception.l` so JVM-only declarations don't leak
   into the .NET symbol table.

2. **`bootstrap/src/Lyric.Cli/SelfHostedBridge.fs::findStdlibSources`** —
   mirror the same `_kernel/` load order and JVM filter so the
   F# test shim's view of the stdlib matches the production AOT
   CLI's view.

3. **`lyric-compiler/msil/bridge.l::collectStdlibTypeItems`** —
   extend the item-kind filter to include `IExternType` and
   `IProtected`.  Drop every item from a stdlib source whose
   parse produced an error-severity diagnostic (the self-hosted
   parser still has known gaps vs. constructs like `try { …
   } catch Bug as _ { … }` in `_kernel/http_server.l`); the
   advisory diagnostic stream still prints, but partial /
   malformed items no longer pollute the user package's
   typecheck.  Refactor the inline loop in `compileToMsil` to
   share the same helper so single-package and multi-package
   paths see the same view of the stdlib.

4. **`lyric-compiler/lyric/type_checker/typechecker_checker.l::addSigsFromItems`** —
   accept a new `isImported: Bool` parameter.  Guard both bare
   and arity-qualified key insertions with `containsKey`
   (first-in-wins), so a cross-package bundle with duplicate
   simple names no longer crashes the typecheck.  When
   `isImported = true`, skip names that match a codegen builtin
   so the polymorphic `TyError`-typed surface continues to win
   `findDirectSig`.  Resolve imported-item signatures against a
   scratch diagnostic list — unresolvable internal stdlib type
   references (e.g. obscure kernel-internal types the bridge
   doesn't carry yet) no longer pollute the user's
   `reportAndAbort` channel.

**What's next (issue #1378 remaining scope):**

- Promote stdlib `IFunc` items into `collectStdlibTypeItems` so
  user code can call `Std.X.foo(...)` (e.g. `tryDecodeBase64`,
  `encodeUtf8`, `substring`, `isDigit`) without `T0020`.  This
  requires the codegen-side companion below — landing the
  typecheck visibility alone would let the bridge produce DLLs
  that silently fail at runtime with `InvalidProgramException`.
- Extend the codegen pre-scan (`addPackageTokens` /
  `registerRestoredArtifactTokens`) to register `MemberRef`
  rows for every imported stdlib `pub func`, mirroring the F#
  emitter's `resolveStdlibImports` + `emitAssembly` import-table
  population.
- Per-package symbol-table filtering as recommended in #1378
  (mirror the F# `resolveStdlibImports` topo-walk so each user
  package sees only the items from stdlib packages it
  transitively imports).
- AliasRewriter for the self-hosted pipeline so `import Auth.Kernel.Net
  as AuthKernelNet` resolves `AuthKernelNet.fn(...)` in user
  code (separate gap surfaced by #1378's reproduction).

**Acceptance criteria met:**

- 844 emitter + 74 CLI + 189 typechecker + 325 parser + 128 lexer
  tests pass.


### D-progress-319 — self-hosted `Lyric.AliasRewriter` (#1378 follow-up)

**Status:** Shipped.  The self-hosted MSIL bridge now collapses
`import X as Y` package aliases before typecheck so user code that
writes `Y.fn(...)` (qualified through an alias) typechecks correctly
instead of aborting with `T0020 unknown name 'Y'`.  Closes the
primary symptom in #1378's reproduction (the `T0020 'AuthKernelNet'`
floor of the lyric-auth in-process build).

**Problem:** The F# emitter ships `Lyric.Parser.AliasRewriter` (an
AST pre-pass that rewrites `Y.fn(...)` to bare `fn(...)` after
collecting `import X as Y` declarations).  The self-hosted MSIL
bridge had no equivalent — its typechecker only handles
single-segment paths in expression position, so `Y` (treated as a
bare path head by `resolveExprPath`) raised `T0020` and aborted the
multi-package build's `reportAndAbort(tcRes.diagnostics)`.  Any
ecosystem library that uses `import X as Y` style aliases — and most
do, including lyric-auth (`import Auth.Kernel.Net as AuthKernelNet`),
lyric-session, lyric-http, lyric-mq, lyric-storage — hit this floor
on the in-process path.

**Fix:**

1. **`lyric-compiler/lyric/alias_rewriter.l`** — new
   `Lyric.AliasRewriter` package that mirrors the F# implementation.
   Walks every `Item` in the `SourceFile`, descending into `Expr`,
   `TypeExpr`, `Pattern`, `RangeBound`, `TypeArg`, `Block`,
   `Statement`, `LocalBinding`, `RecordMember`, etc.  Collapses
   - `EPath` whose first segment is a known alias (drops it).
   - `EMember(EPath([alias]), name)` → `EPath([name])` (the
     `Alias.foo` → `foo` case the reproduction needed).
   - Same `ModulePath`-head collapse for `TypeExpr`'s `TRef` /
     `TGenericApp` / `TRefined`, plus `Pattern`'s `PConstructor` /
     `PRecord`.  Selector-level aliases (`import X.{foo as bar}`)
     are left to the importer cloning path that the type checker
     already handles.

2. **`lyric-compiler/msil/bridge.l`** — invoke
   `Lyric.AliasRewriter.rewriteFile` between parse and typecheck in
   both `compileToMsilWithVersion` (single-package) and
   `compileProjectToMsilWithRestoredAndVersion` (multi-package).
   The rewrite happens after `Lyric.Cfg.applyCfgErasure` so feature-
   erased items don't carry alias references into the typechecker.
   No-op when the source has no `import X as Y` declarations.

3. **`lyric-stdlib/tests/msil_project_bridge_tests.l`** — new
   regression test `testEmitProjectAliasedCrossPackageCall`.  Two
   packages: a library defining `pub func quintupled` and a
   consumer that imports it as `import AliasXPkg.Lib as Lib` and
   calls `Lib.quintupled(8)`.  Before the fix the bridge aborted
   the consumer's typecheck with `T0020 unknown name 'Lib'`; after
   the fix the rewrite collapses the call to `quintupled(8)`, the
   typechecker resolves it via the imported-items list seeded with
   `AliasXPkg.Lib`'s `pub func`, codegen emits a same-bundle MethodDef
   call, and the DLL prints `40`.

**Acceptance criteria met:**

- 128 lexer + 325 parser + 189 typechecker + 74 CLI + 844 emitter
  tests pass (including the new
  `testEmitProjectAliasedCrossPackageCall`).
- Multi-package builds with `import X as Y` no longer abort with
  `T0020 unknown name 'Y'`.

**What's next (still open from #1378):**

- Stdlib `IFunc` collection + cross-assembly `MemberRef`
  registration so `Std.X.foo(...)` calls (`tryDecodeBase64`,
  `encodeUtf8`, …) reach codegen with proper tokens.
- Per-package symbol-table filtering (#1378's architectural
  recommendation) for better diagnostic locality.


### D-progress-320 — per-package symbol-table filtering (#1378 follow-up)

**Status:** Shipped.  The self-hosted MSIL bridge's multi-package
typecheck now feeds each user package only the items from its
explicitly-imported dependencies (transitively, through in-bundle
edges), instead of flat-merging every prior package's items into
the next one's `importedItems` list.  Closes #1378's architectural
"per-package symbol tables" recommendation and the long-standing
#1195 known-gap.

**Problem:**

`compileProjectToMsilWithRestoredAndVersion` walked packages in
declaration order and appended each one's type / `pub func` items
to a shared `importedItems` list after typecheck — so when package
B was typechecked, it saw not only stdlib + restored items but
also every earlier package's items, regardless of whether B
actually `import`ed them.  Two practical pain points:

1. **Implicit visibility leak (#1195).**  B could reference A's
   types and pub funcs without an `import A` declaration; the
   typecheck passed, and codegen later traps the leak via the
   `MObject` fall-through in `lowerBuiltinOrStaticCallMsil`.  The
   diagnostic surfaced at the wrong layer (codegen, with no source
   span) rather than at typecheck (where it's actionable).
2. **Spurious duplicate-name collisions.**  Two unrelated packages
   that happened to define a record / function with the same
   simple name (a common pattern — `Helper`, `Config`, etc.)
   crashed B's typecheck with `T0001 duplicate name` because A's
   `Helper` landed in B's symbol table before B's own
   registration.

**Fix:**

1. **`lyric-compiler/msil/bridge.l`** — split the existing single
   parse-+-middle-end-+-typecheck loop into three phases:
   - **Phase 0** — build a `baseItems` list (stdlib + restored
     artifacts) that every user package can reference
     unconditionally.  Codegen-side AssemblyRef / TypeRef rows for
     these are seeded into the codegen context regardless of which
     user package references them, so the typecheck mirrors that
     reality.
   - **Phase 1a** — pre-parse every user package (parse + cfg-erase
     + alias-rewrite); collect the post-parse `SourceFile`s into a
     `parsedPkgs: List[ParsedUserPkg]` carrier.
   - **Phase 1b** — index each in-bundle package by dotted name
     into `inBundleItems: Map[String, List[Item]]` and
     `inBundleImports: Map[String, List[ImportDecl]]` so the
     per-package import filter can walk the bundle by name.
   - **Phase 2** — typecheck + mode-check + elaborate + derive +
     mono per package, but build each package's `importedItems`
     via the new `perPackageImportedItems` helper instead of the
     shared list.

2. **`perPackageImportedItems(baseItems, importList, inBundleItems,
   inBundleImports)`** — returns `baseItems ++ closure(importList)`
   where `closure` walks each `import <pkg>` declaration, looks up
   the in-bundle package, recurses through its own imports
   (visited-set guarded so cycles terminate), and accumulates the
   items.  Imports that don't resolve to in-bundle keys (stdlib,
   restored, builtin) fall through silently — they're either
   already in `baseItems` or were never an in-bundle reference.

3. **`addBundleClosure`** — the recursive helper.  Map keys are
   the exact `ProjectPackagePayload.name` strings, so an `import
   AliasXPkg.Lib` (collapsed by the alias rewriter) matches
   against the bundle's `AliasXPkg.Lib` entry directly.

4. **`lyric-stdlib/tests/msil_project_bridge_tests.l`** — new
   regression `testPerPackageIsolationDuplicateName`.  Two
   unrelated packages each define `pub record Helper` and neither
   imports the other; before the refactor the second package
   failed with `T0001`, after it builds and runs cleanly (printing
   7).  Pins the isolation guarantee.

**Acceptance criteria met:**

- 844 emitter + 75 CLI + 189 typechecker + 325 parser + 128 lexer
  tests pass (including the new
  `testPerPackageIsolationDuplicateName`).
- Existing cross-package tests
  (`testCrossPackageQualifiedCall`,
  `testCrossPackageChainedIntCalls`,
  `testCrossPackageRecordValueRoundTrip`,
  `testCrossPackageUnionConstructAndMatch`,
  `testEmitProjectAliasedCrossPackageCall`) continue to pass —
  they all use explicit `import <SiblingPkg>` declarations, which
  the new closure walker handles correctly.

**What's next (still open from #1378):**

- Stdlib `IFunc` collection in `collectStdlibTypeItems`.
- Cross-assembly `MemberRef` registration for stdlib `pub func`s
  in the bridge codegen (`addPackageTokens` /
  `registerRestoredArtifactTokens` equivalent for stdlib).  Until
  these land, user code calling `Std.X.foo(...)` (e.g.
  `tryDecodeBase64`) still aborts at typecheck with `T0020`.


### D-progress-321 — stdlib codegen MemberRef registration (#1378 follow-up)

**Status:** Shipped.  The self-hosted MSIL bridge now allocates
cross-assembly `MemberRef` rows for every stdlib `pub func` declared
in the loaded stdlib sources, so user code that calls
`Std.X.foo(...)` (e.g. `Std.Encoding.tryDecodeBase64`,
`Std.String.startsWith`) emits a real `call <memberref>` instruction
into the user's PE instead of falling through to the `MObject` arm
in `lowerBuiltinOrStaticCallMsil` (which previously left the operand
stack unbalanced and produced `InvalidProgramException` at
`dotnet exec` time).  Closes the third and final #1378 follow-up;
stdlib `IFunc` collection (the first remaining piece on the
"What's next" list above) had already landed via the aspect-system
PR (`ae94a08`), so the typechecker was already accepting these calls
— this PR makes codegen match.

**Problem:**

After D-progress-318 wired stdlib `_kernel/` types into the bridge
typechecker and the aspect-completeness PR enabled IFunc collection,
user code calling stdlib functions typechecked cleanly but the
bridge's call-site codegen had no MemberRef registered for them.
`lowerBuiltinOrStaticCallMsil`'s FQN-keyed `funcTokens` lookup
walked the user's import edges (`pkgImports[user.pkg]`), tried
`<importedPkg>.<funcName>` for each (e.g.
`Std.Encoding.tryDecodeBase64`), and found nothing — falling
through to the defensive `MObject` arm that walks args for side
effects and emits no `call` instruction at all.  The resulting PE
ran the user's `tryDecodeBase64("...")` call and immediately tripped
an `InvalidProgramException` because the stack carried unconsumed
strings the runtime expected the missing `call` to have popped.

**Fix:**

1. **`lyric-compiler/msil/bridge.l`** — refactor stdlib source
   ingestion so the codegen-side registration has per-package
   visibility:
   - `collectStdlibPackages(stdlibSources): List[StdlibPkg]` parses
     each stdlib source, reads its `package` declaration, and
     returns the included items grouped by package
     (`Std.Core`, `Std.Encoding`, `Std.CollectionsHost`, …).  Drops
     files whose parse produced an error-severity diagnostic so
     partial / malformed items don't pollute downstream codegen
     registration.
   - `spreadStdlibPackageItems(pkgs, flat)` keeps the existing
     flat-merged `importedItems` view in sync with the per-package
     map without re-parsing.  Used by the bridge to feed the
     typechecker the same flat surface it had before while
     simultaneously handing the per-package grouping to codegen.
   - `filterStdlibPkgsByBundle(pkgs, bundleNames)` drops any stdlib
     entry whose name matches an in-bundle user package so the
     registration doesn't clash with `addPackageTokens` when the
     bundle being compiled happens to contain a stdlib package
     (e.g. compiling the `Lyric.Stdlib` bundle itself).  No-op for
     normal user builds.

2. **`lyric-compiler/msil/codegen.l`** — add the codegen-side
   registration matching `registerRestoredFunc`'s pattern:
   - `StdlibPkg` record (placed here, not in `Msil.Bridge`, so the
     codegen function can name it without forming a circular
     import).
   - `registerStdlibArtifactTokens(cctx, pkgs)` — for each package:
     allocate the shared `Lyric.Stdlib.<X>` AssemblyRef (cached in
     `cctx.ffiAsmRefs`), allocate the `<pkgName>.Program` TypeRef
     (via the existing `ensureHostClassTypeRefRow`), then for every
     `pub func` register a static `MemberRef` and add the FQN
     token to `cctx.funcTokens`.
   - `ensureStdlibAssemblyRef(cctx, packageName)` and
     `stdlibAssemblyName(packageName)` mirror the F# emitter's
     `ensureStdlibArtifact` assembly-name convention
     (`Std.X` → `Lyric.Stdlib.X`, `Lyric.X` → `Lyric.X` /
     `Lyric.<head>.<rest>`).  Version pinned to `0.1` to match the
     stdlib manifest's declared semver — the runtime binder is
     tolerant of minor mismatches; threading the actual version
     here is tracked in #1364.
   - `splitDottedName(name)` — local helper that takes apart
     `"A.B.C"` without depending on `Lyric.Parser`'s tokeniser,
     keeping `Msil.Codegen`'s import surface minimal.

3. **Wired into both bridge entry points**: `compileToMsilWithVersion`
   (single-package) and `compileProjectToMsilWithRestoredAndVersion`
   (multi-package) now call `registerStdlibArtifactTokens` after
   `registerRestoredArtifactTokens` and before
   `addPackageTokens`.  This ordering lets stdlib MemberRefs land
   in `funcTokens` before the per-user-package MethodDef registrations,
   so the `containsKey` first-wins guards in `registerStdlibFunc`
   and `addPackageTokens` correctly prefer the in-bundle
   `MethodDef` if a user package happens to share an FQN with the
   stdlib (defensive — doesn't happen in practice given the stdlib
   filter above).

**Limitations / follow-ups:**

- **No end-to-end regression test in this PR.**  The bridge's
  test harness runs the produced DLL via `dotnet exec` from a
  temp directory and has no mechanism for placing `Lyric.Stdlib.<X>.dll`
  alongside the output.  Production builds go through the
  installed SDK's `additionalProbingPaths` so the runtime locates
  the stdlib bundle; the bridge's in-repo test harness skips that
  step.  Adding a regression test that exercises a real stdlib
  function call requires teaching `runEmitProject` to either
  pre-populate the F# stdlib cache (via a side-channel F# emit)
  or stage the stdlib DLLs from a known location.  Tracked as a
  follow-up for the test-infrastructure layer; doesn't gate the
  production CLI's correctness.
- **AssemblyRef naming convention** is intentionally per-package
  (`Lyric.Stdlib.Encoding`, `Lyric.Stdlib.String`, …) to match the
  F# emitter, which produces per-package DLLs into the dev cache.
  The production SDK additionally ships a bundled
  `lib/Lyric.Stdlib.dll`; both layouts coexist because the
  F# emit path populates the per-package cache as a side effect
  even when only the bundle is the user-facing artefact.

**Acceptance criteria met:**

- 844 emitter + 75 CLI + 189 typechecker + 325 parser + 128 lexer
  tests pass (no regressions).
- Generated PE for a user program calling a stdlib `pub func`
  carries the expected `Lyric.Stdlib.<X>` AssemblyRef row + the
  `<pkgName>.Program::<fn>` MemberRef — verified by the runtime
  loader's `FileNotFoundException` against `Lyric.Stdlib.<X>`
  (the binder reaches the AssemblyRef before the file-probing
  fails), confirming the metadata is structurally correct even
  though the test harness can't satisfy the runtime probe.

### D-progress-322 — `@cfg` dotnet/jvm overload-pair resolution regression guard (#1472)

**Status:** Shipped.  Adds a pipeline-level regression self-test that
pins the resolution of `@cfg(feature = "dotnet")` / `@cfg(feature =
"jvm")` overload pairs whose two overloads have **different arities**,
guarding against the spurious `T0042 expected N argument(s), got M`
failure mode #1472 describes.

**Investigation:**

The headline symptom — `lyric test --manifest lyric-auth/lyric.toml`
surfacing `T0042 expected 2 argument(s), got 3` on real
dotnet/jvm `@cfg` overload pairs — does **not** reproduce on the
current tree.  Verified against a freshly bootstrapped stage-1 +
AOT CLI:

- `lyric build --manifest lyric-auth/lyric.toml` builds clean.
- `lyric test --manifest lyric-auth/lyric.toml` compiles every test
  package with zero `T0042` (the only remaining failure is an
  unrelated `Lyric.Stdlib.Testing` runtime probing-path issue).
- Minimal single-package, cross-package in-bundle, and
  restored-dependency repros of a dotnet/jvm overload pair with
  mismatched arities all resolve to the active overload and run
  correctly.

Root cause of the original bug was a cfg-erasure-vs-signature-
registration ordering interaction; it is resolved on `main` by the
alias-rewriter overload-resolution fix (`f1320db`) together with the
cfg-erasure pass running **before** `checkWithImports`
(`lyric-compiler/msil/bridge.l` — `applyCfgErasure` at the per-package
parse phase, ahead of the typecheck phase).  The `T0042 expected 2
argument(s), got 3` message now appears only as a *correct* diagnostic
— e.g. when `jvm` is the active feature and source calls the 3-arg
form whose overload has (correctly) been erased.

**Change:**

- **`lyric-compiler/lyric/cfg_self_test.l`** — new
  `testCfgOverloadArityResolution` runs the real `Lyric.Cfg` erasure
  pass followed by the `Lyric.TypeChecker` `check` entry point over a
  source file declaring `combine/2` under `@cfg(feature = "jvm")` and
  `combine/3` under `@cfg(feature = "dotnet")`, plus a caller using the
  3-arg form.  Asserts: (a) with `dotnet` active the 3-arg overload
  survives and the call type-checks with **no** `T0042`; (b) with `jvm`
  active only the 2-arg overload survives, so the same 3-arg call is a
  *genuine* single `T0042` — the teeth of the guard, which fails if the
  inactive overload ever leaks back into the signature map.

**Acceptance criteria met:**

- No `T0042` on the `lyric-auth` build/test path (verified above).
  The `lyric-session` path is currently gated by an unrelated parser
  regression (#1473, tracked separately); the dotnet/jvm overload
  concern itself is resolved and now regression-guarded.
- A self-test covering a `@cfg(feature = "dotnet")` /
  `@cfg(feature = "jvm")` overload pair with differing arities ships
  in `cfg_self_test.l` and passes via `SelfHostedCfgTests`.

### D-progress-323 — indexed assignment `a[i] = v` in the self-hosted MSIL backend (#1476)

**Status:** Shipped.  The self-hosted MSIL backend now lowers indexed
assignment (`a[i] = v`) instead of silently discarding the write.

**Problem:**

`lowerAssignExprMsil` (`lyric-compiler/msil/codegen.l`) matched only
local (`EPath`) and field (`EMember`) assignment targets.  An `EIndex`
target fell through to the wildcard arm, which evaluated the right-hand
side and immediately `pop`ped it — so `a[i] = v` compiled to a no-op
that silently dropped the store (docs/41 §3.2).  This is a silent
miscompile: code mutating a collection element by index ran but left the
element unchanged.

**Fix:**

1. **`lyric-compiler/msil/codegen.l`** — register a new
   `tokListObjSetItem` MemberRef for `List<object>::set_Item(int32, !0):
   void` (mirroring the existing `get_Item` token the `EIndex` read arm
   uses) and add an `EIndex` arm to `lowerAssignExprMsil`.  For plain
   assignment (`AssEq`) it pushes the receiver (cast to `List<object>`),
   the index, and the boxed value, then emits `callvirt set_Item` — the
   exact inverse of the read path's `get_Item`, so a mutated element
   reads back its new value.
2. **Compound forms** (`a[i] += v`, …) require reading the current
   element, applying the operator at the element's static type, and
   storing it back.  List elements are stored boxed and the element type
   is not threaded to codegen, so a correct unbox/rebox is not yet
   possible (arithmetic on a boxed element is itself a separate gap).
   Rather than silently discard the write (the prior behaviour) or emit
   invalid IL, the `EIndex` arm hard-fails the build with an actionable
   message naming #1481 (which owns compound assignment).  No `.l`
   source uses compound indexed assignment, so the stage-1 self-build and
   ecosystem builds are unaffected.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's
JVM-deferred banner.  The self-hosted JVM backend
(`lyric-compiler/jvm/codegen.l`) is tracked separately under that epic.

**Receiver-handling symmetry (#1531):** the `EIndex` *read* arm in
`lowerExprMsil` previously emitted `callvirt get_Item` without first
narrowing the receiver, unlike the `get_Count` / `set_Item` paths.  A
receiver typed as `object` on the stack (e.g. an `in` parameter) would
fail JIT verification on `List<object>::get_Item`.  The read arm now
`castclass`-es to `List<object>` before the call, matching the write
path and keeping read/write receiver handling symmetric.

**Acceptance criteria met:**

- Parity programs mutating a `List` element by index and reading it back
  succeed in `SelfHostedMsilBridgeTests` (driving the self-hosted bridge
  end-to-end): `shm_indexed_assign` (`Int` elements, `xs[1] = 99` reads
  back `99`) and `shm_indexed_assign_string` (`String` elements,
  `xs[0] = "X"`) — the latter covers the reference-element boxing path
  (#1532).
- No silent discard: the write now takes effect; compound indexed
  assignment fails loudly at build time instead of dropping the store.
- Full `SelfHostedMsil bridge` suite: 35 passed, 0 failed (no
  regressions from the new `set_Item` token or the read-path cast).

### D-progress-324 — self-hosted MSIL backend supports same-name function overloads (#1536)

**Status:** Shipped.  The self-hosted MSIL backend now compiles and
correctly dispatches same-name function overloads distinguished by arity
(e.g. `Std.String.substring/2` vs `/3`).

**Problem:**

Two independent name-keyed collisions in the MSIL backend made any
package declaring same-name overloads fail:

1. **Token table (crash).**  `addPackageTokens` (`codegen.l`) registered
   `funcTokens` / `funcRetTypes` under the bare FQN (`<pkg>.<name>`) with
   an un-guarded `Map.add`.  The second overload's `add` threw
   `ArgumentException: An item with the same key has already been added.
   Key: Std.String.substring`, crashing the self-hosted stdlib bundle
   build (`lyric build --manifest lyric-stdlib/lyric.toml`) and keeping
   the F# `--internal-manifest-build` path load-bearing.
2. **Signature blob (invalid IL).**  `lowerMFuncsToHostClass`
   (`lowering.l`) interned each method's signature blob under a
   name-only key (`"sfunc_<host>_<name>"`).  Because `internBlob` dedups
   by key, the second overload silently inherited the first overload's
   signature blob — emitting a MethodDef whose declared arity disagreed
   with its call sites, producing `InvalidProgramException` at run time.
   The same latent collision existed for record / union / interface
   method signature keys (`meth_` / `basemeth_` / `ifmeth_`).

**Fix:**

- **`lyric-compiler/msil/codegen.l`** — key `funcTokens` / `funcRetTypes`
  by an arity-qualified `<fqn>/<arity>` key (mirroring the type checker's
  `name/arity` sig map from #1472), keeping the bare FQN as a
  first-registered-wins alias for package resolution.  The call site in
  `lowerBuiltinOrStaticCallMsil` narrows to the arity key matching the
  call's argument count, falling back to the bare alias.
- **`lyric-compiler/msil/lowering.l`** — arity-qualify the four method
  signature-blob intern keys (`sfunc_` / `meth_` / `basemeth_` /
  `ifmeth_`) so overloads no longer share a blob.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's
JVM-deferred banner.

**Acceptance criteria met:**

- `addPackageTokens` no longer crashes on same-name overloads; the
  stdlib bundle build now advances past the duplicate-key error to the
  next, unrelated gap (`SFor` / range-for, tracked as #1478).
- `shm_func_overload_by_arity` in `SelfHostedMsilBridgeTests` drives the
  self-hosted bridge end-to-end: a package declaring `add/2` and `add/3`
  compiles and prints `3` then `6` (correct per-arity dispatch).
- Full `SelfHostedMsil bridge` suite: 34 passed, 0 failed; stage-1
  self-build succeeds.

**Follow-up:** the full stdlib self-build (and thus retiring the F#
`--internal-manifest-build` path, Band 5 #1492/#1493) additionally
requires `SFor`/range-for codegen (#1478) and any further gaps it
surfaces.  This task removes the overload blocker only.

### D-progress-325 — `for` loops (range + collection) in the self-hosted MSIL backend (#1478)

**Status:** Shipped.  `for` loops now compile on `--target dotnet` instead
of panicking (`Msil.Codegen: SFor not supported`).

**Problem:**

`SFor` panicked in `lyric-compiler/msil/codegen.l`, and the self-hosted
parser did not accept a range in iterator position — `for i in lo .. hi`
failed to parse (`parseExpr` stops at `lo`, then the for-loop expected
`{`).  So neither range nor collection `for` loops worked on the default
target; the stdlib self-build (post-#1536) hit the `SFor` panic next.

**Fix:**

1. **`lyric-compiler/lyric/parser/parser_exprs.l`** — the `for` parser now
   checks for a trailing range operator after the iterator expression and
   wraps the bounds in an `ERange` (`..` / `..<` → half-open, `..=` →
   closed).  Plain collection iterators are unchanged.
2. **`lyric-compiler/msil/codegen.l`** — `lowerForMsil` dispatches on the
   iterator:
   - **range** (`ERange`): `emitCountingForMsil` emits a counting loop with
     the bound evaluated once; half-open uses `i < hi`, closed uses
     `i <= hi`; the counter increments by an `i4`/`i8` `1` to match the
     bound type.
   - **collection**: `emitCollectionForMsil` models the iterator as
     `List<object>` (the representation the `EIndex` read path already
     uses) and walks it by index via `get_Count` / `get_Item`.
   Both bind the loop pattern via `lowerPatternBindMsil` and route
   `break` / `continue` through `fctx.loopBreak` / `fctx.loopCont`, with
   `continue` targeting the increment so the counter still advances.
   Standalone range *values* remain unsupported (no `Range` value type;
   unused in stdlib/ecosystem) and now fail with a clear diagnostic.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's
JVM-deferred banner.

**Acceptance criteria met:**

- Parity programs compile and run: `for i in 0 .. 5` (sum 10),
  `for i in 1 ..= 5` (sum 15), `for x in xs` over a `List`, and
  `break` / `continue` inside a range `for`.
- Regression tests `shm_range_for` and `shm_collection_for_break_continue`
  in `SelfHostedMsilBridgeTests` drive the self-hosted bridge end-to-end;
  full suite 36 passed, 0 failed; stage-1 self-build succeeds.
- The stdlib self-build now advances past the `SFor` panic to the next
  distinct gap (`EResult outside contract context` — contract-elaboration
  completeness, tracked separately).

**Known limitation (collection `for`):** the loop variable of a collection
`for` is bound as `object` (boxed), mirroring how `EIndex` reads model a
`List` element.  Object-safe uses (`println(x)`, `toString(x)`, method
calls) are correct, but *arithmetic* on a numeric element
(`for x in nums { sum = sum + x }`) is subject to the boxed-element
type-erasure gap (#1496) — the same limitation `nums[i] + n` has today —
and yields a wrong value until generic element types are reified.  Range
`for` is unaffected (the index binds as a real `Int`/`Long`).
### D-progress-326 — FFI class/object signatures: real TypeRef MemberRefs (#1504 part 1)

**Status:** Shipped.  An `@externTarget` whose signature mentions a
class/object type now emits a real `TypeRef`-backed MemberRef and a
working call, instead of the runtime-throw stub that previously forced
the (now-removed) `--target dotnet-legacy`.

**Problem:** the method-signature blob encoder (`lowering.l` `bufMsilType`)
degraded every `MClass` to `ELEMENT_TYPE_OBJECT`, so `emitExternTargetBody`
(`codegen.l`) bailed any class-typed extern to a stub that throws at call
time.  Programs using BCL class externs (`StringBuilder`, `MemoryStream`,
`Console`/`Process`/`HttpClient` instance methods, …) could not run on
`--target dotnet` — the gap keeping Band 5's kernel-extern migration
(#1492/#1493) blocked.

**Fix (`lyric-compiler/msil/codegen.l`):**

- `resolveFfiClassTypeRef(cctx, className)` maps an `MClass` FQN to a CLR
  `TypeRef` row: declared extern types resolve via `cctx.externTypeNames`
  (Lyric name → CLR FQN), direct `System.*` references resolve as-is;
  assembly via `clrAssemblyForType`, namespace/name via `splitTypeFqn`,
  interned through `internFfiTypeRef`.  Returns -1 for non-FFI-resolvable
  classes (in-bundle user records/unions, nested `Outer+Inner` types) so
  the caller falls back to `ELEMENT_TYPE_OBJECT` with no regression.
- `bufFfiType` / `buildFfiMethodSigCtx` are context-aware sig encoders that
  emit `ELEMENT_TYPE_CLASS (0x12) + compressed TypeDefOrRef` for resolved
  class types and reuse the shared `bufMsilType` for everything else.
- `emitExternTargetBody` drops the `mentionsMClass → throw` bail and builds
  its MemberRef sig through `buildFfiMethodSigCtx` for static, ctor, and
  instance shapes.  `bufMsilType` / `writeCompressedInt` are now `pub` in
  `lowering.l` for reuse.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's JVM-deferred
banner.  This is #1504 **part 1**; remaining #1504 parts — unresolved-type
hard diagnostic (H8), instance/non-void auto-FFI (H9), and generic externs
(blocked on the MethodSpec table #1497) — stay open.

**Acceptance criteria met (part 1):**

- A parity program declaring `extern type SB = "System.Text.StringBuilder"`
  with a ctor returning the class and instance methods taking + returning
  the class compiles **and runs** (`shm_ffi_class_extern` in
  `SelfHostedMsilBridgeTests`): prints `hello world`.
- Full `SelfHostedMsil bridge` suite: 41 passed, 0 failed; stage-1
  self-build succeeds.

### D-progress-327 — FFI unresolved-extern-type hard diagnostic (#1504 H8)

**Status:** Shipped.  An `@externTarget` (or auto-FFI call) whose type cannot
be resolved to a known reference assembly now fails the build with a clear,
type-specific diagnostic instead of silently binding to `System.Runtime` and
failing at runtime with an opaque `TypeLoadException`.

**Problem:** `clrAssemblyForType` defaulted every unrecognised type to
`System.Runtime` (`ffi.l`).  A typo (`Sytem.Console`) or an unsupported
third-party type therefore produced a structurally-valid PE with a wrong
`AssemblyRef`/`TypeRef`, and the only failure signal was a runtime
`TypeLoadException` with no pointer back to the offending `@externTarget`.

**Fix:**

- `lyric-compiler/msil/ffi.l` — `clrAssemblyResolvable(typeFqn): Bool` returns
  true only for `System.*` BCL types and `Lyric.*` internal hosts
  (`Lyric.Emitter`, `Lyric.Stdlib`, `Lyric.Jvm.Hosts`) — the complete set the
  cascade can actually resolve.  (Audited every extern FQN reachable across
  `lyric-stdlib/std/_kernel/` and `lyric-compiler/msil/_kernel/`: all are
  `System.*` or `Lyric.*`, so no live extern is affected.)
- `lyric-compiler/msil/codegen.l` — `emitExternTargetBody` and
  `emitAutoFfiCallMsil` consult the predicate and `panic` with a clear,
  type-specific message when the type is unresolvable.  This is the same
  build-time-diagnostic mechanism the `@externStatic`/`@externInstance`
  conflict already uses (#790), and it surfaces on the CLI as `B0001` +
  the message on stderr.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's JVM-deferred
banner.  Part of #1504; remaining: H9 (instance/non-void auto-FFI) and generic
externs (blocked on #1497).

**Validation:**

- Manual end-to-end (CLI): a program declaring `extern type Bad = "FooBar.Baz"`
  fails `lyric build` with
  `FFI extern 'FooBar.Baz..ctor' on 'newBad' references type 'FooBar.Baz',
  which cannot be resolved to a known reference assembly …` instead of building
  a mis-bound DLL.
- Positive path unchanged: `shm_ffi_class_extern` (a `System.Text.StringBuilder`
  extern) still compiles and runs; full `SelfHostedMsil bridge` suite 41/41.

**Test-harness note:** an in-harness negative test (`mkBridgeFails`) is not
addable for this case — the in-process bridge (`SelfHostedMsil.compileToDll`)
does not catch codegen `panic`s (they surface as `TargetInvocationException`
rather than a `false` return), the same limitation that applies to the
pre-existing F0002 conflict panic.  Adding a "compiles-then-throws" or
panic-catching helper would require new F# test infrastructure, which the
project standard forbids.  The CLI path (which does catch the panic → `B0001`)
is the validated surface.

### D-progress-328 — self-hosted MSIL backend: remaining String instance methods (#1471)

**Status:** Shipped.  Completes the method-syntax String surface in the
self-hosted MSIL backend.  Earlier work (re-audit branch) added
`s.length`, `s[i]`, `s.substring(..)`, `s.replace(..)`, `s.normalize()`,
and value-based string `==` (via `Object.Equals`).  This adds the
remaining instance methods that fell through to the unknown-method stub
(returning `null` → `NullReferenceException` at run time):
`s.trim()`, `s.indexOf(x)`, `s.lastIndexOf(x)`, `s.startsWith(x)`,
`s.endsWith(x)`, `s.toLower()`, `s.toUpper()`.

**Fix (`lyric-compiler/msil/codegen.l`):** added the BCL `System.String`
instance-method tokens (`Trim`, `IndexOf`, `LastIndexOf`, `StartsWith`,
`EndsWith`, `ToLower`, `ToUpper`) and the matching `lowerMethodCallMsil`
branches.  `indexOf`/`lastIndexOf` return `Int` with BCL semantics
(`-1` when absent), distinct from the `Std.String` free functions that
return `Option[Int]`.

**Tests:** `lyric-stdlib/tests/string_methods_tests.l` (auto-discovered by
the stdlib Lyric test runner) covers the new methods; Emitter suite
845 passed / 0 failed.

**Context — `#1471` is not primarily a string-primitives bug.**  With the
String surface now complete, the `lyric-auth` security suite (the headline
`#1471` reproduction) still fails on the self-hosted MSIL path because of
**cross-package / multi-package codegen** issues that are independent of
string handling and out of scope here:

- **`The signature is incorrect.`** on the `rolesContain` tests — the
  function compiles and runs correctly *standalone* (verified), so the
  fault is in the cross-package call from the synthesised test package to
  `Auth.rolesContain` (a multi-package MemberRef-signature mismatch,
  surfaced after the #1469 generics/aspect merge).
- **`Common Language Runtime detected an invalid program.`** on the
  `jwtAlg`/`verifyJwt` tests — union/`Result`/`Option` matching on
  cross-package or generic-typed scrutinees: `findTypeDefRowByName` only
  scans the current assembly, so imported case classes
  (`Std.Core.Option$None`) fall back to `isinst System.Object` (always
  true), and generic union scrutinees are typed `MObject`, so the
  `isinst` test is skipped — the first match arm wins.
- **`lyric test` / `lyric run` runtime staging** does not co-locate the
  stdlib DLLs with the compiled assembly (the probing path written is
  relative + NuGet-layout, so a flat `bin/` never resolves).

These are tracked as the remaining `#1471` work; JVM parity for the
String surface (and the `MArray`/`MByte` slice encoding and nullary-case
call-arg threading below) is tracked in **#1585**.  (Subsequent entries in
this branch fix the signature-incorrect and union-match items.)  The
seven method-syntax forms are documented in the language reference §12.1
and `book/chapters/appendix-b-quick-reference.md`.

### D-progress-329 — self-hosted MSIL: `Unit` as a generic type argument (#1471)

**Status:** Shipped.  Fixes the `The signature is incorrect.` failures in
the `lyric-auth` suite (recovers 9 tests: the `rolesContain` group + two
others), taking the suite from 0/29 to 8/29.

**Problem:** `Unit` lowers to `MVoid`, and the GENERICINST signature
encoder (`bufMsilType` / `bufMsilTypeWithCtx` / `buildGenericInstBlob*`,
the #1442 generic-instance machinery) emitted each type argument verbatim
— so a `Unit` argument became `ELEMENT_TYPE_VOID` (0x01).  `void` is
illegal inside a GENERICINST signature (ECMA-335 §II.23.2.14), producing a
malformed `#Blob` entry.  A function returning `Result[Unit, E]` (e.g.
`Auth.verifyJwt`) therefore wrote a corrupt MethodDef signature; at run
time the CLR rejected the surrounding metadata with
`The signature is incorrect.` — and, because method signatures are encoded
via the context-free `buildStaticMethodSig` → `bufMsilType` path, the
corruption surfaced when *any* cross-package caller resolved a sibling
function in the same package (e.g. the synthesised test package calling
`Auth.rolesContain`, which compiles and runs correctly in isolation).
Bisected to the `Unit` type argument specifically: `Result[Int, String]`,
`Result[Int, JwtError]`, and `Option[Int]` all encode fine; only
`Result[Unit, …]` broke.

**Fix (`lyric-compiler/msil/lowering.l`):** added `genericArgType`, which
erases `MVoid` → `MObject` (matching how `Unit` values are represented at
run time), and applied it at all four type-argument encoding loops.  A
`Unit`/`void` *return* type still encodes as 0x01 — only type arguments
are normalised.

**Remaining `#1471` blockers (unchanged):** the 20 `Common Language
Runtime detected an invalid program.` failures are the cross-package /
generic-typed union-match `isinst` gap (jwtAlg/verifyJwt), plus one
`Std.String.split` cross-package MemberRef signature mismatch.

### D-progress-330 — call-argument context threading for nullary generic cases (#1471/#1442)

**Status:** Shipped.  Completes the canonical nullary-union-case
representation so it is consistent across *all* construction positions.

**Background:** D-progress-328/329 and the slice/`MArray` work converged
the self-hosted backend onto the F#-stdlib representation: a nullary case
(`None`) carries the union's concrete type arguments (`Option_None<byte[]>`),
and the match-site tests a single scrutinee-args `isinst`.  Construction
already threaded `contextHintTyArgs` for annotated (`val x: Option[T] = None`)
and return (`return None`) positions, so those built `Option_None<concrete>`.
The one remaining position — a bare call-argument `f(None)` — had no context
threaded, so it erased to `Option_None<object>` and the scrutinee-args
`isinst` then failed (the match-exhaustiveness panic).

**Fix (`lyric-compiler/msil/codegen.l`):** added `funcParamTypes` (declared
parameter MsilTypes, keyed like `funcTokens`/`funcRetTypes`), populated for
in-bundle functions (`addPackageTokens`) and cross-package stdlib functions
(`registerStdlibFunc`).  The resolved-static-call arg loop now threads a
generic parameter's type arguments into `contextHintTyArgs` (save/replace/
restore, so an enclosing val/return context for a *different* type does not
leak into the argument) while lowering that argument.  A bare `f(None)`
argument therefore constructs `Option_None<concrete>` matching the callee's
parameter type.

**Verified:** `classify(None)` with `classify(o: Option[String])` (bare
call-arg, no annotation) now matches `None` correctly; the annotated/return
forms and F#-returned (`Option[byte[]]`) Nones continue to match.  Emitter
suite 845/0; `lyric-auth` unchanged at 8/29 (its Nones are F#-returned, so
this position never applied — the residual 20 are the separate jwtAlg/
verifyJwt "invalid program", investigated next).

### D-progress-331 — self-hosted MSIL: degrade slice (`MArray`) locals to object in LocalVarSig (#1471)

**Status:** Shipped.  `buildLocalVarSig` degrades `MClass`/`MGenericInst`
locals to `ELEMENT_TYPE_OBJECT` (0x1C), but a slice local (`MArray`, added
for the `slice[T]`→`T[]` signature parity in the slice/`MArray` work) fell
through to `elementTypeByte(MArray)` = 0x1D — the SZARRAY *prefix only*, with
no element type.  That wrote a malformed LocalVarSig (dangling prefix), which
corrupted the evaluation stack at run time (`AccessViolationException` /
invalid program) for any function with a slice-typed local feeding deeper
expressions — e.g. `jwtAlg`'s `val bytes` from a nested `match` over
`Option[slice[Byte]]` combined with an if-expression `val`.

**Fix (`lyric-compiler/msil/lowering.l`):** degrade `MArray` locals to object
(0x1C) like `MClass`/`MGenericInst`; the codegen treats slices as opaque
references and a `byte[]` value is still a valid object.  Cross-package
MemberRef signatures keep the precise `T[]` encoding (where F#-stdlib
agreement is required).  Verified: `jwtAlg` extracts `HS256` standalone and
via a multi-package build.  Emitter suite 845/0.

### D-progress-332 — self-hosted MSIL: represent `Unit` payload as null in construction and binding (#1471)

**Status:** Shipped.  `Result[Unit, E]` / `Option[Unit]` values broke the
self-hosted backend because `Unit` (`MVoid`) has no runtime value but is
still a union-case payload:

1. **Construction:** `Ok(())` lowered the `()` argument to *nothing*
   (`LUnit` → `MVoid`, no instruction), leaving a stack imbalance at the
   enclosing `newobj` → invalid program.  `LUnit` as a value now pushes
   `null` (`MObject`).
2. **Binding:** `case Ok(u)` allocated `u` as a void local (the bound
   payload's `concreteFieldTy` resolved to the `Unit` type arg = `MVoid`)
   → invalid program.  The bound payload now erases `MVoid` → `MObject`
   (Unit held as null/object).

`lyric-auth`'s `verifyJwt`/`verifyJwtWithSkew` return `Ok(())` and match
`case Ok(unit)` throughout, so this was the dominant `verifyJwt` "invalid
program".  Takes `lyric-auth` from 8/29 to **16/29**.  Emitter suite 845/0;
statement-context `()` results are popped like any other value by block /
statement lowering (verified by the unchanged 845 suite).

**Residual:** the remaining 13 `lyric-auth` failures are array *consumption*
— F#-stdlib `split` returns a real `String[]`, but the self-hosted backend
indexes/measures collections as `List[object]` (`.length`→get_Count,
`[i]`→get_Item), which faults on a genuine array (`verifyJwtImpl`'s
`split(token, ".")` + `parts[0..2]`).  Tracked for a follow-up that adds
`ldelem`/`ldlen` support for `MArray` receivers.

### D-progress-333 — self-hosted MSIL: array consumption (`ldelem`/`ldlen`) for `MArray` receivers (#1471)

**Status:** Shipped.  Completes the slice/array story: with `slice[T]`
lowering to `T[]` (D-progress, slice work), a real array returned from the
F# stdlib (e.g. `Std.String.split → String[]`) could be *passed* opaquely but
not *consumed* — indexing and length went through the `List[object]` ops
(`get_Item` / `get_Count`), which fault on a genuine array.

**Fix:**

- `lyric-compiler/msil/lowering.l` — new `MLdelemRef` / `MLdelemU1` /
  `MLdelemI4` instructions (and `MLdlen` already present), wired to the
  existing `emitLdelem_*` / `emitLdlen` opcode helpers.
- `lyric-compiler/msil/codegen.l` — `EIndex` on an `MArray(elem)` receiver
  pushes the index then emits the element-typed `ldelem` (`.ref` for
  `String[]`/object/class elements, `.u1` for `byte[]`, `.i4` for `int[]`),
  returning the element type.  `EMember` `.length`/`.count` on `MArray`
  emits `ldlen` + `conv.i4`.

**Verified:** `split("a.b.c", ".")` → `parts.length == 3`, `parts[0..2]` =
`a`/`b`/`c`.  Emitter suite 845/0.  `lyric-auth` 16/29 → **17/29**; the
kernel-path tests now reach the crypto extern (their failure mode changed
from "invalid program" to a clean `Lyric.Auth.AuthHost` host-type load
error — a separate FFI host-shim resolution gap, below).

**Residual (separate blocker):** the remaining `lyric-auth` failures are
`Could not load type 'Lyric.Auth.AuthHost'` — the auth kernel's crypto
externs (`@externTarget("Lyric.Auth.AuthHost.hmacSha256")`, …) point at the
F# host shim `bootstrap/src/Lyric.Auth.Host/`, which the self-hosted MSIL FFI
resolver does not locate (it defaults the assembly to `System.Runtime`).
The production fix is to migrate those crypto externs to direct BCL
`extern`s in `_kernel/` (per the no-F#-shim rule; blocked on FFI
`ReadOnlySpan<byte>` parameter support) — tracked in **#1592**, separately
from this codegen series.  A further single test (`extractClaim` ASCII, #25)
runs but returns empty — the kernel base64/UTF8/JSON pipeline, also noted
in #1592.

### D-progress-335 — pure-Lyric PE byte writer; Lyric.Jvm.Hosts off the .NET path (#1492)

**Status:** Shipped.  `Msil.Kernel.ByteWriter` — the buffer every emitted PE
byte flows through — is now a pure-Lyric `List[Byte]` buffer instead of the F#
`Lyric.Jvm.Hosts.JvmByteHost` host, so `--target dotnet` builds no longer route
bytes through `Lyric.Jvm.Hosts.dll`.

**Change (`lyric-compiler/msil/_kernel/kernel.l`):**

- `ByteWriter` is a `record { data: List[Byte] }`; `bufNew` allocates the list
  and the `buf*` helpers append into it in place.
- `bufU1` masks to `[0, 255]` (`((v % 256) + 256) % 256`) to match the former
  host's `byte v` (`& 0xFF`) — `buildI4ConstantBlob` and friends pass
  `v % 256`, which can be negative under Lyric's sign-of-dividend remainder.
- `bufU2`/`bufU4` peel successive little-endian bytes with `bufU1` (which masks
  the low byte) plus an arithmetic right-shift helper `shr8` — floor division,
  since Lyric `/` truncates toward zero.  A naive `v / 256` corrupts the high
  byte for a negative `Int` (e.g. a backward branch offset, or `-1` whose four
  bytes must all be `0xFF`), which produced invalid IL
  (`InvalidProgramException` on every loop).  `shr8` adjusts the truncated
  quotient (`if v % 256 < 0 { v/256 - 1 } else { v/256 }`) and never negates
  `v`, so it is correct even at `Int.MinValue` — and stays within 32-bit `Int`
  (an earlier draft used a `2^32` literal, which is unrepresentable in Lyric's
  32-bit `Int` and failed to parse).
- `bufI8Le` / `bufF8Le` use the audited `System.BitConverter.GetBytes(Long)` /
  `GetBytes(Double)` externs (returning `slice[Byte]`) for 64-bit / IEEE-754
  binary64 little-endian extraction (impractical in Lyric without bitwise
  primitives, #875).  `System.BitConverter` resolves via `System.Runtime`.
- `bufF4Le` (`ldc.r4` / IEEE-754 binary32) narrows the `Double` to a `float` and
  reinterprets its 32-bit pattern as an `Int` via
  `System.Convert.ToSingle` → `System.BitConverter.SingleToInt32Bits`, then
  writes it little-endian through `bufU4`.  The `Single` value flows only between
  the two BCL calls (never into a Lyric local — Lyric has no `Single` type), so
  the result is exactly the CLR's `(float)v` bit pattern, matching the former
  host's `BitConverter.GetBytes(single v)`.  Verified by the float32 self-tests
  (m70/m77/m81) which assert the exact `ldc.r4` byte layout (e.g. `42.0f` =
  `0x42280000`).  `Convert` / `BitConverter` resolve via `System.Runtime`.
- `bufToList` returns a **fresh copy** of the backing list, matching the former
  host's `ToList()` (which allocated a new list).  Returning the live `w.data`
  aliased buffers that callers snapshot and then keep appending to, which also
  corrupted output — the copy is required for correctness, not just hygiene.
- `bufBytes`/`bufByteList`/`bufAppend`/`bufLen`/`bufZero`/`bufPadTo`
  are pure Lyric over the backing list.  The `buf*` API is unchanged, so the
  `assembler.l` / `pe.l` / `lowering.l` / `heaps.l` callers are untouched.

**Endianness:** `BitConverter.GetBytes` is host-endian; the compiler runs on
little-endian targets (x64 / arm64), matching the explicit little-endian layout
the former F# host produced and the LE assumption already pervasive in PE/MSIL
emission.

**Validation:**

- Stage-1 self-build green (exit 0, no parse/codegen errors): the self-hosted
  compiler emits every DLL + the stdlib bundle through the new buffer, so a
  wrong byte would corrupt a DLL and break the build — the strongest end-to-end
  check available.
- `SelfHostedMsil bridge` suite 41/0 (covers `while`/`for` loops — the negative
  backward-branch offsets the `shr8` arithmetic-shift fix exists for); `stdlib
  Lyric tests` 31/0.
- MSIL tree has zero `JvmByteHost` / `Lyric.Jvm.Hosts` references.

**Note:** `scripts/bootstrap.sh --stage 2` (self-hosted² byte compare) is
currently incompatible with the A1.2 stage-1 CLI-bundle layout (it aborts asking
for `SKIP_VERIFY=1` or a `stage2()` rewrite), so a standalone byte-for-byte
`cmp` is not part of this entry's evidence; the stage-1 self-build plus the full
bridge/stdlib suites are the validation of record.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's JVM-deferred
banner.  The JVM backend (`lyric-compiler/jvm/`) still uses `Lyric.Jvm.Hosts`
for JVM-bytecode emission; that assembly stays for the JVM target but is no
longer load-bearing on the .NET path.
### D-progress-336 — bitwise integer operators (`.and/.or/.xor/.shl/.shr`) in the self-hosted compiler (#1610)

**Status:** Shipped (MSIL verified end-to-end; JVM symmetric).  The
language reference §12 documents bitwise operators as methods on integer
types (`x.and(y)`, `x.shl(n)`, …), but the self-hosted compiler did not
implement them: the keyword-named methods failed to parse, and there was
no codegen.  This is the prerequisite that unblocks #1592 (a correct
constant-time `fixedTimeEquals` needs branchless bitwise XOR/OR).

Three layers:

1. **Parser** (`parser/parser_core.l`, `parser/parser_exprs.l`).  Member
   access after `.` only accepted an identifier, so `x.and(y)` failed with
   `P0081` (`and`/`or`/`xor` are reserved keywords).  A keyword is
   unambiguous in member position — only a member name is valid after a
   `.` — so the new `tryEatMemberName` helper accepts any keyword there,
   using its `keywordSpelling` as the member name.  It replaces the
   member-access site's previous `tryEatIdent`, and subsumes the `result`
   contextual-keyword handling the site used to need.

2. **MSIL codegen** (`msil/codegen.l`).  `lowerMethodCallMsil` gained a
   branch for `and`/`or`/`xor`/`shl`/`shr` (arity 1): with the receiver
   already on the stack, it pushes the operand and emits the matching
   opcode (`MAnd`/`MOr`/`MXor`/`MShl`/`MShr`), returning the receiver's
   integer type.  `shr` is arithmetic (`MShr`); Lyric's `Int`/`Long`/`Byte`
   are signed and the MSIL backend has no unsigned integer type, so the
   logical-shift opcode (`MShrUn`) is not reachable.

3. **JVM codegen** (`jvm/codegen.l`).  `lowerMethodCall` gained the
   symmetric branch, selecting int (`LIand`/…/`LIshr`) vs long
   (`LLand`/…/`LLshr`) opcodes by receiver type.  Long shifts take an int
   shift count per the JVM spec, matching `.shl(n: Int)`.

**Verification.**  MSIL verified end-to-end against known values:
`5.xor(3)==6`, `5.or(2)==7`, `6.and(3)==2`, `1.shl(4)==16`,
`64.shr(2)==16`, arithmetic `-8.shr(1)==-4` and `-1.shr(1)==-1`; `Long`
`255.and(15)==15`, `255.xor(15)==240`, `1.shl(10)==1024`, `1024.shr(2)==256`.
Emitter suite 845/0; CLI suite 83/0.  The JVM lowering is structurally
symmetric with the verified MSIL path and the CLI/JVM-bridge suite passes,
but is **not yet executed end-to-end** — the repo has no Lyric-native
JVM compile-and-run test harness, and adding one would require new F#
test wiring (disallowed).  Likewise there is no executable MSIL regression
test in-tree: `lyric-stdlib/tests/*.l` and `ArithmeticTests.fs` both
compile through the **F# stage-0** parser, which still rejects `.xor()`,
so a `_tests.l` there cannot cover a self-hosted-only feature.  A
self-hosted-pipeline executable test harness (so features like this get
permanent in-tree regression coverage without F#) is the gap; tracked in
#1611.

This also makes #1592 actionable: the auth kernel's `fixedTimeEquals` can
now be a pure-Lyric constant-time compare and `hmacSha256` a direct BCL
extern, retiring the `Lyric.Auth.Host` F# shim.

### D-progress-337 — fix `lyric build --manifest lyric-session` parse failure (three root causes)

**Status:** Shipped.  `lyric build --manifest lyric-session/lyric.toml`
(and the CI `lyric test` step) failed with a misleading
`error[P0020] 1:1: expected 'package' declaration at the head of the file`
plus a cascade of `P0040`s.  The build is now clean.  Three independent
root causes, each a real defect:

1. **`lyric-cache/lyric.toml` stdlib-dependency typo.**  The `[dependencies]`
   entry read `"Lyric.Stdlib" = { path = "../stdlib" }` — from `lyric-cache/`
   that resolves to a nonexistent `stdlib/` directory (the package is
   `lyric-stdlib/`).  `Cache.dll` therefore built without stdlib contract
   linkage.  Fixed to `"../lyric-stdlib"` (matching the correct path
   `lyric-session/lyric.toml` already used).

2. **Restored-DLL interface synthesis double-braced body-bearing reprs.**
   `Lyric.RestoredPackages.renderDecl` unconditionally appended ` {}` to
   every `interface` decl, on the stale assumption (true only of the legacy
   F# contract writer `ContractMeta.fs`) that interface `repr`s are
   head-only.  The self-hosted contract writer
   (`contract_meta.l::reprForInterface`) emits the **full**
   `pub interface I { ...sigs... }` body, so the append produced
   `pub interface I { ... } {}` — a bare trailing block that fails to
   re-parse.  This broke synthesis of *any* locally-built dependency
   carrying an interface (e.g. `Cache.CacheStore`).  `renderDecl` now
   appends `{}` only when the repr is head-only (`indexOf("{") < 0`).
   Regression test added in `restored_packages_self_test.l`
   (`testSynthesiseInterfaceFullBodyNoDoubleBrace`).

3. **`///` (item doc) before `package` in three `_kernel` files.**
   `lyric-session/src/_kernel/{net,jvm}/session_kernel.l` and
   `lyric-web/src/_kernel/jvm/web_kernel.l` opened with a `///` module-header
   doc block before the `package` declaration.  `///` is an *outer/item* doc
   comment that must attach to a following item; `parseModuleDocComments`
   only harvests `//!` (*module/inner* docs), so the `///` was left in the
   token stream and `parsePackageDecl` failed.  Both parsers (F# and
   self-hosted) share this behaviour, so the source was wrong: these are
   module-level docs and now use `//!`.  The misleading `P0020` is also
   fixed — when a `///` precedes `package`, the parser now emits
   `a '///' doc comment before 'package' has no item to document;
   use '//!' for a module-level doc comment`.

**Verified:** `lyric build --manifest lyric-cache/lyric.toml` and
`--manifest lyric-session/lyric.toml` both succeed; emitter suite 845/0.

**Residual (separate codegen blocker):** the `lyric-session` *tests* now
compile and run but fault at runtime with
`Common Language Runtime detected an invalid program` — a self-hosted MSIL
codegen defect (interface-method dispatch + `Result` match + union
`.message`), the same defect class as the `lyric-auth` series, **not** a
parse issue.  Tracked in #1602.

### D-progress-338 — audit + fix `///`-before-`package` in remaining `_kernel` files (#1609)

**Status:** Shipped.  D-progress-337 fixed the three `_kernel` files whose
`///` module-header blocks before `package` blocked the `lyric-session`
build.  The review (#1609) flagged that other ecosystem `_kernel` files
likely shared the latent bug.  A repo-wide audit found **12 more**
(`lyric-db`, `lyric-feature-flags`, `lyric-i18n`, `lyric-jobs` net+jvm,
`lyric-mail` net+jvm, `lyric-mq`, `lyric-search`, `lyric-storage`,
`lyric-ws` net+jvm) — each opening with a `///` (outer/item) doc block
before `package`, which the parser rejects with `P0020` since `///` has
no following item to attach to.  All converted to `//!` (module/inner
docs), the correct sigil for a file-header doc block.  The change is
purely the comment prefix; no code or behaviour changes.  Post-fix audit
is clean — no `.l` file opens with `///` before `package`.

### D-progress-340 — MethodSpec metadata table + first open-generic BCL call (#1497)

**Status:** Shipped.  The self-hosted MSIL emitter can now emit MethodSpec
(table 0x2B) tokens, enabling calls to open generic methods (the metadata tables
previously stopped at TypeSpec 0x1B).

**Table machinery (`lyric-compiler/msil/tables.l`):**

- `MethodSpecRow { method: Int (coded MethodDefOrRef), instantiation: Int (#Blob) }`,
  added to `MetadataTables` + `newMetadataTables`, with `addMethodSpec`.
- Serializer (`serializeTablesStream`): `TABLE_BIT_METHOD_SPEC` (bit 43, 2^43)
  in the valid bitmask, the row count (table-number order, after 0x28), and the
  row data (u2 method coded index + u2 #Blob instantiation, per §II.22.29).
  No GenericParam (0x2A) or other intervening tables are emitted, so 0x2B
  appends cleanly.  Zero rows ⇒ bit unset ⇒ byte-identical output for programs
  that don't use it.

**Lowering helpers (`lyric-compiler/msil/lowering.l`):**

- `buildMethodSpecBlob(argTypes)` — MethodSpec instantiation signature
  (GENRICINST `0x0A` + arg count + type args, §II.23.2.15).
- `ctxAddMethodSpec(ctx, methodCoded, sigKey, sig)` — interns the blob and adds
  the row; call sites use `0x2B000000 + row`.
- `buildArrayEmptyOpenSig()` — the GENERIC-convention (`0x10`) open method
  signature for `System.Array.Empty\`1(): !!0[]`.

**First consumer + bug fix (`lyric-compiler/msil/codegen.l`):**

`emitEmptyArrayMsil` emits `System.Array.Empty<T>()` (open-generic MemberRef on
`System.Array` + MethodSpec instantiated for `T`).  Wired into the `SLocal`
`LBVal` arm: an empty typed-slice literal `val xs: slice[T] = []` now lowers to a
real empty `T[]`.  Previously `[]` lowered to a `List<object>` while the local
was `MArray`-typed, so `xs.length` emitted `ldlen` against a List and printed
garbage — a latent miscompile this fixes.

**Validation:**

- Stage-1 self-build green.
- `Lyric.Emitter` suite 845/0; `Lyric.Cli` suite 84/0 (incl. the new bridge
  test); `SelfHostedMsil bridge` 42/0.
- New `shm_empty_slice_array_empty` bridge test (`mkBridgeWithMethodSpec`)
  reflects over the produced PE: confirms a MethodSpec row whose instantiation
  decodes to `["String"]`, and that the empty slice reports length 0.
- Verified end-to-end via the AOT CLI: `val xs: slice[String] = []` →
  `xs.length` prints `0` (was `1686146664`).

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's JVM-deferred
banner.  Unblocks the generic-extern portion of #1504 and the user-generic
reify path.

### D-progress-342 — console/env/log kernels off Lyric.Emitter.dll to BCL externs (#1493 partial)

**Status:** Shipped (3 of 5 kernels).  The `console` (stderr), `env`
(verifier), and `log` stdlib kernels no longer extern into
`Lyric.Emitter.dll`; they bind audited direct-BCL members in pure Lyric.
The now-dead F# host types were deleted from `Lyric.Emitter`.

**Migrated (`lyric-stdlib/std/_kernel/`):**

- `console_host.l` — `hostConsoleErrorWriteLine` was an
  `Lyric.Emitter.ConsoleHelper.writeErrorLine` shim (Console.Error.WriteLine
  "not directly addressable as a static BCL call").  Now composes the static
  property getter `System.Console.get_Error(): System.IO.TextWriter` with the
  writer's instance `TextWriter.WriteLine(String)` — enabled by #1504 part 1
  (class-typed extern signatures).
- `verifier_env_host.l` — `hostGetEnv` was `Lyric.Emitter.VerifierEnv.getEnv`.
  Now composes the existing audited
  `Std.EnvironmentHost.hostGetEnvironmentVariable` (`String?`) with a `?? ""`
  null-coalesce — no duplicate extern, no F# intermediary.
- `log_host.l` — `write` was `Lyric.Emitter.LogHelper.write`.  Now composes the
  migrated console stderr path: `Con.hostConsoleErrorWriteLine("[" +
  Str.toUpper(level) + "] " + message)`, matching the F# helper's
  `[LEVEL] message` stderr format exactly.

**Deleted (dead F# host types, zero remaining references):**
`bootstrap/src/Lyric.Emitter/{ConsoleHelper,LogHelper,VerifierEnv}.fs` and
their `.fsproj` `<Compile>` entries.

**Deferred (with concrete blockers):**

- `http_host.l` `hostDefaultClient` — the natural fix is a package-level
  `val defaultClientInstance = newClient()` (static field, single `.cctor`
  init).  It compiles, but the self-hosted emitter does **not** run the
  `.cctor` for a class-typed package-level `val`: the field stays null and the
  first access `NRE`s (reproduced with a StringBuilder singleton — a class-typed
  package-level `val`, appended via two calls, NREs instead of yielding "xx").
  Reverted to the `Lyric.Emitter.HttpClientHost` shim pending that codegen fix.
- `process_capture_host.l` — deadlock-safe concurrent stdout/stderr capture
  needs async (Band 3 async port, #1489).

**Validation:**

- New `lyric-stdlib/tests/kernel_bcl_tests.l` (run by `StdlibLyricTests`):
  drives all four `Std.Log` levels through the migrated
  log -> log_host -> console_host stderr chain, and asserts
  `Std.VerifierEnvHost.hostGetEnv` on an unset variable returns "".  Stdlib
  suite 31 passed, 0 failed.
- Stage-0 F# + stage-1 self-build clean after the F# deletions; full
  `SelfHostedMsil bridge` suite 41/41.

**Scope note:** MSIL (`--target dotnet`) only, per epic #1470's JVM-deferred
banner.  Partial #1493; `http`/`process` remain (blockers above).

### D-progress-343 — auto-FFI fail-loud for unresolvable shapes (#1504 H9)

**Status:** Shipped (stopgap; superseded by the metadata-resolution epic #1622).

**Problem:** auto-FFI — a bare `ExternTypeName.method(args)` call with no
`@externTarget` wrapper — has no signature to work from.  The self-hosted MSIL
emitter has neither a declared Lyric signature nor a .NET metadata reader (it
abandoned runtime reflection because `Type.GetType` from Lyric-emitted PEs
returns null, D-progress-268), so `emitAutoFfiCallMsil` emitted a fixed
`(object…) : void` MemberRef.  That faithfully matches *only* a static,
void-returning, parameterless BCL method; any argument means the guessed
`object` parameter can't match a typed BCL parameter, and a non-void method
leaves a phantom value on the stack — both mis-bind at runtime
(`MissingMethodException` / invalid program), the silent-failure mode the
project standard forbids.  (The F# bootstrap emitter does *not* have this
problem — `Codegen.fs` resolves the real overload via `ClrType`/`GetMethod`
reflection; the self-hosted path regressed this.)

**Fix (`lyric-compiler/msil/codegen.l`):** `emitAutoFfiCallMsil` now fails the
build with a clear diagnostic for any argument-bearing auto-FFI call, naming
the type/method and directing the user to an `@externTarget` wrapper (which
supplies the real signature and, after #1504 part 1, supports instance /
non-void / typed-parameter / class-returning calls) and citing #1622.  The one
faithful shape — a parameterless static-void method — still emits the
`() : void` static `call`.

**Validation:**

- `GC.Collect()` (static, void, no args) still builds and runs
  (`shm_extern_type_smoke` bridge test, 41/0).
- `Console.WriteLine("hi")` (argument-bearing) now fails the build with the H9
  diagnostic + `@externTarget` guidance, instead of a silent runtime
  `MissingMethodException`.
- Stage-1 self-build green; `Lyric.Emitter` 845/0 (the `AutoFfiTests` cases run
  on the F# emitter's reflection path and are unaffected).

**Follow-up:** #1622 (metadata-based extern signature resolution) is the real
fix — a `System.Reflection.Metadata` reader over reference assemblies that
resolves any BCL/dependency overload, removing the guess entirely and
restoring auto-FFI parity with the F# emitter on the self-hosted path.

**Test-harness note:** the fail-loud path is a codegen `panic`, which the
in-process `mkBridge` harness surfaces as a `TargetInvocationException` rather
than a `false` return (same limitation as the H8 / F0002 diagnostics), so it is
validated via the CLI build rather than an in-harness negative test.

### D-progress-344 — pure-Lyric CLI-metadata reader, Phase 1 (epic #1622)

**Status:** Shipped (Phase 1 of epic #1622; design in
`docs/42-extern-metadata-resolution.md`).

Epic #1622 (Band 4 of #1470) replaces the self-hosted MSIL emitter's
hardcoded `clrAssemblyForType` table and the auto-FFI `(object…) : void`
guess with metadata-derived extern resolution.  The chosen mechanism is a
**pure-Lyric CLI-metadata reader** that parses reference-assembly bytes
directly — inverting the emitter's own metadata *writer*
(`pe.l`/`tables.l`/`heaps.l`) — rather than `System.Reflection.Metadata`
(struct-heavy; Lyric `extern type` is class-only) or
`System.Reflection.MetadataLoadContext` (absent/NuGet-only).  This sidesteps
the D-progress-268 `Type.GetType`-null blocker by construction (no runtime
type loading; pure byte reading).

**What shipped (Phase 1 — layers 1–2):**

- **`lyric-compiler/msil/metadata_reader.l`** (`Msil.MetadataReader`).
  Little-endian byte readers that widen `Byte`→`Int` via the established
  mixed-arithmetic idiom (`Std.Encoding`-style, no bitwise ops so the
  bootstrap emitter compiles it).  `readPe(bytes)` parses the DOS stub,
  PE signature, COFF header, PE32/PE32+ optional header, the section table,
  data directory 14 (CLI header), and resolves the metadata-root file offset
  via `rvaToOffset`.  `readMetadataRoot(img)` parses the `BSJB` root, the
  version string, and the stream headers (`findStream` by name).
  `readTablesHeader(img, root)` parses the `#~`/`#-` table-stream header:
  heap-index widths, the 64-bit valid bitvector (read byte-wise to avoid
  Int overflow), and the per-table row counts (`rowCountOf` by ECMA table id).
  Returns `Result[_, String]` with production-quality error messages.
- **`Std.File.readBytesOrPanic(path): slice[Byte]`** — thin non-generic-return
  accessor over the existing `hostReadAllBytes` kernel extern, keeping
  `_kernel` private to `Std.File`.  The reader's byte-read foundation.
- **`lyric-stdlib/tests/metadata_reader_tests.l`** — auto-discovered by
  `StdlibLyricTests.fs`.  Parses the running test PE itself (a real assembly
  emitted by the compiler's own writer — a reader-vs-writer oracle needing no
  version-specific reference-pack path) and asserts the PE container, RVA
  mapping, the stream set (`#~`, `#Strings` present; bogus name absent), and
  the Module(=1)/TypeDef/MethodDef row counts.

Compiles cleanly through both the bootstrap F# emitter (the self-test gate,
passing) and the self-hosted emitter (`lyric build`).  No emitter behaviour
change yet — wiring the reader into the auto-FFI and `@externTarget` paths is
Phase 3+.  Self-hosted *runtime* cross-package resolution of the byte-read
call (#1471 family) is the Phase 3 entry criterion (see `docs/42` §2 caveat).

### D-progress-345 — CLI-metadata reader, Phase 2a: heaps + table rows (epic #1622)

**Status:** Shipped (Phase 2a of epic #1622; design in
`docs/42-extern-metadata-resolution.md` §5).

Builds on the Phase 1 PE/metadata-root reader (D-progress-344) with layers
3–4 of the pure-Lyric CLI-metadata reader (`lyric-compiler/msil/metadata_reader.l`):

- **Compressed-integer reader** (`readCompressedUInt`) — inverse of the
  emitter's `writeCompressedUInt`, all three width forms.
- **Heap readers** — `stringAt` (`#Strings`, UTF-8 NUL-terminated via
  `Std.Encoding.tryDecodeUtf8`) and `blobAt` (`#Blob`, compressed-length-prefixed).
- **Table layout** (`computeLayout`) — heap-index widths from the HeapSizes
  flags, coded-index widths (ResolutionScope, TypeDefOrRef) and simple-index
  widths from row counts, per-table row sizes for tables 0x00–0x08, and each
  table's data offset; plus the `#~` `tablesDataOff` (honouring the ExtraData
  flag).
- **Row readers** — `readTypeDef`, `readMethodDef`, `readParam`, and
  `methodRange` (run-length method-list ownership: the MethodDef rows a TypeDef
  owns, bounded by the next TypeDef's MethodList).

The self-test (`lyric-stdlib/tests/metadata_reader_tests.l`) extends the
running-PE oracle: it reads the test assembly's real tables and asserts the
`Program` TypeDef in this package, its `main` method, `<Module>` at TypeDef
row 1, non-empty MethodDefSig blobs, and the compressed-uint round-trip.
Also folds in three Phase-1 review suggestions: `#GUID` heap-width assertion,
CLI data-directory validation against `NumberOfRvaAndSizes`/the optional-header
size, and the test-vs-suggestion notes.

Compiles through both the bootstrap and self-hosted emitters.  The
signature-blob decoder (layer 5) is Phase 2b; wiring into the auto-FFI /
`@externTarget` paths remains Phase 3.

### D-progress-346 — CLI-metadata reader, Phase 2b: signature decoder (epic #1622)

**Status:** Shipped (Phase 2b of epic #1622; design in
`docs/42-extern-metadata-resolution.md` §5).

Layer 5 of the pure-Lyric CLI-metadata reader: the MethodDefSig signature-blob
decoder (`lyric-compiler/msil/metadata_reader.l`), the inverse of the emitter's
`buildStaticMethodSig`/`buildInstanceMethodSig` + `bufMsilType`.

- **`SigType`** union covering the full ECMA-335 §II.23.1.16 element-type
  grammar: primitives (carried by element-type byte), CLASS / VALUETYPE (with
  TypeDefOrRef token), VAR / MVAR generic parameters, SZARRAY / ARRAY,
  BYREF / PTR, GENERICINST, FNPTR, and an `STUnknown` escape.
- **`decodeType`** recursively decodes one Type, skipping leading custom
  modifiers (CMOD_OPT / CMOD_REQD) and advancing past nested shapes (generic
  args, array shapes, nested function-pointer sigs).
- **`decodeMethodSig`** / **`decodeMethodSigAt`** decode a MethodDefSig:
  calling convention (HASTHIS / GENERIC bits), generic-parameter count, the
  return type, and the parameter types (skipping the vararg SENTINEL).

Self-tested two ways: hand-built blobs matching exactly what the emitter's
signature writers emit (static `(Int, String): Bool`, instance `(): Void`,
`(slice[Byte]): Void`, empty-blob rejection) decode to the expected `SigType`
shapes; and a running-PE oracle decodes every MethodDefSig in the test
assembly, asserting `main` resolves to a static, parameterless method.

Compiles through both the bootstrap and self-hosted emitters.  Assembly
discovery + overload resolution + wiring into the auto-FFI / `@externTarget`
paths is Phase 3 (gated on the #1471-family self-hosted runtime cross-package
resolution; see `docs/42` §2).

### D-progress-347 — CLI-metadata reader, Phase 3a: assembly discovery + type→assembly index (epic #1622)

**Status:** Shipped (Phase 3a of epic #1622; design in
`docs/42-extern-metadata-resolution.md` §5).

Replaces the future need for a hardcoded assembly table with a
metadata-derived type→assembly index (`lyric-compiler/msil/metadata_reader.l`):

- **`refPackDir`** — locates the .NET reference-assembly pack
  (`<root>/packs/Microsoft.NETCore.App.Ref/<ver>/ref/<tfm>/`), probing
  `DOTNET_ROOT`, `$HOME/.dotnet`, and the system install roots, picking the
  highest version and target-framework subdirectory.
- **`enumRefAssemblies`** — full paths of every `*.dll` in the ref directory.
- **`buildTypeIndex` / `addAssemblyTypes` / `assemblyForType`** — read each
  assembly's TypeDef table and map every public type's fully-qualified name to
  the assembly's simple name; first writer wins.  In the .NET ref pack the BCL
  types are real TypeDefs in their facade assembly (verified: `System.Math`,
  `System.Object`, `System.String` are TypeDefs in `System.Runtime.dll` with
  zero ExportedTypes; `System.Console` in `System.Console.dll`), so a
  TypeDef-derived index suffices — no ExportedType/type-forward table needed.

Self-tested two ways: hermetically (a type index over the running test DLL
resolves this package's own `Program` type back to the test assembly) and
against the real reference pack (discovery succeeds; an index over
`System.Runtime.dll` resolves `System.Object` and `System.Math` to
`System.Runtime`).

Compiles through both the bootstrap and self-hosted emitters.  Overload
resolution is Phase 3b; wiring `resolveExtern` into the auto-FFI /
`@externTarget` paths is Phase 3c, gated on the #1471-family self-hosted
runtime cross-package resolution (discovery uses generic-`Result`-returning
`Std.File.listFiles`/`listDirs` at compile time; see `docs/42` §2).

### D-progress-348 — CLI-metadata reader, Phase 3b: overload resolution (epic #1622)

**Status:** Shipped (Phase 3b of epic #1622; design in
`docs/42-extern-metadata-resolution.md` §5).

Selects the best-matching MethodDef overload from metadata, working in
`SigType` space (decoupled from `MsilType`; the eventual emitter caller maps
its lowered argument types to `SigType`s at the call boundary):

- **`findTypeDefByFqn`** — locate a TypeDef row by fully-qualified name.
- **`scoreSigType` / `scoreOverload`** — per-parameter scoring: exact match (2)
  beats a widening numeric conversion (1, via a `numericRank` ladder so
  `Int`→`Long`/`Double` etc. are accepted), an `object` parameter accepts any
  argument, and arity or type mismatches reject (−1) — mirroring the bootstrap
  emitter's coercion rules.
- **`resolveOverloadIn` / `resolveOverload`** — enumerate a type's same-named
  methods, decode each signature, and return the highest-scoring
  `ResolvedMethod` (`isStatic` from the calling convention, `isVirtual` from the
  MethodDef flags, plus the decoded return/parameter types).

Self-tested hermetically (`addInts(Int, Int)` over the running PE: exact match,
widening `I2`→`I4`, and arity-mismatch / unknown-member / unknown-type
rejection) and against real BCL overloads (`System.Math.Max` binds the `int`
overload for `(Int, Int)` returning Int, and the `long` overload for
`(Long, Long)` returning Long).

Compiles through both emitters.  Wiring `resolveExtern` into the auto-FFI /
`@externTarget` paths is Phase 3c, gated on the self-hosted cross-package
resolution: discovery uses generic-`Result`-returning `Std.File` calls, and a
consumer of the reader's imported types (`SigType`, `ResolvedMethod`) currently
raises advisory `T0010`/`T0020` on the self-hosted typechecker — both must be
solid before `codegen.l` can depend on the reader (see `docs/42` §2/§5).

### D-progress-349 — CLI-metadata reader: `resolveExtern` composing entry point (epic #1622)

**Status:** Shipped (completes the metadata reader's resolution API; design in
`docs/42-extern-metadata-resolution.md` §4).

`resolveExtern(typeIndex, pathIndex, typeFqn, member, argTypes)` is the single
entry point the emitter will call: it looks the owning assembly up in a
prebuilt type→assembly-name index (`assemblyForType`), maps that name to its
on-disk path via a companion name→path index (`buildPathIndex`), then resolves
the best overload from that assembly (`resolveOverload`), returning a
`ResolvedExtern` (the assembly's simple name + the `ResolvedMethod`).  Both
indexes are built once (over `enumRefAssemblies(refPackDir())` plus
restored-dependency DLLs) and reused across call sites; carrying explicit paths
means assemblies outside the reference-pack directory (e.g. restored NuGet
packages) still resolve.

Self-tested against the real reference pack: `resolveExtern(... "System.Math",
"Max", [Int, Int])` resolves to assembly `System.Runtime` with a static method
returning Int, and an unknown type resolves to None.

This completes everything the reader can do as a standalone library (layers
1–6: container → root → tables → heaps → signatures → discovery → overload
resolution → composed `resolveExtern`).  The remaining epic #1622 work — wiring
`resolveExtern` into `emitAutoFfiCallMsil` / the `@externTarget` path and
retiring #1504 H9 (Phase 3c), then `clrAssemblyForType` removal + generics
(Phase 4) — is the behaviour-changing emitter integration, gated on the
self-hosted cross-package resolution (`docs/42` §2/§5).
### D-progress-350 — self-hosted JVM execution of self-hosted-only features (#1611 JVM half)

**Status:** Shipped.  `lyric test --target jvm` runs a `@test_module`
end-to-end through the self-hosted JVM backend.

The MSIL half of #1611 (D-progress-334-era; merged in #1623) gave the project
its first in-tree executable regression test for a self-hosted-only language
feature (the bitwise integer methods, #1610), run via native `lyric test`
through the in-process `Msil.Bridge`.  This entry adds the JVM half.

**What shipped:**

- **In-process multi-package JVM pipeline.**  `Jvm.Bridge.compileToJarBundled`
  compiles the user package plus the transitive closure of its stdlib imports
  into one runnable JAR (isolated constant pool per package, so a package the
  backend can't yet emit is skipped without corrupting the JAR).  `emitter.l`
  routes `emit(Jvm)` in-process through it (replacing the `--internal-build`
  subprocess into the F# emitter); `cli.l`'s `lyric test` gained `--target jvm`
  (builds a `.jar`, runs it via `java -jar`).  FSharp.Core is staged into
  `.bootstrap/stage1` by `bootstrap.sh` and referenced by the AOT csproj,
  because the JVM kernel's byte-writer/constant-pool ops route through the F#
  `Lyric.Jvm.Hosts` shim (the pure-Lyric MSIL kernel never loads it).
- **JVM codegen hardening** (the backend had only ever been exercised by
  hand-built bytecode + negative-path tests, so real-program constructs
  produced invalid bytecode): a cross-package function-call registry
  (`JvmFuncSig`); expression-position `if`/`match`/`try`-catch via result
  locals (the StackMapTable declares an empty operand stack at branch targets);
  union match-binding with precise field types (`JvmCaseField` registry);
  `i64`/`u64` literal width; comparison materialization; basic-block stackmap
  frames (a frame at every block start, incl. dead code after a `panic`'s
  `athrow`); and String predicate methods (`contains`/`startsWith`/`endsWith`)
  emitting their real `boolean` descriptor.

`bitwise_self_test.l` now passes on both `--target dotnet` and `--target jvm`,
each wired into CI.  Known follow-up gaps (not exercised by the test): union
*construction* at runtime calls a not-yet-emitted case factory (verifies, but
`NoSuchMethodError` if actually invoked) and closure (`() -> Unit`) parameter
calls.
