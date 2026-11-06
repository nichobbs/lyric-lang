# Unsolved type arguments: qualified and method calls (D383)

The checker's table of unsolved calls (`SymbolTable.unsolvedCallSites`) now
holds package-qualified calls (`Pkg.f(x)`) and method or UFCS calls
(`recv.f(x)`), not only single-segment calls. T0224 therefore covers them from
the checker. A dot-named call through its type name is the one shape still
unrecorded, so Mono's T0224 backstop stays for now (#8760).
