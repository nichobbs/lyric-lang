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

### B6. `format5..N`

D-progress-011 ships `format1..4`.  Add `format5` and `format6` if a
real program needs them; otherwise wait for a varargs story.

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

M1.4 D035 ships `async`/`await` as `.GetAwaiter().GetResult()` blocking
shims.  Phase 4 work — needs a real state-machine lowering or a thin
wrapper over F#'s `task { }` builder via FFI.

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

Big undertaking.  Versioned packages, registry, lockfile, transitive
resolution.  Today's stdlib resolver hard-codes a walk-the-repo lookup
keyed on `LYRIC_STD_PATH` or relative directories.

**Decision needed**: ship a self-hosted registry, or piggyback on an
existing one (NuGet, Cargo-style local-only)?

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
