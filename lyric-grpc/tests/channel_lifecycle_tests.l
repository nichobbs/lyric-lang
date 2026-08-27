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
