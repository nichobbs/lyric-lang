# D-progress-999 — Contract hardening: xray, docker, testing, generator SDK

**Status:** shipped

Closes #7255.

## Decisions

**lyric-aws-xray**
- The `Tracing` aspect ends its subsegment in a `defer`, so a panicking
  target no longer leaves the ambient segment open.
- `annotate` requires `isValidAnnotationKey` (1..500 ASCII letters, digits
  or `_`), which is what X-Ray accepts.
- `beginSubsegment` requires a name of 1..200 characters.
- `sanitizeAnnotation` never ends on a lone high surrogate.

**lyric-docker**
- `demultiplexDockerStream` returns `Err` for a truncated frame, for an
  unknown or stdin stream type, and past `maxDemultiplexedStreamBytes`
  (64 MiB).
- `makeDockerClientTcp` requires `isHostPort`, so a hostPort cannot inject
  a path, query, userinfo or scheme into the API base.
- `makeDockerClient` honours a `tcp://` `DOCKER_HOST`.
  `tryMakeDockerClient` returns `Err` for a malformed one, and
  `makeDockerClient` panics with that message.
- Containers are addressed by an opaque `ContainerId` (a full or prefix
  hex ID, or a name). `createContainer` returns one and
  start/stop/wait/remove/logs take one.
- `stopContainer` and `waitContainer` take `timeoutSec > 0`. Stop passes it
  as Docker's grace period. Wait cancels the client-side request, because
  `/wait` has no server-side bound.
- Container creation requires a non-empty image, `=` in every env entry,
  and `src:dst[:mode]` binds.

**lyric-testing**
- `TestClock` is opaque, with `currentEpochMs >= 0` as an invariant.
- `advance` requires the result to fit in `Long` and ensures
  `now == old(now) + ms`.
- `MockStorageBucket` enforces the `StorageBucket` interface's `maxKeys`
  and `expiresInSeconds` ranges.
- `MockCacheStore.set` requires `ttlSeconds >= 0`.

**lyric-generator-sdk**
- `parseResponse` parses diagnostics, and accepts only a single `import`
  or `import extern` of a qualified name (optionally `as` an identifier)
  in `additionalImports`, so a generator cannot inject source through it.
- `parseJsonString` decodes every RFC 8259 escape.
- `TypeDescriptor` requires a non-empty name, and `runGenerator` exits 1
  on a request without one.

## Compiler issues found

JVM: #7478, #7479, #7480. These block the JVM builds of the docker,
testing and generator-sdk suites; those builds already failed on main.
