# D869: native inherits a default method of another package's interface

Status: accepted (#9451, part of #7791).

## Decision

dotnet and the JVM dispatch a default method that an impl omits on the interface's own default method (D861, D862), so an impl in another package inherits it with no code of its own. Native has no default interface methods: every vtable slot names a function of the impl. Until now a native build of such an impl stopped with **N0106** (D863).

`Lyric.ImplDefaults.inheritCrossPackageDefaults` runs over every package file of a native project build, **before the type checker** (in `llvm_bridge.l`, ahead of `pipeExpandAndRewriteForTo`), so what it generates is checked and lowered like source the user wrote, from TIR:

- the declaring package gets one `pub` free function per default an impl omits, `__lyric_default_<Interface>_<method>[<interface parameters>](self: in <Interface>[...], ...)`, holding the default's own body: it is checked in the declaring package's scope (its private helpers and imports resolve there), `Self` is the interface type, and each bare call of an interface method is written `self.m(...)` (`SelfFields.resolveSelfMembersInBody`);
- the impl gets a member of the default's name that calls that function with `self`, qualified as the impl names the interface. The body then runs on the interface value, as a default interface method does: a call it makes on the interface goes through the vtable back to the impl, and a generic interface's parameters are the free function's type parameters, instantiated at the impl's arguments.

A default native cannot lift this way (a `Self` in a parameter or result, `async`, an `out` or `inout` parameter, a default value, a method of its own type parameters, or an interface named through a selective import) is left alone, and the impl is still **N0106**, naming the method. Generated items take fresh spans through `Expand.respanGenerated`, as stubs do. `Lyric.Mono.substTypeExpr` now substitutes `Self` when a substitution binds that name.

## Not done

The checker does not type-check an interface default body unless an impl inherits it (#9471); the generated free function is the first place it is checked once, in the declaring package, on native. An interface of a standard-library package is not in the build's project files, so a user impl that omits a stdlib default is still **N0106** (no stdlib interface has one today).

## Verification

`default_method_cross_package_native_self_test.l` builds and runs two-package projects on native: a default on the concrete type and through the interface, a default that calls a private helper of the declaring package and another default, a generic interface's default, and the `Self`-parameter case that stays N0106.
