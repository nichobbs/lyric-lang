# D864: `--target native` lays out an impl of a generic interface for a generic record

Status: accepted (#7791, part 2; extends D863).

## Decision

`impl[T] Holder[T] for Box[T]` is laid out per instance of the generic record, as `impl[T] Shape for Box[T]` already was for a plain interface (`genericImplVtable`, one vtable per instantiation): an upcast of a `Box[Int]` to `Holder[Int]` builds the vtable on first use from the impl's methods specialised at `Int`, over the interface instance the upcast names. Only the interface's name was ambiguous: an instance is keyed `Pkg.Holder<i32>`, so `genericImplVtable` reads the impl's method names from the part before `<`.

`N0105` now covers the generic impls this path does not handle: a target that is not a generic record applied to the impl's own type parameters in order (a generic union; the checker already rejects `Pair2[T, Int]` as T0145).

TIR does not lower an upcast of a generic record instance to an interface instance (the instance's vtable is built by the AST path on first use), so the functions that do it keep the AST lowering with a census reason; the output is the AST path's.

## Not done

- Lowering the generic impl's member instances (`Box[Int]::$impl(Holder[Int])::get`) and the upcast from TIR.
- A same-file default method called on a concrete generic implementor (`b.twice(9)`): #9454, an I0002 on every target, not specific to native.
- A generic interface laid out for a generic union implementor.
