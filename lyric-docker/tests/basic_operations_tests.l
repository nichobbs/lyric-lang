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

test "demultiplex incomplete header is stopped safely" {
  // 5 bytes, insufficient for 8-byte header
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isOk(streamResult), "Expected Ok")
  val result = unwrapResultOr(streamResult, "none")
  assertEqual(result, "", "Incomplete header results in empty string")
}

test "demultiplex incomplete payload is stopped safely" {
  // stdout (1), size 5, but only 3 bytes of payload present
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8, 72u8, 101u8, 108u8]
  val streamResult = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isOk(streamResult), "Expected Ok")
  val result = unwrapResultOr(streamResult, "none")
  assertEqual(result, "", "Incomplete payload results in empty string")
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
  assertEqual(extracted, "caf\u{00e9}", "\\u00e9 decodes back to the Unicode character e-acute")
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
