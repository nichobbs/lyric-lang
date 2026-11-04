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
2. At the end of `check` an entry still in the table is the warning
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

## The CI census and the second round (this amendment)

The first PR's CI logs (every manifest, JVM and native source, the examples and
the fixtures) found 49 more distinct hits, in six shapes. The rule changed so
that none of them is reported, without loosening the real case
(`isNone(none())` is still two warnings):

1. **A type parameter any argument binds to a closed type is solved**, even when
   another argument disagrees (`unwrapResultOr(r, Square(...))` over a
   `Result[Shape, String]` binds `T` to `Shape` and to `Square`; the
   disagreement is T0043 or a widening, not a missing annotation).
2. **A nested call takes its parameter as its expected type**, with the parent's
   holes solved from the parent's own expected type
   (`kids.add(keyed("k", paragraph("p")))`, `keyed(..., paragraph(...))` against
   `View[Msg]`): `SymbolTable.callParents`, `effectiveCallExpected`.
3. **A call with an argument the checker typed `TyError`, or one that passes an
   open binding, is indeterminate** and is not reported (`eventName(h)` for a
   loop variable in a generic body, `viewOf(children[0])`, `mapGet(dict.items,
   key)`, `isOk(ok)` for an open `val ok`). The checker does not know; the
   silent `TyError` that makes it not know is item 3 of the phase and the I0001
   gate (D338), and this class closes with them.
4. A solution counts only when nothing in it is a hole or an unsolved inference
   variable and it mentions only the caller's generics.

`noteCallExpected` keeps the first expected type with no hole in it; a call
checked against two different expected types is judged against the first.

The counts: 1,204 (first stage 2 run), 53, then 0 for the compiler and stdlib;
49 more in CI for the sources only CI builds; 0 after the second round in the
compiler and stdlib, and the fixed shapes verified by the self-test cases and by
`stdlib_generic_iface_self_test.l`. The CI run of the PR that carries this
amendment is the census for the rest; the error step reads it first.

## Third round: reads of an open-typed value (CI census of the second round)

The second PR's CI logs still showed ten sites: three `core_tests.l` calls that
are true positives (migrated by writing the first `Result` as an annotated
`val`, in the T0224 step) and seven in `lyric-ui` and `lyric-ws` where the
argument is a read of a value the checker could only type with a hole in it: a
loop variable of a generic body (`eventName(h)` over `List[Handler[Msg]]`), a
member read (`replaceAll(s.tree)`, `mapGet(dict.items, key)`) or an index
(`viewOf(children[0])`). The hole is the checker's lost information, not the
user's omission, so a call such an argument feeds is `indeterminate` (never
reported); a construction (`None`, `Ok(value = 7)`) or a call is the user's
omission and is still judged. This is the same class the silent-`TyError` work
closes (D338, D340), after which the exemption can go.

## Order of work

W0035 (this entry), then T0224 from the checker with Mono's site deleted, then
the `Object` fills in Mono's result-type inference and the exemptions as one
named predicate.
