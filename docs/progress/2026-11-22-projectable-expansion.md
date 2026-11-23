# `@projectable` views as a declaration-expansion pass (D761)

`Lyric.Projectable` appends `<Name>View`, `Name.toView` and `<Name>View.tryInto` as ordinary AST before the check; the MSIL and JVM backends no longer synthesise a projection twin. `msil_self_test_m87.l` and `projectable_jvm_self_test.l` run unchanged on both targets. Docs/70 phase 3a: the `@projectable` bodies of the TIR gate no longer reach the builder as unchecked members.
