//! tests/channel_lifecycle_tests.l — tests for Grpc.openChannel/closeChannel's
//! real Grpc.Net.Client.GrpcChannel-backed lifecycle (#5409).
//!
//! `GrpcChannel.ForAddress` is lazy (it does not dial the network until the
//! first RPC), so these tests exercise what is genuinely observable without
//! a live server: address validation, distinct per-open handles, and clean
//! disposal. `Grpc.callUnary`/`Grpc.openServerStream` are not covered here —
//! see the long comment on `netCallUnary` in
//! `src/_kernel/net/grpc_kernel.l` for why.
@test_module
package Grpc.ChannelLifecycleTests

import Std.Core
import Std.Testing
import Grpc
import Grpc.Types

test "openChannel: a well-formed address succeeds" {
  match Grpc.openChannel("http://localhost:50051") {
    case Ok(channel) -> Grpc.closeChannel(channel)
    case Err(msg) -> assertTrue(false, "expected Ok, got Err(" + msg + ")")
  }
}

test "openChannel: an https address succeeds" {
  match Grpc.openChannel("https://localhost:50052") {
    case Ok(channel) -> Grpc.closeChannel(channel)
    case Err(msg) -> assertTrue(false, "expected Ok, got Err(" + msg + ")")
  }
}

test "openChannel: a malformed address is rejected with a message" {
  match Grpc.openChannel("not a valid uri at all::::") {
    case Ok(_) -> assertTrue(false, "expected Err for a malformed address")
    case Err(msg) -> assertTrue(msg.length > 0, "Err message must be non-empty")
  }
}

test "openChannel: an empty address is rejected" {
  match Grpc.openChannel("") {
    case Ok(_) -> assertTrue(false, "expected Err for an empty address")
    case Err(msg) -> assertTrue(msg.length > 0, "Err message must be non-empty")
  }
}

test "openChannel: repeated open/close does not leak or crash" {
  var i = 0
  while i < 25 {
    match Grpc.openChannel("http://localhost:50051") {
      case Ok(channel) -> Grpc.closeChannel(channel)
      case Err(msg) -> assertTrue(false, "expected Ok on iteration " + i.toString() + ", got Err(" + msg + ")")
    }
    i = i + 1
  }
}

test "closeChannel: closing the same handle twice is a safe no-op" {
  match Grpc.openChannel("http://localhost:50054") {
    case Err(msg) -> assertTrue(false, "expected Ok, got Err(" + msg + ")")
    case Ok(channel) -> {
      Grpc.closeChannel(channel)
      // The second close's registry lookup misses (already TryRemove'd by
      // the first) -- must be a silent no-op, not a crash or double-dispose.
      Grpc.closeChannel(channel)
    }
  }
}

test "closeChannel: a never-issued handle is a safe no-op" {
  // Grpc.Types.wrapChannelHandle constructs a GrpcChannel around a raw
  // registry key with no corresponding live Grpc.Net.Client.GrpcChannel --
  // exercises the same "registry lookup misses" no-op path a stale or
  // forged handle would hit, without needing #6580's pub-visibility
  // workaround to persist for this test to make sense.
  val neverIssued = Grpc.Types.wrapChannelHandle(999999999)
  Grpc.closeChannel(neverIssued)
}

test "openChannel: two concurrently-open channels get independent handles that both close cleanly" {
  match Grpc.openChannel("http://localhost:50051") {
    case Err(msg) -> assertTrue(false, "expected Ok for first channel, got Err(" + msg + ")")
    case Ok(first) -> {
      match Grpc.openChannel("http://localhost:50053") {
        case Err(msg) -> assertTrue(false, "expected Ok for second channel, got Err(" + msg + ")")
        case Ok(second) -> {
          Grpc.closeChannel(first)
          Grpc.closeChannel(second)
        }
      }
    }
  }
}

// ─── Metadata validation (#7247) ─────────────────────────────────────────────
// A CR/LF in a metadata value would reach the HTTP/2 header block; keys are
// lowercase on the wire and `grpc-` is reserved by the protocol.
test "metadata keys: lowercase token characters only, grpc- reserved" {
  assertTrue(isValidMetadataKey("authorization"), "lowercase key")
  assertTrue(isValidMetadataKey("x-trace_id.v1"), "digits, -, _ and . are allowed")
  assertTrue(not isValidMetadataKey(""), "empty key")
  assertTrue(not isValidMetadataKey("Authorization"), "uppercase key")
  assertTrue(not isValidMetadataKey("x key"), "space in key")
  assertTrue(not isValidMetadataKey("grpc-timeout"), "reserved grpc- namespace")
}

test "metadata values: printable ASCII unless the key is -bin" {
  assertTrue(isValidMetadataValue("x-id", "abc 123"), "printable ASCII")
  assertTrue(not isValidMetadataValue("x-id", "a\r\nx-injected: 1"), "CR/LF")
  assertTrue(not isValidMetadataValue("x-id", "café"), "non-ASCII")
  assertTrue(isValidMetadataValue("x-blob-bin", "\u{0001}\u{0002}"), "-bin values are raw bytes")
}

test "tryWithMetadata reports an invalid entry as Err; withMetadata requires a valid one" {
  match tryWithMetadata(defaultOptions(), "x-id", "a\nb") {
    case Std.Core.Ok(_) -> assertTrue(false, "expected Err for a newline in the value")
    case Err(_) -> ()
  }
  match tryWithMetadata(defaultOptions(), "x-id", "ok") {
    case Std.Core.Ok(o) -> assertEqualInt(o.metadata.length, 1, "one entry added")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
  assertPanics("uppercase key", { -> val _ = withMetadata(defaultOptions(), "X-Id", "v") })
  assertPanics("non-positive timeout", { -> val _ = withTimeout(defaultOptions(), 0) })
}
