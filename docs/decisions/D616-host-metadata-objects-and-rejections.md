# D616 - Host calls the metadata cannot resolve: the root object's members, and the backend's own errors (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker accepts exactly what it did.

## Context

Four fixtures of `jvm_auto_ffi_bridge_self_test.l` and one of `emitter_project_self_test.l` call a host member the metadata cannot place, and the typed IR builder counted each unbuilt (I0002), so the always-on gate (D347) would have stopped a build the backend handles:

- `toString()`, `hashCode()` and `equals(x)` on a value of an `extern type` whose class is not located (an absent Maven class): the JVM backend binds them to `java.lang.Object`'s descriptors (#6565) and boxes a primitive argument first (#6718). The builder had no member to bind.
- A method the root object does not declare, called on such a value, and `T.new()` on an abstract class, and a field read on a located class that declares none: the backend aborts the build with `error[J008]` ("no matching instance or inherited method"), `error[J005]` and `error[J009]`, and the tests assert exactly that. An I0002 would say the builder has a gap, which is not what is wrong with these programs.

## Decision

A host call whose class the resolver cannot locate (`resolveBases` answers none) and whose member is one every host reference type inherits (`toString`, `hashCode`, `equals(x)`) is a call of that member of the root object class of the active target (`java.lang.Object` or `System.Object`, the one whose metadata resolves). The receiver is boxed to the root object by an explicit `CvBoxToHost`, as a value of a type parameter is, and an argument converts to `Object` through `hostArgConv`, so `equals(5)` carries an explicit boxing of `5`.

A program the host metadata shows can never link is a rejection, not a gap. The builder answers it with a message under the backend's own code and wording and does not count an uncovered kind: `J005` for `new` on a class the resolver reports abstract (`ExternIterResolver.resolveIsAbstract`, answered by the JVM resolver from the class file and left open by the dotnet one), `J008` for a call on a located class's member the class does not have, and for a call on the untyped result of an unknown member of an unlocated class (the backend types that result `java.lang.Object`, so it names a member of `Object`), `J009` for a field read on a located class that has none (`J007` when the receiver is a field declared at a type parameter, which the JVM backend reads as its erasure), and (on dotnet) `T0119` for a static member read (`MathX.PIE`) of a located class that declares none. `FnBuildFailure.rejected` marks such a body; the census prints it as `rejected` beside `built` and `unbuilt`, and leaves it out of the bodies it counts, as it leaves out a program the checker rejects. The gate reports it under its own code. The backend's checks stay.

## Results

`NoMetadataObjectMethods` (3 bodies) and `EqualsPrimitiveArg` (2) build with the verifier clean; `AbstractCtor`, `NoMetadataUnknownMethod`, `ContainJ009`, `KnownClassNoField` and `ExternMemberTypo` are rejections and no longer unbuilt bodies. The 26 `Ws.Kernel.Jvm` and `Web.Kernel.Runtime` bodies that the earlier census listed were an artefact of the self-test's build lacking the Maven jars: with `lyric restore` of lyric-web and lyric-ws, as CI does, none is left.
