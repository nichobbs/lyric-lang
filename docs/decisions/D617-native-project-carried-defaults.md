# D617 - A native project build shares one store of carried defaults (docs/70 phase 3a, #8613)

**Status:** shipped; builder wiring only.

## Context

A call that leaves out an argument a sibling package declares reads that default from the package's interface (D482), through one store of interfaces (`DepDefaults`) the packages of a build share. The dotnet and JVM project builds create the store once; the native project build made a fresh one for every package, so each package saw no sibling's interface and its calls were counted unbuilt (I0002, "a default argument declared in another package"): the `Dflt.App`, `Df.C` and `Dr.Main` fixtures of `llvm_project_self_test.l`, where a default calls a function only the declaring package imports.

## Decision

`compileNativeProject` creates the store once and passes it to every package's middle-end options (`nativeMiddleEndOptions` takes it), as the dotnet and JVM project builds do. Nothing else changes: a package registers its interface when it builds one, and the packages checked after it read it.

## Results

The `llvm_project_self_test.l` fixtures build every body they declare under `--verify-ir` (they were the eleven unbuilt bodies of the self-test census).
