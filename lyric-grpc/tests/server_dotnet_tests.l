//! tests/server_dotnet_tests.l — dotnet-only server checks that read the
//! `Grpc.Kernel.Net.Server` bookkeeping (#8659).
@cfg(target = "dotnet")
@test_module
package Grpc.ServerDotnetTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Time
import Grpc
import Grpc.Types
import Grpc.Kernel.Net.Server

func echo(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(req)
}

func waitForConnections(handle: in GrpcServerHandle, expected: in Int): Int {
  var waited = 0
  while trackedConnections(handle) != expected and waited < 4000 {
    sleepMillis(20)
    waited = waited + 20
  }
  trackedConnections(handle)
}

test "a finished connection is forgotten: many short-lived clients leave no tracked connections" {
  val registry = Grpc.addUnary(Grpc.create(), "test.Echo", "Echo", echo)
  val server = Grpc.startHandleAt(registry, "127.0.0.1", 0)
  var i = 0
  while i < 25 {
    match Grpc.openChannel("http://127.0.0.1:" + Grpc.serverPort(server).toString()) {
      case Std.Core.Err(m) -> panic("openChannel failed: " + m)
      case Std.Core.Ok(ch) -> {
        match Grpc.callUnary(ch, "test.Echo", "Echo", [1, 2, 3], Grpc.defaultOptions()) {
          case Std.Core.Ok(_) -> ()
          case Std.Core.Err(st) -> panic("call failed: " + st.message)
        }
        Grpc.closeChannel(ch)
      }
    }
    i = i + 1
  }
  assertEqualInt(waitForConnections(server, 0), 0, "every closed client's connection was released")
  Grpc.stop(server, 1000)
}

test "stop releases the connections of clients that are still open" {
  val registry = Grpc.addUnary(Grpc.create(), "test.Echo", "Echo", echo)
  val server = Grpc.startHandleAt(registry, "127.0.0.1", 0)
  match Grpc.openChannel("http://127.0.0.1:" + Grpc.serverPort(server).toString()) {
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
    case Std.Core.Ok(ch) -> {
      match Grpc.callUnary(ch, "test.Echo", "Echo", [1], Grpc.defaultOptions()) {
        case Std.Core.Ok(_) -> assertTrue(trackedConnections(server) >= 1, "the live connection is tracked")
        case Std.Core.Err(st) -> panic("call failed: " + st.message)
      }
      Grpc.stop(server, 1000)
      assertEqualInt(trackedConnections(server), 0, "nothing is tracked after stop")
      Grpc.closeChannel(ch)
    }
  }
}
