# D863: `--target native` lays out a generic interface per instantiation

Status: accepted (#7791, part 2; consumes D513 and D533).

## Decision

1. **A generic interface is laid out per instantiation, like a generic record.** `instantiateGenericIfaceOpt` (the code generator, `llvm_codegen.l`) lays out `Holder[Int]` over the interface's declaration and the argument types: the box and vtable types, the box destructor and each method's erased signature with the interface's parameters replaced by the arguments, registered under `instIrName`. It is reached from `typeToNEnvOpt` (an interface-typed parameter, field or binding) and from the impl's vtable registration. Method-level generics and `Self` inside a generic argument keep their existing diagnostics (N0007, N0006).
2. **An impl of an instance gets a vtable.** `implIfaceInfo` resolves the interface an `impl` names, instantiating a generic one at the impl's arguments; `registerImplVtables` then registers the vtable as for a plain interface. Impl methods keep the AST path's names (`Record.Iface.method`, the interface's bare name), so a record's methods for `Holder[Int]` and a plain interface are named alike.
3. **The bridge drops the checker's T0217 for native** (`MiddleEndOptions.genericInterfaces`), so a construct the checker accepts is either laid out or rejected by the code generator, never miscompiled: an impl of a generic interface for a generic type (`impl[T] Holder[T] for Box[T]`) or with an argument that has no native layout is **N0105**.
4. **TIR registers the instances** (`registerTirIfaceInstances`): each instance of a generic interface in the monomorphised bundle gets the layout the AST path laid out for its arguments, its method entries their vtable slots and each heap record the AST path built a vtable of it for the constant. An impl member is found by the interface's bare name (`tirImplMember` drops the arguments). `lowerUpcast` reads the interface from the expression's type, since `Lyric.Tir.Mono` leaves `CvUpcast.iface` as the generic interface's symbol.
5. **An impl that omits a default method of another package's interface is N0106.** `Lyric.ImplDefaults` copies a default only within a file, and the vtable slot named a function that did not exist (a clang failure); the diagnostic names the method. Tracked in #9451, which has the plan.

## Not done

- A generic implementor (`impl[T] Holder[T] for Box[T]`): N0105. The AST path instantiates a generic impl's methods per record instance (`ensureFnInst`), and the vtable per instance needs the interface instance's arguments in terms of the record's; next slice of #7791.
- A by-value record implementing a generic interface lowers through the AST path, as for a plain interface (TIR does not lower an upcast of a by-value record).
- Cross-package default methods on native: #9451.
- `CvUpcast.iface` after monomorphisation: reported to the mono owner (#8613).

## Verification

`scripts/ci/native-via-tir/genericifaces.l` lowers 11 of 11 functions from TIR with the AST path's output and is clean under AddressSanitizer; `genericifaces_generic_impl.l` is N0105. `default_method_cross_package_self_test.l` runs a cross-package generic interface on dotnet, the JVM and native.
