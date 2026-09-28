# lyric-cache/lyric-feature-flags/lyric-mail run on JVM in CI; book chapter 29 rewritten (#7482, #7483)

## `scripts/ci/jvm-ecosystem-suites.sh` (#7483)

Added `cache`, `feature-flags`, and `mail` to the suite list (now `storage
resilience jsonrpc mcp health generator-sdk web i18n cache feature-flags
mail`) and to the coverage header comment. `cache` and `feature-flags`
run with the same `--target jvm --no-default-features --features jvm`
every other suite uses (neither declares a `[features]` table beyond the
platform flags). `mail` needed `--features jvm,smtp,ses,sendgrid` instead
of the bare `jvm` the other suites use — its `smtp`/`ses`/`sendgrid`
provider backends are behind their own `[features]` flags
(`default = ["dotnet", "smtp", "ses", "sendgrid"]`), off under
`--no-default-features`; without them `Mail.connectSmtp`/`connectSes`/
`connectSendGrid` (all `@cfg`-gated) don't exist and the test file fails
to type-check. `run_suite` now branches on `lib = "mail"` to pass the
wider feature set. No `ci.yml` change was needed — its one "Ecosystem
suites on JVM" step already invokes the script generically, and
`bash scripts/ci/check-workflow-size.sh` still reports comfortably under
the soft ceiling (493,941 / 500,000 bytes). Checked `ci.yml` for
per-library JVM steps that duplicate what the script now covers for
these three libraries: there were none (cache/feature-flags/mail had no
JVM step at all before this).

## Bug fixed: `Flags.Aspects.checkFlagName` unresolved on `--target jvm` (#7483)

`lyric test --manifest lyric-feature-flags/lyric.toml --target jvm
--no-default-features --features jvm` failed to build
`tests/flags_aspect_weaving_tests.l`:

```
error[J008]: JVM codegen failed: Jvm.Codegen: 75:7: unresolved call to
'checkFlagName' (arity 1) imported as 'checkFlagName' in package
'Flags/FlagsAspectWeavingTests' — no registered static signature could be
resolved for this callee.
```

Root cause: `Flags.Aspects.checkFlagName` (the "fail fast on an empty
`flagName` config value" precondition helper called from `FlagGated`'s and
`FlagVariant`'s `around(call)` advice) was a package-private `func`, not
`pub`. The aspect weaver splices an aspect's advice body — including this
call — into whichever package instantiates the aspect (here, the test
module's own package, `Flags.FlagsAspectWeavingTests`), so the callee is
inherently cross-package once woven. The self-hosted JVM backend's codegen
callee resolver only has a registered static signature for a cross-package
callee when it is `pub`; MSIL's resolver tolerates a private cross-package
reference, so this was a silent, JVM-only compile failure — invisible on
`dotnet` (where the suite already passed) and invisible before this task,
since `lyric-feature-flags` had never been run under `--target jvm` in CI.
The exact same idiom this function's own doc comment says it mirrors,
`Resilience.checkRetryConfig`, is already `pub` for the same reason — this
was an oversight in the original port, not a design difference.

Fix: `lyric-feature-flags/src/flags_aspects.l` — `checkFlagName` is now
`pub func`, with a comment recording the root cause so the next aspect
helper written this way doesn't repeat it. This is a general shape for
every `@runtime_checked` aspect-template package: any non-`pub` helper
called from `around`/`before`/`after` advice will hit the same JVM-only
`J008` the first time a consumer package weaves it, whether or not that
consumer is a test module.

No compiler change was needed or attempted — the fix is at the library
level (widening visibility to match the actual cross-package call shape
the weaver produces), not a self-hosted backend change. Whether the JVM
codegen resolver *should* also resolve private cross-package callees (to
match MSIL and avoid this whole class of surprise) is a separate, larger
backend question, out of scope here.

## Local verification

All three suites, both targets, from a full `LYRIC_BOOTSTRAP_VERSION=v0.7.0
make lyric` build on this branch:

| Suite | `dotnet` | `--target jvm` |
|---|---|---|
| lyric-cache | 2 files, 26 tests (19 + 7), 0 failed | 2 files, 26 tests (19 + 7), 0 failed |
| lyric-feature-flags | 2 files, 45 tests (36 + 9), 0 failed | 2 files, 45 tests (36 + 9), 0 failed (9/9 only after the `checkFlagName` fix — 8/9 failed to build before it) |
| lyric-mail | 1 file, 70 tests, 0 failed | 1 file, 70 tests, 0 failed (`--features jvm,smtp,ses,sendgrid`) |

Also ran `bash scripts/ci/jvm-ecosystem-suites.sh` in full (all 11 suites)
and `bash scripts/ci/check-workflow-size.sh`; see the session report for
their output.

`lyric-mail`'s tests already asserted the JVM `smtp`/`ses`/`sendgrid`
`NOT_IMPLEMENTED` status honestly before this task (`Mail.Kernel.Jvm.
connectSmtp` returns `Err("... not yet implemented (#7462)")`, and
`connectSes`/`connectSendGrid` return the same `Err(code =
"NOT_IMPLEMENTED")` on every target after config validation) — no test
change was needed there; running the suite on `--target jvm` in CI simply
makes that honesty regression-tested going forward, matching
`lyric-mail/README.md`'s platform-parity table.

## Book chapter 29 rewrite (#7482)

`book/chapters/29-application-libraries.md` described APIs that don't
exist and platform status that was stale for essentially every section
after `lyric-i18n`. Rewrote every per-library section against the
shipped `pub` API (each library's `src/`) and current platform status
(each library's `README.md`), and re-verified every code example
compiles by running `lyric test`/checking the real signatures against
`--target dotnet` (and `--target jvm` where the library supports the
example's calls) rather than transcribing README prose uncritically:

- **lyric-mail**: `Mail.smtpSender(host, port, user, pass)` never
  existed; the real senders (`Mail.connectSmtp()`/`connectSes()`/
  `connectSendGrid()`) take no arguments and read config from
  `LYRIC_CONFIG_SMTP_*`/`LYRIC_CONFIG_SENDER_*` env vars. Replaced the
  MailKit claim with the real `System.Net.Mail` transport, added the
  `jvm`/`ses`/`sendgrid` `NOT_IMPLEMENTED` status (#7462), and documented
  the header-injection/attachment-size/recipient guards from #7467 that
  the old chapter omitted entirely.
- **lyric-feature-flags**: replaced the removed HTTP-polling remote store
  with the real `Flags.Registry`-backed story, fixed every accessor call
  to include the `store` argument (`Flags.getBool(store, name, default)`,
  not `Flags.getBool(name, default)`), and rewrote the `FlagGated`
  example to show the required `Flags.Registry.registerBoolFlag` startup
  registration step, which the old example never mentioned.
- **lyric-proto**: the encoder API is field-list based
  (`Proto.encodeMessage([Proto.stringField(...), ...])`); the old
  `Proto.newBuffer()`/`writeVarint`/`writeString`/`finish` calls don't
  exist anywhere in `src/proto_main.l`.
- **lyric-grpc**: `Grpc.invoke` doesn't exist; the real entry point is
  `Grpc.callUnary`, and — unlike the old chapter's working-looking
  example — unary calls are not actually implemented yet (#6581); the
  rewritten section says so.
- **lyric-otel**: replaced the fictional `OTel.tracer`/`OTel.configure`
  calls with the real `OTel.startSpan`/`endSpan` and
  `OTel.Otlp.configureOtlp`/`defaultConfig`, and added the `jvm`
  recording-works/export-doesn't split.
- **lyric-storage**: `Storage.s3Bucket(...)` doesn't exist; rewrote the
  example around `Storage.connectLocal` (the only backend that's actually
  production-ready, on both targets) instead of the `NOT_IMPLEMENTED`
  `connectS3`/`connectAzureBlob`, and corrected `put`/`get` to their real
  `Result`-returning, base64-string signatures.
- **lyric-search**: added the "kernel bindings exist but the public API
  never calls them" caveat (#5067) the old chapter omitted.
- **lyric-i18n**: `I18n.loadJson("translations/", locale)` doesn't exist;
  replaced with the real `I18n.fromJson(json)`/`loadFromPath(dirPath)` +
  `I18n.translateWithLocale`.
- **Library availability matrix**: rewrote every row against each
  library's own README platform-parity table instead of the old
  "stable/planned" guesses (e.g. lyric-resilience and lyric-web are
  stable on JVM today, not "planned"; lyric-cache is stable on JVM per
  this task's own verification; lyric-mq's per-broker JVM gaps are now
  named specifically instead of a blanket "planned").

`lyric-mail/README.md` and `lyric-feature-flags/README.md` were already
accurate (both documented the real no-argument `connect*()` API, the
`store`-taking accessors, and the correct platform-parity tables) — no
README changes were needed for either.

Found along the way: `lyric-proto/README.md` used a non-existent
`"...".bytes()` in two examples; they now use `Encoding.encodeUtf8(...)`,
matching chapter 29. A project that depends on `Lyric.Search` fails to
build because the restored contract source cannot resolve `JsonElement`;
the lyric-search example was verified inside its own package instead, and
the dependency failure is tracked in #7668.
