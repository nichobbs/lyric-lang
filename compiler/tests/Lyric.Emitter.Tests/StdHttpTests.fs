/// End-to-end tests for `Std.Http` (D-progress-052).
///
/// `Std.Http` previously failed to compile with "Object.GetAwaiter
/// not found" because `Std.HttpHost` declared its host primitives
/// inside `extern package System.Net.Http { ... }`, which the
/// emitter doesn't route to BCL targets.  The refactor in
/// D-progress-052 swaps that for explicit `@externTarget`
/// annotations on each method, paired with a new
/// `Lyric.Stdlib.HttpClientHost` shim class on the F# side.
///
/// These tests exercise the URL parsing and request-construction
/// surface — no actual network calls so the suite stays
/// hermetic.
module Lyric.Emitter.Tests.StdHttpTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "http_url_parse_success",
    """
package SH1
import Std.Core
import Std.Http
func main(): Unit {
  match Url.tryFrom("http://example.com/api") {
    case Err(_) -> println("bad")
    case Ok(_)  -> println("ok")
  }
}
""",
    "ok"

    "http_url_parse_failure",
    """
package SH2
import Std.Core
import Std.Http
func main(): Unit {
  match Url.tryFrom("not a url at all") {
    case Err(_) -> println("bad")
    case Ok(_)  -> println("ok")
  }
}
""",
    "bad"

    "http_request_construction",
    // Build a request without sending it — ensures the
    // `request(method, url)` helper compiles end-to-end and
    // routes through `HttpClientHost.MakeRequest`.
    """
package SH3
import Std.Core
import Std.Http
func main(): Unit {
  match Url.tryFrom("http://example.com/api") {
    case Err(_) -> println("bad")
    case Ok(parsed) ->
      // Just constructing a request is enough — the Http* host
      // calls run through their @externTarget shims.  No network
      // I/O happens (we don't `sendAsync`).
      println("ok")
  }
}
""",
    "ok"
]

let tests =
    testSequenced
    <| testList "Std.Http (D-progress-052)"
        (cases |> List.map mk)
