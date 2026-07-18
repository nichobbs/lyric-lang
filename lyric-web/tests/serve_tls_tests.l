//! tests/serve_tls_tests.l — dotnet-side tests for lyric-web's TLS server
//! surface (docs/61 §6.3, phase 2.2 of epic #5874, issue #5881).
//!
//! Covers the target-neutral and dotnet pieces of `Web.serveTls` and its
//! `WebTls` config template.  The JVM end-to-end (a real Undertow HTTPS
//! listener negotiating h2, asserted via `HttpResponse.negotiatedVersion()`)
//! is exercised by `tests/jvm_server_smoke.l`'s HTTPS-H2 self-check, which
//! runs in the `compiler-self-tests-jvm` CI job — a `@test_module` cannot
//! start a blocking Undertow server and drive it with a client in one
//! process the way that `func main` smoke does.
//!
//! On dotnet `Web.serveTls` returns a typed `ServerTlsUnsupported` naming the
//! phase-3 tracking issue (#5885) — the loud tracked gap until the sans-IO
//! HTTP engine lands.  `tlsServerConfigFromWebTls` (target-neutral, backed by
//! `Std.Tls`) is exercised for both a successful load and the file-not-found
//! error path.
@test_module
package Web.ServeTlsTests

import Std.Core
import Std.Tls
import Web
import Std.Testing

val certPem = """-----BEGIN CERTIFICATE-----
MIIDNTCCAh2gAwIBAgIUb4NMb9lelfz9FhkutEWaItQgtmgwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRbHlyaWMtdGVzdC1zZXJ2ZXIwHhcNMjYwNzE4MDczMDA2
WhcNMzYwNzE1MDczMDA2WjAcMRowGAYDVQQDDBFseXJpYy10ZXN0LXNlcnZlcjCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALlQ6kMPMzH5HawqSRL83fUc
8bIbxmEnu9Mr4sUYq7QZhizddj7slYwXoOsLkU/LFbGD39uwpNrpqsAZmvTs9BBa
NAQQNxJAMOIPAxI7HULQXrb+z2FDKkwhXR3Rp9YoHjgaNpwaCuzbI2LxtnJAiVcp
AJ5moTcz5ALgZyyQ2D/Z/IvJPQZnEAF0GnVM+JG/yg+3dqN+9Blu9JaZWgK6IfG3
7pEVvmYPpdNkc+1pWCDRG26MqNezo3JviJHlyfnnGhkeJLIxt3N4eUoYwf/KA8jV
2I9zCgcQGGPljAJuKe1cWEgSaH7XZAq+5eEQumx7DaYvdNtXz4NTnVxfvGXJ6fMC
AwEAAaNvMG0wHQYDVR0OBBYEFL9/OZMVlv9mWuYIUpF4icpjcSB1MB8GA1UdIwQY
MBaAFL9/OZMVlv9mWuYIUpF4icpjcSB1MA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0R
BBMwEYcEfwAAAYIJbG9jYWxob3N0MA0GCSqGSIb3DQEBCwUAA4IBAQA/1GMpM+17
ITrUjDRYRWFMvpSNMDzrKifG2pZbwRWpjmVMQlJf3OVif/Qlvb8mPsxWArlQGRrH
OsHdwa9JUzpRoptNVQf63d8SFz4VHcMIF3h/9Iq88LjXMV1MyiObVZLLOAiiSW+j
piF0DjxFPTuCe5WB5VKUUwOtEEN9xIg5W1LNgWK0dvKwAScUiqG1qVPk9WD6IlYW
lbcCkesNrKyWmR4OYe2Cg3ZuXo6Tbd54/kfOFF5/LTRpYZVt7w2pzGX23y4/grrd
glYQptAz1EEgWcpiSkgIVZEBjIntcMrlPE6XDiRDkZovezHMBno47l0w3CgcYXSK
9pV5q75Q4+gt
-----END CERTIFICATE-----"""

val keyPem = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC5UOpDDzMx+R2s
KkkS/N31HPGyG8ZhJ7vTK+LFGKu0GYYs3XY+7JWMF6DrC5FPyxWxg9/bsKTa6arA
GZr07PQQWjQEEDcSQDDiDwMSOx1C0F62/s9hQypMIV0d0afWKB44GjacGgrs2yNi
8bZyQIlXKQCeZqE3M+QC4GcskNg/2fyLyT0GZxABdBp1TPiRv8oPt3ajfvQZbvSW
mVoCuiHxt+6RFb5mD6XTZHPtaVgg0RtujKjXs6Nyb4iR5cn55xoZHiSyMbdzeHlK
GMH/ygPI1diPcwoHEBhj5YwCbintXFhIEmh+12QKvuXhELpsew2mL3TbV8+DU51c
X7xlyenzAgMBAAECggEAB3+6uxP2YmNOTBU598a7xJtzPF3bXTsaYqU3+/nPmO4f
e9lKW6l/M7gRDvHc43m4WwKXIHC5exJRkox2tMqR5ceAq1lsoRRv5fXtjeNOf9Gm
w4j0I19warw+5GIDhKsC7gpBg3eaUZNcjzhwxZbO9/P0znQgufcjluo1wpvp5EuA
Q+oQBGjIEpaeMeYE7E/iZbddWHh5g4ESa31CMmDMjWkEEnZC4SaSLs/kKAQ+P36N
JgEpqoxhsOnoSEtsU8r3oPbC1+mBZXWNF+DJFvN/h9V0rVnnPjoPFpmyrGUNFeRB
rOUkzoIEVyqbPGjmUzsxs23Eg82sBo77sYEy7aTroQKBgQDjQQO7jSNgOqzk0/5V
GAU/uZF5je3zk+dlwD00BKhHNdm1P+F1O82m/x4BPgYwo933ZmwCjLS5q2ybkI2P
m49sfSx8UZCQuUMUiCX989UKDp1UBqzw0WquF9Uyse1g457go7VOly3FoGGO4iWY
RM5u61vu3o1OdLDVdhszl0XThQKBgQDQwdvoVIFrflA1MbJfSu4E+CZ3HX/SMFUt
GAgyYiw2zd1O/ZOHY0OasI01TOMg8wbFYLZ/UoVC2M/Xjk7mp8YqVXBTLBU/igty
IkxAykJYx0D2jlELrsNn6q9PEr/3eZYf4Xw2gv9zDi7F6IKds7DHBQNofYuVHQSj
jogQcqIVFwKBgQCfkg1O6oHGlizE2N6jXaSB5Ilzsuc8u8QlvGC9X+/RYMyn6l0j
doSnGEg3UxgBm27Gw1JgT/Cu1uICMfRUvERvR02vVY6PMKcbiaYztb0HvM9YKv/Q
cRvZdr6rRCiMeggbcJhkwN7RABbAv6bqTpYtaHI7PmY2itWIbdAX38aWCQKBgQC3
3shO7n+/qlYDRG6TuG/FOLzIldcLzz52pYAywH2pF9IhzP+wdCILkg4OMFatouEH
4JNdudVed5E5j0K3rnbAuthgqadde71xHfyD5KJjh70UbW29GIVMdk1LHHyxAQrV
scmySdeuA4P3FUBWnvrJkQTbeBkFkbWQSe5WbmGMqQKBgBkqMpYI7ee8fxtyZk9S
3K4yzZ3/tw97kXSwTbFm61LXWm1BhOCBawKZ5Cz3uUdLHFgZHxlp40DmooELd8pt
hYdhFWFd5WL7G9O4auVFYU6cSdrQ57iEjyhk9iT/xuPgFC5YIMiJY7pBvyBOBcU1
4A8NKn86cmQezL3EpOkMqP2Q
-----END PRIVATE KEY-----"""

func fixtureConfig(): Std.Tls.TlsServerConfig {
  match Identity.fromPem(certPem, keyPem) {
    case Ok(id) -> TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = false)
    case Err(e) -> panic("fixture identity load failed: " + TlsError.message(e))
  }
}

test "serveTls returns a typed ServerTlsUnsupported on dotnet naming phase 3" {
  val router = Web.create()
  match Web.serveTls(router, "127.0.0.1", 8443, fixtureConfig()) {
    case Ok(_) -> panic("expected Err(ServerTlsUnsupported) on --target dotnet")
    case Err(e) -> match e {
      case ServerTlsUnsupported(msg) -> {
        assertTrue(msg.contains("dotnet"), "message names the dotnet target")
        assertTrue(msg.contains("5885"), "message names the phase-3 tracking issue #5885")
      }
    }
  }
}

test "ServeTlsError.message returns the carried message" {
  val e = ServerTlsUnsupported(message = "some reason")
  assertEqual(ServeTlsError.message(e), "some reason", "message accessor")
}

test "WebTls carries required + defaulted fields" {
  val cfg = WebTls(certPath = "/etc/tls/cert.pem", keyPath = "/etc/tls/key.pem", clientCaPath = "", requireClientCert = false)
  assertEqual(cfg.certPath, "/etc/tls/cert.pem", "certPath")
  assertEqual(cfg.keyPath, "/etc/tls/key.pem", "keyPath")
  assertEqual(cfg.clientCaPath, "", "clientCaPath default")
  assertFalse(cfg.requireClientCert, "requireClientCert default")
}

test "tlsServerConfigFromWebTls reports a missing cert file as CertFileNotFound" {
  val cfg = WebTls(
    certPath = "/nonexistent/lyric-web-tls-cert.pem",
    keyPath = "/nonexistent/lyric-web-tls-key.pem",
    clientCaPath = "",
    requireClientCert = false
  )
  match tlsServerConfigFromWebTls(cfg) {
    case Ok(_) -> panic("expected Err for a missing cert file")
    case Err(e) -> match e {
      case CertFileNotFound(_) -> assertTrue(true, "missing file surfaces as CertFileNotFound")
      case PemMalformed(_, _) -> panic("expected CertFileNotFound, got PemMalformed")
      case KeyMismatch(_, _) -> panic("expected CertFileNotFound, got KeyMismatch")
      case Unsupported(_, _) -> panic("expected CertFileNotFound, got Unsupported")
    }
  }
}
