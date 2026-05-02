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
| `@projectionBoundary` cycle handling | not started | — |
| Real async state machines | deferred | — |
| Reflection-driven FFI | not started | — |
| `@stubbable` stub builder synthesis | not started | — |
| Stdlib expansion (collections, time, json, http) | partial | — |

### Phase 3 / 4 / 5
Not started — gated on Phase 2 completion.

---

## Active session decisions

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
| 11. `for` loops + nested-local promotion through loop bodies | Phase B++ |
| 12. `try`/`catch` / `defer` regions that span an `await` | Phase B++ |
| 13. Async impl methods (Phase A — await-free body) | **Shipped (D-progress-038)** |
| 14. Async impl methods (Phase B — body awaits) | **Shipped (D-progress-040)** |
| 15. Async generics | Phase B++ |
| 16. `CancellationToken` propagation | Phase C |

Tier 5 items (`Std.Http` cancellation/timeouts, `wire` scoped
lifetimes) are gated on Phase C landing.  Tier 6 items (CST
formatter, format5+, Regex RE2, C4 phase 2/3) are on-demand.
