# D323 - `Lyric.Tir.Verify`: the TIR verifier and I0003 (docs/70 phase 3a, #8613)

**Status:** shipped. Step 2 of docs/70 §13 phase 3a, after D319.

## Decision

`Lyric.Tir.Verify` (`lyric-compiler/lyric/tir/verify/verify.l`) exposes
`verifyPackage(pkg, deps): List[VerifyDiag]` and `renderVerifyDiag(pass, d)`.
A `VerifyDiag` is a node, a short stable rule name and a message; the rendered
form is `I0003: pass <pass> produced an ill-formed node #<id>: <rule>: <message>`.
`Lyric.Pipeline.pipeVerifyTir(pass, pkg, deps)` is the entry point passes call
on their output. `deps` are the `TSymEntry`s of loaded interfaces; the
package's own are `pkg.symbols`.

Rules (the rule name is what a diagnostic and a test match on):

1. `closed-type`: a `TParam` (or array-length parameter) must belong to the
   function being verified (`index < typeParams.count`) or be the `Self` of a
   declared type.
2. `symbol-defined`: every `SymbolId` a type, callee, construction, field,
   pattern or place names is defined by the package or a loaded interface;
   built-in (negative) ids are exempt.
3. `call-arity`, `call-type-args`, `call-arg-mode`, `call-arg-type`,
   `call-result-type`, `callee-callable`: a call's arguments equal the
   callee's parameters under the instantiation, exactly (substitution of
   `TParam(callee, i)` by the type arguments; interface callees also
   substitute the interface's arguments and `Self` by the receiver's type);
   indirect calls compare against the function value's type.
4. `local-defined`, `local-defined-once`, `local-captured`: a local is bound
   once per package, defined before use, and a closure that uses an outer
   local lists it in its captures.
5. `branch-type`: `if`/`match` arms, block tails, `unsafe` bodies, closure
   bodies and function bodies equal the node's type; a branch of type `Never`
   fits any type. `condition-type`, `pattern-type`, `let-type`, `convert-type`,
   `interp-part-type`, `range-type`, `short-circuit-type`, `old-type` and
   `lambda-type` cover the other typed positions.
6. `assign-mutable`, `assign-type`, `place-type`, `field-exists`: an
   assignment targets a mutable local, global or field, with a value of the
   place's type.
7. `node-unique`: a `NodeId` is used by one node.
8. `construct-arity`, `construct-field-type`, `pattern-arity`: constructions
   and constructor patterns match the case's declared fields.

`verifyPackage` always runs in full; Q-TIR-001 (whether I0003 runs in release
builds) is decided with the I0001 gate, not here.

## Consequences

Nothing builds TIR yet, so no pass is verified yet. `tir_verify_self_test.l`
builds well-formed and ill-formed TIR by hand and checks each rule fires on
the node that breaks it. The builder (docs/70 §6.3) and every later pass call
`pipeVerifyTir`. `pipeNewTirPackage` stays as the builder's seed.
