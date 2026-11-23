# TIR: a generic method of a generic type from another package (D767)

The symbol entry the builder makes for a method of a generic type declared in another package numbers the method's own type parameters after the owner's, as the call's type arguments are laid out, so `bx.pick(Pt(...))` (`restored-dependency-codegen-e2e.sh`, the `erased` case) verifies.
