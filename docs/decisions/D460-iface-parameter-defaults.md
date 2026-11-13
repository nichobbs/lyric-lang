# D460 - A package interface carries each parameter's default as a typed expression (docs/70 phase 5, #8613)

**Status:** shipped; extends D327 and D581. Interface format version 4.

## Context

A call that leaves out a defaulted parameter places the declaration's default expression at the call (D581). The builder
reads that expression from the checker's tables of the callee's own package, so a default declared in another package
could not be built: 66 call sites (62 in the compiler, 4 in the ecosystem) were counted as `a default argument declared in
another package`. docs/70 section 9.2 has the interface carry "defaults as TIR expressions"; phase 5a recorded only
`hasDefault`.

## Decision

- `IfParam` gains `dflt: Option[TExpr]`. It is the default built by the producer from the declaring package's checker tables
  (`Lyric.Tir.Build.buildPackageDefaults`, keyed by the function's DefPath key and the parameter's name), for the functions
  of the package and the methods of its records, protected types and `impl`s. A generic function's default is in terms of
  the function's own `TParam`s, as the carried signature is; the consumer instantiates it at the call like any generic body.
- `iface_expr.l` is the codec and `exprText` the dump form. The kinds are the ones a default occurs as: literals, global
  names, calls by value of a declared function, a host member or an intrinsic, constructions, conversions, list literals
  and tuples. Node ids and spans are not recorded (the consumer numbers its copy afresh, as `refreshDefaultIds` does); every
  other field is, so the producer's round-trip check (I0005, which compares the dump) covers the whole default.
- A default of another shape (a lambda, a block, an `if`) is not carried: `dflt` is `None` and `hasDefault` stays true, so a
  consumer counts the call as it does today instead of guessing. `defaultCarriable` is the producer's test, and writing a
  kind it rejects fails the write.
- The format version is 4. The nodes of a library build are numbered when it writes an interface (the builder's tables are
  keyed by node id), an executable writes none.
- A default of a record field, an interface method and a restored package's own source are not covered: the first two are
  separate consumers of the same data, the last needs the consumer side of phase 5b.

## Consumer

`IfParam.dflt` decoded with the consumer's `DefPathInterner` holds consumer `SymbolId`s. The call-site use
(`buildDefaultArg` for a callee in another package) belongs to the main builder.
