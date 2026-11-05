# D360 - The checker records an expression type per NodeId; `Lyric.Tir.Build` converts it to `Ty` (docs/70 phase 3a, #8613)

**Status:** step one shipped. The expression-type table, the `Type` to `Ty`
conversion and the I0002 census are in; the callee, instantiation, conversion
and argument-order tables, and the expression builder itself, follow (see
Consequences).

## Context

docs/70 §6.3 has the checker record, per `NodeId`, the type, the resolved
callee and instantiation, the chosen conversion and the argument order, and a
builder walk the AST with those tables, failing with I0002 on a node with no
entry. D325 numbered nodes but nothing reads the ids. The existing `*Sites`
tables (`calleeSites` among them, D336) are keyed by span and hold
source-shaped values (`TypeExpr`, rendered DefPath strings), which is the wrong
vocabulary for the phase 5a interfaces that reuse `Ty`.

## Decision

1. **`SymbolTable.exprTypes: Map[Int, Type]`**, keyed by `Expr.nodeId`, written
   by `inferExpr`, the one function every expression is typed through. An
   expression inferred again (speculative checking, an expected-type retry)
   replaces its entry, so the entry is the last type the checker gave the node.
   A node with id 0 (not numbered) has no entry.
2. **The table holds the checker's `Type`; the builder converts.** Keeping the
   checker free of `Lyric.Tir` imports avoids a second type vocabulary inside
   it. `Lyric.Tir.Build.tyOfType(ctx, t): Result[Ty, String]` converts, and the
   `Err` is the I0002 message. A `TyError`, a `TyInfer` the call did not solve,
   `Self` outside an interface, and a `TyParam` whose binder the builder has not
   registered are I0002; none becomes a wildcard in TIR.
3. **Generic parameters.** `TyParam.owner` is the checker's binder key (D337).
   `TyConvCtx.ownerSyms` maps a key to the declaring `SymbolId` and
   `ownerParams` to the parameter names in declaration order, which is the
   `TParam` index. The builder registers a binder as it enters a declaration.
4. **Extern types** convert to `TExtern(HostTypeRef(clrName, args))`; every
   other `TyUser` is `TNamed`.
5. **Census.** With `LYRIC_VERIFY_IR=1`, `pipeCheckFront` numbers the file
   (`Lyric.Resolve.renumberNodeIds`) before checking and, if the check had no
   errors, prints `I0002 census [<package>]: <n> of <m> expressions` and the
   first messages to stderr. Off by default, so a normal build neither numbers
   nor copies the tree. The `lyric build --verify-ir` flag and the stop-the-build
   switch (docs/70 §12.2) come after the census is zero.

## Consequences

- Ids are assigned once, before the check, so a pass that runs after it (Mono,
  the weaver) creates nodes with no entry. The builder runs on the checked file,
  before those passes, until 3b moves expansion ahead of body checking.
- Still to do in phase 3a: the per-call callee/instantiation table keyed by
  `NodeId` (replacing `calleeSites`; the MSIL and JVM backends read it, so the
  rekey is agreed with the phase 2d work first), the conversion and argument
  order tables, then the builder over every `TExprKind`.
