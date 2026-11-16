# 2026-11-16 - TIR builder: a restored record's interface method call dispatches on the interface (D522)

docs/70 phase 3a, #8613. Clears the last I0003 of the census (`cross_package_generics_self_test.l`, `CpGen.StoreApp::main`): a method a restored record implements resolves to the interface's declaration, so the call is built as an interface call on the upcast receiver. The I0003 census also prints the DefPath key of each symbol a diagnostic names. Self-test: `cross_package_generics_self_test.l` (`describe` through the interface and through the record in one body).
