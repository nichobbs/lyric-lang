# D-progress-967 — Protocol and I/O contracts; JVM `default()` assignment

**Status:** shipped

Programmer-config contracts and untrusted-input `Result` conversions for the
stdlib's protocol and I/O modules (#7251), plus a JVM codegen bug found along
the way. Principle, as in D-progress-962: data that can come from outside the
program returns `Err` (or `false`/`None`); a caller building a malformed value
is a `requires:` or invariant.

## HTTP/1.1 engine and client

- `serializeResponseHead` requires a three-digit status (100..999) and an RFC
  9110 token for every header name. A name such as `Location: http://evil`
  used to be written verbatim and forged a header. `isFieldNameToken` is now
  public, and the dotnet and native `Std.HttpServer` kernels filter handler
  header names through it. Their previous name filter only excluded CR/LF, so
  it passed names the new precondition refuses.
- `respond*` / `beginChunkedResponse` panic on the handler's thread for a
  status outside 100..999, before either protocol path runs. On HTTP/2 the
  status is otherwise serialized later on the connection task, where a
  failure would end every stream on the connection.
- `EngineLimits` has invariants: every limit is positive and `maxBodyBytes`
  is non-negative.
- `Url` now has the invariant `isHttpUrlShape(value)`: an `http://` or
  `https://` prefix, a non-empty host after any `user@`, and no space or
  control character. `Url.tryFrom` returns `InvalidUrl` through the same
  predicate. Before this, `http://` and a URL carrying CR/LF were accepted and
  failed later inside the host client.
- `withHeader` returns the new `HttpError.InvalidHeader(url, name)` for a
  non-token name or a value containing CR, LF or NUL. Before, the dotnet
  kernel dropped the header silently and CR/LF surfaced only at send, as an
  opaque `ConnectionFailed`. `Std.Rest` auth headers go through the same
  check.
- `Std.Rest` `fullUrl` returns `Err(InvalidUrl)` for an empty base, an
  absolute or scheme-relative path, a `.`/`..` segment (percent-encoded too)
  or CR/LF/NUL. `path` is often request-derived, and `../` used to escape
  the base prefix.

## HTTP/2 and HPACK

- `serializeFrame` also requires `frameFieldsWellFormed`:
  - stream-level frames need a non-zero 31-bit stream id;
  - `lastStreamId` and priority dependencies are 31-bit;
  - a `WINDOW_UPDATE` increment is positive;
  - SETTINGS values fit 32 bits unsigned;
  - a SETTINGS ACK carries no parameters.

  The writers mask rather than reject, so such frames used to go out
  rewritten.
- `encodeResponseHeaders` requires `isH2ResponseHeaderListSafe`:
  - exactly one leading, three-digit `:status`;
  - otherwise only lowercase token names;
  - no connection-specific fields;
  - no CR/LF/NUL or surrounding whitespace in values.

  The dotnet kernel filters handler headers through `isH2ResponseFieldSafe`.
- `sendData` requires the payload to fit `peerMaxFrameSize`. A larger frame
  is a connection-level `FRAME_SIZE_ERROR` (RFC 9113 §4.2).
- `newServerConnection` requires `isValidLocalSettings`:
  - `maxFrameSize` in 16384..16777215;
  - initial window in 0..2^31-1;
  - `enablePush == 0`;
  - no negative sizes.

  `newFrameDecoderWithMaxSize` and `withMaxFrameSize` require the same frame
  range. Their docs now say the receiver enforces its own advertised value.
- HPACK:
  - `encodeInteger` requires a non-negative value and a 1..8 prefix.
  - `encodeIndexedField` requires `index >= 1`.
  - Table sizes are non-negative.
  - `DynamicTable` has the invariant `0 <= size <= maxSize`.

## TLS, process, random, property testing

- `Certificate.fromPem` / `Identity.fromPem` return `PemMalformed` for empty
  input (usually an unset secret) instead of failing a precondition.
- `Std.Process.runCapture*` and `Std.ProcessCapture.runCaptureWithDiagnosticsTimeout`
  require `timeoutMs > 0`, and `pipedWaitExit` requires `>= 0`: the host
  kernels disagree on what zero or negative timeouts mean.
- `Std.Random`: `nextIntBelow` requires `max > 0`, and `nextIntRange` requires `min < max`.
- `Std.Testing.Property` is `@runtime_checked`, and `forAll*` require
  `n > 0` (and `min < max` for the ranged forms). New
  `testing_property_tests.l` on both targets.

## JSON and XML

- `Std.Json` is `@runtime_checked`:
  - `getProperty` requires `hasProperty`, and each `get*` leaf accessor
    requires its `isJson*` predicate (a number that fits, a string, a bool).
    Wrong-shape calls fail as contract violations rather than host
    exceptions.
  - `tryGetProperty` returns `None` for a non-object receiver instead of
    throwing.
  - The `lyricJsonGet*` readers used by `@generate(Json)` fail closed:
    malformed JSON, a non-object root, or a missing, wrong-kind or
    out-of-range field returns `false`.
  - Their per-field re-parse is a performance issue, tracked in #7347.
- `Std.Xml` character references must name an XML 1.0 `Char`. `&#0;`, other
  C0 controls, surrogates and U+FFFE/U+FFFF are `UnexpectedChar`.

## Compiler: `default()` assigned into a primitive target (JVM)

A bare `default()` lowers to an erased `aconst_null` on the JVM. `val`/`var`
initializers already pushed the primitive zero, but assignments did not. So
`value = default()` into an `out Int` parameter, a primitive local, a
closure-captured var or a record field unboxed null and threw
`NullPointerException`. `lowerAssignValue` now pushes the target's primitive
zero. `default_assign_self_test.l` runs on both targets (MSIL was already
correct).

Also on the JVM: an import re-exported under an alias
(`import Std.Random` inside `Std.Testing.Property`) left the aliased extern
class unresolved in the consumer (`NoClassDefFoundError`). The bridge now
registers re-exported extern aliases.

## Not changed, with reasons

- `TlsServerConfig` gets no invariant for `requireClientCert` without
  `clientCa`: the listeners already return `Err` for it before binding, on
  every host (#6042), and an invariant would turn that tested `Err` into a
  panic.
- `withCaCertificate` + `withExclusiveCaCertificate` keep their documented
  precedence (the exclusive, stricter one wins). `build()` is specified never
  to fail, so it cannot report the combination.
- No `H2Stream`/`H2Connection` window invariants: a send window can
  legally go negative after a `SETTINGS_INITIAL_WINDOW_SIZE` decrease (RFC
  9113 §6.9.2). Peer stream ids are validated as connection errors on
  receipt, which is the correct place for wire data.

## Follow-ups

- #7346: an unsuffixed integer literal outside `Int`'s range is accepted as
  `Int` (wraps on dotnet, VerifyError on JVM). Found writing the
  `WINDOW_UPDATE` tests.
- #7347: single-parse `@generate(Json)` decoding.
- #7345: a test using `Std.Rest` needed an explicit `import Std.Rest` on the
  JVM.
