# D332 - The TIR verifier tracks scopes and checks record patterns and function-level diagnostics (docs/70 phase 3a, #8613)

**Status:** shipped. Follow-up to D323, from the review suggestions on #8737.

## Decision

1. **Locals are scoped.** A local is usable only inside the block, match arm,
   `catch` clause, `for` loop, `scope` statement, closure or quantifier that
   binds it. `Ctx.live` and `Ctx.scopeIds` track the open scopes (`enterScope`
   / `exitScope`); the declaration stays in `Ctx.locals`, because a `LocalId` is
   still bound once per package. A use after the scope ends is
   `local-in-scope`. A closure's outer set is the locals live where it is
   created. A `val v = v` initialiser still reports `local-defined`, because the
   pattern is bound after the initialiser is visited (now pinned by a test).
2. **Patterns and fields.** A record pattern's field references are checked like
   a field read (`checkFieldRef`: the owner declares a field of that name at
   that index, rule `field-exists`). A constructor pattern on a case that has no
   signature is `pattern-callable`. `XField` and assignment through a field use
   the same check.
3. **Function-level diagnostics.** `VerifyDiag` carries `fnSym`, and the
   rendered I0003 reads `... node #N (in function #F): rule: message`, so a
   diagnostic about a parameter, a return type or a function body (which has no
   node of its own, `NodeId(0)`) says where it is.
4. **Constructs that bind locals** and are not in TIR today (if-let,
   while-let) would stay live to the end of their block until they get scope
   handling; add it when they appear.
5. **Not added:** a rule that an assignment through an index needs a mutable
   receiver. Whether `xs[i] = v` through an immutable binding of a reference
   container is an error is a language question, not a TIR invariant; it is
   left to the checker. A comment on `TExtern` records that host names are not
   checked by the verifier.

## Consequences

`tir_verify_self_test.l` grows from 16 to 26 cases (block, arm, `for`, `catch`,
quantifier and closure scoping, `val v = v`, record-pattern field names, case
without signature, function in the diagnostic). `resolve_self_test.l` pins that a second renumbering keeps ids
dense. No pipeline behaviour changes: nothing builds TIR yet.
