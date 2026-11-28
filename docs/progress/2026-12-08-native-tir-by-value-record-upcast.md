# native TIR: a by-value record used as an interface lowers from TIR (D890)

A record with only by-value fields, upcast to an interface it implements, fell back from TIR to the AST path (#9477, part of #7791): TIR's vtable environment held heap records only and `lowerUpcast` rejected a non-reference value. It now copies the record into the `__box<R>` the interface value owns, as the AST path does. Covered by `scripts/ci/native-via-tir/byvalueiface.l` in the native via-TIR e2e.
