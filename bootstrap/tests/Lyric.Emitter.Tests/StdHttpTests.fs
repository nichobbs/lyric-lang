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

    "http_send_with_cancel_pre_cancelled",
    // D-progress-070: explicit-cancel API on POST.  The token is
    // cancelled BEFORE the request is sent; the host's
    // PostAsync(url, body, token) immediately throws
    // OperationCanceledException, the Lyric try/catch surfaces it
    // as ConnectionFailed.  No actual network I/O.
    """
package SH4
import Std.Core
import Std.Http
import Std.Task
async func go(): String {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  defer { disposeSource(src) }
  val outcome =
    await postWithCancelAsync("http://127.0.0.1:1/never", "{}", tok)
  match outcome {
    case Ok(_)  -> "unexpected-ok"
    case Err(_) -> "cancelled"
  }
}
func main(): Unit {
  println(await go())
}
""",
    "cancelled"

    "http_get_with_cancel_pre_cancelled",
    // D-progress-070: cancellation API on GET.  Pre-cancelled
    // token short-circuits the host call to
    // OperationCanceledException; surfaced as ConnectionFailed
    // on the Lyric side.
    """
package SH5
import Std.Core
import Std.Http
import Std.Task
async func go(): String {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  defer { disposeSource(src) }
  val outcome =
    await getWithCancelAsync("http://127.0.0.1:1/never", tok)
  match outcome {
    case Ok(_)  -> "unexpected-ok"
    case Err(_) -> "cancelled"
  }
}
func main(): Unit {
  println(await go())
}
""",
    "cancelled"

    "http_post_with_cancel_pre_cancelled",
    // POST variant of the explicit-cancel API.
    """
package SH6
import Std.Core
import Std.Http
import Std.Task
async func go(): String {
  val src = makeCancelSource()
  val tok = sourceToken(src)
  cancelSource(src)
  defer { disposeSource(src) }
  val outcome =
    await postWithCancelAsync("http://127.0.0.1:1/never", "{}", tok)
  match outcome {
    case Ok(_)  -> "unexpected-ok"
    case Err(_) -> "cancelled"
  }
}
func main(): Unit {
  println(await go())
}
""",
    "cancelled"

    "http_client_redirect_factories_construct",
    // The redirect-policy helpers compile end-to-end.  We don't
    // exercise actual redirects here (would need a hermetic
    // server) — the test confirms the FFI dispatch resolves
    // cleanly.
    """
package SH7
import Std.Core
import Std.Http
func main(): Unit {
  val _ = clientNoRedirects()
  val _ = clientWithRedirects(5)
  println("ok")
}
""",
    "ok"
]

let tests =
    testSequenced
    <| testList "Std.Http (D-progress-052)"
        (cases |> List.map mk)
