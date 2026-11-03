package Lib

pub union Failure {
  case Timeout(message: String)
  case Invalid(message: String)
}

pub func describe(f: in Failure): String {
  match f {
    case Timeout(m) -> m
    case Invalid(m) -> m
  }
}
