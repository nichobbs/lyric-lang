# D-progress-997 — Contract hardening: jobs, cache, i18n, health, mail, feature flags

**Status:** shipped

Closes #7254.

## Decisions

**lyric-jobs**
- The job constraints move from `JobHandler.handle`'s `requires:` onto
  the `JobSpec`/`JobResult` records as invariants, because the scheduler,
  not the handler, builds that data.
- `InProcessJobScheduler.runNext` now honours `maxAttempts`: `Err` and
  panics are retried. It measures `timeoutMs` per attempt, since an
  in-process runner cannot pre-empt a handler; an overrun counts as a
  failed attempt.
- `schedule` embeds the payload as a JSON string, not as spliced JSON.
- Cron has one dialect on both targets: 5-field Unix cron, parsed into an
  opaque `CronExpr` by `parseCron`. The Quartz 6/7-field form is derived
  from it for the JVM kernel, and a string `schedule` returns `Err` for an
  invalid expression.

**lyric-cache**
- `InProcessCacheStore` states `maxEntries >= 1` and
  `insertionOrder.count == valueMap.count` as invariants, re-checked after
  each mutation because record invariants are checked only at construction
  (#7222).
- The aspects' `ttlSeconds` is a ranged config field, `0 ..= 31536000`.
  `0` stays "no expiry", as in `Cache.setWithTtl`.
- The store stays a plain record. `impl` of an interface on a
  `protected type` builds but fails at runtime on both targets (#7457).

**lyric-i18n**
- `fromJson` returns `Err` for malformed JSON, a non-object root, a
  non-string value, and a key containing the `|` compound-key separator.
- `Locale` is opaque, with invariants on its BCP 47 parts.
  `parseLocale(tag)` normalises case and accepts `_`.
- The substitution length cap is a documented public constant. It is not
  a `Result`, so existing callers keep compiling.

**lyric-health**
- Check names must be non-empty and unique (`hasCheckNamed`).
- Each check runs isolated from panics and reports a generic message, so
  panic text never reaches the HTTP body.
- Each check carries a `timeoutMs`. It is enforced with a bounded wait on
  dotnet. On the JVM it is validated but not enforced: there is no bounded
  wait for a Lyric closure there (#7461), and `Health.timeoutEnforced`
  reports which applies.

**lyric-mail**
- The `System.Net.Mail` externs move into the dotnet kernel, which also
  lets the package build for the JVM.
- The JVM kernel's dead `extern package` stubs are replaced by honest
  `NOT_IMPLEMENTED` results (#7462).
- The SES/SendGrid credential checks live on the shared API.
- Recipients must be non-empty and contain `@`, instead of being skipped.
  `displayName` is carried through.
- Total attachments are capped at 25 MiB.
- The SMTP port (1..65535) and timeout (>= 1) are validated.

**lyric-feature-flags**
- Flag registration requires a non-empty name.
- `FlagGated`/`FlagVariant` check an empty `flagName` at first use.

## Compiler issues found

#7455, #7457, #7460, #7461, #7357 (new case), #7458.
