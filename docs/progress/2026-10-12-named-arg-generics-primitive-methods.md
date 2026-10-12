# Named arguments bind type parameters by name; method calls on primitives and extensions (#8240, #8217, #8219)

## Generic inference pairs named arguments by name (#8240)

`instantiateReturnType` and `checkBoundsSatisfied` unified the callee's
parameters, in declaration order, with the argument types, in source order.
A named argument written out of order bound the type parameter of whatever
parameter sat at its position: for `func pick[A, B](x: inout A, y: B):
List[B]`, `pick(y = 5000000000, x = a)` was typed `List[Int]`, and
`pick(y = "str", x = a)` a `List[Int]` holding a `String`.  The checker
accepted the program and every backend failed it (`InvalidProgramException`
on dotnet, `VerifyError` on the JVM, `N0007` on native).

The type checker now rearranges the argument types into parameter order with
the D171 pairing before inferring (`argTypesInSigOrder`, built on
`argTypesInFieldOrder`), for the return type, for `where` bounds, for the
return type of a dot-named method (whose receiver stays first), and for
method overload selection (`resolveMethodCallPick`'s argument check).
`ArgOrderSite.resultType` (#8180) goes through `instantiateReturnType`, so it
is fixed by the same change.

`Lyric.Mono` inferred each generic call's type arguments the same way, so the
specialisation was still `pick__Int__Int`.  Every inference loop in mono
(free and qualified generic calls, method generics, candidate checks, value
generics, expected-type marking) now pairs through `argSlotsMono`, which uses
the parser's `pairCallArgs`.  Mono also typed an unsuffixed integer literal as
`Int` whatever its value; it is now a `Long` when it does not fit an `Int`, as
the checker types it (#7346), so `pick(a, 5000000000)` (positional) is
specialised at `Long` too instead of truncating the value.

Tests: `typechecker_self_test.l` checks the inferred type of out-of-order
named arguments (a `Long` and a `String` `B`, a mixed positional/named call),
a generic dot-named method in both call forms, and a `where` bound checked
against the argument its parameter names.  `named_arg_eval_order_self_test.l`
runs a `Long` and a `String` `B`, a generic dot-named method and its
type-qualified form, with the evaluation order of each, on dotnet, the JVM and
native.

## Method syntax on a primitive's dot-named function (#8217)

`func Int.twice(self: in Int): Int` called as `k.twice()` type-checked
leniently (method resolution only looked at user types) and then failed on
every target: dotnet at codegen or run time, the JVM and native at codegen.
`Int.twice(k)` worked.

Method resolution now takes a primitive receiver's dot-named functions as
candidates (`dotNamedOwnerName`), so the call is checked against the function
(its result type, arity, argument types, an `inout` receiver's place,
`T0166`), and the call is recorded for the same rewrite into a plain call
`Int.twice(k)` that by-reference dot-named calls use (#8179), with another
package's function named through its package.  A built-in method of the
primitive keeps its meaning in method syntax: the methods the checker types
(`toLong`, `trim`, ...) already won, and `toString()` and the bitwise
`and`/`or`/`xor`/`shl`/`shr`, which every backend lowers itself, are now
excluded from the dot-named lookup too (`isPrimitiveIntrinsicMethod`), so a
same-named dot-named function is reached only through the type.

Tests: `dot_named_primitive_self_test.l` (new, 10 cases, dotnet, JVM and
native, wired into the three batch scripts) covers `in` receivers of `Int`,
`Long`, `Double`, `Bool`, `Char` and `String`, a literal, a call result and a
chain as the receiver, `inout` receivers (a local, a field, a `String`), an
`inout` argument, named arguments in and out of order with their evaluation
order, a default, a generic function, and built-in methods beside same-named
dot-named functions.  `typechecker_self_test.l` checks the result type,
arity, argument types and `T0166`.  `scripts/ci/inout-receiver-e2e.sh` calls a
library's `Int.twice` and `Int.bump` (an `inout` receiver) from a sibling
package and from a restored dependency, by method syntax and through the type.

## Extensions resolve through the imports, on every target (#8219)

A dot-named function a package declares for a type another package declares
(an extension) bound to whichever package's `T.m` registered first: with
`ALib.Bag`, `func Bag.extra` in `BLib` and in `CLib`, and a caller importing
only `BLib`, native called `CLib`'s; dotnet and the JVM could not call an
extension by method syntax at all (`unsupported method 'extra'`,
`NoSuchMethodError`).  Two imported packages declaring it raised nothing.

The rule (docs/01 §5.1, D181) is now: a method call `b.m(args)`, or `Bag.m(b,
args)`, binds the type's own function (from its body or its declaring
package) when one takes the call's arguments; otherwise an extension of a
package the file's imports reach, nearest first as a bare name resolves
(this package, then a whole import, then a package reached through those
packages' whole imports).  Two packages at the nearest level are `T0123`, an
extension the imports do not reach is not a candidate (`T0113` names its
package), and `BLib.Bag.extra(b)` names a package's extension whether or not
that package declares `Bag` (`isPackageDottedCallee`).  An extension call is
rewritten into a plain call of the function through its package, as a
by-reference or primitive one is, so every backend calls what the checker
bound (`bindableDotNamed`, `dotNamedExtensionTier`,
`reportAmbiguousDotNamed`).  A primitive has no declaring package, so each of
its dot-named functions is an extension.

A generic function of another package reaches the calling package as parsed,
so none of these rewrites (nor #8179's by-reference ones) were applied to its
specialisation: a library generic calling `c.grow(5)` (an `inout` receiver),
`c.n.twice()` or an extension failed on dotnet and the JVM once specialised in
a caller.  The declaring package's check of each such specialisation
(`foreignMethodCallArities`, already run for method dispatch, #7828) now also
returns the calls it rewrites, named through that package, and
`rewriteForeignDotCalls` applies them to the specialisation.

Tests: `typechecker_self_test.l` checks `T0123` by method syntax and through
the type (naming both packages), a call through the package, a single
imported extension, a direct import beating a transitive one, an extension
of a package not imported (`T0113`), and the type's own function bound ahead
of two imported extensions.  `scripts/ci/inout-receiver-e2e.sh` runs an
extension project on every target: an extension beside a same-named one of a
package the caller does not import, by method syntax, through the type and
through its package; an `inout` and a generic extension; the caller's own
extension; an extension of another arity than the type's own function; and a
generic function of the extending package, specialised in the caller, whose
body calls its extensions, an `inout` one among them, and a primitive's.

Left open: when the type's own function and an imported extension both take
the call's arguments, the own function is bound (the behaviour before this
change, and the rule of Kotlin, C# and Swift).  The issue suggested ordering the two
by import level like any extensions instead; D181 records the choice and
the alternative as open.
