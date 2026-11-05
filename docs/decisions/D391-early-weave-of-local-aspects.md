# D391 - Aspects declared in the package are woven before the check (docs/70 phase 3b slice S2, #8613)

**Status:** accepted; implemented in the same PR. Second slice of D370.

## Context

The weaver runs after mono, on a tree the checker has already passed, and
builds the wrapper and the renamed target from the advice AST. Two things the
slice has to settle before the weave can move ahead of the checker:

1. **Contracts.** The weaver lowers the aspect's own `requires:`/`ensures:` into
   the wrapper body itself (`elaborateWrapperBodyForAspectContracts`), because
   the elaborator has already run, and keeps the composed list (aspect ++
   target) on the wrapper for the verifier and the interface. The renamed
   target keeps its own clauses, so the target's contracts run once, at the
   target. If the wrapper reached the elaborator with that composed list, the
   aspect's clauses would be checked twice and the target's twice.
2. **Names.** Advice from a library template (`from`-instance, C-mode splices,
   B'-mode specialisations) names things in the library's scope. Checked in the
   receiving package, those names do not resolve (D370 S3).

## Decision

1. `Weaver.weaveFileEarly` weaves only the aspects declared in the package
   being built (no `from`). A function that a `from`-instance also matches is
   left untouched for the late weave, which still weaves it with the whole
   chain; the early weave keeps every aspect declaration so the late weave sees
   them. The late weave is otherwise unchanged and runs after mono as before.
2. The outermost wrapper carries `@woven`. `Lyric.ContractElaborator` skips a
   function with `@woven` (as it skips `@axiom`): its aspect clauses are already
   in the body and its composed list is metadata. The renamed target is
   elaborated normally. This preserves where every contract runs, exactly.
3. Neither weave touches a function a weave generated: `isWeaverGenerated`
   (an `__aspect_` name or `@woven`) is passed through, so the late weave does
   not wrap the early wrappers again.
4. `WeaveResult.generated` lists the runs of items the weave generated
   (wrappers, never the renamed target, whose body is the user's with its real
   spans), each with the span of the function that caused it. `pipeWeaveEarly`
   gives each run spans from `Lyric.Expand.respanGenerated` with that function
   as the cause (D390), and `pipeCheckAndMono` calls it straight after the
   derive. Weave diagnostics (A0042-A0044) are reported by it and stay fatal.

## Consequences

- The wrapper, advice body, `call.*` and `config` preludes of a local aspect are
  type-checked like user code, and the checker records callee sites for the
  calls the weaver synthesises (`__aspect_target`, `proceed`), the part of the
  2d fallbacks that concerns local aspects.
- The interface and contract metadata now see the wrapper with its composed
  clauses where they saw the unwoven function before. The target is a private
  `__aspect_target` function.
- `from`-instance aspects (S3) and `specialiseWovenContracts` for woven
  generics are unchanged.
