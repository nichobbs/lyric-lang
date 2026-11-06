# D393 - The post-weave mono pass is deleted (docs/70 phase 3b slice S4, #8613)

**Status:** accepted; implemented in the same PR. Fourth slice of D370, after
D390 (derives), D391 (local aspects) and D392 (library templates).

## Context

D285 added a second mono run over the woven file (`specialiseWovenContracts`,
fed by `pipeWovenGenerics`) because an aspect contract such as
`ensures: isSome(result)` only existed once the weaver had built a wrapper,
after `pipeCheckAndMono`, so the generic call in it was never specialised
(T0123). D304 added M0009 for the specialisations that run could not re-check.
D392 moved every weave ahead of the check, so the wrapper and its contracts are
in the file when ordinary mono runs; the second pass had nothing left to do.

## Decision

1. `specialiseWovenContracts`, `pipeWovenGenerics`, `fileHasWovenWrapper` and
   the `wovenGenerics` parameter of `pipeFinishWeave` are deleted, together with
   the MSIL bridge's per-package bookkeeping that fed them.
   `MiddleEndOptions.genericItemsOut` stays: the native backend uses it to
   instantiate a package's generics from another package (#8417).
2. M0009 (D304) no longer exists as a diagnostic: nothing is specialised after
   the checks any more, so no contract is specialised with the wrong operand
   semantics.

## Consequences

- One mono run per package on every target; a woven generic contract call is
  specialised, rechecked (unsigned, equality, operator bounds) and diagnosed
  like any other call.
- Remaining slice work (transitional span allocator replaced by cause spans
  once the checker's tables are NodeId-keyed, docs/70 phase 3a; `synSpan()`
  deletion) waits for those tables.
