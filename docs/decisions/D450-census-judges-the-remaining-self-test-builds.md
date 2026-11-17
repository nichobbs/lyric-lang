# D450 - The census judges the five self-test builds it could not check (docs/70 phase 3a, #8613)

**Status:** shipped; extends D523 and D528.

## Context

The wide census listed five compiler self-tests as "unchecked builds" (the build stopped before the checker's census line), so their bodies were a hole in the count:

- `contract_meta_emit_self_test.l` imports `Lyric.ContractMetaEmit`, which no compiler package imports, so the staged `Lyric.Compiler.dll` (the closure of `Lyric.Cli`) did not contain it and `lyric test` could not link it. Its two tests were `func` declarations, not `test` blocks, so none ever ran, and a cross-package default (`reexports: List[String] = newList()`) builds a `List[Object]` on dotnet (#9204).
- `msil/kernel_self_test.l` passed `0x80000000` (a `Long`) to `bufU4(v: Int)` and no longer compiled.
- `cross_package_generics_jvm_self_test.l` and `field_access_list_of_slice_add_jvm_self_test.l` are .NET programs that drive `Jvm.Bridge` in process (CI runs them without `--target`), but the census built them with `--target jvm` from their names, where compiler packages are not linked.
- `stdlib_jvm_kernels_self_test.l` builds and is judged with the current compiler.

## Decision

`scripts/stage-selfhosted-compiler.sh` names `Lyric.ContractMetaEmit` in its driver so the bundle carries it. `contract_meta_emit_self_test.l` uses `test` blocks, passes `reexports` explicitly (#9204) and joins `compiler-self-tests-batch.sh`. `kernel_self_test.l` passes `Int.MIN` as an `Int`. `tir-census.sh` builds the two JVM-bridge tests for dotnet.

## Results

All five builds print their census lines (`TIR build census`, 0 I0003) and the tests pass.
