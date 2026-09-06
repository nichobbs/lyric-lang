# D-progress-886 — Native `String` gains `s[i]` bracket indexing and `String + Char` concatenation (#6237)

**Status:** shipped

**Context.** Found independently while diagnosing native builds of
`lyric-auth`/`lyric-web` (#6809/#6815's evidence trail): `s[i]` bracket
indexing and `String + Char` concatenation were entirely unsupported
codegen shapes on `--target native`, confirmed via direct repro against
a from-source `Lyric.LlvmCodegen`. Both are widely-used stdlib idioms
(character access, `Char`→`String` conversion) that work fine on
`--target dotnet`/`--target jvm`.

**Item 1 — `s[i]` bracket indexing.** `lyric_string_char_at(s, byteIdx)`
(`lyric-rt/src/lyric_string.c`) decodes the full Unicode scalar value
starting at `byteIdx` via genuine UTF-8 iteration (reusing the existing
`utf8_decode_at` helper `.trim()`/`.toLower()` already use) —
deliberately NOT a raw byte read. `native/plan/03-type-mapping.md`'s own
`Char` note settles this design question directly: "converting between
Char and a position in a string buffer requires UTF-8 iteration, not
byte indexing." The index itself stays a byte offset, consistent with
this backend's existing byte-indexed `.length`/`.substring` model
(D-N-006) — only the character *decode* performs real iteration. A byte
offset that lands mid-sequence (malformed or truncated UTF-8) decodes to
that raw byte's value, matching `.trim()`/`.toLower()`'s existing
lenient handling of invalid encoding elsewhere in this file; only a
genuinely out-of-range offset panics, mirroring `lyric_string_byte_at`'s
existing bounds check. Wired into `Lyric.LlvmCodegen.lowerCollectionIndex`
as a new String case ahead of the existing List/Map cases.

**Item 2 — `String + Char` and `Char.toString()`.** This one needed
more than a runtime primitive: `Char` and `Int` both erase to the same
`NI32` with **no runtime tag anywhere in this backend** — confirmed by
`.toChar()`'s own existing implementation, which is a bare pass-through
for an `NI32` value with nothing to convert. `NVal.ty` alone can
therefore never distinguish a bare Char from a bare Int at the two call
sites that actually need to (`lowerStringBinop`'s "both operands must be
String" check, and `.toString()`'s dispatch to `emitToString`, whose
`NI32` case calls `lyric_string_from_int` — wrong for a Char, since it
would print the codepoint's decimal digits instead of the character).

The fix is a new best-effort side-table, `Ctx.varIsChar: Map[String,
Bool]`, deliberately scoped narrower than a general type-inference pass:
- Populated at `val`/`let`/`var` binding sites (`charnessOfBinding`: an
  explicit `Char` type annotation wins outright; otherwise the
  initializer expression's own char-ness), function parameters, and
  lambda parameters/captures (propagated from the enclosing function's
  own `varIsChar` at closure-synthesis time).
- `exprIsCharTyped` reads it back for a bare local-variable reference, a
  `Char` literal directly, and — a derived rule needing no table entry at
  all — `s[i]` indexing on a recognizably String-typed receiver
  (`exprIsStringTyped`, reusing this backend's already-unambiguous String
  tracking to disambiguate "index into a String" from "index into a
  `List[Int]`", since `indexElementType`'s `TyPrim(PtString) -> Char` rule
  has no other outcome).
- `lowerBinop` consults `exprIsCharTyped` on the ORIGINAL (pre-lowering)
  operand expressions to widen a bare Char operand to a real
  `LyricString*` via `lyric_string_from_char` (declared in the runtime-decl
  table since #6588 but never actually called by any codegen path until
  now) before `lowerStringBinop`'s own operand-type check runs.
  `lowerScalarMethodCall`'s `.toString()` arm consults the same check
  (threaded through as a new `recvExpr: Option[Expr]` parameter at both
  of its call sites) before falling back to `emitToString`.

This is intentionally best-effort, not full static type inference — an
unannotated function-return-typed intermediate value (e.g., a `Char`
returned from a plain function call used inline, with no local binding)
stays untracked and would still hit the pre-existing panic. That residual
gap is accepted for the same reason `varTypes`/`varSlots` are themselves
incomplete for exotic shapes elsewhere in this backend: the common
real-world idioms (an annotated or literal-initialized local, a typed
parameter, direct bracket-index use) are exactly what #6237's own repro
and the `lyric-auth`/`web.l` call sites needing this fix actually use.
Two related gaps are explicitly OUT of this fix's scope, per review
feedback on the PR: compound assignment (`s += someCharVar`) still
routes through `lowerAssign`'s `+=` path (`coerceTo`, which has no
Char->String widening arm) and hits the same pre-existing panic — this
PR only widens the `+` binary operator, not `+=`; and `exprIsCharTyped`'s
`s[i]`-is-Char derived rule only recognizes a String-typed *receiver*
via `exprIsStringTyped`'s existing tracking, so e.g. a `Map[Int, Char]`
value indexed inline (`"prefix: " + someMap[k]`) is not recognized
either. Neither is a regression — both panicked identically before this
PR — and both are consistent with the documented best-effort scope
above, not separately tracked.

**Verification.** New cases in `lyric-rt/test/lyric_rt_test.c`:
`lyric_string_char_at` across an ASCII string and a multi-byte UTF-8
string (byte offset vs. codepoint offset diverging correctly); a new
fork-based out-of-bounds panic test for `char_at` mirroring the existing
`.slice` OOB pattern (`run_forked_char_at_oob`/
`test_string_char_at_oob_aborts`). New end-to-end cases in
`llvm_codegen_self_test.l`: `s[i]` across ASCII byte offsets and a
multi-byte decode, plus an out-of-bounds panic case; `String + Char`/
`Char.toString()` across a `Char` literal, an explicitly
`Char`-annotated `val` whose initializer is itself bracket-indexing
syntax (exercising the annotation-driven half of `charnessOfBinding`
independent of literal inference), a `Char`-typed function parameter,
and a direct `s[i]` used inline in a binop with no intervening binding
at all. `make -C lyric-rt test`/`test-asan` and the full
`native-backend-self-tests` self-test list (`llvm_ir_self_test.l`,
`llvm_codegen_self_test.l`, `llvm_heap_self_test.l`,
`llvm_ffi_self_test.l`, `llvm_collections_self_test.l`,
`llvm_stdlib_self_test.l` — via `make self-test NAME=llvm_codegen` and
direct `LYRIC_LOAD_COMPILER=1` runs, using the freshly staged
`<libdir>/selfhosted/` compiler DLLs) pass with zero regressions,
including every ASan-linked case in that list.

**Related:** #6237, #6240 (the broader native `String` search-method
audit this issue was split out of — #6588 already covered its other six
named methods), #6755 (native `.lastIndexOf`, unaffected by this change
and shipped separately), D-progress-831 (the #6588 fix this extends),
`native/plan/03-type-mapping.md` (`Char`'s UTF-8-iteration note),
`native/plan/08-work-items.md` (N9.3/N9.6/N9.7 write-ups updated),
`docs/01-language-reference.md` §12.1 (updated).

**Addendum (#7010) — `Ctx.varIsChar` leaked stale entries across a name
shadow at three of `bindLocal`'s eight call sites.** `claude-review`
found this PR's `markVarChar` bookkeeping was applied at only 4 of the
8 places `bindLocal` binds a name: the `for`-loop element bind, the
tuple-destructure bind (`bindTuplePattern`'s `PBinding` arm), and the
match-arm pattern bind (`applyPatternBinds`) all bound a new value
without clearing or re-setting any prior `varIsChar` entry for that
name. Since `Map[String, Bool]` keys purely by name, not by scope
depth, a `val c: Char = 'X'` followed by a `for c in someIntList { ... }`
(or a tuple/match rebind of `c` to a non-Char value) left the stale
`true` entry in place — `c.toString()` inside the new scope would then
silently route through `emitToString`'s Char arm instead of the correct
`Int` arm, printing the wrong output with no diagnostic.

Fixed by adding `markVarChar(ctx, name, false)` immediately after each
of the three previously-unguarded `bindLocal` calls, matching the
remove-then-add convention `bindLocal` itself already uses for
`varTypes`/`varSlots`. The `false` is unconditional at these three
sites — this fix closes the staleness bug (an old `true` surviving a
rebind) without attempting genuine Char-detection for a `for`-loop
element, tuple-destructured field, or match-bound payload; a value that
is genuinely a `Char` at one of these three sites still hits this
backend's pre-existing untracked-Char panic, which is a documented,
separate best-effort-scope gap (see above), not a new regression.

**Verification.** Three new regression cases in
`llvm_codegen_self_test.l`, each shadowing a `val c: Char = 'X'` with a
non-Char rebind through one of the three fixed sites and asserting
`c.toString()` on the new binding formats as the correct decimal
number rather than the stale Char glyph: a `for`-loop shadow (iterating
a `List[Int]`), a tuple-destructure shadow (`val (c, _) = (65, 66)`),
and a match-arm shadow (a non-generic `union Box { case Full(v: Int)
case Empty }`, since `--target native` does not yet support generic
types per Phase N1 — `Option[Int]` was not usable here). All three
failed against the pre-fix compiler and pass against the fix. Full
`llvm_codegen_self_test.l` (38 cases, including every pre-existing ASan
case) passes with zero regressions.
