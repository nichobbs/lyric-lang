# D-progress-883 — JVM codegen: closures get the same `maxStack = 16` safety floor top-level functions already carry for the known `try`/`catch` stack-tracking under-count (#6714)

**Status:** shipped

**Context.** `defer { … }` + `try { … } catch … { … }` inside a closure body,
capturing two extern-typed values plus a captured closure parameter (not just
a captured local), with a call to a separate function inside the `try`, hit
`VerifyError: Operand stack overflow` at class load — found while fixing
#6711 (PR #6709), not itself blocking anything landed since the production
shape it was found alongside (`_kernel_jvm/regex_host.l`'s
`raceWithDeadline`) verified to lower correctly, but a real, pre-existing gap
worth tracking.

**Root cause.** `Jvm.Lowering.lowerFuncForClass` computes the emitted
method's `maxStack` as `max(caller-supplied maxStack, asm.peakStack)` — a
deliberate design (see its own `actualMaxStack` comment) because
`asm.peakStack`'s tracked stack-depth simulation is a KNOWN under-count for a
function containing `try`/`catch` (confirmed for `Std.Testing.
runAndCapturePanic`, the #6089 follow-up). Every top-level `func` already
carries an explicit `maxStack = 16` floor for exactly this reason. A
closure's synthesised `invoke` method (`lowerClosureMethod`) is the ONE other
caller of `lowerFuncForClass` that lowers a full statement/`defer`/`try`
body — and it passed `maxStack = 0` (no floor at all, "trust `asm.peakStack`
exactly"), the one caller left uncovered by the established mitigation.

**Fix.** `lowerClosureMethod` now passes `maxStack = 16`, matching top-level
funcs. This is not a new workaround: it applies the SAME accepted,
already-shipped idiom this codebase uses everywhere else for this exact
known gap, closing an inconsistency rather than introducing one.

**Verification.** New `closure_jvm_self_test.l` cases pin the exact reported
repro shape (`defer` incrementing a captured `AtomicInteger`, a `try` calling
a separate function against a captured closure parameter, a `catch Bug`
setting a captured `AtomicBoolean`) on both the no-fault and faulted paths —
`closure_jvm_self_test` 16/16. No regression in the broader JVM self-test
sweep (`record_method_jvm_self_test`, `out_inout_jvm_self_test`,
`out_inout_instance_jvm_self_test`, `control_flow_jvm_self_test`,
`try_catch_expr_jvm_self_test`, `silent_miscompile_guard_jvm_self_test`,
`middle_end_passes_jvm_self_test`, `jvm_bundle_leak_reachability_self_test`
all green).
