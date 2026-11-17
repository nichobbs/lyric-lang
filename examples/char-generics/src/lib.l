package CharGenLib

import Std.Core
import Std.Collections

pub record Box[T] {
  value: T
}

pub union Maybe[T] {
  case Just(value: T)
  case Nothing
}

pub func showMaybe[T](m: in Maybe[T]): String {
  match m {
    case Just(v) -> "just ${v}"
    case Nothing -> "nothing"
  }
}

pub func showOption[T](o: in Option[T]): String {
  match o {
    case Some(v) -> "some " + v
    case None -> "none"
  }
}

pub func showPair[A, B](a: in A, b: in B): String {
  a.toString() + "/" + b.toString()
}

pub func concatLeft[T](x: in T): String {
  "[" + x
}

pub func showToString[T](x: in T): String {
  x.toString()
}

pub func showInterpolated[T](x: in T): String {
  "<${x}>"
}

pub func showViaHelper[T](x: in T): String {
  "(" + describe(x) + ")"
}

pub func showBoxed[T](b: in Box[T]): String {
  "box " + b.value
}

pub func showAll[T](xs: in List[T]): String {
  var acc = ""
  for x in xs {
    acc += x
    acc += ","
  }
  acc
}

pub func twice[T](x: in T): String {
  showInterpolated(x) + showToString(x)
}

pub func pick[T](x: in T): T {
  x
}

func describe[T](x: in T): String {
  "v=${x}"
}

func unwrapBox[T](b: in Box[T]): T {
  b.value
}

pub func showUnwrapped[T](b: in Box[T]): String {
  "u=" + unwrapBox(b)
}
