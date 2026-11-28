# JVM: generic-interface call results are narrowed to the instantiated type (D866)

`+` (and every other primitive operator) over two results of generic-interface methods no longer fails with J008 on `--target jvm` (#9459, part of #7791). The checker records the instantiated primitive or `String` result of a call through a generic interface and the JVM backend unboxes or casts the erased `Object` result to it right after the call. Covered by `generic_interface_self_test.l` on dotnet and the JVM and by the native fixture `genericifaces.l`.
