# CI: stage-2 JVM self-tests run inside build-stage2

`compiler-self-tests-jvm` needed `build-stage2` only for five steps that run
on the stage-2 binary (pattern lowering, silent-miscompile guard,
erased-element checkcast, J3 lowering, NaN comparison). Because of that
dependency it started about 6 minutes after `build` finished, which made it
the critical path of a CI run: `build` (10 min), then `build-stage2`
(6.5 min), then the JVM suite (10.5 min), about 27 minutes in all.

The five steps now run at the end of `build-stage2`, which already has
Java 21 and the stage-2 toolchain, so `compiler-self-tests-jvm` needs only
`build` and runs alongside `build-stage2`. The `stage2-artifacts`
upload/download hand-off goes away, and with it the rule that both jobs
share a CPU architecture (#7025), since the self-contained Native AOT
stage-2 binary is now built and run in the same job.

Verified locally: `scripts/bootstrap.sh --stage 2`, then each of the five
tests passes with `lyric test --target jvm` from a tree holding only the
stage-2 toolchain (about 10 s each).

The same change moves the verifier's platform check
(`Lyric.Verifier`'s `isWindows`) onto `Std.Environment.isWindows()` and
removes the duplicate `OperatingSystem.IsWindows` extern from
`Std.VerifierEnvHost`. `verifier_self_test.l` passes 55/55.
