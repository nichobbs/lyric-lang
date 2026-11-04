# The three T0224 exemptions are one named predicate (docs/70 phase 3a, #8760)

D339, step three, part one.

- `unpinnedCallKeepsErasedDefault` (`mono.l`) names the three calls whose
  unpinned type arguments keep the erased default (an `@externTarget` generic,
  a name the local environment binds, a call without a source position); the
  checker's `noteUnsolvedCall` exempts the same three. No behaviour change.
- Next: the checker records constructor calls with an unsolved type argument
  (a warning first), so Mono's `ctorFill` and `importedFill` can be deleted.
