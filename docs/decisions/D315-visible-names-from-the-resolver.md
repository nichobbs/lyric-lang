# D315 - What a bare name can mean comes from `Lyric.Resolve` (docs/70 phase 2c, #8612)

**Status:** shipped for the checked package's own scope. Step 5 of docs/70 §13
phase 2c, after D314.

## Context

D314 made `symTableTryFindOne` take the resolver's single answer. The checker
still had two ways to ask "every symbol with this name": `symTableTryFindAll`,
which ignored the file's imports altogether (about two dozen callers), and
`symTableTryFindAllVisible`, which applied the checker's own import rule. The
resolver has no unfiltered lookup (§4.4), so neither could be deleted.

## Decision

1. **`Lyric.Resolve.visibleDecls`** gives every declaration of a name the file
   can reach, whatever the tier or visibility: its package's, those of the
   packages it imports whole (and what they re-export), the names its selective,
   renamed and `import extern` imports bind, and the prelude, in registration
   order. It takes the file's scope; it does not pick. A pass that must see
   every meaning of a name (the cases that share one, the arities of an overload
   set a local function shadows) uses it.
2. **`symTableTryFindAllVisible` answers from it** for the checked package's
   scope, mapped to symbols by DefPath, plus the symbols that name no package
   (built-ins, `import extern` bindings). A dependency's signature scope keeps
   the checker's scan.
3. **`symTableTryFindAll` is renamed `symTableTryFindAllNamed`** and is only for
   a caller that narrows by something the declaration is known by: a package
   qualifier the file was already allowed to write, the `SymbolId` of an owner
   type, a declaring package, the type-qualified name of a dot-named function
   (a method, which the resolver reaches through its type and does not index by
   name). The bare "what does this name mean here" callers moved to
   `symTableTryFindAllVisible`, except three that are program-wide by design
   and stay on the unfiltered lookup:
   - the checks that a case or enum name is shared with another package's
     (`nameIsSharedUnionCase`, the enum-case and enum-name checks in
     `inferExpr`): a bare case that two packages declare is told apart by the
     callee's parameter type or the expected type, whatever the caller imports
     (#6688). Narrowing them to the visible set made `B.log(Debug)` bind to the
     caller's own `Level`; `enum_case_collision_self_test` pins it. Tightening
     `nameIsSharedUnionCase` is #8722 (`regex_tests.l` constructs `TimedOut`
     through a package imported only under an alias);
   - the value-generic callee and the two dot-named-callee checks, whose names
     (`Shape.size`) are methods of a type that the resolver reaches through
     the type, not by name.
4. **Differential mode compares the sets** (`R0002`: the declaring packages and
   kinds the scan and the resolver give), beside `R0001`.

## Consequences

- No source or behaviour change intended; the census (`scripts/ci/resolve-diff.sh`,
  now `R0001` and `R0002`) is the check.
- Still the checker's own: the scan under a dependency's scope, the hidden-import
  hint, the sibling-file (T0219) rules, and `symTableBareFuncVisible`. They go
  when dependency scopes join the resolver (#8612).

## Verification

`resolve_self_test` (visibleDecls over tiers, selective and renamed imports),
`typechecker_self_test` (1057, unchanged), the reject corpus and the census.
