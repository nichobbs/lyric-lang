# Invariant boundary re-checks (#7222) and imported callees in proofs (#7532)

## #7222: public-boundary and `inout` invariant re-checks (D284)

Construction-time enforcement shipped in D-progress-958. This slice adds the
re-checks of docs/08 section 7.1 points 2, 3 and 5 for non-generic types named
in the signature of a `pub` top-level function. The type checker exports the
invariant-bearing types (`invariantBoundaryTypes`); `elaborateMember` adds an
entry check for foreign-typed parameters and exit asserts for foreign-typed
results and `inout`/`out` parameters. See D284 and
`examples/invariant-boundary` (dotnet and JVM).

## #7532: imported functions in `@proof_required` contracts

`Lyric.Verifier.ScopeDecls` now carries the public, non-generic functions of
each resolved package that are `@pure` or carry contracts, take and return
primitives only and name nothing but their own parameters (`callees`).
`registerImportedFunctions` makes them callees of a proof of a file importing
the package, by package-qualified name, import alias and, when unambiguous,
bare name, so `Std.String.isEmpty(s)` is the function applied to its
arguments with its `@pure` body, instead of a value of sort `call.<name>`.
`Std.Core` stays with the monad models.
