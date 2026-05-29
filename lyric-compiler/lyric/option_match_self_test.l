@test_module
package TestOptionMatch
import Std.Core

union Container {
  case WithOpt(value: Option[String])
}

func testIt(c: Container): Int {
  match c {
    case WithOpt(o) -> match o {
      case Some(_) -> 1
      case None -> 2
    }
  }
}

@test("matches Some correctly")
func testSome(): Bool {
  testIt(WithOpt(value = Some(value = "hello"))) == 1
}

@test("matches None correctly")
func testNone(): Bool {
  testIt(WithOpt(value = None)) == 2
}
