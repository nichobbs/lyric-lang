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
   through the type. Any other method name on a primitive other than
   `String`, and on a distinct type that does not declare it, is T0113. A
   dot-named function declared through an alias (`alias Num = Int`,
   `func Num.neg`) is the aliased type's (`Int.neg`), for an imported alias
   and an alias chain too; an alias of a generic instance, a function or a
   tuple type cannot name one (T0171).

2. **The type's own applicable function wins.** A method call `b.m(args)`
   and a call through the type `T.m(b, args)` bind the same function: one of
   the type's own, declared in its body or by its declaring package, when one
   is applicable in the Kotlin sense, taking the call's arguments in number
   and type, defaults included. An own function that does not take the
   arguments leaves the call to the extensions. An extension whose parameters
   after the receiver have the number and types of one of the type's own
   functions of that name can never be bound by either form, and is warned
   about at its declaration (T0170); it stays reachable as `Pkg.T.m(x)`.

3. **Otherwise an extension the imports reach, nearest first.** The
   extensions considered are those of packages the file's imports reach, in
   the order a bare name resolves (§9.2): the calling package's, then those of
   a package imported whole, then those of a package reached only through
   those packages' whole imports. A package imported only selectively or under
   an alias does not contribute extensions. At the nearest level an
   applicable extension is preferred; two packages left (an extension with
   defaulted parameters counting when it takes the call's arguments) are
   T0123, the bare-name ambiguity code, since the case is the same collision.
   An extension no import reaches is not a candidate (T0113, whose message
   names the package declaring it, and for a package imported under an alias
   or selectively, the call through it).

4. **`Pkg.T.m(x)` names `Pkg`'s function.** A call through a package reaches
   that package's dot-named function `T.m` whether or not the package
   declares `T`, which is how an ambiguous call is resolved by hand.

5. **The middle end lowers it.** A method call bound to an extension (every
   dot-named function of a primitive is one) is rewritten into a plain call of
   the function through its package, as a by-reference dot-named call is
   (#8179), so no backend chooses among same-named functions itself. Every
   call through the type (`T.m(x, args)`, `Pkg.T.m(x, args)`) that binds a
   method in the type's body is rewritten into the method call, and one that binds another package's own function that a
   same-named function of another package could capture by name is named
   through its package. In a
   generic function of another package, the declaring package's check of the
   specialisation records the rewrite, which is applied to the
   specialisation in the calling package.

## Rationale

Item 3 reuses the import rule a bare name follows, so an extension is
visible exactly where a function of its package would be, and the same
collision gets the same diagnostic.

Item 2 settles the one choice #8219 left open. The issue suggested ordering
the type's own function and the extensions together by import level, which
would let an imported extension take a call the type's own function also
accepts, or make the call ambiguous. It was rejected: an import must never
change what an applicable own-method call means. A type's own functions are
part of its definition (D037 makes a method in its body one of them), and
for opaque and invariant-bearing types they are what maintains the
invariants; a package that happens to be imported must not be able to
replace them. This is the rule of Kotlin, C# and Swift (an applicable
member wins over an extension), and applicability rather than the name
alone decides it, so an extension can still add an overload the type's own
functions do not take. T0170 reports the one case the rule makes useless,
an extension no call can reach.
