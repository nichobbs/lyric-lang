# D438 - The builder types the `Future` result of a host call the checker left untyped (docs/70 phase 3a, #8613)

**Status:** shipped; extends D445. The checker is unchanged.

## Context

`Web.Kernel.Runtime.startWorkerLoop` does `val _ = workerExecutor.submit(runnable)` on a `java.util.concurrent.ExecutorService`. `submit` is overloaded on `Runnable` and `Callable`, and the checker recorded no type for the call. The builder's chain typing refused every `java.util.concurrent` result because the checker maps `Future` to its built-in task type.

## Decision

`hostChainResult` takes a `java.util.concurrent.Future` result as the host class itself. The builder is asked only for a call the checker recorded no type for, so there is no checker type to disagree with; a result the checker does type keeps its own type. Other `java.util.concurrent` classes already read as plain host classes (D434).

## Results

`Web.Kernel.Runtime::startWorkerLoop` builds. `jvm_host_kernel_shapes` gains the `submit` shape.
