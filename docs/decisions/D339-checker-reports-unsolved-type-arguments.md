# D339 - The checker reports an unsolved type argument (W0035, then T0224) (docs/70 phase 3a, #8760)

**Status:** step one in progress: the checker reports the condition as the
warning W0035 while Mono still reports T0224. Steps two and three follow in
their own entries or amendments of this one.

## Context

D335 made an imported generic call whose type argument nothing fixes the error
T0224, but the monomorphiser reports it, so `lyric check` depends on Mono
running and the checker never states the rule docs/70 §5.2 gives it.

## Decision (step one)

1. The checker keeps a table of calls to an imported, non-extern generic whose
   type argument(s) the call's arguments leave unsolved
   (`SymbolTable.unsolvedCallSites`, keyed by `recordCopySiteKey` of the
   callee's span). An entry is removed when a later step fixes the arguments:
   the expected type of the call, an open binding resolved by its later uses,
   or a recorded `genericCallTypeArgSites` entry.
2. At the end of a function body an entry still in the table is the warning
   **W0035** ("cannot infer type argument(s) 'T' of 'f' ..."), the same message
   T0224 will carry. Calls Mono exempts (an `@externTarget` generic, a name the
   local environment binds, a call without a source position) never enter the
   table.
3. W0035 is compared with Mono's T0224 on the compiler, stdlib and ecosystem
   sources; the checker's set must be empty wherever Mono's is.

## Order of work

W0035 (this entry), then T0224 from the checker with Mono's site deleted, then
the `Object` fills in Mono's result-type inference and the exemptions as one
named predicate.
