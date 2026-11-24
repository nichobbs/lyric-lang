# D533: the native backend lowers the monomorphised TIR of a bundle

Status: accepted (docs/70 phase 4a, part 6; D520 slice 34; consumes D500).

## Decision

1. **One DefPath interner per native bundle.** `Lyric.Tir.Mono.monoBundle` reads the packages of a bundle as one program, so a declaration must be one `SymbolId` in every package's table. The native bridge creates a `DefPathInterner` when `--via-tir` is requested and checks the user package (`MiddleEndOptions.sharedInterner`) and each bundled standard-library package (`checkWithImportedPackagesForTargetIterShared`, `newSymbolTableWith`) with it. Without a shared interner the checker mints its own, as before.
2. **The bridge monomorphises the bundle.** `llvm_bridge.l` builds a `PackageBuild` for the user package and each bundled package, runs `pipeMonoTir`, and gives each unit its own monomorphised TIR as `tir[0]` and the instances package (`Lyric.Mono.Instances`, with `MonoResult.instances` and the instance unions' case lists) as `tir[1]`, shared by every unit.
3. **Instance layouts are the AST path's.** The code generator already instantiates a generic record or union over argument types (`instantiateGenericRecordOpt`, `instantiateGenericUnionOpt`, named by `instIrName`), and a function lowered from TIR must agree with one lowered from the AST on the LLVM type of `Option[Int]`. `registerTirInstances` therefore instantiates each `InstanceInfo` through those functions, from the instance's generic key and the argument types (scalars and types already laid out, resolved to a fixed point), and registers the resulting `TirRecLayout`/`TirUnionLayout` and each case's tag from `PackageBuild.cases`. An instance with an argument shape outside that set stays unregistered, and its users stay on the AST path with a census reason.
4. **Instance functions reuse the AST copy's name and signature.** The AST monomorphiser also specialises every generic function (`ident__Int`). `registerTirInstanceFns` finds the AST copy of an instance function by the name `Lyric.Mono.specFuncName` would give it (`LlvmTir.tirAstTypeKey`), points the instance's symbol at that IR name, and `tirTry` lowers the copy from the instance's TIR body. The mangling follows how the source spelled the argument, so this is checked against the names that exist: an instance with no matching copy has no IR name and its callers stay on the AST path. The mono'd `newList`/`newMap`/`mapKeys`/`mapValues` instances are registered as the intrinsics their generics were. This mapping is removed with the AST path's own generic copies (§13 phase 4a, last step).

5. **Project builds monomorphise too.** Every own package and every bundled package of a multi-package build is checked with the one interner and monomorphised together; each own unit receives its own TIR plus the instances package.
6. **A generic function of another package is instantiated on demand.** The AST path has no mangled copy of such a function; the code generator instantiates it at a call (`ensureFnInst`). A TIR call to an instance with no IR name is recorded by the lowering (`TirLowerEnv.needFns`), the code generator instantiates the generic over the instance's argument types (`instantiateTirFnInst`), registers the IR name under the instance's symbol and the lowering is tried again, as it is for tuple and list layouts. Functions the AST lowering of a call replaces by name (`mapGet`, `dictGetKeys`, `dictGetValues`, `newList`, `newListWithCapacity`, `newMap`, `panic`, `print`, `println`) and the `Std.Collections`/`Std.CollectionsHost` packages are never instantiated this way: their Lyric bodies are not what the AST path runs (a census run caught `mapGet` reading `None` otherwise). The instantiated body is still the AST's; lowering it from TIR follows.
7. **A function whose AST copy is found by name is looked for in every package** (the AST path puts the copy of another package's generic in the package that asks for it), the unit's own copy first, since a copy in a pruned package is not reachable.

## Not done

Tracked in #9370:

- Instance arguments that are `List`/`Map` host types, functions, arrays, value-generic lengths or distinct types (scalars, `Unit`, records, unions, enums, tuples and slices are covered); generic interfaces and impls (3c mono slice 2); `async` instance functions; lowering the on-demand instances' bodies from TIR.

## Verification

`scripts/ci/native-via-tir/fallback.l` (generic record, union and function) now lowers 5 of 5 functions from TIR with the AST path's output and is clean under AddressSanitizer; the two-package project fixture lowers 5 of 5 with a generic record and function crossing the package boundary; the rest of `native-via-tir-e2e.sh` is unchanged in outcome (`lists.l` 11 of 11).
