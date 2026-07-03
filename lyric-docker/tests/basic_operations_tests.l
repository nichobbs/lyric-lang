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
