@test_module
package TestOptionMatch
import Std.Core

// Test Option[String] — reference-type type argument (#1550)
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

// Test Option[Int] — value-type type argument (#1550)
union IntContainer {
  case WithIntOpt(value: Option[Int])
}

func testIntIt(c: IntContainer): Int {
  match c {
    case WithIntOpt(o) -> match o {
      case Some(v) -> v
      case None -> 0
    }
  }
}

@test("matches Some[Int] correctly")
func testSomeInt(): Bool {
  testIntIt(WithIntOpt(value = Some(value = 42))) == 42
}

@test("matches None from Int correctly")
func testNoneInt(): Bool {
  testIntIt(WithIntOpt(value = None)) == 0
}

// Test nested Result[Option[String], String] (#1550)
union ResultContainer {
  case WithResultOpt(value: Result[Option[String], String])
}

func testResultIt(c: ResultContainer): Int {
  match c {
    case WithResultOpt(r) -> match r {
      case Ok(o) -> match o {
        case Some(_) -> 1
        case None -> 2
      }
      case Err(_) -> 0
    }
  }
}

@test("matches Ok(Some) correctly")
func testOkSome(): Bool {
  testResultIt(WithResultOpt(value = Ok(value = Some(value = "x")))) == 1
}

@test("matches Ok(None) correctly")
func testOkNone(): Bool {
  testResultIt(WithResultOpt(value = Ok(value = None))) == 2
}

@test("matches Err correctly")
func testErr(): Bool {
  testResultIt(WithResultOpt(value = Err(value = "oops"))) == 0
}

// Test binding alias — case Some(x) binding instead of Some(_) (#1550)
union AliasContainer {
  case WithAliasOpt(value: Option[String])
}

func testAliasIt(c: AliasContainer): String {
  match c {
    case WithAliasOpt(o) -> match o {
      case Some(x) -> x
      case None -> "none"
    }
  }
}

@test("binding alias extracts value correctly")
func testBindingAlias(): Bool {
  testAliasIt(WithAliasOpt(value = Some(value = "extracted"))) == "extracted"
}

@test("binding alias handles None correctly")
func testBindingAliasNone(): Bool {
  testAliasIt(WithAliasOpt(value = None)) == "none"
}
