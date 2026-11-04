# D339 - The checker reports an unsolved type argument (W0035, then T0224) (docs/70 phase 3a, #8760)

**Status:** step one shipped: the checker reports the condition as the
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

## What fixes a call (step one as shipped)

A recorded call is fixed when any of these holds at the end of the file: a
`genericCallTypeArgSites` entry exists for it; its whole-call span keys an open
binding (`newList()` as a binding's initializer); or the type expected of the
call, unified with the callee's declared result, solves every open parameter.
The expected type is recorded by `noteExpectedFlow`, by the declared type of a
constructor field, a call parameter, an assignment target, and by the type a
consumed `if`/`match` joins to (`closePropagateBranch`). The first census
(1,204 hits, every one `newList()`/`newMap()` as a constructor field argument)
found the field and parameter positions; the second (53, all `newList()` as a
`match`/`if` arm) found the join. The third finds none in the compiler,
stdlib and their tests (`./scripts/bootstrap.sh --stage 2`); the ecosystem
libraries and the JVM and native sources are covered by CI's logs.

## Order of work

W0035 (this entry), then T0224 from the checker with Mono's site deleted, then
the `Object` fills in Mono's result-type inference and the exemptions as one
named predicate.
