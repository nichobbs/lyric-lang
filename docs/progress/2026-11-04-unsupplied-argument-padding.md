# Unsupplied arguments are inference variables, not holes (docs/70 phase 3a, #8613)

First slice of the §5 work that types the remaining silent `TyError` sites.

- `instantiateSigOrdered` padded a parameter the call does not supply with
  `TyError`, the wildcard; it now pads with `TyInfer`, the named unsolved
  variable, so a parameter that binds nothing is no longer indistinguishable
  from an expression the checker failed to type.
- `typeIsUnsolved` (`TyError` or `TyInfer`) is the new predicate. `inferOneGenericArg`
  (a later occurrence fixes a binding an earlier one left open), the by-reference
  pin check and `instantiateSigOrdered` read it; `joinOpenTypes` treats an
  unsolved side as open. `typeIsHole` is unchanged and still means `TyError`.
- Covered by `typechecker_self_test.l` ("a defaulted generic parameter left
  unsupplied binds nothing").
