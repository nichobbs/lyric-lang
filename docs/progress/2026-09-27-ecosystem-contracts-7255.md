# 2026-09-27 — Contract hardening in xray, docker, testing and the generator SDK

D-progress-999, #7255.

- **lyric-aws-xray:**
  - a subsegment is ended even when the target panics;
  - annotation keys and subsegment names are validated;
  - truncation is surrogate-safe.
- **lyric-docker:**
  - stream demultiplexing fails closed and is capped;
  - the TCP host is validated, and a `tcp://` `DOCKER_HOST` is honoured
    (`tryMakeDockerClient`);
  - containers are addressed by an opaque `ContainerId`;
  - stop and wait take timeouts;
  - container-creation inputs are validated.
- **lyric-testing:**
  - `TestClock` is opaque and monotonic;
  - the storage and cache mocks enforce their interfaces' ranges.
- **lyric-generator-sdk:**
  - diagnostics are parsed;
  - `additionalImports` must be real import statements;
  - JSON escapes are fully decoded;
  - a type descriptor without a name is rejected.
