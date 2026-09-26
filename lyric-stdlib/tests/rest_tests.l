//! stdlib/tests/rest_tests.l — Coverage for the contract `Std.Rest`
//! relies on (#1119).
//!
//! `Std.Rest.RestClient.json` is a `@stable(since="1.0")` async function
//! whose contract is:
//!
//!   1. Read the response body text via `HttpResponse.bodyText`.
//!   2. On transport failure, return `Err(Http(Transport(url, error)))`.
//!   3. On success, parse the body via `Std.Json.parseJson` and hand
//!      ownership of the resulting `JsonDoc` to the caller — the caller
//!      is then responsible for `disposeJson(doc)` exactly once.
//!
//! True round-trip coverage of `RestClient.json(response)` requires
//! constructing an `HttpResponse`, which is `pub opaque` in `Std.Http`
//! and has no test-stub constructor.  This file gets a flat `lyric run`
//! invocation (the "Stdlib runtime suites on dotnet" CI step) with no
//! task-runtime priming for an in-process server, so it deliberately
//! stays offline; genuine live coverage lives in
//! `lyric-compiler/lyric/rest_json_roundtrip_self_test.l` instead — a
//! `@test_module` run via native `lyric test`, which spins up a real
//! `Std.HttpServer` listener in a child process and drives
//! `RestClient.json` against a real fetched `HttpResponse`. That file's
//! header also documents the remaining gap this one does NOT close: the
//! `RestClient.get`/`.post`/`.put`/`.patch`/`.delete` request-building
//! path (`fullUrl` -> `sendRequest`) is runtime-broken on both MSIL
//! (#5622) and JVM, so no test anywhere exercises that path live yet.
//!
//! What this file CAN cover, and does, without a live server:
//!
//!   * The `parseJson` + `rootElement` + `getProperty` + `disposeJson`
//!     sequence — the exact sequence `RestClient.json` invokes after a
//!     successful body read.  Pinning this contract here guards against
//!     a `System.Text.Json` adapter regression that would surface
//!     downstream as a `RestClient.json` failure.
//!   * The `disposeJson`-after-traversal idiom — caller MUST release
//!     the pooled buffer; the test verifies this completes without a
//!     panic so the ownership doc on `RestClient.json` (#1119) is
//!     pinned at the dependency boundary.
//!   * The transport-error error-shape contract via `HttpError.message`
//!     — `RestClient.json` wraps `bodyText` failures in
//!     `Http(Transport(...))`; the formatting of the inner error is
//!     delegated to `HttpError.message`, so verifying that here pins
//!     the surface text that surfaces in production logs.
package Std.Rest.Tests

import Std.Core
import Std.Errors
import Std.Json
import Std.Rest
import Std.Testing

// ─── HttpError.message formatting (transport-error contract) ─────────────────
func testTransportMessageEmbedsUrl(): Unit {
  // The Transport variant is what RestClient.json wraps a body-text
  // failure in (`Err(Http(Transport(url, error)))`).  Verifying the
  // formatting here pins the user-visible text without needing the
  // full Std.Rest import.
  val io: IOError = IoError(path = "https://example.test/data", message = "refused")
  val err: HttpError = Transport(url = "https://example.test/data", error = io)
  val msg = HttpError.message(err)
  assertTrue(msg.contains("https://example.test/data"), "HttpError.message includes URL: " + msg)
  assertTrue(msg.contains("refused"), "HttpError.message includes inner reason: " + msg)
}

func testInvalidUrlMessageEmbedsUrl(): Unit {
  val err: HttpError = InvalidUrl(url = "::not a url::")
  val msg = HttpError.message(err)
  assertTrue(msg.contains("::not a url::"), "InvalidUrl.message embeds the offending URL: " + msg)
}

func testBadStatusMessageEmbedsCode(): Unit {
  val err: HttpError = BadStatus(url = "https://example.test/missing", statusCode = 404)
  val msg = HttpError.message(err)
  assertTrue(msg.contains("404"), "BadStatus.message includes the status code: " + msg)
}

// ─── parseJson / disposeJson — the contract RestClient.json depends on ───────
func testJsonDocRootAccessibleAfterParse(): Unit {
  val doc = parseJson("{\"name\":\"alice\",\"age\":30}")
  val root = rootElement(doc)
  val name = getString(getProperty(root, "name"))
  val age = getInt32(getProperty(root, "age"))
  assertEqual(name, "alice", "parsed name property")
  assertEqualInt(age, 30, "parsed age property")
  disposeJson(doc)
}

func testDisposeJsonAfterRoot(): Unit {
  // RestClient.json documents that callers MUST `disposeJson` after
  // they're done extracting values.  Disposing must not panic when the
  // document was successfully parsed and used.
  val doc = parseJson("{\"ok\":true}")
  val root = rootElement(doc)
  val ok = getBoolean(getProperty(root, "ok"))
  assertTrue(ok, "boolean true round-tripped")
  disposeJson(doc)
  // No further assertion is needed beyond `disposeJson` returning
  // normally; any panic would already have aborted the test.
  assertTrue(true, "disposeJson returned without panic")
}

func testJsonDocSimpleArray(): Unit {
  // The RestClient.json caller typically walks objects and arrays; pin
  // the array enumeration shape used by typical consumers.
  val doc = parseJson("[1,2,3]")
  val root = rootElement(doc)
  // `JsonValueKind.Array = 2` per System.Text.Json (#1164).
  val kArray = 2
  assertEqualInt(valueKind(root), kArray, "array valueKind is JsonValueKind.Array")
  disposeJson(doc)
}

func testJsonDocMissingFieldNotPresent(): Unit {
  // The optional-access path RestClient.json users walk: tryGetProperty
  // returns None for absent keys instead of panicking.  Pins the
  // contract `RestClient.json` users rely on for graceful field handling.
  val doc = parseJson("{\"present\":1}")
  val root = rootElement(doc)
  match tryGetProperty(root, "absent") {
    case None -> assertTrue(true, "absent field returns None")
    case Some(_) -> assertTrue(false, "absent field unexpectedly present")
  }
  disposeJson(doc)
}

func testMalformedJsonThrowsBug(): Unit {
  try {
    val doc = parseJson("{ malformed }")
    disposeJson(doc)
    assertTrue(false, "malformed JSON should have thrown Bug")
  } catch Bug as b {
    assertTrue(b.message.length > 0, "caught Bug with message: " + b.message)
  }
}

func testEmptyJsonThrowsBug(): Unit {
  try {
    val doc = parseJson("")
    disposeJson(doc)
    assertTrue(false, "empty JSON should have thrown Bug")
  } catch Bug as b {
    assertTrue(b.message.length > 0, "caught Bug with message: " + b.message)
  }
}

// #7251: a request path that could leave the base URL is refused before
// any request is built.
func escapeCode(client: in RestClient, path: in String): String {
  match await RestClient.get(client, path) {
    case Ok(_) -> "OK"
    case Err(Http(InvalidUrl(_))) -> "InvalidUrl"
    case Err(e) -> RestError.message(e)
  }
}

func testPathCannotLeaveBase(): Unit {
  val client = RestClient.create("http://127.0.0.1:1/api")
  assertTrue(escapeCode(client, "../admin") == "InvalidUrl", "leading ..")
  assertTrue(escapeCode(client, "users/../../admin") == "InvalidUrl", "embedded ..")
  assertTrue(escapeCode(client, "%2e%2e/admin") == "InvalidUrl", "percent-encoded ..")
  assertTrue(escapeCode(client, "//evil.example/x") == "InvalidUrl", "network-path reference")
  assertTrue(escapeCode(client, "http://evil.example/x") == "InvalidUrl", "absolute URL")
  assertTrue(escapeCode(client, "users\r\nX-Injected: 1") == "InvalidUrl", "CR/LF")
  assertTrue(escapeCode(RestClient.create(""), "users") == "InvalidUrl", "empty base")
  assertTrue(escapeCode(client, "..%2fadmin") == "InvalidUrl", "encoded slash after ..")
  assertTrue(escapeCode(client, "users%5C..%5Cadmin") == "InvalidUrl", "encoded backslashes around ..")
  assertTrue(
    escapeCode(client, "callback?next=https://example.com/x") != "InvalidUrl",
    "a URL in the query string is data"
  )
  assertTrue(escapeCode(client, "files/a%2fb") != "InvalidUrl", "an encoded slash in a plain segment is allowed")
  // A base ending in `/` and a path starting with `/` join with one slash;
  // the join used to take one character too many from the path and fail
  // `substring`'s precondition (#7251). The transport error names the URL.
  val slashed = escapeCode(RestClient.create("http://127.0.0.1:1/api/"), "/users")
  assertTrue(slashed.contains("127.0.0.1:1/api/users") and not slashed.contains("api//users"), "joined URL: " + slashed)
}

func main(): Int {
  testPathCannotLeaveBase()
  testTransportMessageEmbedsUrl()
  testInvalidUrlMessageEmbedsUrl()
  testBadStatusMessageEmbedsCode()
  testJsonDocRootAccessibleAfterParse()
  testDisposeJsonAfterRoot()
  testJsonDocSimpleArray()
  testJsonDocMissingFieldNotPresent()
  testMalformedJsonThrowsBug()
  testEmptyJsonThrowsBug()
  println("rest_tests: ok")
  return 0
}
