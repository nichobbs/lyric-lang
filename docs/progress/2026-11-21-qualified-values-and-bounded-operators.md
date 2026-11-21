# Qualified cross-package values, operators on a bounded parameter, an untyped module val (D681)

The TIR builder now types a package-qualified read of a sibling package's `val` from that package's interface, a conversion method on a distinct or refined operand, `T.default()` bound to a local and an operator on a bounded type parameter, and reports an unannotated module `val` with an untypeable host initializer as the backend's F0047 rejection. Checker unchanged. Census over the affected self-tests: see the #8613 handoff.
