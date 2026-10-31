//! tests/grpc_types_tests.l — tests for the pure-Lyric surface of lyric-grpc.
//!
//! Covers GrpcStatusCode enum, statusCodeFromInt, and GrpcStatus construction.
//! The GrpcChannel opaque type and call functions require a live gRPC server
//! and are not exercised here.
@test_module
package Grpc.GrpcTypesTests

import Std.Core
import Std.Testing
import Grpc.Types

// ─── statusCodeFromInt ────────────────────────────────────────────────────────
test "statusCodeFromInt: 0 maps to Ok" {
  match Grpc.Types.statusCodeFromInt(0) {
    case GrpcStatusCode.Ok -> ()
    case _ -> assertTrue(false, "0 must map to Ok")
  }
}

test "statusCodeFromInt: 1 maps to Cancelled" {
  match Grpc.Types.statusCodeFromInt(1) {
    case GrpcStatusCode.Cancelled -> ()
    case _ -> assertTrue(false, "1 must map to Cancelled")
  }
}

test "statusCodeFromInt: 2 maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(2) {
    case GrpcStatusCode.Unknown -> ()
    case _ -> assertTrue(false, "2 must map to Unknown")
  }
}

test "statusCodeFromInt: 3 maps to InvalidArgument" {
  match Grpc.Types.statusCodeFromInt(3) {
    case GrpcStatusCode.InvalidArgument -> ()
    case _ -> assertTrue(false, "3 must map to InvalidArgument")
  }
}

test "statusCodeFromInt: 5 maps to NotFound" {
  match Grpc.Types.statusCodeFromInt(5) {
    case GrpcStatusCode.NotFound -> ()
    case _ -> assertTrue(false, "5 must map to NotFound")
  }
}

test "statusCodeFromInt: 7 maps to PermissionDenied" {
  match Grpc.Types.statusCodeFromInt(7) {
    case GrpcStatusCode.PermissionDenied -> ()
    case _ -> assertTrue(false, "7 must map to PermissionDenied")
  }
}

test "statusCodeFromInt: 12 maps to Unimplemented" {
  match Grpc.Types.statusCodeFromInt(12) {
    case GrpcStatusCode.Unimplemented -> ()
    case _ -> assertTrue(false, "12 must map to Unimplemented")
  }
}

test "statusCodeFromInt: 14 maps to Unavailable" {
  match Grpc.Types.statusCodeFromInt(14) {
    case GrpcStatusCode.Unavailable -> ()
    case _ -> assertTrue(false, "14 must map to Unavailable")
  }
}

test "statusCodeFromInt: 16 maps to Unauthenticated" {
  match Grpc.Types.statusCodeFromInt(16) {
    case GrpcStatusCode.Unauthenticated -> ()
    case _ -> assertTrue(false, "16 must map to Unauthenticated")
  }
}

test "statusCodeFromInt: unknown integer maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(99) {
    case GrpcStatusCode.Unknown -> ()
    case _ -> assertTrue(false, "out-of-range must map to Unknown")
  }
}

test "statusCodeFromInt: negative integer maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(-1) {
    case GrpcStatusCode.Unknown -> ()
    case _ -> assertTrue(false, "negative must map to Unknown")
  }
}

// ─── GrpcStatus construction ──────────────────────────────────────────────────
test "GrpcStatus: fields are accessible" {
  val s = GrpcStatus(code = GrpcStatusCode.NotFound, message = "user not found")
  assertEqual(s.message, "user not found", "GrpcStatus message")
  match s.code {
    case GrpcStatusCode.NotFound -> ()
    case _ -> assertTrue(false, "GrpcStatus code must be NotFound")
  }
}

test "GrpcStatus: Ok status has correct code" {
  val s = GrpcStatus(code = GrpcStatusCode.Ok, message = "")
  match s.code {
    case GrpcStatusCode.Ok -> ()
    case _ -> assertTrue(false, "code must be Ok")
  }
}

test "GrpcStatus: error status carries non-empty message" {
  val s = GrpcStatus(code = GrpcStatusCode.Internal, message = "unexpected panic")
  assertTrue(s.message.length > 0, "error status must have non-empty message")
}

// ─── GrpcMetadataEntry construction ──────────────────────────────────────────
test "GrpcMetadataEntry: fields are accessible" {
  val e = GrpcMetadataEntry(key = "authorization", value = "Bearer token123")
  assertEqual(e.key, "authorization", "key field")
  assertEqual(e.value, "Bearer token123", "value field")
}

test "GrpcMetadataEntry: empty value is valid" {
  val e = GrpcMetadataEntry(key = "x-request-id", value = "")
  assertEqual(e.key, "x-request-id", "key field")
  assertEqual(e.value, "", "empty value is valid")
}

// ─── statusFromException: host exception text -> GrpcStatus ──────────────────
test "statusFromException: grpc-dotnet RpcException text carries its code and detail" {
  val st = statusFromException("Grpc.Core.RpcException", "Status(StatusCode=\"NotFound\", Detail=\"no such row\")")
  assertTrue(st.code == GrpcStatusCode.NotFound, "code from StatusCode")
  assertEqual(st.message, "no such row", "detail without the Status(...) wrapper")
}

test "statusFromException: the AggregateException wrapper and DebugException are not part of the detail" {
  val wrapped = statusFromException(
    "System.AggregateException",
    "One or more errors occurred. (Status(StatusCode=\"Internal\", Detail=\"boom\"))"
  )
  assertTrue(wrapped.code == GrpcStatusCode.Internal, "code found inside the wrapper")
  assertEqual(wrapped.message, "boom", "detail stops at its closing quote")
  val debug = statusFromException(
    "Grpc.Core.RpcException",
    "Status(StatusCode=\"Unavailable\", Detail=\"Error connecting\", DebugException=\"x: y\")"
  )
  assertTrue(debug.code == GrpcStatusCode.Unavailable, "code")
  assertEqual(debug.message, "Error connecting", "DebugException is dropped")
}

test "statusFromException: grpc-java StatusRuntimeException text carries its code and description" {
  val st = statusFromException("io.grpc.StatusRuntimeException", "DEADLINE_EXCEEDED: deadline exceeded after 0.3s")
  assertTrue(st.code == GrpcStatusCode.DeadlineExceeded, "UPPER_SNAKE code")
  assertEqual(st.message, "deadline exceeded after 0.3s", "description after the colon")
  val bare = statusFromException("io.grpc.StatusRuntimeException", "UNAVAILABLE")
  assertTrue(bare.code == GrpcStatusCode.Unavailable, "a code with no description")
}

test "statusFromException: any other exception is Unknown and keeps its type and message" {
  val st = statusFromException("System.InvalidOperationException", "Sequence contains no elements")
  assertTrue(st.code == GrpcStatusCode.Unknown, "Unknown")
  assertEqual(st.message, "System.InvalidOperationException: Sequence contains no elements", "nothing is lost")
  val prose = statusFromException("java.io.IOException", "Connection reset")
  assertTrue(prose.code == GrpcStatusCode.Unknown, "free text before a colon is not mistaken for a code")
}

// ─── decodeMetadata: inverse of Grpc.metadataString ──────────────────────────
test "decodeMetadata: key:value pairs split on commas" {
  val entries = decodeMetadata("a:1,b:2")
  assertEqualInt(entries.count, 2, "two entries")
  assertEqual(entries[0].key, "a", "first key")
  assertEqual(entries[1].value, "2", "second value")
}

test "decodeMetadata: percent escapes restore reserved characters" {
  val entries = decodeMetadata("k%3Ax:v%2C1%25")
  assertEqualInt(entries.count, 1, "one entry")
  assertEqual(entries[0].key, "k:x", "escaped colon in the key")
  assertEqual(entries[0].value, "v,1%", "escaped comma and percent in the value")
}

test "decodeMetadata: an empty string has no entries and a colon-less part is dropped" {
  assertEqualInt(decodeMetadata("").count, 0, "empty")
  assertEqualInt(decodeMetadata("novalue").count, 0, "dropped")
}

// ─── parseAddress ────────────────────────────────────────────────────────────
test "parseAddress: http and https authorities" {
  match parseAddress("http://localhost:50051") {
    case Std.Core.Ok(a) -> {
      assertFalse(a.secure, "http is plaintext")
      assertEqual(a.authority, "localhost:50051", "authority")
    }
    case Std.Core.Err(m) -> panic(m)
  }
  match parseAddress("https://collector.example:4317/") {
    case Std.Core.Ok(a) -> {
      assertTrue(a.secure, "https is TLS")
      assertEqual(a.authority, "collector.example:4317", "trailing slash dropped")
    }
    case Std.Core.Err(m) -> panic(m)
  }
}

test "parseAddress: malformed addresses are rejected with a message" {
  val bad = [
    "",
    "not a valid uri at all::::",
    "localhost:50051",
    "http://",
    "http://:80",
    "http://h/path",
    "http://h p",
    "ftp://h:1"
  ]
  for b in bad {
    match parseAddress(b) {
      case Std.Core.Ok(_) -> panic("expected Err for '" + b + "'")
      case Std.Core.Err(m) -> assertTrue(m.length > 0, "message for '" + b + "'")
    }
  }
}
