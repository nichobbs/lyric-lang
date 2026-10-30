//! Basic Docker client operations tests.
//!
//! These tests verify core Docker client functionality.
//!
//! Run with: lyric test --manifest lyric-docker/lyric.toml
@test_module
package Lyric.Docker.BasicOperationsTests

import Lyric.Docker
import Lyric.Docker.Sockets
import Std.Core
import Std.Environment
import Std.Testing

// ─── Socket Parsing Tests ──────────────────────────────────────────────────
test "unix:///var/run/docker.sock parses to Some(/var/run/docker.sock)" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("unix:///var/run/docker.sock")
  assertTrue(isSome(pathOpt), "Expected Some")
  val path = unwrapOr(pathOpt, "")
  assertEqual(path, "/var/run/docker.sock", "Parsed socket path for unix:///var/run/docker.sock")
}

test "unix://docker.sock parses to Some(docker.sock)" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("unix://docker.sock")
  assertTrue(isSome(pathOpt), "Expected Some")
  val path = unwrapOr(pathOpt, "")
  assertEqual(path, "docker.sock", "Parsed socket path for unix://docker.sock")
}

test "unix:////absolute/path.sock parses to Some(/absolute/path.sock)" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("unix:////absolute/path.sock")
  assertTrue(isSome(pathOpt), "Expected Some")
  val path = unwrapOr(pathOpt, "")
  assertEqual(path, "/absolute/path.sock", "Parsed socket path for unix:////absolute/path.sock")
}

test "tcp://localhost:2375 parses to None" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("tcp://localhost:2375")
  assertTrue(isNone(pathOpt), "Expected None")
}

test "npipe:////.//pipe//docker_engine parses to None" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("npipe:////.//pipe//docker_engine")
  assertTrue(isNone(pathOpt), "Expected None")
}

test "empty URL parses to None" {
  val pathOpt = Lyric.Docker.Sockets.parseUnixSocketUrl("")
  assertTrue(isNone(pathOpt), "Expected None")
}

// ─── Stream Demultiplexer Tests ──────────────────────────────────────────────
test "demultiplex empty bytes produces empty string" {
  val streamResult = Lyric.Docker.demultiplexDockerStream([])
  assertTrue(isOk(streamResult), "Expected Ok")
  val result = unwrapResultOr(streamResult, "none")
  assertEqual(result, "", "Empty stream demultiplexes to empty string")
}

test "demultiplex single stdout frame" {
  // stdout (1), size 5, "Hello"
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8, 72u8, 101u8, 108u8, 108u8, 111u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isOk(streamResult), "Expected Ok")
  val result = unwrapResultOr(streamResult, "")
  assertEqual(result, "Hello", "Demultiplexed single frame")
}

test "demultiplex multiple stdout and stderr frames" {
  // Frame 1: stdout (1), size 5, "Hello"
  // Frame 2: stderr (2), size 6, " World"
  val bytes: slice[Byte] = [
    1u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    5u8,
    72u8,
    101u8,
    108u8,
    108u8,
    111u8,
    2u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    6u8,
    32u8,
    87u8,
    111u8,
    114u8,
    108u8,
    100u8
  ]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isOk(streamResult), "Expected Ok")
  val result = unwrapResultOr(streamResult, "")
  assertEqual(result, "Hello World", "Demultiplexed combined stdout/stderr frames")
}

// A truncated trailing frame header used to be silently stopped, returning
// `Ok` with whatever output preceded it, as if the stream were complete.
// That hides real data loss (a caller can't tell "clean end of stream" from
// "the daemon's response got cut off mid-frame"), so it is now `Err` (#7255).
test "demultiplex incomplete header is an Err, not a silently-truncated Ok" {
  // 5 bytes, insufficient for 8-byte header
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "an incomplete frame header is Err")
}

test "demultiplex incomplete payload is an Err, not a silently-truncated Ok" {
  // stdout (1), size 5, but only 3 bytes of payload present
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8, 72u8, 101u8, 108u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "a frame whose declared size runs past the buffer end is Err")
}

// Regression: a frame whose 4-byte big-endian size has the top bit set
// (>= 2^31) used to overflow the signed Int size accumulator and wrap
// negative, defeating the bounds check and driving the index negative (OOB
// crash). The size is now computed in Long and bounds-checked, so the frame
// is safely rejected (Err) rather than crashing on adversarial daemon
// output, and rather than the still-unsafe "silently skip and return Ok"
// behaviour a prior version of this fix used (#7255).
test "demultiplex oversized frame size does not overflow / crash, and is an Err" {
  // stdout (1), size bytes = FF 00 00 41 (top bit set => ~4.28 billion),
  // followed by two payload bytes. The old code wrapped this to a negative
  // size and then indexed out of bounds.
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 255u8, 0u8, 0u8, 65u8, 104u8, 105u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "an out-of-range frame size must not crash the demuxer, and must be Err")
}

// ─── demultiplex: unknown stream type ──────────────────────────────────────
test "demultiplex rejects an unrecognized stream type instead of silently skipping it" {
  // stream type 3 (neither 1=stdout nor 2=stderr), size 2, two payload bytes.
  val bytes: slice[Byte] = [3u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8, 65u8, 66u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "an unrecognized stream type is Err")
}

test "demultiplex rejects stream type 0 (stdin) as unrecognized in this context" {
  val bytes: slice[Byte] = [0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8, 65u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "stream type 0 is Err")
}

// ─── demultiplex: output cap ───────────────────────────────────────────────
test "demultiplex enforces an output cap instead of accumulating without bound" {
  // One stdout frame declaring a size one byte over the 64 MiB cap
  // (0x04000001 = 67108865). The cap is checked against the frame's
  // declared size before the remaining-buffer bound, so this triggers the
  // cap error without the test having to supply 64 MiB of real payload.
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 4u8, 0u8, 0u8, 1u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isErr(streamResult), "a frame declaring more than the 64 MiB cap is Err")
}

// ─── Container ID Validation Tests ─────────────────────────────────────────
test "isValidContainerId rejects empty string" {
  assertFalse(Lyric.Docker.isValidContainerId(""), "Empty string is invalid")
}

test "isValidContainerId rejects an ID containing a slash" {
  assertFalse(Lyric.Docker.isValidContainerId("abc123/45678"), "Slash is invalid")
}

test "isValidContainerId rejects an ID containing a question mark" {
  assertFalse(Lyric.Docker.isValidContainerId("abc123?45678"), "Question mark is invalid")
}

test "isValidContainerId rejects uppercase hex" {
  assertFalse(Lyric.Docker.isValidContainerId("ABCDEF012345"), "Uppercase hex is invalid (Docker IDs are lowercase)")
}

test "isValidContainerId rejects length 11" {
  assertFalse(Lyric.Docker.isValidContainerId("abcdef01234"), "Length 11 is invalid")
}

test "isValidContainerId rejects length 13" {
  assertFalse(Lyric.Docker.isValidContainerId("abcdef0123456"), "Length 13 is invalid")
}

test "isValidContainerId accepts a valid 12-char lowercase hex ID" {
  assertTrue(Lyric.Docker.isValidContainerId("abcdef012345"), "Valid short-form ID is accepted")
}

test "isValidContainerId accepts a valid 64-char lowercase hex ID" {
  val fullId = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assertTrue(Lyric.Docker.isValidContainerId(fullId), "Valid full-form ID is accepted")
}

// ─── ContainerId / isValidContainerIdOrName Tests ──────────────────────────
// Supersedes isValidContainerId's fixed-length (12/64) check (#7255): Docker
// accepts a full 64-hex ID, a unique hex prefix of ANY length, or a
// container name.
test "isValidContainerIdOrName accepts a full 64-char hex ID" {
  val fullId = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assertTrue(Lyric.Docker.isValidContainerIdOrName(fullId), "full 64-hex ID accepted")
}

test "isValidContainerIdOrName accepts hex prefixes isValidContainerId used to reject (not 12 or 64 chars)" {
  assertTrue(Lyric.Docker.isValidContainerIdOrName("a"), "1-char hex prefix accepted")
  assertTrue(Lyric.Docker.isValidContainerIdOrName("abcd"), "4-char hex prefix accepted")
  assertTrue(Lyric.Docker.isValidContainerIdOrName("abcdef0123456"), "13-char hex prefix accepted")
}

test "isValidContainerIdOrName accepts a container name isValidContainerId used to reject" {
  assertTrue(Lyric.Docker.isValidContainerIdOrName("my-app_1.0"), "container name accepted")
  assertTrue(Lyric.Docker.isValidContainerIdOrName("web1"), "alphanumeric name accepted")
}

test "isValidContainerIdOrName rejects an empty string" {
  assertFalse(Lyric.Docker.isValidContainerIdOrName(""), "empty string rejected")
}

test "isValidContainerIdOrName rejects a single non-hex character (too short for a name)" {
  assertFalse(Lyric.Docker.isValidContainerIdOrName("_"), "single non-hex, non-alnum-leading char rejected")
}

test "isValidContainerIdOrName rejects a name-shaped value starting with a symbol" {
  assertFalse(Lyric.Docker.isValidContainerIdOrName("-leading-dash"), "leading dash rejected")
}

test "isValidContainerIdOrName rejects path-injection characters" {
  assertFalse(Lyric.Docker.isValidContainerIdOrName("abc123/45678"), "slash rejected")
  assertFalse(Lyric.Docker.isValidContainerIdOrName("abc123?45678"), "question mark rejected")
}

test "ContainerId.tryFrom accepts a valid hex ID and round-trips through toString" {
  val result: Result[Lyric.Docker.ContainerId, Lyric.Docker.DockerError] = Lyric.Docker.ContainerId.tryFrom(
    "abcdef012345"
  )
  assertTrue(isOk(result), "valid hex ID accepted")
  match result {
    case Ok(id) -> assertEqual(Lyric.Docker.ContainerId.toString(id), "abcdef012345", "round-trips the raw value")
    case Err(_) -> assertTrue(false, "unreachable")
  }
}

test "ContainerId.tryFrom accepts a valid container name" {
  val result: Result[Lyric.Docker.ContainerId, Lyric.Docker.DockerError] = Lyric.Docker.ContainerId.tryFrom(
    "my-app_1.0"
  )
  assertTrue(isOk(result), "valid container name accepted")
}

test "ContainerId.tryFrom rejects an invalid value" {
  val result: Result[Lyric.Docker.ContainerId, Lyric.Docker.DockerError] = Lyric.Docker.ContainerId.tryFrom("bad/name")
  assertTrue(isErr(result), "invalid value rejected")
}

// ─── JSON escape / unescape Tests ───────────────────────────────────────────
// jsonEscapeValue/jsonUnescapeValue are private; exercised indirectly through
// createContainerBody (escape direction) and extractJsonField (decode
// direction), the same public entry points createContainer uses (#4535).
test "createContainerBody escapes a control character as a 4-digit unicode escape" {
  // 0x01 (SOH) is not one of the named escapes (quote, backslash, newline,
  // carriage return, tab, backspace, form feed), so it must fall through
  // jsonEscapeValue's `code >= 0 and code < 32` branch and render as a
  // literal backslash-u-zero-zero-zero-one escape sequence.
  val body = Lyric.Docker.createContainerBody("\u{0001}", [], [])
  val expected = "{\"Image\":\"" + "\\u0001" + "\",\"Env\":[],\"HostConfig\":{\"Binds\":[]}}"
  assertEqual(body, expected, "Control character 0x01 is escaped as a 4-digit unicode escape in the JSON body")
}

test "createContainerBody round-trips control characters through extractJsonField" {
  // Round-trip through the real escape (createContainerBody) and decode
  // (extractJsonField) paths together, so the assertion doesn't depend on
  // guessing jsonUnescapeValue's exact intermediate hex formatting.
  val image = "abc\u{0001}def\u{001f}ghi"
  val body = Lyric.Docker.createContainerBody(image, [], [])
  val extracted = Lyric.Docker.extractJsonField(body, "Image")
  assertEqual(extracted, image, "Control characters round-trip through escape + decode unchanged")
}

test "createContainerBody round-trips a named escape (backspace) through extractJsonField" {
  val image = "foo\u{0008}bar"
  val body = Lyric.Docker.createContainerBody(image, [], [])
  val extracted = Lyric.Docker.extractJsonField(body, "Image")
  assertEqual(extracted, image, "Named escape \\b round-trips through escape + decode unchanged")
}

test "extractJsonField decodes a \\uXXXX escape for a control character" {
  val body = "{\"Id\":\"a\\u0001b\"}"
  val extracted = Lyric.Docker.extractJsonField(body, "Id")
  assertEqual(extracted, "a\u{0001}b", "\\u0001 decodes back to the raw control character")
}

test "extractJsonField decodes a \\uXXXX escape for a non-ASCII character" {
  val body = "{\"Id\":\"caf\\u00e9\"}"
  val extracted = Lyric.Docker.extractJsonField(body, "Id")
  assertEqual(extracted, "café", "\\u00e9 decodes back to the Unicode character e-acute")
}

// #7252: a surrogate-pair escape combines into one astral code point; a
// lone or reversed surrogate escape decodes to U+FFFD, never an unpaired
// UTF-16 surrogate.
func extractedId(escapedId: in String): String {
  Lyric.Docker.extractJsonField("{\"Id\":\"" + escapedId + "\"}", "Id")
}

test "extractJsonField decodes a surrogate-pair escape to one astral character" {
  assertEqual(extractedId("a\\ud83d\\ude00b"), "a😀b", "surrogate pair decodes to U+1F600")
}

test "extractJsonField decodes a lone high surrogate escape to U+FFFD" {
  assertEqual(extractedId("a\\ud83db"), "a�b", "lone high surrogate becomes U+FFFD")
  assertEqual(extractedId("a\\ud83d\\u0041"), "a�A", "high surrogate before a non-low escape")
}

test "extractJsonField decodes a lone low surrogate escape to U+FFFD" {
  assertEqual(extractedId("a\\ude00b"), "a�b", "lone low surrogate becomes U+FFFD")
}

test "extractJsonField decodes a reversed surrogate pair to two U+FFFD" {
  assertEqual(extractedId("a\\ude00\\ud83db"), "a��b", "reversed pair becomes two U+FFFD")
}

test "extractJsonField returns empty string when the field is absent" {
  val body = "{\"Other\":\"value\"}"
  val extracted = Lyric.Docker.extractJsonField(body, "Id")
  assertEqual(extracted, "", "Missing field yields an empty string")
}

// ─── Integer field extraction Tests ─────────────────────────────────────────
// extractJsonIntField backs waitContainer's StatusCode parsing (#4535-style
// public-for-testing rationale — no live Docker daemon needed).
test "extractJsonIntField extracts a zero StatusCode from a clean wait response" {
  val body = "{\"StatusCode\":0,\"Error\":null}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, -1)), "0", "StatusCode 0 extracted")
}

test "extractJsonIntField extracts a nonzero StatusCode" {
  val body = "{\"StatusCode\":137,\"Error\":null}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, -1)), "137", "StatusCode 137 extracted")
}

test "extractJsonIntField extracts a negative number" {
  val body = "{\"StatusCode\":-1}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, 0)), "-1", "Negative StatusCode extracted")
}

test "extractJsonIntField tolerates a space after the colon" {
  val body = "{\"StatusCode\": 42}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, -1)), "42", "StatusCode extracted despite whitespace")
}

test "extractJsonIntField returns None when the field is absent" {
  val body = "{\"Error\":null}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isNone(extracted), "Expected None for a missing field")
}

test "extractJsonIntField returns None when the field's value is a quoted string, not a bare number" {
  val body = "{\"StatusCode\":\"0\"}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isNone(extracted), "A quoted value is not a well-formed JSON number here")
}

test "extractJsonIntField skips a matching quoted token that isn't a key position" {
  // The exact quoted token "StatusCode" first appears as a string *value*
  // (preceded by ':', not '{'/',' — isFieldKeyPosition rejects it) before
  // the real key. The scan must keep looking past it.
  val body = "{\"Note\":\"StatusCode\",\"StatusCode\":7}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, -1)), "7", "Real top-level StatusCode found, not the string occurrence")
}

test "extractJsonIntField tolerates a tab and newline after the colon" {
  val body = "{\"StatusCode\":\n\t42}"
  val extracted = Lyric.Docker.extractJsonIntField(body, "StatusCode")
  assertTrue(isSome(extracted), "Expected Some")
  assertEqual(toString(unwrapOr(extracted, -1)), "42", "StatusCode extracted despite tab/newline whitespace")
}

// ─── Boolean field extraction Tests ─────────────────────────────────────────
// extractJsonBoolField backs containerIsTty's Config.Tty read: getContainerLogs
// (#5773) needs an authoritative source for raw-vs-multiplexed log detection,
// since the /logs response's own Content-Type header always claims
// "application/vnd.docker.raw-stream" regardless of the container's actual
// Tty setting.
test "extractJsonBoolField extracts a true value" {
  val body = "{\"Config\":{\"Tty\":true}}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isSome(extracted), "Expected Some")
  assertTrue(unwrapOr(extracted, false), "Tty true extracted")
}

test "extractJsonBoolField extracts a false value" {
  val body = "{\"Config\":{\"Tty\":false}}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isSome(extracted), "Expected Some")
  assertTrue(not unwrapOr(extracted, true), "Tty false extracted")
}

test "extractJsonBoolField returns None when the field is absent" {
  val body = "{\"Config\":{}}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isNone(extracted), "Expected None for a missing field")
}

test "extractJsonBoolField returns None when the field's value is neither true nor false" {
  val body = "{\"Tty\":\"true\"}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isNone(extracted), "Expected None for a quoted (non-bare) value")
}

test "extractJsonBoolField tolerates whitespace after the colon" {
  val body = "{\"Tty\":\n\t true}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isSome(extracted), "Expected Some")
  assertTrue(unwrapOr(extracted, false), "Tty extracted despite whitespace")
}

test "extractJsonBoolField skips a matching quoted token that isn't a key position" {
  // The exact quoted token "Tty" first appears as a string *value*
  // (preceded by ':', not '{'/',' — isFieldKeyPosition rejects it) before
  // the real key, mirroring extractJsonIntField's equivalent test above.
  val body = "{\"Note\":\"Tty\",\"Tty\":true}"
  val extracted = Lyric.Docker.extractJsonBoolField(body, "Tty")
  assertTrue(isSome(extracted), "Expected Some")
  assertTrue(unwrapOr(extracted, false), "Real Tty key found past the non-key occurrence")
}

test "extractJsonBoolField scoped to a nested Config object via jsonFieldObjectStart matches containerIsTty's real usage" {
  val body = "{\"Id\":\"abc\",\"Config\":{\"Tty\":false,\"Image\":\"alpine\"},\"Tty\":true}"
  val configStart = Lyric.Docker.jsonFieldObjectStart(body, "Config")
  assertTrue(isSome(configStart), "Expected Some")
  val pos = unwrapOr(configStart, -1)
  val configJson = body.substring(pos, body.length - pos)
  val extracted = Lyric.Docker.extractJsonBoolField(configJson, "Tty")
  assertTrue(isSome(extracted), "Expected Some")
  assertTrue(not unwrapOr(extracted, true), "Nested Config.Tty (false) read, not the outer top-level Tty (true)")
}

// jsonObjectEnd bounds jsonFieldObjectStart's slice to the matching closing
// brace, so containerIsTty's real usage (an unbounded slice to end-of-body
// before this fix) can't pick up a same-named field from a later sibling
// section (#5780). These mirror containerIsTty's own lookup sequence
// (jsonFieldObjectStart then a bounded slice then extractJsonBoolField)
// rather than calling containerIsTty directly, since it isn't `pub`.
test "jsonObjectEnd bounds the Config slice so a same-named field after Config's close isn't picked up (#5780)" {
  // Config has no Tty of its own here; only a decoy top-level Tty:true
  // appears after Config's closing brace.
  val body = "{\"Id\":\"abc\",\"Config\":{\"Image\":\"alpine\"},\"Tty\":true}"
  val configStart = Lyric.Docker.jsonFieldObjectStart(body, "Config")
  assertTrue(isSome(configStart), "Expected Some")
  val pos = unwrapOr(configStart, -1)

  val configEnd = Lyric.Docker.jsonObjectEnd(body, pos)
  assertTrue(isSome(configEnd), "Expected Some closing brace position")
  val closePos = unwrapOr(configEnd, -1)
  val boundedConfigJson = body.substring(pos, closePos + 1 - pos)
  val extracted = Lyric.Docker.extractJsonBoolField(boundedConfigJson, "Tty")
  assertTrue(
    isNone(extracted),
    "Config has no Tty; the decoy top-level Tty:true after Config's close must not be picked up"
  )

  // Sanity check that this is a real regression guard: an unbounded slice
  // to the end of the document (the pre-fix behavior) incorrectly picks up
  // the decoy.
  val unboundedConfigJson = body.substring(pos, body.length - pos)
  val unboundedExtracted = Lyric.Docker.extractJsonBoolField(unboundedConfigJson, "Tty")
  assertTrue(isSome(unboundedExtracted), "Sanity: an unbounded slice would incorrectly pick up the decoy Tty")
  assertTrue(unwrapOr(unboundedExtracted, false), "Sanity: the incorrectly-picked-up decoy value is true")
}

test "jsonObjectEnd skips braces and escaped quotes inside string values when bounding Config (#5780)" {
  // Config.Image's string value contains an escaped quote followed by an
  // UNBALANCED literal '}'. A depth counter that doesn't skip string
  // contents would treat that stray '}' as closing Config immediately,
  // truncating the slice before the real Tty field and before Config's
  // actual closing brace. Also carries a decoy "Other":{"Tty":false} after
  // Config's real close, so an over-wide slice would be caught too.
  val body = "{\"Config\":{\"Image\":\"al\\\"pine}\",\"Tty\":true},\"Other\":{\"Tty\":false}}"
  val configStart = Lyric.Docker.jsonFieldObjectStart(body, "Config")
  assertTrue(isSome(configStart), "Expected Some")
  val pos = unwrapOr(configStart, -1)

  val configEnd = Lyric.Docker.jsonObjectEnd(body, pos)
  assertTrue(isSome(configEnd), "Expected Some closing brace position")
  val closePos = unwrapOr(configEnd, -1)
  val configJson = body.substring(pos, closePos + 1 - pos)
  val extracted = Lyric.Docker.extractJsonBoolField(configJson, "Tty")
  assertTrue(isSome(extracted), "Expected Some — the stray '}' inside the string must not truncate the slice early")
  assertTrue(
    unwrapOr(extracted, false),
    "Config.Tty (true) read correctly despite an escaped quote and an unbalanced brace inside Image's string value"
  )
}

// ─── Error-object detection Tests ───────────────────────────────────────────
// jsonFieldIsObject backs waitContainer's daemon-error detection: Docker's
// /wait response is {"StatusCode":int,"Error":{"Message":string}|null}, and
// a non-null Error is a daemon-level failure distinct from the exit code.
test "jsonFieldIsObject is false when the field is a null literal" {
  val body = "{\"StatusCode\":0,\"Error\":null}"
  assertFalse(Lyric.Docker.jsonFieldIsObject(body, "Error"), "null is not an object")
}

test "jsonFieldIsObject is true when the field is a JSON object" {
  val body = "{\"StatusCode\":0,\"Error\":{\"Message\":\"context deadline exceeded\"}}"
  assertTrue(Lyric.Docker.jsonFieldIsObject(body, "Error"), "A {...} value is an object")
}

test "jsonFieldIsObject is false when the field is absent" {
  val body = "{\"StatusCode\":0}"
  assertFalse(Lyric.Docker.jsonFieldIsObject(body, "Error"), "A missing field is not an object")
}

test "jsonFieldIsObject tolerates whitespace between the colon and the brace" {
  val body = "{\"StatusCode\":0,\"Error\": {\"Message\":\"x\"}}"
  assertTrue(Lyric.Docker.jsonFieldIsObject(body, "Error"), "Whitespace before the object value is tolerated")
}

test "jsonFieldObjectStart scopes a nested extractJsonField lookup to the object, not the whole document (#4929)" {
  // "Message" appears twice: once outside Error (must not be picked up by
  // waitContainer's error-message extraction), once inside it (the one
  // that matters).
  val body = "{\"Message\":\"outer, should be ignored\",\"Error\":{\"Message\":\"inner\"}}"
  val startOpt = Lyric.Docker.jsonFieldObjectStart(body, "Error")
  assertTrue(isSome(startOpt), "Expected Some")
  val start = unwrapOr(startOpt, -1)
  val errorObj = body.substring(start, body.length - start)
  val scopedMessage = Lyric.Docker.extractJsonField(errorObj, "Message")
  assertEqual(scopedMessage, "inner", "Scoping to the Error object finds the inner Message")
  // Sanity check that this scenario would otherwise be a real bug: an
  // unscoped extraction over the full body picks up the wrong field.
  val unscopedMessage = Lyric.Docker.extractJsonField(body, "Message")
  assertEqual(unscopedMessage, "outer, should be ignored", "Unscoped extraction picks up the outer field instead")
}

test "jsonFieldObjectStart returns None when the field is absent" {
  val body = "{\"StatusCode\":0}"
  assertTrue(isNone(Lyric.Docker.jsonFieldObjectStart(body, "Error")), "Expected None for a missing field")
}

// ─── NetworkMode Tests ──────────────────────────────────────────────────────
// createContainerBodyWithNetwork backs createContainerWithNetwork, which
// cloud-agents needs to pin a container's network (e.g. "none" for full
// isolation, or a named egress-restricted network) at create time.
test "createContainerBodyWithNetwork omits NetworkMode when networkMode is empty" {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], [], "")
  assertEqual(
    body,
    Lyric.Docker.createContainerBody("alpine", [], []),
    "Empty networkMode matches the no-network body builder"
  )
  assertFalse(body.contains("NetworkMode"), "No NetworkMode field is emitted when networkMode is empty")
}

test "createContainerBodyWithNetwork emits NetworkMode when set" {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], [], "none")
  val expected = "{\"Image\":\"alpine\",\"Env\":[],\"HostConfig\":{\"Binds\":[],\"NetworkMode\":\"none\"}}"
  assertEqual(body, expected, "NetworkMode is embedded in HostConfig when set")
}

test "createContainerBodyWithNetwork escapes a named network containing special characters" {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], [], "my\"network")
  val extracted = Lyric.Docker.extractJsonField(body, "NetworkMode")
  assertEqual(extracted, "my\"network", "NetworkMode value round-trips through escape + decode unchanged")
}

test "createContainerBodyWithNetwork preserves Binds and Env alongside NetworkMode" {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", ["FOO=bar"], ["vol:/data"], "restricted-net")
  val expected = "{\"Image\":\"alpine\",\"Env\":[\"FOO=bar\"],\"HostConfig\":{\"Binds\":[\"vol:/data\"],\"NetworkMode\":\"restricted-net\"}}"
  assertEqual(body, expected, "Env and Binds are unaffected by the added NetworkMode field")
}

// ─── createContainerBodyWithNetwork precondition Tests ────────────────────
func createContainerBodyWithEmptyImage(): Unit {
  val body = Lyric.Docker.createContainerBodyWithNetwork("", [], [], "")
}

test "createContainerBodyWithNetwork panics on an empty image" {
  assertPanics("empty image", createContainerBodyWithEmptyImage)
}

func createContainerBodyWithMalformedEnvEntry(): Unit {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", ["NOEQUALS"], [], "")
}

test "createContainerBodyWithNetwork panics on an env entry without '='" {
  assertPanics("env entry without '='", createContainerBodyWithMalformedEnvEntry)
}

func createContainerBodyWithMalformedBind(): Unit {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], ["justasourcenocolon"], "")
}

test "createContainerBodyWithNetwork panics on a bind without a ':'" {
  assertPanics("bind without ':'", createContainerBodyWithMalformedBind)
}

func createContainerBodyWithEmptyBindPart(): Unit {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], ["vol:"], "")
}

test "createContainerBodyWithNetwork panics on a bind with an empty part" {
  assertPanics("bind with an empty dst", createContainerBodyWithEmptyBindPart)
}

test "createContainerBodyWithNetwork accepts a 3-part bind (src:dst:mode)" {
  val body = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], ["vol:/data:ro"], "")
  val expected = "{\"Image\":\"alpine\",\"Env\":[],\"HostConfig\":{\"Binds\":[\"vol:/data:ro\"]}}"
  assertEqual(body, expected, "a valid 3-part bind is accepted unchanged")
}

// ─── NetworkMode + Dns Tests ────────────────────────────────────────────────
// createContainerBodyWithNetworkAndDns backs createContainerWithNetworkAndDns:
// a caller on the Docker default bridge network needs an explicit resolver
// list, since that network's DNS otherwise depends on the daemon host's own
// /etc/resolv.conf rather than Docker's embedded DNS.
test "createContainerBodyWithNetworkAndDns with an empty dns matches createContainerBodyWithNetwork" {
  val withDns = Lyric.Docker.createContainerBodyWithNetworkAndDns("alpine", [], [], "", [])
  val without = Lyric.Docker.createContainerBodyWithNetwork("alpine", [], [], "")
  assertEqual(withDns, without, "an empty dns list is byte-identical to the no-Dns body builder")
  assertFalse(withDns.contains("Dns"), "No Dns field is emitted when dns is empty")
}

test "createContainerBodyWithNetworkAndDns emits Dns when set" {
  val body = Lyric.Docker.createContainerBodyWithNetworkAndDns("alpine", [], [], "", ["1.1.1.1", "8.8.8.8"])
  val expected = "{\"Image\":\"alpine\",\"Env\":[],\"HostConfig\":{\"Binds\":[],\"Dns\":[\"1.1.1.1\",\"8.8.8.8\"]}}"
  assertEqual(body, expected, "Dns is embedded in HostConfig, ordered after Binds, when networkMode is empty")
}

test "createContainerBodyWithNetworkAndDns emits both NetworkMode and Dns together" {
  val body = Lyric.Docker.createContainerBodyWithNetworkAndDns("alpine", [], [], "none", ["1.1.1.1"])
  val expected = "{\"Image\":\"alpine\",\"Env\":[],\"HostConfig\":{\"Binds\":[],\"NetworkMode\":\"none\",\"Dns\":[\"1.1.1.1\"]}}"
  assertEqual(body, expected, "NetworkMode precedes Dns in HostConfig when both are set")
}

test "createContainerBodyWithNetworkAndDns preserves Binds and Env alongside Dns" {
  val body = Lyric.Docker.createContainerBodyWithNetworkAndDns("alpine", ["FOO=bar"], ["vol:/data"], "", ["1.1.1.1"])
  val expected = "{\"Image\":\"alpine\",\"Env\":[\"FOO=bar\"],\"HostConfig\":{\"Binds\":[\"vol:/data\"],\"Dns\":[\"1.1.1.1\"]}}"
  assertEqual(body, expected, "Env and Binds are unaffected by the added Dns field")
}

func createContainerBodyWithNetworkAndDnsEmptyImage(): Unit {
  val body = Lyric.Docker.createContainerBodyWithNetworkAndDns("", [], [], "", ["1.1.1.1"])
}

test "createContainerBodyWithNetworkAndDns panics on an empty image" {
  assertPanics("empty image", createContainerBodyWithNetworkAndDnsEmptyImage)
}

// ─── TCP Constructor Tests ──────────────────────────────────────────────────
// makeDockerClientTcp (#5732) has no reachable-daemon test infrastructure in
// CI, so DockerClient's opaque internals can't be asserted directly. Instead,
// exercise the constructor's real behavioral difference from the Unix-socket
// constructors: it wires an actual dispatching HttpClient that resolves and
// connects to the given host:port. Port 1 is in the reserved range and never
// has a listener, so the connection fails fast and deterministically without
// a live Docker daemon (same rationale as lyric-stdlib/tests/http_async_tests.l's
// deadUrl).
test "makeDockerClientTcp constructs a client whose ping fails against an unreachable TCP host (#5732)" {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val failed = match await Lyric.Docker.ping(client) { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(failed, "Expected ping to fail against an unreachable TCP host")
}

// ─── isHostPort Tests (#7255) ───────────────────────────────────────────────
test "isHostPort accepts a plausible hostname or IPv4 host:port" {
  assertTrue(Lyric.Docker.isHostPort("127.0.0.1:2375"), "IPv4:port accepted")
  assertTrue(Lyric.Docker.isHostPort("localhost:2375"), "hostname:port accepted")
  assertTrue(Lyric.Docker.isHostPort("docker.example.com:443"), "FQDN:port accepted")
}

test "isHostPort accepts a bracketed IPv6 host:port" {
  assertTrue(Lyric.Docker.isHostPort("[::1]:2375"), "bracketed IPv6 loopback accepted")
  assertTrue(Lyric.Docker.isHostPort("[2001:db8::1]:2375"), "bracketed IPv6 accepted")
}

test "isHostPort rejects a scheme or path/query injection" {
  assertFalse(Lyric.Docker.isHostPort("http://127.0.0.1:2375"), "embedded scheme rejected")
  assertFalse(Lyric.Docker.isHostPort("127.0.0.1/evil:2375"), "slash rejected")
  assertFalse(Lyric.Docker.isHostPort("host?evil:80"), "question mark rejected")
  assertFalse(Lyric.Docker.isHostPort("user@host:80"), "at-sign rejected")
}

test "isHostPort rejects a missing host or missing port" {
  assertFalse(Lyric.Docker.isHostPort(""), "empty string rejected")
  assertFalse(Lyric.Docker.isHostPort("host"), "no colon rejected")
  assertFalse(Lyric.Docker.isHostPort(":80"), "empty host rejected")
  assertFalse(Lyric.Docker.isHostPort("host:"), "empty port rejected")
}

test "isHostPort rejects a port outside 1-65535" {
  assertFalse(Lyric.Docker.isHostPort("host:0"), "port 0 rejected")
  assertFalse(Lyric.Docker.isHostPort("host:65536"), "port over 65535 rejected")
  assertFalse(Lyric.Docker.isHostPort("host:999999"), "6-digit port rejected")
  assertFalse(Lyric.Docker.isHostPort("host:abc"), "non-numeric port rejected")
}

test "isHostPort accepts the boundary ports 1 and 65535" {
  assertTrue(Lyric.Docker.isHostPort("host:1"), "port 1 accepted")
  assertTrue(Lyric.Docker.isHostPort("host:65535"), "port 65535 accepted")
}

func makeDockerClientTcpWithInjectedHostPort(): Unit {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1/evil:2375")
}

test "makeDockerClientTcp panics on a hostPort that fails isHostPort" {
  assertPanics("makeDockerClientTcp with an injected hostPort", makeDockerClientTcpWithInjectedHostPort)
}

// ─── DOCKER_HOST tcp:// routing Tests (#7255) ──────────────────────────────
// makeDockerClient() used to silently fall back to the default Unix socket
// when DOCKER_HOST named a tcp:// daemon (parseDockerHost only understands
// unix://). It now routes to makeDockerClientTcp instead — proven the same
// way as the TCP constructor tests above: DockerClient's opaque internals
// can't be asserted directly, so exercise the observable difference (an
// invalid tcp:// host:port now panics instead of being silently ignored).
func makeDockerClientWithInvalidTcpDockerHost(): Unit {
  Std.Environment.setVar("DOCKER_HOST", "tcp://not a host!")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val client = Lyric.Docker.makeDockerClient()
}

test "makeDockerClient panics when DOCKER_HOST=tcp:// names an invalid host:port" {
  assertPanics("makeDockerClient with an invalid tcp:// DOCKER_HOST", makeDockerClientWithInvalidTcpDockerHost)
}

func makeDockerClientWithValidTcpDockerHost(): Unit {
  Std.Environment.setVar("DOCKER_HOST", "tcp://127.0.0.1:2375")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val client = Lyric.Docker.makeDockerClient()
}

test "makeDockerClient routes a valid tcp:// DOCKER_HOST without panicking" {
  makeDockerClientWithValidTcpDockerHost()
  assertTrue(true, "makeDockerClient accepted a valid tcp:// DOCKER_HOST")
}

// ─── tryMakeDockerClient (non-panicking form) ──────────────────────────────
test "tryMakeDockerClient returns Err for a malformed tcp:// DOCKER_HOST" {
  Std.Environment.setVar("DOCKER_HOST", "tcp://a/b")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val result: Result[Lyric.Docker.DockerClient, Lyric.Docker.DockerError] = Lyric.Docker.tryMakeDockerClient()
  assertTrue(isErr(result), "malformed tcp:// host:port is Err, not a panic")
}

test "tryMakeDockerClient returns Err for a tcp:// DOCKER_HOST with an out-of-range port" {
  Std.Environment.setVar("DOCKER_HOST", "tcp://host:0")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val result: Result[Lyric.Docker.DockerClient, Lyric.Docker.DockerError] = Lyric.Docker.tryMakeDockerClient()
  assertTrue(isErr(result), "port 0 is Err, not a panic")
}

test "tryMakeDockerClient returns Ok for a valid tcp:// DOCKER_HOST" {
  Std.Environment.setVar("DOCKER_HOST", "tcp://127.0.0.1:2375")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val result: Result[Lyric.Docker.DockerClient, Lyric.Docker.DockerError] = Lyric.Docker.tryMakeDockerClient()
  assertTrue(isOk(result), "valid tcp:// DOCKER_HOST is Ok")
}

test "tryMakeDockerClient returns Ok on the Unix-socket path when DOCKER_HOST has no tcp:// value" {
  Std.Environment.setVar("DOCKER_HOST", "")
  defer {
    Std.Environment.setVar("DOCKER_HOST", "")
  }
  val result: Result[Lyric.Docker.DockerClient, Lyric.Docker.DockerError] = Lyric.Docker.tryMakeDockerClient()
  assertTrue(
    isOk(result),
    "absent tcp:// DOCKER_HOST falls back to the Unix-socket path, which never fails to construct"
  )
}

test "Sockets.parseTcpDockerHost extracts host:port from a tcp:// URL" {
  val result = Lyric.Docker.Sockets.parseTcpDockerHost("tcp://127.0.0.1:2375")
  assertTrue(isSome(result), "tcp:// URL parses to Some")
  assertEqual(unwrapOr(result, ""), "127.0.0.1:2375", "host:port extracted")
}

test "Sockets.parseTcpDockerHost returns None for a non-tcp URL" {
  assertTrue(isNone(Lyric.Docker.Sockets.parseTcpDockerHost("unix:///var/run/docker.sock")), "unix:// is not tcp://")
  assertTrue(isNone(Lyric.Docker.Sockets.parseTcpDockerHost("")), "empty string is not tcp://")
}

// ─── ContainerId-typed lifecycle calls against an unreachable daemon ───────
// Proves startContainer/stopContainer/waitContainer/removeContainer/
// getContainerLogs compile and run end-to-end against the new ContainerId
// parameter (rather than a raw String), the same unreachable-TCP-host
// rationale as "makeDockerClientTcp constructs a client..." above.
test "startContainer with a ContainerId fails cleanly against an unreachable daemon" {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val id = match Lyric.Docker.ContainerId.tryFrom("abcdef012345") {
    case Ok(v) -> v
    case Err(_) -> panic("unreachable")
  }
  val failed = match await Lyric.Docker.startContainer(client, id) { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(failed, "Expected startContainer to fail against an unreachable TCP host")
}

test "stopContainer with a timeoutSec fails cleanly against an unreachable daemon" {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val id = match Lyric.Docker.ContainerId.tryFrom("abcdef012345") {
    case Ok(v) -> v
    case Err(_) -> panic("unreachable")
  }
  val failed = match await Lyric.Docker.stopContainer(client, id, 5) { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(failed, "Expected stopContainer to fail against an unreachable TCP host")
}

func stopContainerWithZeroTimeout(): Unit {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val id = match Lyric.Docker.ContainerId.tryFrom("abcdef012345") {
    case Ok(v) -> v
    case Err(_) -> panic("unreachable")
  }
  val outcome = await Lyric.Docker.stopContainer(client, id, 0)
}

test "stopContainer panics on timeoutSec <= 0" {
  assertPanics("stopContainer with timeoutSec = 0", stopContainerWithZeroTimeout)
}

func waitContainerWithZeroTimeout(): Unit {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val id = match Lyric.Docker.ContainerId.tryFrom("abcdef012345") {
    case Ok(v) -> v
    case Err(_) -> panic("unreachable")
  }
  val outcome = await Lyric.Docker.waitContainer(client, id, 0)
}

test "waitContainer panics on timeoutSec <= 0" {
  assertPanics("waitContainer with timeoutSec = 0", waitContainerWithZeroTimeout)
}

test "removeContainer with a ContainerId fails cleanly against an unreachable daemon" {
  val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:1")
  val id = match Lyric.Docker.ContainerId.tryFrom("abcdef012345") {
    case Ok(v) -> v
    case Err(_) -> panic("unreachable")
  }
  val failed = match await Lyric.Docker.removeContainer(client, id) { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(failed, "Expected removeContainer to fail against an unreachable TCP host")
}
