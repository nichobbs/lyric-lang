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
- No `List[T]` / `Map[K, V]` collections — the natural next step.  A
  pure-Lyric `Std.Collections` slice-grow API was scoped but punted
  pending generics polish.
