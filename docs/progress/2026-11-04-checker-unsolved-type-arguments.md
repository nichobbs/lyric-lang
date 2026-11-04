# The checker reports an unsolved type argument as W0035 (docs/70 phase 3a, #8760)

D339, step one.

- `SymbolTable.unsolvedCallSites` keeps each call to an imported, non-extern
  generic whose arguments leave a type argument unsolved;
  `SymbolTable.callExpectedSeen` keeps the type expected of each call.
  `reportUnsolvedTypeArgs` reports what neither a recorded type-argument site,
  an open binding nor the expected type fixed, as the warning W0035, at the end
  of `check`. Mono still reports T0224.
- Census over the compiler and stdlib closure with the rule on: 1,204 hits
  (constructor fields), 53 (`if`/`match` arms), then none.
- Next: T0224 from the checker with Mono's site deleted, then the `Object`
  fills and the exemption predicate.
