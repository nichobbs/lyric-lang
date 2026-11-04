# D338 - The silent TyError census, and the I0001 gate decided (Q-TIR-001, docs/70 phase 3a, #8613)

**Status:** census run and recorded; the decision is made; the gate itself is
not yet switched on (see "Order of work").

## Context

D280 measured about 11.5k `TyError` results with no error reported when the
checker runs over the compiler's own packages and deferred the I0001 gate (a
`TyError` with no diagnostic stops the build) to phase 3a, because a gate on the
current checker would fire on valid programs. This entry records the census that
replaces the estimate, classifies it, and decides Q-TIR-001.

## The census

The census was a temporary instrumentation of `inferExpr` (commit `c8abbc3` on
`claude/docs70-phase-3a-tyerror`; not merged): after typing an expression it
compared the diagnostic count before and after, and when the result was
`TyError` with no new diagnostic it logged one line
`TYERR<TAB>package<TAB>kind<TAB>name<TAB>file:offset` to stderr, gated on
`LYRIC_TYERR_CENSUS=1`. It was run through stage 2 of the bootstrap
(`LYRIC_TYERR_CENSUS=1 ./scripts/bootstrap.sh --stage 2`, log in
`.bootstrap/stage2-emit.log`), which checks the whole compiler and stdlib
closure. It is not merged because adding it to `typechecker_exprs.l` made the
per-package typechecker DLL throw `Unable to cast List<Object> to
List<Symbol>` in the CI job that runs `typechecker_self_test.l` against
per-package output (1069 of 1075 cases); the cause is tracked in #8765. The numbers below are from that run.

**Result: 11,654 distinct sites** (Lyric 8,682, Std 1,682, Msil 789, Jvm 501):

| Class | Sites | What it is |
|---|---|---|
| Callee path, qualified (`Std.Path.join`) | 5,272 | a function named in call position; the call is typed from its signature |
| Callee path, type or case name (`Expr`, `NArg`, `IOError`) | 5,085 | a record or union-case constructor in call position |
| Callee path, bare lower-case | 136 | a function named in call position |
| `call` result | 862 | `x.toString()` 378, `Std.Console.println` 192, `default()` 31, extern `.new` 28, host methods (`.clear`, `.Dispose`, `.add`) |
| `member` read | 265 | the builtin `.count` 165, `.length`, extern properties |
| `binop`, `index`, `if`, `match` | 34 | to be read one by one |

About 90% are not values at all: the checker types a callee expression `TyError`
and types the call from the signature. That is the structural gap the TIR
builder closes (a call node carries a `Callee`, not a typed callee expression),
so those 10.5k sites need no checker change, only an explicit "callee position"
exemption in the gate that the builder removes.

## Decision (Q-TIR-001)

1. **I0001 always stops the build**, as docs/70 proposes: there is no
   user-facing switch to turn it off, because a switch is how the silent
   `TyError` class came back before.
2. **What the gate counts.** A `TyError` result on an expression that is not the
   callee of a call, with no diagnostic added while it was typed. Callee
   positions are exempt by construction, as a named predicate, until the TIR
   builder replaces them with `Callee`.
3. **Migration order (docs/70 section 12.2).** The 1,161 non-callee sites are the
   work: `toString`/`println`/`default` results get their real types (the
   builtin signatures of D334 already exist; the call-result path does not use
   them), `.count`/`.length` get the collection property types, and extern
   `.new`/methods get their metadata types. Each class is fixed or made a
   diagnostic, then the gate is switched on as a warning (W-code) for one CI
   cycle, then as the error I0001.
4. **`TyError` carrying its diagnostic** (`TyError(diag)`) follows the gate: once
   no silent `TyError` can reach the end of a statement, the constructor can
   require the id.

## Order of work

Done here: the census (recorded above, not merged) and this decision. Next, in order: type the `call`
results and `member` reads above; read the 34 operator sites; add the callee
exemption predicate and the gate as a warning; then the error. The
`instantiateSigOrdered` padding (`TyError` to `TyInfer`) was tried and made
the self-test "a site recorded for a synthesized literal binds only the
literal" fail through `inferOneGenericArg`'s hole handling; it is deferred to
the checker-side T0224 work (#8760), which owns that inference code.
