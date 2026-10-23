# Buffer value semantics: spawn snapshot on the JVM, copy-before-write-loop warning (#8391, #8395)

- **#8391.** On `--target jvm` a spawned call evaluated its whole operand inside the task, so the copy the checker
  records for an `array[N, T]` or `buffer[T]` argument ran when the task started, after any write the spawner made
  next (`expected 109, got 909`). `Jvm.Codegen.lowerSpawnSubmit` now evaluates each copied array or buffer argument
  of the spawned call into a fresh local when `spawn` runs and the task captures that local (`hoistSpawnCopyArgs`).
  The operand keeps its `spawn f(args)` shape, so the MSIL spawn-handle pre-scan is unaffected.
  `buffer_spawn_self_test.l` now also covers `array[2, Int]` and `array[2, String]` and runs on the JVM
  (`jvm-generics-self-tests-batch.sh`).
- **#8395.** New checker warning **W0030** (docs/01 section 2.7, docs/67 section 9): a `var` initialised by copying a
  buffer place and directly followed by a loop that writes through it. Covered by `typechecker_self_test.l`.
- Also fixes `explicitTypeArgCallType` passing `args.count` to `findDirectSig` (main did not bootstrap under the
  released stage-0 compiler); the same one-line fix is in #8474.

Left open: #8389 (lazy shared-mark buffers on dotnet/JVM), #7955 (explicit mutable-record form), #7941 (G2 tracker).
