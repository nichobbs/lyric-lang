package Repro.Lib

pub union ListenError {
  case NotSupported
  case InvalidConfig(reason: String)
}

pub func ListenError.message(e: in ListenError): String {
  match e {
    case NotSupported -> "not supported"
    case InvalidConfig(reason) -> "invalid: " + reason
  }
}

pub func listen(ok: in Bool): Result[Int, ListenError] {
  if ok {
    Ok(value = 7)
  } else {
    Err(error = InvalidConfig(reason = "bad"))
  }
}
