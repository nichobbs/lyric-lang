# D-progress-964 — PR #7307 review fixes; MSIL module-level collection vals

**Status:** shipped

Fixes for the REQUIRED findings on PR #7307 (#7315–#7333), and two MSIL bugs
found while fixing them.

## Compiler: module-level `val`s holding collections (MSIL)

- `val m: Map[String, Bool] = newMap()` at module level built a
  `Dictionary<object, object>` in the `.cctor`, and the first read (which
  expects the annotated `Dictionary<string, bool>`) threw
  `InvalidCastException`. The initializer is now lowered with the
  annotation as its construction hint, as a local binding's is.
- A module-level `val` of a record or protected type whose field defaults to
  `newMap()` failed codegen ("Dictionary`2 TypeRef not seeded"). The TypeDef
  discovery pass lowered `.cctor` bodies in a throwaway context without BCL
  TypeRefs; it now skips them, as it already skipped method bodies.
- `module_val_collections_self_test.l` covers all of these on both targets
  (the JVM backend was already correct).

## Stdlib

- **`Std.Path` (#7318, #7328).**
  - `isFilesystemRoot` resolves `.`/`..` segments (`/tmp/..` and
    `C:\Windows\..` are roots) and handles UNC share roots and `\\?\`/`\\.\`
    device prefixes. A relative path counts as a root when it climbs above
    its start (`..`, `a/../..`).
  - `joinWithin` rejects every segment made only of dots and spaces, since
    Windows strips trailing dots and spaces (`.. ` is `..`), and it rejects
    an empty base.
  - `path_tests.l` is now a `@test_module` (#7315).
- **`Std.Log` (#7330).** A field value that is empty or contains a space,
  tab, `=` or `"` is written in logfmt quotes, so `bob role=admin` can no
  longer read as two fields. Keys escape space and `=`.

## Ecosystem

- **Auth aspects (#7319).**
  - `Auth.jwtConfigProblem` reports a secret under 32 bytes or an unusable
    algorithm list. `Web.Aspects.RequiresAuth`/`RequiresRole`,
    `Grpc.Aspects.RequiresGrpcAuth`/`RequiresGrpcRole` and
    `Ws.Aspects.WsAuth` panic with that message before handling a request,
    whatever its token.
  - The product-catalog example supplies `issuer`/`audience`.
  - The lyric-grpc README documents the aspects and the migration.
  - The lyric-auth README (#7316) uses a 32-byte example secret, and the
    lyric-db README (#7317) describes `getInt`'s no-truncation behaviour.
- **lyric-mq (#7320, #7321, #7322).**
  - `DeadLetter` dead-letters on the `maxDeliveries`-th failed delivery
    (`attempts >= maxDeliveries` now that `deliveryCount` is 0-based), and a
    `maxDeliveries` below 1 is a configuration error.
  - `Idempotent` claims each id atomically through the new
    `IdempotencyLedger` protected type before running the handler, and
    releases the claim on failure or panic (a `defer`). Two concurrent
    deliveries of one id in a process can no longer both run.
    Deduplication across processes still needs a shared store with an
    atomic put-if-absent.
  - `messageFromJson` (now public) reads every field from the one parsed
    document with its kind checked, so a non-string id, a malformed headers
    array and similar input are an `Err`, never a panic in `consume`. It
    also no longer leaks a second `JsonDoc` per message.
  - The README's aspect sections now name the real config fields.
- **lyric-search (#7323).** `suggest` validates its size (1..10000) and
  returns `INVALID_PAGINATION`, replacing the interface precondition.
- **lyric-jobs (#7324).** `Retryable` reports an impossible configuration
  (`maxAttempts < 1`, `initialDelayMs` outside `0..maxDelayMs`) with a
  message before the handler runs. The README config table is corrected
  and the breaking change noted. `jobs_aspect_weaving_tests.l` is the
  aspect's first test coverage.
- **Rate limiters.** The lyric-web and lyric-ws kernels call
  `Resilience.newTokenBucket`/`takeToken`/`TokenBucket` qualified. Unqualified,
  they did not resolve when lyric-web was compiled for the JVM as another
  project's dependency.
- **lyric-web (#7325, #7331).**
  - The JVM kernel reads and caps the body for every method, so a GET with
    an oversized body gets 413 as on dotnet (smoke-tested).
  - `HttpCircuitBreaker` checks its config before the handler.
- **lyric-grpc (#7331).** `GrpcCircuitBreaker` checks its config before the
  handler.
- **lyric-resilience (#7332).** `checkCircuitConfig` is public (with
  `isValidCircuitConfig`), so a consumer's `from Resilience.CircuitBreaker`
  instantiation compiles.
- **lyric-storage (#7326, #7327).**
  - `ValidateKey` has no config fields, since an env-settable `enabled`
    switch removed the traversal check.
  - `isSafeKey` rejects segments ending in `.` or space, Windows device
    names and `:`.
- **lyric-testing (#7333).** `MockStorageBucket.list` sorts and resumes by
  comparison, like `LocalBucket`.
