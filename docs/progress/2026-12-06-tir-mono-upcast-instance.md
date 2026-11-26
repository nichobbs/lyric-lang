# A TIR upcast to a generic-interface instance names the instance (docs/70 phase 3c, D516)

## What shipped

- `Lyric.Tir.Mono` rewrites `CvUpcast(iface)` to the instance of a generic interface when the expression's type is one (D516, amends D513 item 2; reported by the generic-interfaces session).
- `tir_mono_self_test.l`: `val h: Holder[Int] = IntBox(v = 3)` upcasts to `App::Holder[Int]` and the bundle verifies.
