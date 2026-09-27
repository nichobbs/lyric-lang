# 2026-09-27 — Contract hardening in six ecosystem libraries

D-progress-997, #7254.

- **lyric-jobs:**
  - job invariants on the records;
  - real retries and per-attempt timeouts in the in-process scheduler;
  - no payload JSON injection;
  - a validated `CronExpr` with one dialect on both targets.
- **lyric-cache:** store invariants and a ranged aspect `ttlSeconds`.
- **lyric-i18n:**
  - `fromJson` returns `Err` instead of throwing;
  - a normalised opaque BCP 47 `Locale`.
- **lyric-health:**
  - unique check names;
  - panic isolation;
  - per-check timeouts (enforced on dotnet; JVM tracked in #7461).
- **lyric-mail:**
  - externs moved into the kernel, so the package now builds for the JVM;
  - recipient validation, `displayName` carried through, an attachment
    cap, and SMTP config validation.
- **lyric-feature-flags:** empty flag names rejected.
