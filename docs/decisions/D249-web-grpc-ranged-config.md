# D249 - Ranged config for lyric-web and lyric-grpc guards

**Status:** shipped

Closes the remaining config-contract items of #7247 and #7249, using the
range-field support from D-progress-995 (#7229).

## Decision

- `Web.Aspects.RateLimit`, `RateLimitByClient`, `HttpCircuitBreaker` and
  `Grpc.Aspects.GrpcRateLimit`, `GrpcCircuitBreaker` declare their numeric
  config as ranges: `requestsPerMinute 1 ..= 100000000`, `burstSize
  1 ..= 1000000`, `failureThreshold 1 ..= 1000000`, `cooldownMs
  1 ..= 86400000`. A zero or negative instance override is a G0010 build
  error instead of a per-call panic (or, for a rate limit, a limiter that
  never admits a call).
- `GrpcServer.port` is `Int range 1 ..= 65535` and `maxConnectionIdleMs`
  `Int range 1 ..= 2147483647`; a bad env value exits 78 (G0004) at startup.
  `serverConfigProblem` stays as a defence for callers that read it.
- The per-call `Resilience.isValidCircuitConfig` panic tests are removed:
  the state they exercised is now rejected at build time and covered by
  `weaver_self_test.l`.

## Already done on main (verified)

Metadata and deadline validation (#7290), the refilling token bucket,
`RateLimitByClient`, header/status/route/CORS/static-file contracts (#7307),
the limiter cache key on `(method, rpm, burst)`, and dotnet static-file
symlink resolution (#8505). The aspects that remain env-toggleable
(`enabled`) are only the rate limiters and breakers; the auth aspects
(`RequiresAuth`, `RequiresRole`, `ApiKey`) have no `enabled` switch.
Aspect config is a compile-time literal, so it cannot be flipped from the
environment.

## Left open

Native static-file symlink handling is tracked in #8507.
