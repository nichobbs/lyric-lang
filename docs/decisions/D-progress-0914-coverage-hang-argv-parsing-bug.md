# D-progress-914 — `lyric test --coverage`'s "2+ hour hang" was an argv-parsing infinite loop, not a JaCoCo/JVM interaction (#6659)

**Status:** shipped

**Context.** #6659 (filed while landing #5294/D135 in PR #6627) documented
`lyric test --target jvm --coverage` hanging for 2+ hours on real GitHub
Actions runners under the JaCoCo `-javaagent` instrumentation, while the
identical non-instrumented test file runs fine in the same job. The CI step
was removed outright rather than shipped hanging. The issue's own
investigation ruled out several plausible causes (instrumentation scale,
`ProcessCapture`'s kernel-level timeout/kill logic) and converged on a JaCoCo
shutdown-hook / `System.exit()` race as the leading hypothesis, noting that
neither of the coverage codegen's own internal timeouts (600s for the
instrumented `java -jar` run, 120s for `jacococli.jar report`) ever fired —
"the hang occurs somewhere the internal timeout doesn't cover."

**Actual root cause: an argv-parsing infinite loop, well upstream of any
JaCoCo/JVM interaction.** `cmdTest`'s argument-parsing loop
(`lyric-compiler/lyric/cli/cli_test.l`) is a `while i < argv.length { if arg
== "--flag" { ...; i += 1 } else if ... }` chain — every branch advances `i`
except one: `} else if arg == "--coverage" { coverage = true }` had no `i +=
1` at all. Any invocation with `--coverage` anywhere in argv (not just at
the end) spun the loop forever re-processing the same argv slot: a pure
CPU busy-loop that never reaches the `java`/JaCoCo codegen the original
investigation suspected. That fully explains why neither of that codegen's
internal timeouts ever fired (the loop that hangs is BEFORE either of them
runs) and why the external `timeout --signal=KILL 900` was the only thing
that ever terminated it. Confirmed empirically in this session: building
`./bin/lyric` from source with the bug still present is not itself
reproducible as a quick check (a busy loop, unlike a real subprocess hang,
gives no external symptom to inspect other than 100% CPU), but adding the
missing `i += 1` and re-running the EXACT command
(`lyric test lyric-compiler/lyric/bitwise_self_test.l --target jvm
--coverage`) that previously required the 900s external kill now completes
in **~4 seconds**, producing a real Cobertura report (`lines-valid="245"`).
`scripts/ci/coverage-smoke-test.sh` run end-to-end also passes cleanly.

**Fix.** One line: `i += 1` in the `--coverage` branch. A regression test
(`cli_test_self_test.l`, "lyric test --coverage: argv parser advances past
--coverage to a later flag") places `--coverage` *before* `--target dotnet`
(not the last argv token) so a still-buggy parser would spin forever right
there instead of ever reaching `--target`'s own validation; the fixed parser
reaches the fast, deterministic "`--coverage` requires `--target jvm`"
rejection, proving forward progress past `--coverage` without needing real
JaCoCo jars staged.

**CI.** The `Coverage smoke test on JVM` step (`compiler-self-tests-jvm`
job) is re-added as a normal (non-`continue-on-error`) step —
`coverage-smoke-test.sh` also gained a background-poll-then-`jcmd`/`jstack`
timeout path (instead of a plain `timeout --signal=KILL`) as defense in
depth for any *future*, unrelated hang in this path, but the fix above is
what actually closes #6659.

**Lesson for the next investigation like this one:** "the internal timeouts
never fired" was the load-bearing clue — it means the hang is upstream of
where those timeouts start being relevant, not "somewhere inside a black
box the timeouts don't reach." A `--coverage`-shaped busy-loop bug in the
CLI's own argv parser was findable by direct code reading (grepping every
branch of the parsing loop for a missing index-advance) without any live
runner access at all; the JaCoCo/`System.exit()` shutdown-hook race
hypothesis, while a real documented category of bug in general, was a red
herring here.
