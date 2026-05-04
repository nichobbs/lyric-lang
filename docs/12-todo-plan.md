# 12 — Priority-ordered TODO

What's still left after PR #41 (native AOT) merged.  Items are grouped by
priority band (most urgent first); within a band they're roughly ordered by
likely-implementation-effort.  This doc is **not** append-only — entries
move out as they ship and into `docs/10-bootstrap-progress.md`.

The phased plan in `docs/05-implementation-plan.md` is the strategic view;
this doc is the *next-N-sessions* tactical view.

---

## Band A — active queue (this session and the next)

### A1. ~~Allocating iter helpers on `slice[T]`~~ — shipped

Landed in this branch (`feat: allocating iter helpers ...`).  See
`docs/10-bootstrap-progress.md` D-progress-015 for the writeup.

### A2. ~~`@stubbable` stub builder synthesis~~ — shipped (bootstrap-grade)

Landed in this branch.  Bootstrap covers single-arity stubs with
constant return values; recording / failing / argument-matching DSL
deferred.  See `docs/10-bootstrap-progress.md` D-progress-016.

### A3. ~~LSP server (skeleton)~~ — shipped (bootstrap-grade)

`compiler/src/Lyric.Lsp/` ships a console-app `lyric-lsp` that speaks
push diagnostics over JSON-RPC stdio.  Initialize, didOpen,
didChange (full sync), didClose, hover (placeholder), shutdown,
exit are all wired.  The server lifts parse + type-check and
publishes the resulting diagnostics; no IL emission.  See
`docs/10-bootstrap-progress.md` D-progress-017.

Real type-resolution-on-position hover, go-to-definition, completion,
and incremental sync are Phase 3 follow-ups.

---

## Band B — short-term follow-ups (next 2–3 sessions)

### B1. ~~`import X as Y` alias~~ — shipped

Both flavours work:
- `import Std.Collections.{newList as mkList}` — selector alias.
- `import Std.Collections as Coll` — package alias (`Coll.foo`,
  `Coll.Type[T]`).

See `docs/10-bootstrap-progress.md` D-progress-018.

### B2. ~~`@projectionBoundary` cycle handling~~ — shipped

Cycle detection lands in this branch.  A `@projectable` cycle without
an `@projectionBoundary` marker is now a structured T0092 diagnostic
naming the cycle path.  See `docs/10-bootstrap-progress.md`
D-progress-019.

The full `asId` rename semantic from §7.3 / D026 (project as the
underlying ID type) is still **bootstrap-grade**: today
`@projectionBoundary` keeps the source opaque type in the view rather
than substituting the source's id field type.  Promoted to follow-up.

### B3. ~~`out`/`inout` on record fields and array elements~~ — shipped

Both array elements (`xs[i]`) and record fields (`r.f`) work as `out`
parameter targets via `Ldelema` / `Ldflda`.  The `inout`-of-record
field-store case (`func bump(c: inout Counter): Unit { c.count = ... }`)
also works now via the new `SAssign EMember` branch in codegen that
walks `ctx.Records` to find the `FieldBuilder` directly (sidestepping
`Type.GetField` on an unsealed TypeBuilder).  See
`docs/10-bootstrap-progress.md` D-progress-022.

### B4. ~~`Std.File`: `Result[Unit, IOError]`~~ — shipped

`Std.File.writeText` and `Std.File.createDir` now return
`Result[Unit, IOError]` directly (no more `Bool` stand-in).  The
underlying fix in `Codegen.fs` makes the `()` literal lower to a real
`ValueTuple` value via `Ldloca + Initobj + Ldloc`, replacing the
broken `Ldc_I4 0` shape that caused `InvalidProgramException` on
generic-Unit instantiations.  See `docs/10-bootstrap-progress.md`
D-progress-020.

### B5. ~~DA propagation through `match` arms~~ — shipped

`daExpr` now handles `EMatch` and `EBlock`.  Match arms join via set
intersection — same shape as `if`/`else` — so a function that assigns
an `out` param in every arm has the param marked definitely-assigned
after the match.  See `docs/10-bootstrap-progress.md` D-progress-021.

### B6. ~~`format5..N`~~ — shipped

`format5` and `format6` shipped (D-progress-035).  Both type-check
in `ExprChecker.fs` (one extra `TyError` payload per arity) and
codegen routes through new `Lyric.Stdlib.Format::Of5`/`Of6` static
helpers.  Format arities beyond 6 wait for a varargs story.

---

## Band C — Phase 2/3 polish (medium term)

### C1. ~~`parseInt` / `parseLong` / `parseDouble` collapsing into `tryParse`~~ — shipped

`parse.l` is now built directly on the BCL's `Int32.TryParse` /
`Int64.TryParse` / `Double.TryParse` / `Boolean.TryParse` family via FFI
out-params (D-progress-014).  The IsValid + Value pair on the host
side is gone for parse.

A unified generic `tryParse[T]` requiring type-driven BCL-method dispatch
is a separate follow-up (would need codegen to pick the right BCL
TryParse method based on the closing `T`).  Per-primitive
`parseOptInt` / `parseOptLong` etc. work fine for the bootstrap.

### C2. ~~Real async state machines~~ — shipped

The full C2 chain landed: Phase A (D-progress-033), Phase B
(D-progress-034), every Phase B+/B++/B+++ extension across
D-progress-036 through 058, Phase C (D-progress-068/069/071), and
the Tier-4 close-out work — generic async (D-progress-075) +
spill-prior-siblings ordering (D-progress-076) — landed in PR #62.
Stack-spilling for nested awaits is D-progress-074.  The only
async sub-piece left is generic instance impl methods, which
gates on the underlying generic-impl-methods feature gap (Tier 6
#16) rather than on async work.

### C3. ~~Range-subtype symbolic bounds~~ — shipped

D-progress-025: a `Lyric.TypeChecker.ConstFold` module exposes
`tryFoldInt` (literals, named-const lookup with cycle detection,
`+ - * / %` arithmetic with overflow checks).  Both the well-
formedness checker (T0090 / T0091 / new T0093) and the emitter's
runtime range-check IL consume the folded value, so symbolic
bounds like `type Age = Int range MIN_AGE ..= MAX_AGE` no longer
escape the check.

### C4. ~~Reflection-driven FFI~~ — shipped

Two-phase rollout: D-progress-026 (phase 1, strict-match auto-FFI
that resolves a name when exactly one BCL overload matches by
`(name, arg-arity, exact-type-match)`) and D-progress-061 (phase 2,
score-based matching with principled coercion rules).  Users can
now write `xs.add(item)` against a BCL `List<T>` directly without
an `@externTarget` declaration.  Phase 3 special shapes
(by-ref structs, `Span<T>`, `params T[]`, extension methods) lands
on demand under Tier 6.

### C5. ~~Stdlib expansion: Time, Json, Http~~ — shipped (Regex deferred)

- `Std.Time` — ISO-8601, `Duration` arithmetic, IANA tz lookup
  shipped via D-progress-027 / D-progress-039.
- `Std.Json` — `@derive(Json)` source-gen with primitive / Option /
  nested-record / slice support shipped via D-progress-030 /
  D-progress-043..046 / D-progress-060.  `fromJson` covers slice
  + nested-record cases.
- `Std.Http` — full surface (cancellation, timeout, redirect
  policy, headers) shipped via D-progress-052 / D-progress-070.
- `Std.Regex` — RE2 engine still deferred (Tier 6); no Lyric
  program is yet exposed to attacker-controlled regex input that
  would force the upgrade off the BCL ECMA backtracker.

### C6. ~~Wire blocks (compile-time DI)~~ — shipped

D-progress-028 shipped the bootstrap-grade wire (singleton +
`@provided` + `expose` + multi-wire + topo-sort + cycle detection).
D-progress-072 added scoped wire lifetimes — `scoped[Request]`
synthesises per-scope factories plus a singleton-references-scoped
lifetime checker, gated on the `AsyncLocal<T>` ambient cancellation
plumbing from D-progress-071.

### C7. Formatter (`lyric fmt`)

M3.3.  Need a printer that round-trips the AST without losing
information.  Phase 1 parser doesn't preserve trivia; the printer
needs either a CST layer or a re-parse.  Lowest-priority Tier 6
item per the C7 decision (D-progress-029) — the CST layer pays
off most when LSP / refactor tools come online, so the formatter
itself isn't on the v1.0 critical path.

### C8. ~~Package manager (`lyric.toml`)~~ — shipped

D-progress-031 shipped the embedded `Lyric.Contract` managed
resource on every emitted assembly (the cross-package contract
metadata format).  D-progress-077 shipped the `lyric.toml`
manifest plus `lyric publish` / `lyric restore` wrappers around
`dotnet pack` / `dotnet restore`.  The build-time consumer of
restored Lyric packages — wiring `lyric build`'s import resolver
to read each restored DLL's contract resource instead of walking
the in-tree stdlib — is the remaining loop, tracked under Tier 6.

### C9. ~~`lyric doc` documentation generator~~ — bootstrap shipped

`lyric doc <source.l> [-o out.md]` walks the parsed AST and emits
Markdown describing the file's `pub` surface — package header,
module-level doc, per-item signature + `///` body for every `pub func`,
`pub record`, `pub union`, `pub enum`, `pub opaque type`,
`pub interface`, `pub distinct type`, `pub type`, `pub const`.

Cross-file roll-ups, anchor links, doctest extraction are
**bootstrap-grade scope** — promoted to follow-ups.  See
`docs/10-bootstrap-progress.md` D-progress-023.

---

## Decisions needed before further Band C work

The remaining Band C items each require a design decision before they
can be implemented.  Each is too large for a single-shot session
without input.

### C2 — real async state machines

The bootstrap currently lowers `async` / `await` to a blocking
`.GetAwaiter().GetResult()` shim (M1.4 D035).

**Decision (D-progress-024)**: ship hand-rolled state-machine IL.

For each `async func`, the emitter synthesises an `IAsyncStateMachine`
struct/class with a state field, locals-that-cross-`await` promoted to
fields, and a `MoveNext` that dispatches on state.  Each `await`
saves state, calls
`AwaitUnsafeOnCompleted`, and returns.  Exceptions route through
`AsyncTaskMethodBuilder<T>.SetException`; the function returns the
builder's `Task<T>`.

**Rationale.**  AOT-friendly (BCL types only, no runtime pin), the
shape the language reference promises, the only path to real
non-blocking concurrent I/O without adopting a thread-pool fake.
Option (b)'s F# `task { }` builder is a compile-time CE expansion,
not a runtime-importable API — it isn't really viable as stated.
Option (c) (defer) ships v1.0 with ornamental async that breaks under
fan-out workloads; not acceptable for a v1.0 promise.

**Bootstrap-grade scope.**  Cancellation tokens and structured
concurrency scopes follow once the basic state-machine lowering is
stable.  Try/catch and defer regions that span an `await` are the
two trickiest edge cases — the existing defer / try-leave plumbing
(D-progress-001) gives us a starting point but each await inside a
try region needs the state-machine restore to enter the protected
region correctly.

### C3 — range-subtype symbolic bounds

`type X = Int range MIN ..= cap` requires constant folding to evaluate
the symbolic bounds at compile time before the well-formedness checker
runs (D-progress-003).

**Decision (D-progress-025)**: ship named-constant + arithmetic folding.

A new `Lyric.TypeChecker.ConstFold` module exposes
`tryFoldInt : SymbolTable -> Expr -> Result<int64, FoldError>`.  The
folder walks:

- `ELiteral (LInt n)` → the literal
- `EPath { Segments = [name] }` resolving to a `DKConst` symbol →
  recurse on the const's `Init` (with cycle detection via a set of
  names currently being resolved)
- `EBinop` for `+ - * / %` and `EPrefix` for unary `-` over folded
  operands, with checked-arithmetic overflow detection

Two call sites change: the range-bound well-formedness checker
(T0090 / T0091) calls the folder so symbolic bounds are validated
against the folded value, and the emitter's runtime range-check
IL emission uses the folded constant directly.

**Rationale.**  Catches the practical patterns (`MIN_AGE ..= MAX_AGE`,
`0 ..= PAGE_SIZE * MAX_PAGES - 1`) without opening the door to "what
counts as a pure function call?" — the design space option (c) would
expand into.  Effort is bounded (~300 LOC + tests, ~half-session).
A new T0093 fires when a bound expression can't be folded, replacing
today's silent escape.

**Out of scope.**  Function calls in bounds (`max(a, b)`), `if`-in-
bounds, float literals, mixed-width arithmetic.  All of those land
when option (c)'s full pure-expression folder ships, gated on a
real use case.

### C4 — reflection-driven FFI

Today's FFI requires a per-method `@externTarget` declaration.  Auto-
FFI would let the codegen resolve `xs.add(item)` against the BCL type
directly, dropping the boilerplate.

**Decision (D-progress-026)**: ship aggressive auto-FFI with phased
resolver complexity.

The reflection happens at Lyric *compile time* — `System.Reflection`
on the F#-side codegen looks up `List<T>::Add`, the emitter writes a
fully-resolved `Callvirt` MethodRef into the user's PE.  AOT
trimming sees the static reference and roots it the same way it
roots a `@externTarget`-declared method.  The Cecil contract-rewrite
already handles the assembly-identity story.

**Phased rollout.**

- Phase 1 — strict match.  Resolve a name only when there's exactly
  one viable overload by `(name, arg-arity, exact-type-match)`.
  Ambiguous calls still need `@externTarget` to disambiguate.
- Phase 2 — score-based matching with principled coercion rules.
  Each Lyric→CLR coercion (Int↔int/long/double, String↔string,
  records↔class refs, unboxing/boxing, widening, nullable conversion)
  contributes a "distance" score; the resolver picks the lowest-cost
  match.  Tie → ambiguity diagnostic listing the candidates.
- Phase 3 — special shapes: out-params (already in via D-progress-014),
  by-ref structs, `Span<T>` / `ReadOnlySpan<T>`, default args,
  `params T[]`, extension methods, explicit interface
  implementations.

**Rationale.**  AOT-friendly (compile-time-resolved refs, no runtime
reflection in user PE), big ergonomic win for the common case, and
the explicit `@externTarget` route stays available as the escape
hatch when the resolver can't disambiguate.

**Out of scope.**  Wrong-overload silent failures need a "show all
viable candidates" diagnostic mode and IDE completion against the
auto-discovered surface — both Phase 4 work.

### C5 — stdlib expansion

Four sub-areas, each independent.

**Decision (D-progress-027)**: ship Json source-gen + Time
expansion in this band; defer Http and Regex.

**Json source-gen.**  Replace today's stub with a compile-time
source-generator pass: walk every `pub record` annotated
`@derive(Json)` and synthesise a per-record `toJson(self): String`
method emitting RFC 8259-conformant output.  Inverse `fromJson`
synthesised when the record's fields are all reconstructable.  No
runtime reflection — the generated code reads each field via the
existing record FieldBuilders and produces literal JSON.  AOT-clean
because every reachable record is rooted by the synthesised method.
Aligns with the `derive`-driven philosophy from D016 / `@stubbable`
and `@projectable` derives.

**Time expansion.**  Three concrete adds on top of the existing
`Std.Time`:
- `Time.zoneOf(id: in String): Result[TimeZone, IOError]` via
  `System.TimeZoneInfo.FindSystemTimeZoneById` (FFI).
- `Instant.fromEpochMillis(n: in Long): Instant` / `Instant.toEpochMillis`
  (FFI to `DateTimeOffset.FromUnixTimeMilliseconds`).
- Calendar arithmetic helpers: `addMonths`, `addYears`,
  preserving day-of-month rules per `DateTime.AddMonths` semantics.

**Http expansion — deferred.**  Cancellation tokens, real timeouts,
and redirect policy are coupled to C2's async state-machine
implementation.  Threading a `CancellationToken` through the blocking
shim is awkward and would leak when the shim is replaced.  Tracked as
a follow-up gated on C2 landing.

**Regex RE2 — deferred.**  ECMA-regex backtracking is a real
attacker-input concern but no Lyric program in the bootstrap is yet
exposed to attacker-controlled regex.  Defer until either (a) a real
program needs it or (b) we can pin a NuGet engine that's AOT-clean
across all RID targets.  Tracked as a follow-up.

### C6 — wire blocks (compile-time DI)

Parser accepts `wire { ... }` already; semantics not implemented.

**Decision (D-progress-028)**: ship bootstrap-grade — singleton +
`@provided` + multi-wire — defer everything else from §10 to follow-
ups.

**What ships.**
- `singleton name: T = init` — one instance per wire, constructed in
  topological order at `bootstrap` time.
- `@provided name: T` — caller supplies via `bootstrap(...)` args.
- `expose name` — name appears as a field on the wire's bootstrap-
  result record.
- Multi-wire — one program can declare `ProductionWire` + `TestWire`
  side-by-side; each gets its own `<WireName>.bootstrap(...)`
  factory + result record.
- The compiler topo-sorts the dependency graph and reports a clear
  diagnostic on cycles.

**Implementation outline.**  A new pre-emit pass over `IWire` items
synthesises:
1. A record `<WireName>` with one field per `expose`d component.
2. A static factory `<WireName>.bootstrap(provided: ...) : <WireName>`
   whose body constructs every singleton in topo order, then returns
   the record literal with the `expose`d names as fields.
3. The factory's IL just chains the `init` expressions (already
   parsed as Lyric `Expr`) using the prior singletons as in-scope
   bindings.

**Deferred follow-ups (full §10 / option (a) coverage).**
- **Per-`scoped` lifetimes** — `scoped` declarations attached to a
  `scope_kind` (Request, Transaction, Tenant, …).  Needs an
  `AsyncLocal<T>` propagation story.  Coupled to C2's real
  async state machines; threading scope through the blocking shim
  would leak when the shim is replaced.
- **Lifetime checker** — reject singleton-depends-on-scoped at
  compile time (Dagger-style).  Trivial when only singletons exist
  (the bootstrap version), real graph-coloring problem once scopes
  land.
- **`@bind`-style multiple-impls-of-an-interface** registration.
- **Async-local scope tracking** for HTTP frameworks /
  database integrations.  Gated on C2.

**Rationale.**  (b) covers the test-wire pattern from worked-example
#7 (the `@stubbable` story is only useful with wire support) and the
production-singleton case.  Per-Request scopes ride along when C2
lands.  Cuts ~70% of the implementation cost of (a) for ~80% of the
practical value.

### C7 — formatter (`lyric fmt`)

Today's parser produces an AST — abstract syntax tree, no trivia.  A
round-trip-faithful formatter needs source position info the AST
doesn't carry.

**Decision (D-progress-029)**: ship a full CST layer; lowest priority
of the Band C items decided so far.

**What ships eventually.**  A Concrete Syntax Tree where every token
(including whitespace, blank lines, line comments, and doc comments)
is a node, and the existing AST becomes a structured projection over
the CST.  Roslyn / rust-analyzer / SwiftSyntax all use this shape.

**Why full (a) instead of bootstrap (b').**  The CST is reusable for
later tools — `lyric fix` / structural refactoring / a real LSP with
rename-symbol — that all want token-position-faithful traversal.
Building (b') first and (a) later means doing the formatter twice;
the CST is the right end-state and we'd rather pay the cost once.

**Implementation outline.**
- Lexer attaches leading + trailing trivia (whitespace, comments)
  to every token.
- Parser builds CST nodes carrying tokens-with-trivia; the existing
  `Lyric.Parser.Ast` types become a thin projection layer that
  hides trivia from AST consumers (type checker, emitter,
  AliasRewriter, doc generator).
- Existing AST consumers stay unchanged — they call into the
  projection layer.
- `lyric fmt` walks the CST, rewrites the trivia between tokens to
  canonical spacing, and re-serializes.

**Effort.**  ~1500-2500 LOC of plumbing.  Lexer +30%, parser +50%,
every AST consumer unchanged via the projection.  Multi-week project
that touches every existing parser test (tests need updating to
account for trivia attachment but their *assertions* about parsed
shapes shouldn't change).

**Priority.**  Lowest of the Band C items decided so far — `lyric
fmt` itself isn't on the user-visible critical path until v1.0
polish, and the CST infrastructure pays off most when LSP / refactor
tools come online.

### C8 — package manager (`lyric.toml`)

Today's stdlib resolver hardcodes a walk-the-repo lookup keyed on
`LYRIC_STD_PATH`.  Real package management means declared
dependencies, version resolution, lockfiles, registry, transitive
resolution.

**Decision (D-progress-030)**: piggyback on NuGet + embed contract
metadata directly in the DLL.

**Distribution = NuGet.**  Lyric packages publish as `.nupkg` files;
the registry is nuget.org (or any standard NuGet feed including
private GitHub Packages, Azure Artifacts, etc.).  `lyric.toml` is a
thin manifest that the build pipeline lowers to `<PackageReference>`
items in a generated `.csproj`; transitive resolution is `dotnet
restore`.  Convention: Lyric-shipped packages use a `Lyric.*` prefix
for namespace separation in search; a `lyric search` filter reads
the embedded contract resource (below) to surface only Lyric
packages.

**Why not self-hosted (a).**  A real registry is its own product —
auth, abuse handling, mirroring, takedowns, security incidents.
Cargo / npm / nuget each represent 5+ years of dedicated team work.
Lyric programs already produce .NET assemblies; piggybacking on the
mature NuGet infrastructure costs ~weeks instead of years and gives
us signing, mirroring, private feeds, search, credential helpers,
and threat-model day one.

**Why not local-only (c).**  Fine as a starting point but no
third-party-package story; the community can't share libraries.
Not a v1.0 endpoint.

**Contract metadata = embedded resource.**  Per language reference
§3.3, every package emits a `.lyric-contract` artifact alongside the
DLL.  Rather than ship that as a separate file in the .nupkg, embed
it as a managed resource on the DLL itself:

- `<EmbeddedResource>` named `Lyric.Contract` on every emitted
  assembly.
- Format is a hand-rolled custom binary blob:
  `<version><checksum><pub-decls>` — versioned, checksummed,
  big-endian.  Modeled on F#'s `FSharpSignatureData` resource.
- Reader lives in a small `Lyric.Contract` library that
  `lyric build` (cross-package consumption) and
  `lyric public-api-diff` (SemVer enforcement) both link.
- AOT-clean: the resource is rooted because consumers reference it
  by name via `Assembly.GetManifestResourceStream`.
- Cross-package flow: download .nupkg → extract DLL →
  `MetadataLoadContext.LoadFromAssemblyPath` → read
  `Lyric.Contract` resource → done.  No sidecar files.

**Rationale.**  Embedded metadata means the .nupkg ships only the
DLL — fewer moving parts, no risk of contract / DLL drift, the same
reader flow works for monorepo (no NuGet) and registry-fetched
packages.  `MetadataLoadContext` is already in the codebase from the
Cecil rewrite path so the infrastructure cost is low.

---

## Order of attack

All Band C items now have decisions (above).  Sequenced for
progress-per-session and dependency unblocking:

### Tier 1 — half-session quick wins — shipped

1. ~~**C3 — const folding for range-subtype symbolic bounds.**~~ —
   shipped via D-progress-025 (named-const lookup with cycle
   detection, `+ - * / %` arithmetic with overflow checks; the
   well-formedness checker T0090 / T0091 / new T0093 and the
   emitter's range-check IL both consume the folded value).
2. ~~**C4 phase 1 — strict-match auto-FFI.**~~ — shipped per the
   C4 entry above (single-overload-by-arity-and-type resolution
   for `recv.method(args)`; ambiguous calls still take
   `@externTarget`).
3. ~~**C5 Time expansion.**~~ — shipped per the C5 entry above
   (IANA `zoneOf`, epoch-millis converters, calendar arithmetic
   all live in `Std.Time`).

### Tier 2 — mid-cost, high practical value — shipped

4. ~~**C6 wire blocks bootstrap-grade.**~~ — shipped per the C6
   entry above (singleton + `@provided` + multi-wire; combined
   with `@stubbable` unlocks worked-example #7's test-wire
   pattern + production singleton DI).
5. ~~**Reified generic records (`record Box[T] { value: T }`).**~~ —
   shipped via D-progress-029 (`record` declarations are now
   reified at the CLR level; field-access lowering and type-arg
   inference both work end-to-end).
6. ~~**C5 Json source-gen.**~~ — shipped via D-progress-030 +
   D-progress-032 (`@derive(Json)` synthesises `toJson` /
   `fromJson` at compile time, with real String escaping landing
   in the follow-up).

### Tier 3 — package ecosystem — shipped

7. **C8 — NuGet piggyback + embedded contract resource.**  Both
   parts shipped.  Embedded `Lyric.Contract` resource per
   D-progress-031; `lyric.toml` manifest + `lyric publish` /
   `lyric restore` wrappers per D-progress-077.  Build-time
   consumption of restored packages — making `lyric build` actually
   use a NuGet-restored Lyric package via its embedded contract
   resource — is the remaining C8 follow-up tracked under Tier 6.

### Tier 4 — the tentpole

8. **C2 — real async state machines.**  ~~All phases shipped.~~
   Free-standing async funcs land Phase A / B / B+ / B++ / B+++ /
   C plus generic-async (D-progress-075) and the spill-prior-
   siblings ordering follow-up (D-progress-076).  C2 is **done**
   for every async shape Lyric currently supports.  Generic instance
   impl methods (`impl[T] Foo for Bar[T]`) are gated on the
   underlying generic-impl-methods feature gap, NOT on async work
   — see the C2 status table in `docs/10-bootstrap-progress.md`
   for why the SM-side wiring is mechanical once the type checker /
   interface emitter / impl-block emitter learn to pass through
   impl-block + method-level generics.  Tracked under Tier 6 below.
   - **Phase A — shipped (D-progress-033).**
   - **Phase B — shipped (D-progress-034).**
   - **Phase B+ / B++ / B+++ — shipped.**  Awaits inside if /
     match (D-progress-036, 041), while/loop bodies
     (D-progress-037, 042), try/catch (D-progress-056), defer
     (D-progress-057), for-loops (D-progress-058), async impl
     methods (D-progress-038, 040), stack-spilling for nested
     awaits (D-progress-074), generic async funcs (D-progress-075),
     and spill-prior-siblings ordering (D-progress-076).
   - **Phase C — shipped.**  `CancellationToken` propagation
     (D-progress-068), structured-concurrency scopes
     (D-progress-069), AsyncLocal ambient cancellation
     (D-progress-071).

### Tier 5 — gated on C2 — both shipped

9. **C5 Http expansion** — shipped via D-progress-070
   (cancellation tokens, real timeouts, redirect policy on
   `Std.Http`).
10. **C6 scoped wire lifetimes** — shipped via D-progress-072
    (`scoped[Request]` synthesises per-scope factories +
    singleton-references-scoped lifetime checker).

### Tier 6 — long tail / not blocking v1.0

11. **C7 — full CST formatter.**  Lowest priority per the C7
    decision; the CST infrastructure mostly pays off for LSP /
    refactor tools that come after the formatter itself.
12. **B6 — `format5..N`.**  Only when a real program needs it.
13. **C5 Regex RE2.**  Only when a real program is exposed to
    attacker-controlled regex inputs.
14. **C4 phase 2/3 — score-based matching, special shapes.**  Pulls
    in as user programs hit cases that strict match misses.
15. ~~**C8 build-time consumer of restored packages.**~~ — shipped
    via D-progress-078.  `lyric build --manifest <lyric.toml>` (or
    auto-discovered next to the source) now resolves
    `import <Pkg>` declarations against restored Lyric packages
    by reading their embedded `Lyric.Contract` resource
    (D-progress-031), without needing to re-parse the package's
    source.  Cross-package symbol references inside a contract
    Repr (e.g. `Result[Int, ParseError]` from `Std.Core`) still
    require the consumer's source to also `import Std.Core`;
    enriching the contract format with explicit re-exports is a
    follow-up.
16. **Generic interface methods + impl-block generics.**  The
    grammar accepts `impl[T] Foo for Bar[T] { func[U] foo(): U }`
    but neither the type checker nor the emitter wires the generics
    through (`Lyric.TypeChecker/Checker.fs:134` skips `IImpl` in
    symbol collection; `Lyric.Emitter/Emitter.fs`'s interface
    method definition uses `tb.DefineMethod` without
    `DefineGenericParameters`; Pass A.5 ignores `impl.Generics`).
    Zero stdlib usage today.  When this lands, the async SM
    extension is mechanical: extend the impl-method `defineState
    MachineHeader` caller to thread impl-block + method-level
    GTPBs and re-use the free-standing path's `kickoffBuilder*`
    helpers.

### Why this order

Tiers 1–5 are all shipped — see the strikethrough entries above for
the corresponding D-progress numbers.  The original rationale, which
the actual session order followed:

- **Tier 1** maintained momentum with concrete improvements that
  didn't block on anything.  Cleaned up known correctness / ergonomic
  gaps in a single session each.
- **Tier 2** landed the high-leverage feature work that combined with
  already-shipped pieces (`@stubbable`, records).  After Tier 2 the
  compiler could express test-wire patterns and JSON-serializable
  REST DTOs end-to-end.
- **Tier 3** shipped the package ecosystem before the biggest single
  feature.  External users can now publish libraries against v0.x
  Lyric; the embedded contract format lands in every emitted
  assembly from D-progress-031 forward.
- **Tier 4** was C2 alone — long-running, focused effort.  Putting
  it after package management meant the async release was shippable
  as a versioned package upgrade once it landed.
- **Tier 5** was the post-C2 cleanup that completed the Http /
  wire-scope stories.
- **Tier 6** is the work that doesn't gate v1.0 — formatter,
  varargs polish, RE2, FFI fanciness, generic interface methods +
  impl-block generics — done on demand as bootstrap consumers
  surface real needs.

---

## Band D — Phase 4 proof system (in progress)

M4.1 + M4.2 core shipped (D-progress-085 / 089); see the Phase 4
status table in `docs/10-bootstrap-progress.md`. The remainder
splits into "M4.2 close-out" (small, unblocks the M4.2 exit
criteria) and "M4.3" (the v2.0 release scope).

### D1. M4.2 close-out

1. **`std.core.proof` subpackage.** **SHIPPED** — D-progress-091
   landed `compiler/lyric/std/core_proof.l` (package
   `Std.Core.Proof`). Bootstrap-grade scope: identity witnesses
   (`identity`, `pickFirst`/`pickSecond`), Boolean literal anchors
   (`trueLit`, `falseLit`), let-rebind passthroughs (`tag`,
   `assertEq`), and a `wrappedIdentity` exercising the §10.4
   cross-call rule + §5.5 `@pure` unfold. Self-verifies (9/9) under
   the trivial discharger so the package is portable across CI
   hosts without `z3`. The aspirational `List[T]` / `Result[T,E]`
   proof surface is deferred to Phase 4 polish — gated on the
   verifier's structural-induction support past the M4.2-core
   primitives.
2. **`--allow-unverified` flag.** **SHIPPED** — D-progress-091.
   `Driver.ProveOptions.AllowUnverified` plumbed through
   `Driver.proveSourceWithOptions` / `proveFileWithOptions`; CLI
   parses `lyric prove --allow-unverified`. V0007 (`unknown`)
   downgrades to a warning and exits 0; V0008 counterexamples
   remain hard errors. Summary surfaces `[N unverified, allowed]`
   when the flag is set and at least one obligation came back
   `unknown`.
3. **Pagination-helper or token-bucket end-to-end proof.** Pick
   one worked example from `docs/02-worked-examples.md`, add the
   loop invariants, prove. Replaces the
   `examples/prove_demo.l` integration test as the M4.2
   demonstration. Likely surfaces 1-2 missing wp/sp rules. Still
   open after D-progress-091 — `02-worked-examples.md` Example 2
   (token-bucket) uses Doubles + `protected type`, neither in the
   M4.2-core verifier scope; `pagination-helper` is referenced in
   `15-phase-4-proof-plan.md` §M4.2 but not yet drafted as a
   worked example.
4. **Verification regression suite to 200.** **SHIPPED** —
   D-progress-091. `Lyric.Verifier.Tests` is 217 tests today (216
   passing; 1 environment-gated `z3`-only failure that predates
   this milestone), up from 83. Coverage:
   - Positive driver shapes (~50): identity, `let`/`val`-bound
     passthroughs, `@pure` single-level unfold, `invariant: true`
     loop establish/preserve, cross-call rule, no-contract
     baselines, multi-arity / multi-type axes (Bool/Long/String).
   - Negative driver shapes (5): wrong-sign post, wrong identity
     ensures, wrong loop establish, false `assert`,
     `result == false` on `true`.
   - SMT-LIB rendering (15): every binary boolean / arithmetic
     operator, `set-logic ALL`, `check-sat`, `get-model`,
     Bool/Int literal forms.
   - Trivial-discharger matrix (12): reflexive `=`/`>=`/`<=`
     across Int/Bool/String, `P ⇒ P`, `(P∧Q) ⇒ P/Q` flatten-on-
     adopt, conjunctions of tautologies, hypothesis-membership.
   - `parseModel` / `renderCounterexample` (7): empty / single-Int
     / Bool / three-binding / `unknown` blob / pair-render /
     Bool-render.
   - IR construction (25): `mkAnd`/`mkOr`, `isClosed`, `sortOf`,
     `subst`, `Goal.asImplication`, `Sort.display`,
     `GoalKind.display`, `Builtin.display`.
   - Sort/builtin display matrix (21): `BitVec[8/32/64]`,
     `Float32/64`, `SDatatype` arity 0/1/2, `SSlice`, `SUninterp`,
     every `Builtin` variant.
   - `ProveOptions` defaults (3).
   Tests bias toward shapes the trivial discharger handles so the
   suite is portable across CI hosts without `z3`; z3-only shapes
   stay in `DriverTests.fs` and assert the *non-Discharged*
   invariant (Counterexample-or-Unknown) rather than a specific
   verdict. The negative-counterexample bucket today is small; full
   counterexample-trace assertions land with M4.3
   (`docs/15-phase-4-proof-plan.md` §9).

### D2. M4.3 — v2.0 release work

5. **Counterexample reporting + trace reconstruction.** Today only
   parses `name : sort = value` bindings from `(get-model)`. M4.3
   wants a step-trace from the failing assertion back to the
   originating contract clause, plus heuristic suggestions
   ("strengthen this `requires:`", "add this loop invariant").
6. **`lyric prove --explain --goal <n>` mode.** Per
   `15-phase-4-proof-plan.md` §9.4.
7. **`lyric prove --json` schema.** Frozen public surface; needs a
   schema doc and a regression test that fails when the schema
   drifts.
8. **LSP V0007/V0008 integration.** Hover-rendered counterexamples
   + code-action fix-its for the suggestion list.
9. **`@proof_required(checked_arithmetic)` mode** (§5.4).
10. **`unsafe { ... }` + `assert φ` end-to-end.** V0003 / V0009 in
    the diagnostic surface; assertion lowering to a side-VC.
11. **Banking-example proof tutorial chapter** in
    `docs/13-tutorial.md`.
12. **`docs/16-axiom-audit.md`** — list every `@axiom` the stdlib
    ships with its rationale.
13. **Contract-aware `lyric public-api-diff`.** A SemVer minor that
    *strengthens* a `requires:` (or weakens an `ensures:`) is
    breaking. Spec already in `01-language-reference.md` §11; M4.3
    is the first time the tooling can detect it.
14. **CVC5 solver-swap parity.** Feature-flag build that runs ≥95 %
    of the M4.2 corpus through CVC5.

### D3. Q021 follow-ups (audit-surfaced)

15. **Q021 #5 — user-defined interface constraints.** Today's
    `Codegen.fs:630` `satisfiesMarker` only knows D034 markers;
    user interfaces fall through to `_ -> false` and the build
    aborts with a misleading B0001 even when the candidate type
    implements the interface. Either (a) reject user-interface
    constraints at the type checker until codegen learns interface
    lookup, or (b) extend `satisfiesMarker` to walk
    `ClrType.GetInterfaces()`. Choose (a) for the bootstrap; (b)
    can land with the Phase 5 stdlib re-host.
16. **Distinct-types `derives` propagation.** `DistinctTypeInfo`
    doesn't snapshot the `derives` list, so `f[Age] where Age:
    Hash` rejects even when `type Age = Int derives Hash`.
    Comment at `Codegen.fs:626-629` acknowledges this. Half-session
    fix once Q021 #5 is decided.
17. **`09-msil-emission.md` §9.4 update.** Spec says marker
    constraints lower to interface dispatch; bootstrap actually
    uses a closed lookup table in `Codegen.fs:satisfiesMarker`.
    Either retrofit interface dispatch (bigger) or correct the
    spec to reflect the shipped lowering (smaller; preferred for
    the bootstrap).

## Band E — long-horizon (Phase 5+)

- Self-hosting port (Phase 5)
- JVM backend (Phase 6+)
- ISO standardisation (Phase 6+)

Out of scope for the bootstrap.

---

## Notes

- **Triage rule**: when the type checker or emitter throws `failwithf` or
  produces invalid IL on a program that the language reference says
  should work, that's a Band A bug regardless of where it sits in this
  list.  PR #41's Cecil-based AOT rewrite is an example: surfaced as a
  user-visible "the compiled program crashes when published with
  PublishAot=true" and jumped the queue.
- **Don't add documentation-only items to Band A**.  If the spec needs
  clarification, fix the spec; if the implementation needs work, that's
  what this doc is for.
- **Keep this doc current.**  When something ships, delete the entry
  here and add it to `docs/10-bootstrap-progress.md` as a numbered
  D-progress entry.
