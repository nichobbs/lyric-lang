# D380 - The checker counts the contexts that already fix a construction (docs/70 phase 3a, #8760)

**Status:** shipped. W0038 (D353) stays a warning; this removes its known false
positives so CI's logs can serve as the census before it becomes the error.

## Context

The first W0038 census (CI run 41943411204) found 60 sites, almost all of them
constructions the checker already types elsewhere: a join of branches, a tuple
or list element, a nested constructor argument. `unsolvedCallFixed` did not read
those contexts, so it called them unsolved.

## Decision

A construction is fixed, and not reported, when it is:

1. a branch of a value-position `try`: the body and the handlers join like the
   arms of an `if`/`match` (`joinTryBranches`), and the join is the expected type
   of each branch value, also recorded for Mono (`recordBranchConstructionType`);
2. an element of a list literal, whose elements are expected to have the join of
   their types, or of a literal checked against `slice[T]`;
3. an element of a tuple whose expected type is a tuple (`noteCallExpected`
   recurses per element), or a child of an open tuple whose uses fixed its type;
4. a branch value of an `if`/`match`/block that is the operand of `?`: the `?`
   never yields the operand's success value (`operandBranchCtors`);
5. an argument of a union-case construction: its expected type is the field it
   fills, with the construction's holes solved from the construction's own
   expected type (`noteNestedCtorFlow`, through `callParents`);
6. an argument of a call with explicit type arguments, expected to have the
   instantiated parameter type;
7. the value of a lambda body: its expected type is the declared result, also
   when that result names the enclosing function's type parameters, or the
   result of the parameter it fills in a generic call (`noteNestedCallFlow`).

## Census

With the stage-1 compiler of this change, the 60 sites of the first census fall
to none in the compiler self-tests and `core_tests.l`; the library sites
(`lyric-storage`, `lyric-game`, `lyric-ws`, `lyric-search`) no longer report.
The error, and deleting Mono's `ctorFill` and `importedFill`, follow once CI's
logs of this change show no W0038.
