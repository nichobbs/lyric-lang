# D513 - The TIR monomorphiser instantiates generic interfaces and their impls (mono slice 2)

**Status:** accepted, implemented in `Lyric.Tir.Mono` and the TIR builder (docs/70 phase 3c, §7.2; follows D500 and D860)

## Decision

1. **An interface is an instantiable type.** The builder's interface entry now carries the interface's parameter count (`typeEntries`; it was 0), so `Lyric.Tir.Mono` makes `Pkg::Holder[Int]` for a `Holder[Int]` as it does for a generic record, and a type mentioning it names the instance.
2. **A call through a generic interface names instances.** `Callee.Interface(Holder, [Int], get, targs)` becomes `Interface(Holder[Int], [], Holder[Int]::get(...), targs)`: the interface-method entry is made under the instance with its signature substituted at the interface's arguments, so no pass after Mono sees an interface argument. A call whose arguments are not closed, or whose interface is not in the bundle, stays as it was and is counted in `unresolved` ("generic interface call").
3. **Impls follow.** An `impl` block with no parameters is kept, its target and interface arguments mapped (`impl Holder[Int] for IntBox` records `Holder[Int]` with no arguments, and the instance's method entries exist). An `impl[T]` block is dropped and instantiated at each instance of its target type: its parameters are bound by matching the target pattern against the instance's arguments, its members are instantiated at those arguments, and the instance impl (`Pkg::Box[T]::$impl[Int](Holder[T])`) is recorded in the instances package over the instance of the target and the instance of the interface. The pass runs to a fixpoint, since a member instance can ask for more instances.
4. **Out of scope, counted in `unresolved`:** a generic impl whose target is not a named generic type, an impl member with type parameters of its own.

## Effect

`Lyric.Tir.Mono`'s output has no generic interface left, so a backend lowering TIR needs one vtable per instantiated interface and one impl per instance; native can drop T0217 once its lowering (phase 4a) uses `TPackage.impls`. D860 item 8 anticipated this.
