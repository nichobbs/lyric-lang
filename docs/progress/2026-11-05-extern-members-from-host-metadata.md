# Extern members typed from host metadata (#8613)

D354.

- `ExternIterResolver.resolveMember` (MSIL metadata reader, JVM class reader);
  host results typed as primitives or bound `extern type`s, otherwise the named
  unchecked marker `tyErrorHost()` (not counted by the I0001 gate); TyError
  cascades keep their cause; `List`/`Map`/`Set` `clear()` and `Set.add` are
  `Unit`; slice `.count` is warning W0042; package-qualified union cases and
  `.isSome()`-style calls are typed; qualifier positions are exempt.
- Non-callee silent sites in the compiler and stdlib closure: 327 -> 0. Named
  unchecked classes: `tyErrorHost`, `tyErrorGeneric`, `tyErrorUnresolved`.
