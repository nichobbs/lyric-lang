# D546 - Record construction defaults in the TIR builder (docs/70 phase 3a, #8613)

**Status:** shipped; extends D545 and corrects part of its measurement note.

## Context

D545 placed a function parameter's literal or constant default at a call that leaves it
out. A record construction `P(x = 1)` that leaves a defaulted field out went through the
same argument placement but with a constructor signature built from the record's
fields, which carried no default expression, so it stayed counted.

## Decision

1. The checker's record constructor signature (`recordCtorSigNode`) carries each field's
   default expression (`ResolvedParam.dfltExpr = fd.dflt`). A field with only a zero
   default (an array field, which has no expression) still has none and stays counted.
2. The construction places the default through `buildDefaultArg`, as a call does.
3. Two review notes on D545 are fixed: the doc comments that had slipped onto
   `buildRefPath` and `buildDefaultArg` are back on `buildExpr` and `buildCallArgs`, and
   a default whose type the checker did not record is an I0002 naming the node instead of
   silently taking the parameter's type.

## Correction to D545

D545 said the defaults left over under `a defaulted argument` were record constructions
and imported functions' defaults, the latter waiting for the package interface to carry
defaults (docs/70 phase 4). The census shows otherwise for packages loaded from source:
their signatures carry the default expression, and with record constructions placed the
kind is gone. Only a package restored from a compiled DLL has a signature without
`dfltExpr`; that case stays counted as `a defaulted argument` and is phase 4's.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: `a defaulted argument` 76 -> 0 (5
remain as `a default argument that is not a literal or a name`), I0003 0. Bodies built
stay at 965 of 1165: the bodies that were blocked by a default now reach their next
kind (`an argument conversion` 34 -> 37, `a built-in call needing a conversion` 3 ->
10). Next by count: a name that is not a local (75), a method, constructor or member
call (58), a method call with no declared receiver (39), an argument conversion (37), a
function with no symbol (37).

## Tests

`tir_build_self_test.l`: a literal-defaulted field left out of a construction builds and
verifies; the array-field zero default stays counted.
