# D502 - Contract elaboration on TIR: the declaration step lowers clauses into the body

**Status:** accepted, implemented as `Lyric.Tir.Contracts` (docs/70 phase 3c, §7.2)

## Decision

1. **`Lyric.Tir.Contracts.elaborateFn(d, owner, enabled)` is a `TFnDecl` to `TFnDecl` pass** that lowers `requires:` and `ensures:` into `assert(cond, message)` calls (`Callee.Intrinsic(IoBuiltin "assert")`) in the body, as `Lyric.ContractElaborator` does on the AST: `old(e)` operands are bound to `__old_N` locals first, then the preconditions are asserted, and every way out of the body (the tail value and a `return` at any depth, not inside a lambda) binds its value to a local, asserts each postcondition with `result` read from that local, and yields it. The clauses stay on the `TFnDecl` (`preconds`/`postconds`) for the verifier. `elaborateBundle` applies it to every function of a bundle; `Pipeline.pipeContractsTir` is the pipeline entry. A declaration with no body, no clause, or a generator is returned as it is, and `enabled = false` (contracts off, docs/63 Q-BP-009) leaves the body alone.
2. **Messages come from the clause source.** TIR has no source text, so the builder records each clause's formatter-rendered text beside it (`TFnDecl.precondTexts`/`postcondTexts`, defaulted so every construction site and interface reader is unchanged) and the pass prints `PreconditionViolated: Owner.f requires x > 0` / `PostconditionViolated: Owner.f ensures ...` exactly as the AST pass does (`Owner.f` is the DefPath key without its parameter list, `::` as `.`).
3. **Node ids.** Each assertion clones its clause with fresh node ids (starting at 700,000,000), because the original clause stays on the declaration and node ids are unique per package.
4. **Order with monomorphisation.** The pass has no dependence on generics (a clause is a TIR expression like any other), so it runs before or after `Lyric.Tir.Mono`; the native consumer runs it after, on instance bodies.

## Not done

Type invariants, parameter and return range checks, loop `invariant:` lowering, protected-entry clauses and aspect-composed contracts are separate slices of phase 3c (the AST pass still does them); the `@pure`-only filtering of runtime clauses and the dropping of quantified conjuncts (`forall`/`exists` cannot run) are not yet applied here: a clause containing a quantifier is asserted as written. Caller-side checks are phase 6.
