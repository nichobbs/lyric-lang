//! stdlib/tests/http_client_h2_interop_tests.l -- `Std.Http` on `--target
//! native` against independent TLS servers (docs/72 slice 7, D803):
//!
//!   - `nghttpd` (nghttp2) selects ALPN `h2`: the send is served over h2, a
//!     404 and a 5 MiB body included (nghttpd speaks only h2, so the
//!     pinned-HTTP/1.1 client is covered by `http_client_h2_native_tests.l`).
//!   - `openssl s_server -WWW` negotiates no ALPN protocol and answers in
//!     HTTP/1.x: a client offering `h2,http/1.1` falls back to HTTP/1.1 on the
//!     connection it already has.
//!
//! Not runnable on its own: `scripts/ci/native-h2-client-interop.sh` starts
//! both servers on a document root holding `index.html` and `big.bin`,
//! generates the certificate, and passes the coordinates in the environment:
//!
//!   - `LYRIC_NGHTTPD_TLS_PORT`: the nghttpd TLS listener
//!   - `LYRIC_OPENSSL_TLS_PORT`: the `s_server` listener
//!   - `LYRIC_NGHTTPD_CERT`: the PEM certificate both serve, the only trust
//!     anchor the client is given (`localhost`)
//!   - `LYRIC_NGHTTPD_BIG_BYTES`: the size of `big.bin`
//!
//! A missing variable fails the suite: the script is the only caller, so
//! there is nothing to skip.
@test_module
package Std.Http.H2ClientInteropTests

import Std.Core
import Std.Errors
import Std.Parse
import Std.Tls
import Std.Http
import Std.Environment as Env
import Std.File as File
import Std.Testing

val indexBody = "lyric-h2-interop\n"

func envOrFail(name: in String): String {
  match Env.getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic("the interop suite needs " + name + "; run it through scripts/ci/native-h2-client-interop.sh")
  }
}

func envInt(name: in String): Int {
  match tryParseInt(envOrFail(name)) {
    case Ok(n) -> n
    case Err(_) -> panic(name + " is not an integer")
  }
}

func trustedClient(pinHttp11: in Bool): HttpClient {
  val ca = match Certificate.fromPem(File.readTextOrPanic(envOrFail("LYRIC_NGHTTPD_CERT"))) {
    case Ok(c) -> c
    case Err(e) -> panic(TlsError.message(e))
  }
  val b = HttpClientBuilder.new().withExclusiveCaCertificate(ca)
  if pinHttp11 {
    b.withHttpVersion(Http11).build()
  } else {
    b.build()
  }
}

func nghttpdUrl(path: in String): String {
  "https://localhost:" + envInt("LYRIC_NGHTTPD_TLS_PORT").toString() + path
}

func opensslUrl(path: in String): String {
  "https://localhost:" + envInt("LYRIC_OPENSSL_TLS_PORT").toString() + path
}

func fetch(client: in HttpClient, url: in String): HttpResponse {
  match await client.get(url) {
    case Ok(r) -> r
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
  }
}

func bodyOf(resp: in HttpResponse): String {
  match await HttpResponse.bodyText(resp) {
    case Ok(t) -> t
    case Err(e) -> panic("body read failed: " + IOError.message(e))
  }
}

func assertVersion(resp: in HttpResponse, wantH2: in Bool, what: in String): Unit {
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(wantH2, what + ": negotiated h2")
    case Http11 -> assertTrue(not wantH2, what + ": negotiated HTTP/1.1")
    case _ -> assertTrue(false, what + ": unexpected version")
  }
}

test "nghttpd: a small GET is served over h2" {
  val resp = fetch(trustedClient(false), nghttpdUrl("/index.html"))
  assertEqualInt(resp.statusCode(), 200, "status")
  assertVersion(resp, true, "nghttpd")
  assertEqual(bodyOf(resp), indexBody, "body")
  assertTrue(isSome(resp.header("content-length")), "a response header is readable")
}

test "nghttpd: a missing path is a 404 over h2" {
  val resp = fetch(trustedClient(false), nghttpdUrl("/does-not-exist"))
  assertEqualInt(resp.statusCode(), 404, "status")
  assertVersion(resp, true, "nghttpd 404")
}

test "nghttpd: a 5 MiB body arrives in full over h2" {
  val resp = fetch(trustedClient(false), nghttpdUrl("/big.bin"))
  assertEqualInt(resp.statusCode(), 200, "status")
  assertVersion(resp, true, "nghttpd big")
  val bytes = match await HttpResponse.bodyBytes(resp) {
    case Ok(b) -> b
    case Err(e) -> panic("body read failed: " + IOError.message(e))
  }
  assertEqualInt(bytes.length, envInt("LYRIC_NGHTTPD_BIG_BYTES"), "every byte arrived")
}

test "openssl s_server (no ALPN): the client falls back to HTTP/1.x on the same connection" {
  val resp = fetch(trustedClient(false), opensslUrl("/index.html"))
  assertEqualInt(resp.statusCode(), 200, "status")
  assertVersion(resp, false, "s_server")
  assertEqual(bodyOf(resp), indexBody, "body")
}
