//! tests/otlp_net_kernel_tests.l - the .NET OTLP kernel's own error text.
//!
//! dotnet-only: `OTel.Kernel.Net.Otlp` exists only under `@cfg(dotnet)`.
//! The target-neutral behaviour is covered by `otlp_transport_tests.l`.
@cfg(target = "dotnet")
@test_module
package OTel.OtlpNetKernelTests

import Std.Core
import Std.Testing
import Std.String as Str
import OTel.Kernel.Net.Otlp as OtelNetOtlp

test "netPostProtobuf names the header the HTTP stack rejected" {
  match await OtelNetOtlp.netPostProtobuf("http://127.0.0.1:1/v1/traces", [1u8, 2u8], ["Content-Type"], ["text/plain"], 1000) {
    case Err(e) -> assertTrue(Str.contains(e, "Content-Type"), "the rejected header is named: " + e)
    case Ok(_) -> assertTrue(false, "a rejected header must fail the export")
  }
}
