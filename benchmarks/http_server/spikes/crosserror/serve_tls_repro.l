package Repro.ServeTls

import Std.Core
import Std.Console
import Std.HttpServer
import Std.Tls

pub union ServeTlsError {
  case ServerTlsUnsupported(message: String)
}

// The shape of lyric-web's shared `serveTls` (web.l ~2426): match Result[_, TlsListenError] from the
// stdlib inside a function returning Result[_, ServeTlsError].
func serveTlsShape(tls: in TlsServerConfig): Result[Unit, ServeTlsError] {
  val listener = match startListenerTls("127.0.0.1", 18999, tls) {
    case Ok(l) -> l
    case Err(e) -> {
      val reason = match e { case NotSupportedOnTarget(m) -> m }
      return Err(error = ServerTlsUnsupported(message = "could not start: " + reason))
    }
  }
  stopListener(listener)
  Ok(value = ())
}

func main(): Int {
  val id = match Identity.fromPemFiles("cert.pem", "key.pem") {
    case Ok(i) -> i
    case Err(e) -> panic("identity: " + TlsError.message(e))
  }
  val cfg = TlsServerConfig(identity = id, requireClientCert = true)
  match serveTlsShape(cfg) {
    case Ok(_) -> println("unexpected Ok")
    case Err(e) -> match e { case ServerTlsUnsupported(m) -> println("OK: " + m.substring(0, 60)) }
  }
  0
}
