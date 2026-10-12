# D181 - A method call binds the type's own function, then an extension the imports reach

**Status:** accepted, implemented (#8217, #8219)

## Context

D037 makes a method in a type's body a dot-named function `T.m` of the
type's package, and lets any package declare a dot-named function at top
level. Two cases had no rule in docs/01:

- A dot-named function of a primitive (`func Int.twice(self: in Int)`). The
  type-qualified call `Int.twice(k)` worked; the method call `k.twice()`
  type-checked leniently and then failed on every target (#8217).
- A dot-named function a package declares for a type another package
  declares, an *extension* (`func Bag.extra` in `BLib` for `ALib.Bag`). The
  checker bound whichever package's `Bag.extra` registered first, whatever the
  caller imported; dotnet and the JVM could not call an extension by method
  syntax at all, and native called one from a package the caller did not
  import. Two imported packages declaring it raised nothing (#8219).

## Decision

1. **A primitive's dot-named functions are methods of the primitive.** A
   method call on a value of a primitive type resolves among them and is
   checked against the one it binds (result type, arity, argument types, an
   `inout` receiver's place). A built-in method of the primitive keeps its
   meaning in method syntax; a same-named dot-named function is reached
   through the type.

2. **The type's own functions come first.** A method call `b.m(args)`, or
   `T.m(b, args)`, binds a function of the type itself, declared in its body
   or by its declaring package, when one takes the call's arguments.

3. **Otherwise an extension the imports reach, nearest first.** The
   extensions considered are those of packages the file's imports reach, in
   the order a bare name resolves (§9.2): the calling package's, then those of
   a package imported whole, then those of a package reached only through
   those packages' whole imports. A package imported only selectively or under
   an alias does not contribute extensions. Two packages at the nearest level
   are T0123, the bare-name ambiguity code, since the case is the same
   collision. An extension no import reaches is not a candidate (T0113, whose
   message names the package declaring it).

4. **`Pkg.T.m(x)` names `Pkg`'s function.** A call through a package reaches
   that package's dot-named function `T.m` whether or not the package
   declares `T`, which is how an ambiguous call is resolved by hand.

5. **The middle end lowers it.** A method call bound to an extension (every
   dot-named function of a primitive is one) is rewritten into a plain call of
   the function through its package, as a by-reference dot-named call is
   (#8179), so no backend chooses among same-named functions itself. In a
   generic function of another package, the declaring package's check of the
   specialisation records the rewrite, which is applied to the
   specialisation in the calling package.

## Rationale

Item 3 reuses the import rule a bare name follows, so an extension is
visible exactly where a function of its package would be, and the same
collision gets the same diagnostic. Item 2 is the rule of Kotlin, C# and
Swift (a member wins over an extension) and keeps the behaviour the checker
already had for a type's own function: an import cannot change which method
a type's own call means, which matters for opaque and invariant-bearing
types whose methods maintain their invariants.

## Open

Item 2 is the one choice here that #8219 did not settle: the issue suggested
ordering the type's own function and the extensions together by import
level, which would let an imported extension take a call the type's own
function also accepts, or make the call ambiguous. That alternative remains
open for review; adopting it changes only `bindableDotNamed` in the type
checker and this entry.
