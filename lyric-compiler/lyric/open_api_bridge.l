// openapi_bridge.l — text-protocol bridge for the F# SelfHostedOpenApi.fs shim.
//
// Protocol (first line "ok" or "err"):
//   ok
//   <generated .l source — may be many lines>
//   ---
//   err
//   <error message>

package Lyric.OpenApiBridge

import Std.Core
import Lyric.OpenApiParser
import Lyric.OpenApiGen

/// Parse `json` as an OpenAPI 3.x spec and generate a Lyric REST client.
/// Returns "ok\n<source>" on success or "err\n<message>" on failure.
pub func generateFromJson(
  json:        in String,
  clientName:  in String,
  packageName: in String
): String {
  match parseSpec(json) {
    case Err(msg)  -> "err\n" + msg
    case Ok(spec)  -> "ok\n"  + generate(spec, clientName, packageName)
  }
}
