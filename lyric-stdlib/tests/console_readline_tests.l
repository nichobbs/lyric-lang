//! stdlib/tests/console_readline_tests.l -- `Std.Console.readLine` on piped
//! stdin (#7968): lines come back as `Ok`, end of input is the typed
//! `EndOfInput` error, and no host `Bug` is caught on the way (native has no
//! try/catch).  Run by `scripts/ci/console-readline-test.sh`, which pipes
//! `alpha\nbeta\n` into the program.  Runs on every target.
package Std.Console.ReadLineTests

import Std.Core
import Std.Console
import Std.Errors

func expectLine(want: in String): Bool {
  match readLine() {
    case Ok(line) -> {
      if line == want {
        true
      } else {
        println("console_readline_tests: expected '" + want + "', got '" + line + "'")
        false
      }
    }
    case Err(e) -> {
      println("console_readline_tests: expected '" + want + "', got error: " + IOError.message(e))
      false
    }
  }
}

func expectEnd(): Bool {
  match readLine() {
    case Err(EndOfInput(_)) -> true
    case Ok(line) -> {
      println("console_readline_tests: expected EndOfInput, got line '" + line + "'")
      false
    }
    case Err(e) -> {
      println("console_readline_tests: expected EndOfInput, got error: " + IOError.message(e))
      false
    }
  }
}

func main(): Int {
  if expectLine("alpha") and expectLine("beta") and expectEnd() and expectEnd() {
    println("console_readline_tests: all passed")
    0
  } else {
    1
  }
}
