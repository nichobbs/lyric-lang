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
