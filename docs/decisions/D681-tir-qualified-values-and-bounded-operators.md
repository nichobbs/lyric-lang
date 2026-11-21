# D681 - Qualified cross-package values, operators on a bounded parameter, an untyped module val (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

The census after D680 still counted the project fixtures that read a `pub val` of a sibling package by its package-qualified name (`println(MultiSegVal.Lib.GREETING)`, `Pkg.Lib.neg`), a numeric conversion method on a distinct or refined value used as an operand (`s.toLong() + 1`), `T.default()` bound to a local (`var total = T.default()`), and an operator on a value of a type parameter bounded by `Add` (`total + x`). `msil_codegen_diag_self_test.l` also holds an intentionally rejected program: a module `val` whose host initializer has no type the metadata gives (F0047).

## Decision

- The name a package-qualified read spells is taken from its path or its member chain (`flatSegments`); a `val` of the named package carries its type from that package's interface, whether the checker recorded a reference for the read or not (`openRefValueTy` falls back to `bareForeignValKey`).
- `x.toInt()`, `toLong()`, `toDouble()` and `toFloat()` on a numeric, refined or distinct operand are typed as the primitive they name (`openConvMethodTy`); `T.default()` where `T` is a type parameter in scope is typed as that parameter (`openParamDefaultTy`).
- An arithmetic operator whose left operand has a type parameter's type has that type, and is built as the intrinsic operator on it.
- A read of an unannotated module-level `val` whose initializer the checker could not type is a rejection under the MSIL backend's own code, F0047, at the initializer, as the backend reports it (`rejectUntypedModuleVal`), not an unbuilt body.
- A native project build checks its packages in dependency order (`nativeDependencyOrder`: each after the own packages it imports, input order otherwise), so a consumer reads the defaults its dependency's interface carries (D617); the packages' lists stay parallel by index.
- A fixture that imports `Std.Console` (the large-bundle and package-cycle fixtures) is given the stdlib it names; it was compiled with none, which the checker did not refuse.

## Results

`msil_project_bridge_self_test.l`, `msil_restored_qualified_val_self_test.l`, `nat_cross_package_self_test.l` and `bounded_generic_ops_self_test.l` build the bodies they held unbuilt; the F0047 fixture is `rejected` in the census.
