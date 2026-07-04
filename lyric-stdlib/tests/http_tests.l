//! stdlib/tests/http_tests.l — Tests for Std.Http.
//!
//! Covers the core surface flagged as untested in
//! docs/57-stdlib-ecosystem-library-review.md §5.1 that does *not*
//! require a live network connection: URL validation, request/response
//! object construction (headers, JSON/text bodies), the
//! `HttpClientBuilder` fluent API, and `HttpError` message rendering.
//! Actually sending a request (`sendAsync`/`getAsync`/`postAsync`)
//! needs a live server and is out of scope here — see docs/57 §5.2.
@test_module
package Std.Http.Tests

import Std.Core
import Std.Errors
import Std.Http
import Std.Testing

test "Url.tryFrom accepts http and https URLs" {
  match Url.tryFrom("http://example.com") {
    case Ok(url) -> assertEqual(Url.toString(url), "http://example.com", "http URL round-trips")
    case Err(e) -> panic("expected Ok for http URL, got: " + HttpError.message(e))
  }
  match Url.tryFrom("https://example.com/path?q=1") {
    case Ok(url) -> assertEqual(Url.toString(url), "https://example.com/path?q=1", "https URL round-trips")
    case Err(e) -> panic("expected Ok for https URL, got: " + HttpError.message(e))
  }
}

test "Url.tryFrom rejects an empty URL" {
  match Url.tryFrom("") {
    case Ok(_) -> panic("expected InvalidUrl for an empty string")
    case Err(InvalidUrl(url)) -> assertEqual(url, "", "InvalidUrl carries the empty input")
    case Err(other) -> panic("expected InvalidUrl, got: " + HttpError.message(other))
  }
}

test "Url.tryFrom rejects URLs without an http(s) scheme" {
  match Url.tryFrom("ftp://example.com") {
    case Ok(_) -> panic("expected InvalidUrl for a non-http(s) scheme")
    case Err(InvalidUrl(_)) -> ()
    case Err(other) -> panic("expected InvalidUrl, got: " + HttpError.message(other))
  }
  match Url.tryFrom("example.com") {
    case Ok(_) -> panic("expected InvalidUrl for a schemeless host")
    case Err(InvalidUrl(_)) -> ()
    case Err(other) -> panic("expected InvalidUrl, got: " + HttpError.message(other))
  }
}

test "request/withHeader/withJsonBody/withTextBody construct without a live connection" {
  val url = match Url.tryFrom("https://example.com") {
    case Ok(u) -> u
    case Err(e) -> panic("unexpected InvalidUrl: " + HttpError.message(e))
  }
  val getReq = request(GET, url)
  val withAuth = withHeader(getReq, "Authorization", "Bearer token")
  val _ = withAuth

  val postReq = request(POST, url)
  val withJson = withJsonBody(postReq, "{\"key\":\"value\"}")
  val _ = withJson

  val putReq = request(PUT, url)
  val withText = withTextBody(putReq, "plain body")
  val _ = withText

  assertTrue(true, "request construction completed without panicking")
}

test "HttpClientBuilder.new starts with TCP defaults" {
  val b = HttpClientBuilder.new()
  match b.socketPath {
    case None -> ()
    case Some(_) -> panic("new() builder should have no unix socket configured")
  }
  match b.maxRedirects {
    case None -> ()
    case Some(_) -> panic("new() builder should have no explicit redirect cap")
  }
  assertFalse(b.noRedirects, "new() builder follows redirects by default")
}

test "HttpClientBuilder.withRedirects sets maxRedirects and clears noRedirects" {
  val b = HttpClientBuilder.withRedirects(HttpClientBuilder.new(), 5)
  match b.maxRedirects {
    case Some(n) -> assertEqualInt(n, 5, "maxRedirects is set to the requested value")
    case None -> panic("expected maxRedirects to be Some(5)")
  }
  assertFalse(b.noRedirects, "withRedirects does not set noRedirects")
}

test "HttpClientBuilder.withNoRedirects sets noRedirects and clears maxRedirects" {
  val withCap = HttpClientBuilder.withRedirects(HttpClientBuilder.new(), 3)
  val b = HttpClientBuilder.withNoRedirects(withCap)
  assertTrue(b.noRedirects, "noRedirects is set")
  match b.maxRedirects {
    case None -> ()
    case Some(_) -> panic("withNoRedirects should clear any previously configured maxRedirects")
  }
}

test "HttpClientBuilder.withUnixSocket sets the socket path" {
  val b = HttpClientBuilder.withUnixSocket(HttpClientBuilder.new(), "/var/run/docker.sock")
  match b.socketPath {
    case Some(path) -> assertEqual(path, "/var/run/docker.sock", "socketPath carries the configured path")
    case None -> panic("expected socketPath to be Some(...)")
  }
}

test "HttpClientBuilder.build constructs a client without a live connection" {
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  val _ = client
  assertTrue(true, "build() completed without panicking")
}

test "HttpError.message renders each variant" {
  assertTrue(
    HttpError.message(InvalidUrl(url = "not-a-url")).contains("not-a-url"),
    "InvalidUrl message contains the URL"
  )
  assertTrue(
    HttpError.message(ConnectionFailed(url = "https://example.com", message = "refused")).contains("refused"),
    "ConnectionFailed message contains the detail"
  )
}
