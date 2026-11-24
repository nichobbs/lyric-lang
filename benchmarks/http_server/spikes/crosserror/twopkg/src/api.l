package Repro.Api

import Repro.Lib

pub union ServeError {
  case Unsupported(message: String)
}

pub func serve(ok: in Bool): Result[Unit, ServeError] {
  val port = match listen(ok) {
    case Ok(p) -> p
    case Err(e) -> {
      return Err(error = Unsupported(message = "could not listen: " + ListenError.message(e)))
    }
  }
  if port == 7 {
    Ok(value = ())
  } else {
    Err(error = Unsupported(message = "port"))
  }
}

pub func serveNested(ok: in Bool): Result[Unit, ServeError] {
  match listen(ok) {
    case Ok(_) -> Ok(value = ())
    case Err(InvalidConfig(reason)) -> Err(error = Unsupported(message = "nested invalid: " + reason))
    case Err(NotSupported) -> Err(error = Unsupported(message = "nested not supported"))
  }
}

pub func serveCases(ok: in Bool): Result[Unit, ServeError] {
  val port = match listen(ok) {
    case Ok(p) -> p
    case Err(e) -> {
      val text = match e { case NotSupported -> "ns"; case InvalidConfig(r) -> "ic:" + r }
      return Err(error = Unsupported(message = text))
    }
  }
  if port > 0 {
    Ok(value = ())
  } else {
    Err(error = Unsupported(message = "x"))
  }
}
