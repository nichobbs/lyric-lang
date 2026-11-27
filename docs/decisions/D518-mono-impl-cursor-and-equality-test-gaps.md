# D518 - Mono matches each generic impl against an instance once

**Status:** accepted, implemented in `Lyric.Tir.Mono` (docs/70 phase 3c, §7.2; follows D513 and D514)

## Decision

1. **A cursor per generic impl.** `instantiateImpls` ran to a fixpoint and, on every pass, rescanned the whole instance list for every generic impl (impls x instances x passes). Instances are only appended and an impl's match against an instance depends on that instance's arguments alone, so `MCtx.implCursor` records, per impl symbol, how many instances it has been matched against, and the next pass resumes there. The result is the same set of impl instances in the same order.
2. **Review-suggested coverage** (D515): a tuple with a `Float` part compares it with the NaN rule and the array in a loop, and a generic record holding a tuple with an array builds and verifies (never an I0002). The union-equality match is documented as exhaustive because the checker records every case of the union.
