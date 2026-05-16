// pack_bridge.l — text-protocol bridge for the F# SelfHostedPack.fs shim.
// Wraps Lyric.Pack.{publishCsproj, restoreCsproj} and serialises the result to
// a simple prefix protocol so the F# shim avoids CLR reflection on Lyric unions.
//
// Protocol:
//   First line: "ok" or "parsefail"
//   On "parsefail": second line is the error message.
//   On "ok": remainder is the csproj XML text.
package Lyric.PackBridge

import Std.Core
import Std.Collections
import Lyric.Manifest
import Lyric.Pack

pub func publishCsprojToProtocol(toml: in String, dllAbsPath: in String): String {
  match parse(toml, "<bridge>") {
    case Err(e) -> "parsefail\n" + ManifestError.message(e)
    case Ok(m)  -> "ok\n" + publishCsproj(m, dllAbsPath)
  }
}

pub func restoreCsprojToProtocol(toml: in String): String {
  match parse(toml, "<bridge>") {
    case Err(e) -> "parsefail\n" + ManifestError.message(e)
    case Ok(m)  -> "ok\n" + restoreCsproj(m)
  }
}
