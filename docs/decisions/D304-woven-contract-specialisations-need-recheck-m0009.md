# D304 - A woven aspect contract whose generic call needs a re-check is M0009 (#8665)

**Status:** shipped (`Lyric.Pipeline.specialiseWovenContracts`; all targets)

## Context

`pipeCheckAndMono` re-checks a specialisation that binds a type parameter to
`UInt`/`ULong` (#7842), that uses `==` on a named type (D172 item 4), or that
needs an operator bound (M0008), then runs mono again with what the check
recorded. Aspect contracts exist only once the weaver has built a wrapper, so
a generic call in one (`ensures: isSome(result)`, #7530) is specialised by a
second plain mono run over the woven file. That run had none of the re-checks:
a contract calling a generic whose body compares or divides a `ULong` was
specialised with signed semantics, silently.

## Decision

1. After the second mono run, `specialiseWovenContracts` collects the
   specialisations it made that the first pass would have re-checked (the same
   predicate: `unsignedSpecs`, and `structSpecs` that use equality or
   rendering in the local package or are operator-bound).
2. Any such specialisation is **M0009**: "cannot specialise '<name>' in an
   aspect contract". The program is refused rather than compiled with the
   wrong operand semantics. A contract that calls a non-generic function, or a
   generic whose specialisations need none of these, is unaffected.
3. The T0123 text for an unresolved call in a generic body specialised into
   another package no longer says "make `<f>` `pub`" when `<f>` already is: it
   says the name did not resolve in the declaring package's scope and names the
   packages searched (the declaring package and its imports).

Running the re-check and a third mono loop over the woven file would remove
the restriction; it needs the type-check context `pipeWeave` does not hold, and
is left until a program needs it.
