# D500 - Monomorphisation on TIR: instances are ordinary symbols in one synthetic package

**Status:** accepted, implemented as `Lyric.Tir.Mono` (docs/70 phase 3c, §7.2, §7.3; #8613)

## Decision

1. **The pass is `Lyric.Tir.Mono.monoBundle(interner, bundle): MonoResult`**, a pure `Lyric.Tir` to `Lyric.Tir` function over the built packages of a bundle (`PackageBuild`s). There is no inference: a generic call's type arguments (`Callee.Direct.typeArgs`, `XGlobal.typeArgs`) and a construction's, field's and pattern's type fix the instance. `Lyric.Tir.Verify` runs on the output (`verifyMonoBundle`).
2. **An instance is an ordinary symbol.** Its DefPath key is the generic's key with the canonical, name-based rendering of the arguments in brackets: `Std.Core::Option[Int]`, `Std.Core::Option[Int]::Some`, and for a function the brackets go before the parameter list, `App::map[Int,String](P1,P2)`. The key is interned on the shared `DefPathInterner`, so one `(generic, arguments)` is one symbol in the whole bundle. The table `(generic, arguments) -> instance` is `MonoResult.instances`.
3. **Every instance lives in one synthetic package, `Lyric.Mono.Instances`**, the last package of the result: an instance can name types of several packages (`Option[UserRecord]`), so a home in the generic's package would create unit-ordering cycles. The generics themselves are dropped from the output; non-generic declarations stay in their own packages with generic applications in their types replaced by instances. Instance records and unions are `TSymEntry` (`TSkType` with concrete fields, `TSkCase` with concrete signatures) and instance functions are `TFnDecl` with `typeParams = []`; `cases` of the instances package keeps each union's cases in declaration order (tag = index).
4. **Value-generic parameters** (`XValueParam`, `ALParam`, `TLen`, D467/D469) are substituted by the length the call fixes, with the type parameters.
5. **Instance bodies have fresh node ids** (from 500,000,000), so node ids stay unique within the instances package.
6. **Termination.** An instance whose key would pass 1500 characters is polymorphic recursion: the pass reports `M0010` and leaves the call as written.
7. **The builder describes every union.** `typeEntries` gave a union `typeParamCount` 0 and only the cases a body reached had entries; the pass needs a union's arity and every case, so `buildPackage` now records both (`unionDeclGenericNames`, `noteCaseSym` over `caseSymbolsByParent`).
8. **Policy.** This slice monomorphises everything, which is the native target's policy (docs/70 §7.3); MSIL's reified in-bundle generics and the JVM's erasure are policies of later slices.
9. **Census.** `lyric build --verify-ir` prints `I0003 mono census [label]` for each built package (the package alone as the bundle, so a dependency's generics are `unresolved`).

## Not done

Generic interfaces and impls of generic interfaces (`Callee.Interface` with arguments stays, counted in `unresolved["generic interface call"]`), generic distinct types, and calls of generic functions whose body did not build stay as written and are counted. Contract elaboration, `?` propagation, the typed lowerings and await hoisting on TIR are the next slices of phase 3c.
