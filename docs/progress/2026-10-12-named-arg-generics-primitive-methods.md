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

Tests: `dot_named_primitive_self_test.l` (new, 12 cases, dotnet, JVM and
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

The type's own function wins when it is applicable, in the Kotlin sense:
it takes the call's arguments in number and type, defaults included (D181
item 2, decided in review: an import must never change what an applicable
own-method call means).  An own function that does not take the arguments
(`tag(String)` beside an extension `tag(Int)`) leaves the call to the
extensions.

## Follow-up from review

- **Both call forms bind the same function.**  `T.m(b)` bound the caller's
  own same-named dot-named function while `b.m()` bound the type's own
  (`1 10 20 2 10` on every target).  `typeQualifiedDotSig` now resolves
  through `dotNamedCandidatesFor`/`bindableDotNamed`, a method in the type's
  body included.  A call through the type that binds a body method is
  rewritten into the method call `b.m(args)`, and one that binds another
  package's own function a same-named function of another package could
  capture by name is named through its package, so every target calls it.
- **T0170 (warning)**: an extension whose parameters after the receiver have
  the number and types of one of the type's own functions of that name is
  never bound by either call form; it is reported at its declaration.
- **Defaults**: an extension with defaulted parameters is a candidate (and
  takes part in T0123) whenever it takes the call's arguments.
- **Applicability**: the own-function check, and the choice among the
  nearest extensions, compare argument types (`dotNamedApplicable`).
- **Aliases**: `func Num.neg` for `alias Num = Int` is renamed `Int.neg`
  before type checking, with every call through the alias
  (`canonicalAliasDotNamed`).  The native bridge now resolves type aliases
  like the MSIL and JVM bridges (`resolveTypeAliasesNative`); before, any
  scalar alias (`val n: Num`) failed native codegen with N0007.
- **Unknown methods**: a method call on a primitive other than `String`, or
  on a distinct type, naming none of its built-in methods or dot-named
  functions is T0113 at check time (it used to fail at codegen or run time);
  on a distinct type the message points at `.value`.  A `String`'s methods
  stay open-ended (the JVM reaches its host methods by name); the rest of
  #8334 (other receivers) is not covered here.
- **T0113 hint**: for an extension of a package imported under an alias or
  selectively, the message gives the call through it (`EB.Bag.extra(b)`).

Tests: `typechecker_self_test.l` asserts which function binds in both call
forms (the own functions return `String`, the extensions `Int`), an own
function that does not take the arguments, a defaulted extension in T0123,
the alias hint, T0170, and unknown methods on `Int`, a distinct type and
`String`.  `dot_named_primitive_self_test.l` adds an alias-declared and a
distinct-type function on all three targets.  `inout-receiver-e2e.sh` adds
the type's own body method and dot-named function beside the caller's
same-named functions, from a sibling package and from a restored
dependency, in both call forms, and an extension with defaults.

## Second review

- **Calls through the type of a body method.**  The rewrite into the method
  call fired only when a same-named dot-named function also existed, so
  `Bag.one(b)` stopped with an internal error (T0120) on dotnet, and on the
  JVM for a method with arguments; a generic `Box.get(bx)` and a
  cross-package `Bag.get(b)` failed too.  Every call through the type, or
  through the type's package, that binds a body method is now typed against
  it (`bodyMethodViaType`) and written as the method call, its arguments
  paired in that shape for the source-order evaluation (D171).
  `type_qualified_method_self_test.l` (new, 10 cases, all targets) and the
  e2e projects cover it.
- **Aliases resolved like type names.**  The file-local pre-pass is
  replaced: the type checker registers `func X.m` under the aliased type's
  name whenever `X` resolves to an alias (imported, chained, or named
  through its package), records the rename (`SymbolTable.dotNameRenames`),
  and the pipeline renames the declaration after the check; calls through
  the alias are named by the aliased type.  An alias of a generic instance,
  function or tuple type is T0171 (it used to type-check and fail in
  codegen).  The native bridge also resolves a project package's imported
  `pub` aliases.
- **Dependency warnings.**  On the JVM, a path dependency compiled from
  source into the consumer's build no longer reports its type-check
  warnings again (`MiddleEndOptions.quietWarnings`).
- **A body method's own type parameter on dotnet.**  The MSIL backend
  erases a method's own type parameter (`func pairWith[U](...)`), but
  registered the call site's parameter and return types with `U` read as a
  class name, so a bare `U` result was never unboxed:
  `assertEqualInt(bx.pairWith(9), 9, ...)` stopped with
  `InvalidProgramException`.  The emitted MethodDef, the call-site
  registrations and a restored method's MemberRef (records, `impl`s and
  interfaces) now all encode a member's signature through one function,
  `memberSigTypeMsil`, which writes each of the method's own type
  parameters as `object` wherever it occurs (`U` is `object`, `List[U]` is
  `List<object>`), so the two sides cannot disagree.

## Third review

- **No disagreement between the method and its calls.**  The fix above
  first erased the call site's whole `List[U]` to `object` while the method
  kept `List<object>` (`MissingMethodException`); the shared
  `memberSigTypeMsil` replaces it.  `type_qualified_method_self_test.l`
  covers `U` bare and inside a `List`, an `Option`, a tuple and a function
  type, on a generic and a non-generic record, and the e2e restored
  dependency `Box.listV` and `Pt.echoP`.
- **Native: a non-generic record's generic method.**  A method with its own
  type parameters in a non-generic record (`func echo[U]` in `record Tag`)
  was dropped by the native backend (N0007 at the call); it is now
  specialised per call like a generic record's method.
- **The type named through its own package.**  `Main.Bag.two(b, 1, 2)` in
  `Main` reached the checker as a member chain, which bound the method but
  never recorded the rewrite, so dotnet (T0115) and the JVM (J008) failed;
  a dot-named function called that way (`Main.Bag.top(b)`) is now named by
  its own name for the backends too.
- **T0171** suggests the working declaration
  (`func Box.get(self: in Box[Int], ...)`).

## Restored-dependency regression (#8097)

- **Both kinds of the type's own function.**  A package may declare a
  method in a type's body and a dot-named function of the same name
  (`func scaled` in `record Acc` and `pub func Acc.scaled`); #8097 tests
  that `acc.scaled()` binds the body method and `Acc.scaled(acc)` the
  dot-named function.  The first D181 change bound the body method through
  the type too (`restored_default_args_self_test.l` printed -3 for 12).  A
  call through the type now names the type package's dot-named function
  whenever that package declares one (so a parameter it declares without a
  default stays required, as #8097 tests), and the body method only when it
  declares none; a method call binds the body method first and falls back
  to the dot-named function; extensions come only after the type's own.
  The typechecker self-test covers both forms, the method-call fallback,
  the required parameter, the own-package prefix and a call from another
  package, with no T0170 for the type's own package.
- **Through the declaring package too.**  `Pkg.T.m(x)` with no dot-named
  `T.m` of `Pkg` taking the argument count fell through to the body method,
  so `Main.Acc.trim(a)` and `ALib.Acc.trim(a)` type-checked and then failed
  in codegen (T0120 / J008).  The package's function is now named whatever
  the count, and the count is reported against it (T0042); the typechecker
  self-test and `restored_default_args_self_test.l` cover both.
