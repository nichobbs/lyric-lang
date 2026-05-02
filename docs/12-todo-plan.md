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

### C2. Real async state machines

M1.4 D035 shipped `async`/`await` as `.GetAwaiter().GetResult()`
blocking shims.  Phase A (D-progress-033) shipped real
`IAsyncStateMachine` synthesis for await-free async bodies.
Phase B (D-progress-034) shipped real `AwaitUnsafeOnCompleted`
suspend/resume with state dispatch, exception flow through
`SetException`, and locals promoted to fields.  Remaining work:
Phase B+ (await inside try/catch/defer/match, async impl
methods, async generics) and Phase C (cancellation tokens,
structured concurrency scopes).

### C3. Range-subtype symbolic bounds

D-progress-003.  `T0090` / `T0091` only fire on integer-literal bounds;
`type X = Int range MIN ..= cap` escapes the well-formedness check.  Needs
constant folding before the well-formedness pass runs.

### C4. Reflection-driven FFI

Phase 4.  Today's FFI is hand-routed through `Lyric.Stdlib`.  A
reflection-driven path would let users write `extern type Url =
"System.Uri"` and get every public method without an `@externTarget`
declaration.  Lots of design work — `out` semantics, ref-vs-byref-vs-Span
shape decisions, extension-method handling — defer until the language
spec catches up.

### C5. Stdlib expansion: Time, Json, Http, regex hardening

`docs/10-stdlib-plan.md` Phases 2-4.  Several modules have source
shapes drafted but no real implementation.  Specifically:

- `Std.Time`: ISO-8601 parser, `Duration` arithmetic, IANA tz lookup.
- `Std.Json`: source-generated serialiser instead of the current stub.
- `Std.Http`: full `HttpClient` wrapping with cancellation, timeouts,
  redirect policy, JSON body deserialisation.
- `Std.Regex`: RE2-compatible engine instead of dispatching to BCL's
  ECMA regex.

### C6. Wire blocks (compile-time DI)

M3.2.  Parser accepts `wire { ... }`; semantics not implemented.
Generates static factory code at compile time.  Big feature; design
sketched in `docs/01-language-reference.md` §11.

### C7. Formatter (`lyric fmt`)

M3.3.  Need a printer that round-trips the AST without losing
information.  Phase 1 parser doesn't preserve trivia; the printer needs
either a CST layer or a re-parse.

### C8. Package manager (`lyric.toml`)

M3.4.  Today's stdlib resolver is hard-coded to walk-the-repo.  A real
package manager fetches versioned packages from a registry, compiles
them on first import, and caches the resulting DLLs.

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

### Tier 1 — half-session quick wins, no dependencies

1. **C3 — const folding for range-subtype symbolic bounds.**  Closes
   a known correctness gap (D-progress-003: bounds escape T0090 /
   T0091 silently).  ~300 LOC + tests.
2. **C4 phase 1 — strict-match auto-FFI.**  Resolve a name when
   exactly one BCL overload matches by `(name, arg-arity, exact-
   type-match)`.  Ergonomic win for the common case
   (`xs.add(item)`); ambiguous calls still need `@externTarget` as
   the escape hatch.
3. **C5 Time expansion.**  IANA `zoneOf`, epoch-millis converters,
   calendar arithmetic.  All thin FFI wrappers.

### Tier 2 — mid-cost, high practical value

4. **C6 wire blocks bootstrap-grade.**  Singleton + `@provided` +
   multi-wire.  Combined with the already-shipped `@stubbable`,
   unlocks worked-example #7's test-wire pattern + production
   singleton DI.  ~1-1.5 sessions.
5. **Reified generic records (`record Box[T] { value: T }`).**  Today
   `record` declarations are non-generic at the CLR level — the
   parser accepts `Box[T]` but the emitter's type-arg inference and
   field-access lowering produce `InvalidProgramException` at
   runtime.  Reified generic functions (PR #f8c04fe) and unions
   (PR #9ad8962) already landed; records are the missing third leg.
   Fresh re-implementation on top of the current main; the April-30
   `claude/generic-records` branch (PR #43) is too far behind to
   rebase cleanly so we'll do this from scratch.  Ordered before C5
   Json source-gen because Json benefits from generic record support
   (e.g. `record Page[T] { items: slice[T], total: Int }`).
   ~1 session.
6. **C5 Json source-gen.**  `@derive(Json)` on records synthesises
   `toJson` / `fromJson` at compile time.  Unlocks REST services
   without manual string concat.  ~1 session.

### Tier 3 — package ecosystem

7. **C8 — NuGet piggyback + embedded contract resource.**  Two
   parts: contract-metadata embedded resource format (~1 session),
   then `lyric.toml` manifest + `lyric publish` / `lyric restore`
   wrappers around `dotnet pack` / `dotnet restore` (~1 session).
   Lands the package ecosystem before async so external libraries
   have somewhere to live while C2 is in flight.

### Tier 4 — the tentpole

8. **C2 — real async state machines.**  Phases A / B / B+ / B++ /
   B+++ / C all shipped.  Async generic funcs (closed-generic SM on
   `TypeBuilder`) are the last remaining sub-item; outside of that
   the only loose end is the Roslyn-style "spill-side-effecting-
   siblings-to-the-left-of-an-await" follow-up to the Phase B+++
   stack-spilling rewrite.
   - **Phase A — shipped (D-progress-033).**  Real
     `IAsyncStateMachine` synthesis for await-free async bodies.
   - **Phase B — shipped (D-progress-034).**  Real
     `AwaitUnsafeOnCompleted` protocol with state dispatch,
     exception flow through `SetException`, and locals promoted
     to fields.
   - **Phase B+ / B++ / B+++ — shipped.**  Awaits inside if /
     match (D-progress-036, 041), while/loop bodies
     (D-progress-037, 042), try/catch (D-progress-056), defer
     (D-progress-057), for-loops (D-progress-058), async impl
     methods (D-progress-038, 040), and stack-spilling for
     nested awaits (D-progress-074).
   - **Phase C — shipped.**  `CancellationToken` propagation
     (D-progress-068), structured-concurrency scopes
     (D-progress-069), AsyncLocal ambient cancellation
     (D-progress-071).
   - **Remaining.**  Async generic funcs (closed-generic SM on
     `TypeBuilder`); side-effecting-sibling spill ordering for
     the rare `f(printAndReturn(), await g())` pattern.

### Tier 5 — gated on C2

9. **C5 Http expansion.**  Cancellation tokens, real timeouts,
   redirect policy.  All want async-state-machine threading; doing
   them on the blocking shim leaks when the shim is replaced.
10. **C6 scoped wire lifetimes.**  `scoped` declarations + the
    lifetime checker that rejects singleton-depends-on-scoped.
    Wants `AsyncLocal<T>` scope propagation across `await`.

### Tier 6 — long tail / not blocking v1.0

11. **C7 — full CST formatter.**  Lowest priority per the C7
    decision; the CST infrastructure mostly pays off for LSP /
    refactor tools that come after the formatter itself.
12. **B6 — `format5..N`.**  Only when a real program needs it.
13. **C5 Regex RE2.**  Only when a real program is exposed to
    attacker-controlled regex inputs.
14. **C4 phase 2/3 — score-based matching, special shapes.**  Pulls
    in as user programs hit cases that strict match misses.

### Why this order

- **Tier 1** maintains momentum with concrete improvements that
  don't block on anything.  Cleans up known correctness / ergonomic
  gaps in a single session each.
- **Tier 2** lands the high-leverage feature work that combines with
  already-shipped pieces (`@stubbable`, records).  After Tier 2 the
  compiler can express test-wire patterns and JSON-serializable
  REST DTOs end-to-end.
- **Tier 3** ships the package ecosystem before the biggest single
  feature.  External users can publish libraries against the v0.x
  Lyric while C2 is in flight; the embedded contract format lands
  in every emitted assembly from this point forward.
- **Tier 4** is C2 alone — long-running, focused effort.  Putting
  it after package management means the async release is shippable
  as a versioned package upgrade once it lands.
- **Tier 5** is the post-C2 cleanup that completes the Http /
  wire-scope stories.
- **Tier 6** is the work that doesn't gate v1.0 — formatter,
  varargs polish, RE2, FFI fanciness — done on demand.

---

## Band D — long-horizon (Phase 4+)

- SMT-backed proof system (Phase 4)
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
