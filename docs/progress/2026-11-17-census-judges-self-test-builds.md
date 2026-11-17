# docs/70 phase 3a: the five unchecked self-test builds are judged (D450)

`Lyric.ContractMetaEmit` is staged in the compiler bundle, `contract_meta_emit_self_test.l` runs real `test` blocks in the CI batch, `msil/kernel_self_test.l` compiles again, and the census builds the two JVM-bridge self-tests for dotnet, so no self-test build is left unchecked (cross-package `newList()` default: #9204).
