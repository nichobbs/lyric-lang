package Repro.Main

import Std.Core
import Std.Console
import Repro.Api

func main(): Int {
  match serve(false) {
    case Ok(_) -> println("ok")
    case Err(e) -> match e { case Unsupported(message) -> println("err: " + message) }
  }
  match serve(true) {
    case Ok(_) -> println("ok")
    case Err(e) -> match e { case Unsupported(message) -> println("err: " + message) }
  }
  match serveNested(false) {
    case Ok(_) -> println("ok")
    case Err(e) -> match e { case Unsupported(m) -> println("nested: " + m) }
  }
  match serveCases(false) {
    case Ok(_) -> println("ok")
    case Err(e) -> match e { case Unsupported(m) -> println("cases: " + m) }
  }
  0
}
