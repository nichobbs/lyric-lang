/// End-to-end tests for the multi-module stdlib import resolver.
///
/// `import Std.X` (for any X beyond Core) walks the dependency
/// closure, compiles each module to its own DLL, and links the user
/// emit against all of them.
module Lyric.Emitter.Tests.StdlibImportTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "import_std_parse_int_ok",
    """
package SI1
import Std.Core
import Std.Parse

func main(): Unit {
  match tryParseInt("42") {
    case Ok(value) -> println(value)
    case Err(_)    -> println(-1)
  }
}
""",
    "42"

    "import_std_parse_int_err",
    """
package SI2
import Std.Core
import Std.Parse

func main(): Unit {
  match tryParseInt("nope") {
    case Ok(value) -> println(value)
    case Err(_)    -> println(-1)
  }
}
""",
    "-1"

    "import_std_parse_long",
    """
package SI3
import Std.Core
import Std.Parse

func main(): Unit {
  match tryParseLong("9000000000") {
    case Ok(value) -> println(value)
    case Err(_)    -> println(-1)
  }
}
""",
    "9000000000"

    "user_func_returning_cross_assembly_result",
    """
package SI8
import Std.Core
import Std.Errors

func makeOk(): Result[Int, ParseError] {
  Ok(value = 42)
}

func main(): Unit {
  match makeOk() {
    case Ok(v) -> println(v)
    case Err(_) -> println(-1)
  }
}
""",
    "42"

    "import_std_errors_directly",
    """
package SI5
import Std.Core
import Std.Errors

func main(): Unit {
  val e: ParseError = InvalidFormat(input = "x", expected = "y")
  println(ParseError.message(e))
}
""",
    "invalid format: 'x' (expected y)"

    "import_std_errors_io_error_message",
    """
package SI6
import Std.Core
import Std.Errors

func main(): Unit {
  val e: IOError = FileNotFound(path = "/missing")
  println(IOError.message(e))
}
""",
    "file not found: /missing"

    "import_std_errors_multiple_unions",
    """
package SI7
import Std.Core
import Std.Errors

func describe(p: in ParseError): String {
  match p {
    case InvalidFormat(input, _) -> "invalid: " + input
    case OutOfRange(value, _)    -> "oor: " + value
  }
}

func main(): Unit {
  println(describe(InvalidFormat(input = "abc", expected = "int")))
  println(describe(OutOfRange(value = "999", bounds = "0..100")))
}
""",
    "invalid: abc\noor: 999"
]

let tests =
    testSequenced
    <| testList "stdlib import resolver (Std.Parse / Std.Errors)"
        (cases |> List.map mk)
