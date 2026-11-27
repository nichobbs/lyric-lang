# D516 - A TIR upcast to an instance of a generic interface names the instance

**Status:** accepted, implemented in `Lyric.Tir.Mono` (docs/70 phase 3c, §7.2; amends D513 item 2)

## Decision

1. **`CvUpcast(iface)` follows the expression's type.** When the converted expression's type is an instance of a generic interface (`Holder[Int]`), the monomorphiser rewrites the conversion's interface to that instance's symbol, as it does for `Callee.Interface` (D513 item 2). Before, the conversion kept the generic interface's symbol while its type named the instance, which the verifier accepted and a backend had to reconcile.
2. A conversion to a non-generic interface, or to a generic one whose arguments are not closed, is as it was.

## Effect

After monomorphisation no interface-typed node names a generic interface, so a backend reads the interface from either the node's type or the conversion.
