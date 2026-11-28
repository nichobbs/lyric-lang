# D890: native TIR boxes a by-value record that implements an interface

Status: accepted (#9477, part of #7791).

## Decision

On `--target native` a record whose fields are all by-value (scalars, enums, other by-value records) is a struct **value**, not a heap object. A value of one used as an interface it implements is copied into a fresh `__box<R>` (an ARC header and the record) that the interface value owns, and the vtable's slots are thunks that read the record back out of that box (#8010). The AST path built it; the TIR lowering did not: `ifaceVts` (the TIR environment's `<record>|<interface>` table) held heap records only and `lowerUpcast` rejected a non-reference value, so **every function that upcast a by-value record to any interface**, plain or generic, in one package or across two, fell back to the AST path (#9477 first described this as a cross-package generic-interface gap; it is neither).

- `TirRecLayout.valueBoxTy` carries the `__box<R>` pointer type for a by-value record that some `impl` makes an interface (`NVoid` otherwise); `registerTirIfaceInstances`' environment now keys every record that has a vtable, by-value included, in `recIrById`.
- `lowerUpcast` for a non-reference value allocates the box (`allocObject` with no destructor, as the AST path's `boxByValue`), stores the record at the payload slot and hands the box to the interface box as its object, without the retain a heap record gets (the box is already owned).
- A missing vtable now reports the vtables the environment does hold for the record and for the interface, so a key registered under another instance shows.

## Not done

Nothing for #9477 remains: the generic and cross-package shapes it named lower from TIR through the same path (a by-value record with `Holder[Int]` from another package, `scripts/ci/native-via-tir/byvalueiface.l` covers the generic interface in one package). The cross-package case differs only in names.

## Verification

`scripts/ci/native-via-tir/byvalueiface.l` (a by-value record through a plain and a generic interface, on the record, an inherited default): every function lowered from TIR, the same output as the AST path, clean under AddressSanitizer (`scripts/ci/native-via-tir-e2e.sh`).
