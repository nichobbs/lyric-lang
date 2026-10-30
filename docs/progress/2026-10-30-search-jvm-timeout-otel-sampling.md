# lyric-search JVM deadline test; OTel sampling draw (#8571)

- `lyric-search/tests/search_jvm_timeout_tests.l` (`@cfg(target = "jvm")`) points
  the request deadline at a `java.net.ServerSocket` that is bound and never
  accepted, so the connection completes in the kernel backlog and the peer stays
  silent. It asserts the `request timed out after 400 ms` message, which an
  unreachable port never produces. MSIL cannot host such a server (`spawn` is
  synchronous there), so this is JVM-only.
- The `search` suite joins `scripts/ci/jvm-ecosystem-suites.sh`. `search_tests.l`
  called the package's own functions as `Search.f(...)`; on the JVM a call
  qualified with the current package name loses its return type (J007 on the
  next field read), so those calls are unqualified. The whole suite (50 tests)
  now passes on the JVM as well as dotnet. The underlying JVM gap is not fixed
  here.
- `OTel.randomUnit` (public, `@stable`) draws from `Std.Random` instead of
  `Std.SecureRandom`; ids still come from the secure source. The parent-based
  sampling design is recorded in D278 and the `lyric-otel` README: every span is
  a trace root today, so the per-call draw is the root decision.
- The named connect timeout (item 2 of #8571) shipped in #8576.
