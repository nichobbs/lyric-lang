# docs/70 phase 3a: untyped host overloads and `host() ?? []` (D416)

The JVM kernels `Std.TimeHost` (`hostMillis`, `hostSeconds`, `hostMinutes`, `hostHours`, `hostDays`), `Std.ConsoleHost::threadJoinMs`, `Std.Task::runWithin*` and `Std.FileHost::listChildren`/`deleteRecursively` build with 0 I0003. The builder picks the overload of an untyped host call from its argument types (`Math.round(double)` is a `Long`, `Thread.join(long)` is `void`), types a primitive host result, and gives the empty default of `host() ?? []` the type of the coalesce. `Std.FileHost` declares `val children: slice[JFile]` and reads `.length`.

Also from part 10's review: `jvm_host_kernel_shapes` now runs its shapes, a `testdata/reject` case (`nullable_string_read_as_string`) shows a real `String?` read as `String` stays a checker error (the claim D435 rests on), checker self-tests cover the D432 filter for `internal` values and extern functions as well as functions, and `buildPlace` and the builder's doc comments are tidied (the review of #9252).

`Std.HttpHost::readToEnd` (a covariant `Object` bridge candidate of `ByteBuffer.array()`) and the three process kernels' environment overlays build too; a `Unit` block no longer settles its tail to `Unit`, which had given a host call such as `proc.destroyForcibly()` the wrong type (an I0003 in `Std.ProcessCaptureHost::runCmd`, found by the first JVM build of `plugin_e2e_tests.l`). The kernels declare the locals that coalesce a host `getProperty`, `getValue` or `LinkTarget` read.

Not in this PR: `Std.Collections::mapEntries` and `Std.Iter::find` (the non-host kinds, builder part 14).
