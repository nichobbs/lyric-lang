# lyric-jobs: unimplemented backends removed from the public API (D552 item 2)

`Jobs.connectHangfire()` and `Jobs.connectQuartz()` returned `Err("... not yet
implemented")` on `dotnet`. The JVM Quartz Scheduler binding was checked
before deciding its fate, by reading `src/_kernel/jvm/jobs_kernel.l` and
running it (`--target jvm --no-default-features --features jvm,quartz`, the
only test is `"NativeJobScheduler (quartz feature): ..."`, passing 66/66 plus 3
aspect tests):

- The Quartz jobs run `org.quartz.jobs.NativeJob` with the fixed command
  `true`. No application handler can ever run, so a "Succeeded" status means
  only that Quartz removed the one-shot job from its store.
- `NativeJobScheduler.enqueue` never accepted a `JobHandler` on either target,
  and running a Lyric callback needs JVM `impl <ExternInterface>` support that
  does not exist.
- The only test covers enqueue, poll, cancel and an unknown id. `schedule`
  (cron) and `results()` have no coverage, and the test file records that
  `results()` is affected by a JVM enum-argument defect.
- `scripts/ci/jvm-ecosystem-suites.sh` ran the jobs suite with
  `--features jvm,inprocess`, so CI never compiled or ran the Quartz path.

It was therefore removed with the dotnet stubs. Removed: `NativeJobScheduler`,
`Jobs.connect`, `connectHangfire`, `connectQuartz`, `cronExprToQuartz` and the
kernel dispatchers (the `JobScheduler` interface and `InProcessJobScheduler`
stay), the `inprocess`/`hangfire`/`quartz` features, the `[nuget]` and
`[maven]` tables, the `ConcurrentDictionary` and Quartz kernel code, 13
`cronExprToQuartz` tests and the Quartz end-to-end test. The kernels keep
`nowMs`, `sleepMs` and `generateId`. The CI script no longer Maven-restores
the jobs suite. `LYRIC_CONFIG_JOBS_HANGFIRE_CONNECTIONSTRING` is no longer
read. The README carries a migration note.

Tests: dotnet 55/55 (was 68), JVM 55/55 (was 68, 69 with `quartz`).
