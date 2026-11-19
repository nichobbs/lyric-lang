# D416 - The builder chooses an untyped host overload by its argument types, and types a primitive host result (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444 and D445. The checker is unchanged: docs/01 section 2.11 still leaves a host result unchecked, and there is no typing rule for `host() ?? default`.

## Context

The JVM kernels `Std.TimeHost` (`hostMillis` to `hostDays`), `Std.ConsoleHost::threadJoinMs`, `Std.Task::runWithinThreadJoinMs`, `Std.FileHost::listChildren` and `deleteRecursively` stayed counted for three reasons.

- `Math.round(float)` returns `int` and `Math.round(double)` returns `long`; `Thread.join(long)` returns `void` and `join(Duration)` returns `boolean`. The checker gives a host call whose overloads of one arity disagree on the result no type, and `hostChainResult` (D444) refused a member whose candidates disagreed, so `Duration.ofNanos(JMath.round(n * 1000000.0))` had an untyped argument.
- `hostChainResult` typed a host-class result only. A primitive result (`long`) of a static host member was never typed.
- `val children = d.listFiles() ?? []` has no type: the checker has no rule for `??` over an unchecked host result, and the empty list had nothing to take its type from.

## Decision

- `hostChainResult` takes the checker's types of the call's arguments. When the candidates of one arity do not agree, it keeps the candidates whose parameters fit those arguments best (`scoreOverload`, the scoring `buildExternCall` already uses to pick the call's overload) before it compares their results. A tie between different parameter lists, a named argument or an untyped argument leaves every candidate, so a call the arguments do not settle stays counted.
- A primitive host result (`EIEPrim`) is typed as the Lyric primitive.
- `a ?? b` settles an untyped `b` to the type of the whole expression, as `x == None` settles its right operand to the type of the left. The kernel declares the type of the local it binds, as docs/01 section 2.11 and D436 spell it: `val children: slice[JFile] = d.listFiles() ?? []`. Reading the declared `slice` with `.length` replaces `.count`, which only `List`, `Map` and `Set` have.

- **Covariant bridge candidates.** Among disagreeing candidates, one that is the host's root `Object` is the bridge method of a covariant override and the other is the member a call binds (`ByteBuffer.array()` is `byte[]`, `Buffer.array()` is `Object`).
- **A host value as a `List[JObject]` element.** `coerceArg` boxes a host value passed where the host's root `Object` is wanted (`args.add(address)`) with `CvBoxToHost`.
- **A `Unit` block does not settle its tail.** `settleBlockTail` skips a `Unit` block: its tail is discarded, so `Unit` says nothing about the tail's own type, and an untyped host call kept its real result (`if stop { proc.destroyForcibly() }` was an I0003, `call-result-type: expected Process but found Unit`).
- **Kernel locals.** The kernels declare the host results they bind, as docs/01 section 2.11 asks: the dotnet `LinkTarget ?? ""` reads in `Std.FileHost`, the JVM `getProperty`/`getValue` reads in the plugin, config-override and annotation-meta kernels, and the three `val _ = env.put(k, v)` of the process kernels.

## Results

On `--target jvm`, `Std.TimeHost`, `Std.ConsoleHost::threadJoinMs`, `Std.Task::runWithin*` and `Std.FileHost::listChildren`/`deleteRecursively`, `Std.HttpHost::readToEnd` and the three process kernels' environment overlays build with 0 I0003; `plugin_e2e_tests.l` builds on `--target jvm` with only `Std.Collections::mapEntries` unbuilt. `tir-builder-shapes-e2e.sh` gains `jvm_host_overload_shapes` (built and run), and `jvm_host_kernel_shapes` now calls its shapes.
