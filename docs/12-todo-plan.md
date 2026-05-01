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
runs (D-progress-003).  Constant folding is a non-trivial pass that
also unlocks compile-time generic value-arg evaluation.

**Decision needed**: scope of constant folding (literals + arithmetic
only?  full pure-expression evaluation?  recursion limits?).

### C4 — reflection-driven FFI

Today's FFI requires `extern type` + `@externTarget` per function.  A
reflection-driven path (`extern type Url = "System.Uri"` then call any
method without a per-method declaration) needs:

- A way to surface BCL members as if they were Lyric-side functions.
- Out-parameter / Span / extension-method semantics decided.
- A trim-friendly story for AOT (reflection trimming would otherwise
  remove uncited members).

**Decision needed**: how aggressive should the reflection layer be,
and where does the AOT-vs-flexibility tradeoff land?

### C5 — stdlib expansion

Concrete sub-items, each pickable independently:

- **`Std.Time`** is mostly complete (DateTime + TimeSpan via FFI).
  IANA tz lookup, calendar arithmetic, and "since epoch" helpers are
  the remaining gaps.
- **`Std.Json`** is a stub.  Real JSON requires a source-generator
  pass over user records, OR reflection-driven serialisation (which
  conflicts with C4).
- **`Std.Http`** has the basics; cancellation, timeouts, and redirect
  policy are next.
- **`Std.Regex`** dispatches to the BCL's ECMA regex.  RE2-compatible
  semantics would require a separate engine (or a pinned NuGet).

**Decision needed**: pick which stdlib gaps to close first.

### C6 — wire blocks (compile-time DI)

Significant feature.  Parser accepts `wire { ... }` already; semantics
are not implemented.  Needs a graph algorithm + lifetime checker.
Design sketched in `docs/01-language-reference.md` §11.

**Decision needed**: full Phase 3 commitment or partial bootstrap
(no scopes, no lifetime checker, just the basic resolution)?

### C7 — formatter (`lyric fmt`)

Today's parser doesn't preserve trivia (whitespace, comments) — it
produces a syntactic AST, not a CST.  A round-trip-faithful formatter
needs either:

- A new CST layer with trivia attached to every token, OR
- A printer that re-parses and reconstructs canonical formatting from
  the AST alone (loses the user's idiomatic whitespace).

**Decision needed**: CST or canonical-form-only?

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
