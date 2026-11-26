# D864: `--target native` lays out an impl of a generic interface for a generic record

Status: accepted (#7791, part 2; extends D863).

## Decision

`impl[T] Holder[T] for Box[T]` is laid out per instance of the generic record, as `impl[T] Shape for Box[T]` already was for a plain interface (`genericImplVtable`, one vtable per instantiation): an upcast of a `Box[Int]` to `Holder[Int]` builds the vtable on first use from the impl's methods specialised at `Int`, over the interface instance the upcast names. Only the interface's name was ambiguous: an instance is keyed `Pkg.Holder<i32>`, so `genericImplVtable` reads the impl's method names from the part before `<`.

`N0105` now covers the generic impls this path does not handle: a target that is not a generic record applied to the impl's own type parameters in order (a generic union; the checker already rejects `Pair2[T, Int]` as T0145).

TIR does not lower an upcast of a generic record instance to an interface instance (the instance's vtable is built by the AST path on first use), so the functions that do it keep the AST lowering with a census reason; the output is the AST path's.

## A default copied into a generic implementor (#9454)

`Lyric.ImplDefaults` copied a default method into an `impl[T]` block with the interface member's own span, and a concrete call on the implementor (`b.twice(9)` on a `Box[Int]`) had no callee on any target (I0002, "no usable type for a type parameter with no registered binder"): member lookups match a signature by span, and the interface's member and the copy were one to them. The copy now gets its own span (the impl's start, the member's end). `generic_interface_self_test.l` (dotnet and JVM) and `genericifaces_generic_impl.l` (native) call the inherited default on `Wrapped[Int]`/`Box[Int]` and `Box[String]`.

## Not done

- Lowering the generic impl's member instances (`Box[Int]::$impl(Holder[Int])::get`) and the upcast from TIR.
- A generic interface laid out for a generic union implementor.
