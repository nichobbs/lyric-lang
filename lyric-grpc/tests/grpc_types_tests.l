// tests/grpc_types_tests.l — tests for the pure-Lyric surface of lyric-grpc.
//
// Covers GrpcStatusCode enum, statusCodeFromInt, and GrpcStatus construction.
// The GrpcChannel opaque type and call functions require a live gRPC server
// and are not exercised here.

@test_module
package Grpc.GrpcTypesTests

import Std.Core
import Std.Testing
import Grpc.Types

// ─── statusCodeFromInt ────────────────────────────────────────────────────────

test "statusCodeFromInt: 0 maps to Ok" {
  match Grpc.Types.statusCodeFromInt(0) {
    case GrpcStatusCode.Ok -> ()
    case _                 -> assertTrue(false, "0 must map to Ok")
  }
}

test "statusCodeFromInt: 1 maps to Cancelled" {
  match Grpc.Types.statusCodeFromInt(1) {
    case GrpcStatusCode.Cancelled -> ()
    case _                        -> assertTrue(false, "1 must map to Cancelled")
  }
}

test "statusCodeFromInt: 2 maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(2) {
    case GrpcStatusCode.Unknown -> ()
    case _                      -> assertTrue(false, "2 must map to Unknown")
  }
}

test "statusCodeFromInt: 3 maps to InvalidArgument" {
  match Grpc.Types.statusCodeFromInt(3) {
    case GrpcStatusCode.InvalidArgument -> ()
    case _                              -> assertTrue(false, "3 must map to InvalidArgument")
  }
}

test "statusCodeFromInt: 5 maps to NotFound" {
  match Grpc.Types.statusCodeFromInt(5) {
    case GrpcStatusCode.NotFound -> ()
    case _                       -> assertTrue(false, "5 must map to NotFound")
  }
}

test "statusCodeFromInt: 7 maps to PermissionDenied" {
  match Grpc.Types.statusCodeFromInt(7) {
    case GrpcStatusCode.PermissionDenied -> ()
    case _                               -> assertTrue(false, "7 must map to PermissionDenied")
  }
}

test "statusCodeFromInt: 12 maps to Unimplemented" {
  match Grpc.Types.statusCodeFromInt(12) {
    case GrpcStatusCode.Unimplemented -> ()
    case _                            -> assertTrue(false, "12 must map to Unimplemented")
  }
}

test "statusCodeFromInt: 14 maps to Unavailable" {
  match Grpc.Types.statusCodeFromInt(14) {
    case GrpcStatusCode.Unavailable -> ()
    case _                          -> assertTrue(false, "14 must map to Unavailable")
  }
}

test "statusCodeFromInt: 16 maps to Unauthenticated" {
  match Grpc.Types.statusCodeFromInt(16) {
    case GrpcStatusCode.Unauthenticated -> ()
    case _                              -> assertTrue(false, "16 must map to Unauthenticated")
  }
}

test "statusCodeFromInt: unknown integer maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(99) {
    case GrpcStatusCode.Unknown -> ()
    case _                      -> assertTrue(false, "out-of-range must map to Unknown")
  }
}

test "statusCodeFromInt: negative integer maps to Unknown" {
  match Grpc.Types.statusCodeFromInt(-1) {
    case GrpcStatusCode.Unknown -> ()
    case _                      -> assertTrue(false, "negative must map to Unknown")
  }
}

// ─── GrpcStatus construction ──────────────────────────────────────────────────

test "GrpcStatus: fields are accessible" {
  val s = GrpcStatus(code = GrpcStatusCode.NotFound, message = "user not found")
  assertEqual(s.message, "user not found", "GrpcStatus message")
  match s.code {
    case GrpcStatusCode.NotFound -> ()
    case _                       -> assertTrue(false, "GrpcStatus code must be NotFound")
  }
}

test "GrpcStatus: Ok status has correct code" {
  val s = GrpcStatus(code = GrpcStatusCode.Ok, message = "")
  match s.code {
    case GrpcStatusCode.Ok -> ()
    case _                 -> assertTrue(false, "code must be Ok")
  }
}

test "GrpcStatus: error status carries non-empty message" {
  val s = GrpcStatus(code = GrpcStatusCode.Internal, message = "unexpected panic")
  assertTrue(s.message.length > 0, "error status must have non-empty message")
}

// ─── GrpcMetadataEntry construction ──────────────────────────────────────────

test "GrpcMetadataEntry: fields are accessible" {
  val e = GrpcMetadataEntry(key = "authorization", value = "Bearer token123")
  assertEqual(e.key,   "authorization",  "key field")
  assertEqual(e.value, "Bearer token123", "value field")
}

test "GrpcMetadataEntry: empty value is valid" {
  val e = GrpcMetadataEntry(key = "x-request-id", value = "")
  assertEqual(e.key, "x-request-id", "key field")
  assertEqual(e.value, "", "empty value is valid")
}
