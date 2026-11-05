# D361 - A callee table keyed by the call's NodeId, beside `calleeSites` (docs/70 phase 3a, #8613)

**Status:** shipped for calls to a declared function (free or
package-qualified) and for method calls; the census counts the calls it does not
yet cover.

## Context

D360 recorded each expression's type under its `NodeId`. docs/70 §6.3 also asks
for the resolved callee per call. D336's `calleeSites` already records one, but
keyed by span and valued with a rendered DefPath string, and the MSIL and JVM
backends read it.

## Decision

1. **`SymbolTable.calleeByNode: Map[Int, SymbolId]`**, keyed by the call
   expression's `NodeId`, valued with the callee's interned `SymbolId`. It is
   filled at the one point that fills `calleeSites` (`recordCalleeSite`), from
   the same DefPath key, so the two agree by construction.
2. **`calleeSites` is not rekeyed or removed.** The backends keep reading it
   until phase 4 moves them to TIR, which carries the `Callee` itself; an
   additive table means no backend change and no coordination hazard. It is
   the 2d session's contract, told of this plan.
3. **Census.** `Lyric.Tir.Build.calleeCensus` lists the calls with no entry as
   I0002, and `LYRIC_VERIFY_IR=1` prints `I0002 census [<package>]: <n> of <m>
   calls without a recorded callee`. The uncovered routes are the work list:
   built-ins (`IoBuiltin`), constructors and union cases (`XConstruct`), methods
   and UFCS, interface methods, function values (`Indirect`), and extern members.
4. **Method calls** record the dot-named function `Type.member` the method pick
   resolved to (`recordMethodCalleeNode`), found by the signature's span in its
   declaring package, under the same key form as a free call. The census message
   names the call's line and column, and `LYRIC_VERIFY_IR=1` prints the first
   five.
5. **Synthesised calls.** A call with no node id (id 0, a node a pass built
   after numbering) and a call whose span is `noSourceSpan` have no entry; they
   are counted until numbering follows the expansions (docs/70 phase 3b).
6. **Instantiation** (the type arguments of a generic callee) is not recorded
   yet; it comes with the routes above, since each knows its own substitution.
