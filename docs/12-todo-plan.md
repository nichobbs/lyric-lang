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

### B1. `import X as Y` alias

Parsed at `compiler/src/Lyric.Parser/Parser.fs:376` (`Cursor.tryEatKeyword
KwAs`) and `Ast.ImportDecl` / `Ast.ImportItem` carry an `Alias: string
option`, but the type checker and emitter never read it.  Effect today:
the alias parses cleanly and is silently dropped — `import Std.Core as
Core` does not introduce `Core.foo` into scope.

To wire through:

- Type checker resolver: when a `use`-style alias is present, register
  the imported symbol/package under the alias name as well as (or
  instead of, depending on selector) its source name.
- Emitter: same plumbing for direct calls and for `EPath` head-segment
  lookup.
- Tests: add a smoke that `import Std.Collections as Coll` then
  `val xs: Coll.List[Int] = Coll.newList()` works.

This isn't urgent — every existing program just uses bare names — but
the documented language reference promises it works, so it's a real bug.

### B2. `@projectionBoundary` cycle handling

D-progress-002.  Recursive view derivation lands in PR #21 but
`@projectionBoundary(asId)` is parsed and ignored.  Cycle detection at
type-check time is also missing, so a recursive opaque-without-boundary
crashes the compiler instead of erroring.

### B3. `out`/`inout` on record fields and array elements

The codegen-side l-value rule already supports `EIndex` (Ldelema) and
`EMember` (Ldflda) — that landed in PR #40 alongside string interpolation.
But the type-checker T0085 rule still rejects compound lvalues at the
source level.  Loosen `isAddressableLValue` and the codegen should follow.

Verify:

```lyric
val xs = [0, 0]
mutate(xs[0])               // currently T0085

record Point { var x: Int; var y: Int }
val p = Point(x = 0, y = 0)
mutate(p.x)                 // currently T0085
```

### B4. `Std.File`: `Result[Unit, IOError]` instead of `Result[Bool, IOError]`

D-progress-011 documents that the cross-assembly generic-Unit
instantiation produces invalid IL today (`Result_Ok<int32, IOError>`
fails JIT verification).  The bootstrap stand-in is `Bool` carrying
`true`.  Fix the union codegen so `Unit` works as a generic arg, then
swap `Std.File`'s success arms over.

### B5. DA propagation through `match` arms

D-progress-014.  The definite-assignment analysis joins `if`/`else` via
set intersection but doesn't yet enter pattern arms.  Means functions
that assign an `out` param inside a `match` arm and rely on it must fall
through after the match — they can't `return` from inside.

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

### C9. `lyric doc` documentation generator

M3.3.  Walk the typed AST, emit Markdown per package.  Cross-link
references.  Could ship after wire and before formatter.

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
