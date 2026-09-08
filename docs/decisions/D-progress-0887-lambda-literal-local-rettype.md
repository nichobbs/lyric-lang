# D-progress-887 — MSIL codegen: an unannotated local `val`/`let`/`var` bound directly to a lambda LITERAL now registers its inferred return type in `funcValRetTypes` (#6690)

**Status:** shipped

**Context.** `registerFieldFuncValTypesMsil` (`msil/codegen.l`) is the shared
`#5511`-era fallback, called from `LBVal`/`LBLet`/`LBVar`'s local-binding
lowering, that populates `fctx.funcValRetTypes` for a function-typed local
whose binding carries no literal `(A,...) -> R` annotation. Before this
change it recognized two shapes: a record-field-read (`val fld = h.f`) and a
bare `EPath` naming an already-tracked function value or a known
same-package top-level function (`val f = double`, D-progress-684/#5366).
Every other `init` shape — including `ELambda`, a lambda LITERAL bound
directly to the local — fell through unhandled.

**Symptom.** `val f = (x) -> false; f(y)` never registered `f` in
`funcValRetTypes`. Every lifted lambda is emitted through the uniform boxed
`Func<object,...>` ABI (#1877): its synthesized `__lambda_N` function always
declares return type `Object` (`collectLambdasBfsExpr`'s `ELambda` arm), so
`lowerFuncValueInvokeMsil`'s `case None -> MObject` arm never materializes
the boxed call result at the invoke site. A non-null boxed `object`
reference reads as truthy under any boolean use regardless of the lambda's
real body, so `f(y)` was silently `true` no matter what `f` actually
computed.

**Fix.** Added an `ELambda(lparams, body)` arm to `registerFieldFuncValTypesMsil`'s
init-shape match. It builds a small `paramEnv: Map[String, MsilType]` from
any EXPLICITLY-typed lambda parameters (only possible via the brace
`{ params -> body }` form — the bare-paren-arrow sugar, grammar.ebnf
§7.1.3.1, accepts untyped identifiers only), finds the body's trailing
value expression via the existing `blockTrailingExprMsil` helper (already
used elsewhere in this file for the analogous "does this block have a
direct value?" question; `None` for a statement-only or `defer`-routed body,
which really does return `null` per `collectLambdasBfsExpr`'s own synthesis
comment — so `MVoid` there is not a guess), and infers the trailing
expression's type by reusing `inferUntypedStaticValMsilType` (the SAME
no-symbol-table heuristic already used for untyped module-level vals:
literals, `EParen`, `EPrefix`, `EBinop`, and `EPath` resolved against
`paramEnv`) rather than duplicating its logic. Any shape that heuristic
can't resolve still falls back to `MObject` — identical to today's
unregistered behaviour, never a regression.

**Scope note.** This is orthogonal to the pre-existing, deliberate #1939
diagnostic ("a lambda that uses an un-annotated parameter … is not yet
supported on `--target dotnet`"), which fires only when an UNANNOTATED
param's own VALUE needs unboxing inside the body (e.g. `(x) -> x + 1`) —
unrelated to this fix, which is about the LAMBDA'S OWN return type, not its
parameters' types. A lambda whose body never touches its unannotated
param's value (the exact `(x) -> false` repro, or a body that only
references a captured outer value) is unaffected by #1939 and is exactly
what this fix targets.

**Coverage.** Extended `func_val_local_rettype_self_test.l` (already CI-wired
on both `--target dotnet` and `--target jvm`, per its own docstring on JVM
parity for this whole defect family) with: the exact repro
(`val f = (x) -> false`), a comparison-bodied lambda over a captured outer
value (exercises the `EBinop`/always-`MBool` comparison arm without
touching #1939's territory), and a typed-param lambda with a multi-statement
block body whose trailing statement is the value (exercises the `paramEnv`
`EPath` lookup and `blockTrailingExprMsil` picking the LAST statement).
Verified green on both targets against a from-source `make lyric` build.

**Formatter note (#6869), corrected below.** This entry originally claimed
`lyric fmt --write` could not run on this file because of its PRE-EXISTING
brace-lambda usage (`{ y: Int -> x + y }` etc.). That was a misdiagnosis:
brace-form lambdas format fine (verified directly); #6869 is scoped
specifically to the BARE-PAREN-ARROW SUGAR form (`(x) -> expr`), which this
file's two `#6690` test cases used at the time. See the follow-up below,
which converts both to the equivalent brace form and makes the file
fmt-clean.

**Follow-up (review, #6932/#6933).** `claude-review` raised two REQUIRED
findings against this entry's own PR:

- **#6932** claimed the `ELambda` arm's `case None -> MVoid` fallback
  misclassifies a `return`-terminated lambda body, causing a stack-underflow
  crash at the invoke site. Investigated and found NOT reproducible as
  described: a lambda body ending in `return <value>` types as `Never`
  (`checkBlock`'s divergence rule), and passing a `Never`-typed call result
  as a plain call argument is rejected at COMPILE time (`error[T0043]`)
  before codegen ever runs — confirmed against the issue's own exact repro.
  A more permissive consuming position (the lambda passed DIRECTLY to a
  typed HOF parameter, `Never` freely unifying there) does compile and does
  crash with `NullReferenceException` — but that crash was verified to
  reproduce IDENTICALLY on `main` at 57b130e (this PR's own base commit,
  before any of its changes existed) via a lambda passed directly to a HOF
  parameter with NO `val` binding and no `registerFieldFuncValTypesMsil`
  involvement at all — i.e. a materially different, much deeper, entirely
  pre-existing "a `return` statement inside ANY lambda-literal body panics
  at runtime regardless of how its return type is registered" gap. Filed
  separately as #6947 (out of `group:msil-codegen-correctness` scope).
  `registerFieldFuncValTypesMsil`'s trailing-value search (renamed
  `lambdaBodyTrailingValueMsil`) still now ALSO unwraps an explicit trailing
  `return <expr>` as a value producer instead of assuming `MVoid` — a
  genuine, harmless correctness improvement kept regardless of #6947's
  unrelated crash — but no runtime regression test could be added for it:
  every reachable way to actually invoke such a lambda hits #6947's crash
  independent of this fix, leaving no passing repro to pin the
  type-inference improvement in isolation.
- **#6933** confirmed correct: `inferUntypedStaticValMsilType`'s arithmetic
  `EBinop` arms (`BAdd`/`BSub`/`BMul`/`BDiv`/`BMod`) fall back to `MInt` when
  an operand's type can't be resolved — sound for that function's original
  module-level-val context (`env` covers every name in scope by
  construction there) but NOT for a lambda body, which can reference an
  outer CAPTURE `paramEnv` (the lambda's own explicitly-typed params only)
  knows nothing about; a captured `Double`/`String` operand used in
  arithmetic was silently mis-inferred as `MInt`, and the invoke site's
  resulting `unbox.any int32` against a boxed `Double`/`String` throws
  `InvalidCastException`. Fixed by a new `inferLambdaBodyExprMsilType`
  (`msil/codegen.l`) that mirrors `inferUntypedStaticValMsilType`'s dispatch
  for every shape that heuristic resolves WITHOUT depending on an operand's
  own resolvability (literals, `EPath`, the comparison/boolean arms — always
  `MBool` regardless of either operand's type — `BXor`, `EPrefix`), but
  propagates `MObject` (unknown) through the arithmetic arms instead of
  guessing `MInt` when the recursively-inferred operand type is itself
  `MObject`. Verified with new regression cases: arithmetic over a captured
  `Double` and a captured `String`, both bound through an explicitly-typed
  local (the established `#5519` real-unboxing-at-a-typed-bind pattern) to
  prove which type actually got registered — a wrong `MInt` registration
  would throw INSIDE the call's own invoke codegen, before ever reaching the
  bind; a companion case pins that the fix does not regress the
  always-safe comparison arm over a captured value.

Also converted this file's two pre-existing `#6690` bare-paren-arrow-sugar
lambda literals (`(x) -> false` / `(x) -> threshold > 0`) to the equivalent
brace form (`{ x -> false }` / `{ x -> threshold > 0 }` — both parameters
are genuinely unused, so the type-erasure/#1939 semantics are unaffected):
the two forms are identical for an untyped single param, but the bare-paren
sugar trips #6869 while the brace form does not, so the file (with this
follow-up's new cases, also written in brace form) is now fully
`lyric fmt --write`-clean — the "Formatter note" above no longer applies.

**Related:** #6690, #5511/#5366/D-progress-684 (the pre-existing
`registerFieldFuncValTypesMsil` fallback this extends), #1939 (the
unrelated, still-in-effect diagnostic this fix does not touch), #6869 (the
bare-paren-sugar `lyric fmt` bug, now sidestepped in this file), #6932
(review finding, not reproducible as described — closed in favor of #6947),
#6933 (review finding, confirmed and fixed), #6947 (the newly-discovered,
much deeper `return`-inside-any-lambda-body crash, unrelated to this PR).
