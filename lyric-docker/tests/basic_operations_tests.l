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
  val resultOpt = Lyric.Docker.demultiplexDockerStream([])
  assertTrue(isSome(resultOpt), "Expected Some")
  val result = unwrapOr(resultOpt, "none")
  assertEqual(result, "", "Empty stream demultiplexes to empty string")
}

test "demultiplex single stdout frame" {
  // stdout (1), size 5, "Hello"
  val bytes: slice[Byte] = [
    1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8,
    72u8, 101u8, 108u8, 108u8, 111u8
  ]
  val resultOpt = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isSome(resultOpt), "Expected Some")
  val result = unwrapOr(resultOpt, "")
  assertEqual(result, "Hello", "Demultiplexed single frame")
}

test "demultiplex multiple stdout and stderr frames" {
  // Frame 1: stdout (1), size 5, "Hello"
  // Frame 2: stderr (2), size 6, " World"
  val bytes: slice[Byte] = [
    1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8,
    72u8, 101u8, 108u8, 108u8, 111u8,
    2u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 6u8,
    32u8, 87u8, 111u8, 114u8, 108u8, 100u8
  ]
  val resultOpt = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isSome(resultOpt), "Expected Some")
  val result = unwrapOr(resultOpt, "")
  assertEqual(result, "Hello World", "Demultiplexed combined stdout/stderr frames")
}

test "demultiplex incomplete header is stopped safely" {
  // 5 bytes, insufficient for 8-byte header
  val bytes: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8]
  val resultOpt = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isSome(resultOpt), "Expected Some")
  val result = unwrapOr(resultOpt, "none")
  assertEqual(result, "", "Incomplete header results in empty string")
}

test "demultiplex incomplete payload is stopped safely" {
  // stdout (1), size 5, but only 3 bytes of payload present
  val bytes: slice[Byte] = [
    1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 5u8,
    72u8, 101u8, 108u8
  ]
  val resultOpt = Lyric.Docker.demultiplexDockerStream(bytes)
  assertTrue(isSome(resultOpt), "Expected Some")
  val result = unwrapOr(resultOpt, "none")
  assertEqual(result, "", "Incomplete payload results in empty string")
}
