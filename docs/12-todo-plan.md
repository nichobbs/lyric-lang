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

### C1. `parseInt` / `parseLong` / `parseDouble` collapsing into `tryParse[T]`

D-progress-004.  Today's pair is `xxxIsValid(s)` + `xxxValue(s)` because
Lyric had no out-params when `parse.l` shipped.  PR #40's out-params now
make `tryParse[T](s: in String, value: out T): Bool` straightforward; the
parse host class collapses to one method per primitive.

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
