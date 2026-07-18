//! stdlib/tests/tls_server_jvm_tests.l — Tests for
//! `Std.HttpServer.startListenerTls` (docs/61-https-tls-http-versions.md
//! §6.3, phase 2.1 of epic #5874, issue #5880).
//!
//! JVM-only: `startListenerTls` only builds a real listener on
//! `--target jvm` today (`_kernel_jvm/http_server.l`); the `--target
//! dotnet` twin is a typed `NotSupportedOnTarget` stub (issue #5884) with no
//! runtime surface to exercise, so this file is not run on that target.
//!
//! Coverage boundary: the client-side TLS surface
//! (`HttpClientBuilder`/`withCaCertificate`, #5877/#5878) has not shipped
//! yet, so `Std.Http`'s client cannot trust a custom CA and cannot be used
//! here. Per the task's documented fallback, this suite exercises the TLS
//! handshake layer directly with raw JDK classes reached through the same
//! extern surface the kernel itself uses (`javax.net.ssl.*`,
//! `java.security.*`): a real `SSLSocket`, built from a `SSLContext`
//! trusting the fixture cert as its own CA, completes a genuine handshake
//! and HTTP/1.1 request/response round trip against
//! `Std.HttpServer.startListenerTls`'s real `HttpsServer`. End-to-end
//! `Std.Http`-client-vs-server coverage arrives with #5878.
//!
//! mTLS (`requireClientCert` / `clientCa`) has no accept/reject-at-handshake
//! coverage here because it is not yet supported on this target at all:
//! `startListenerTls` rejects any mTLS request with a typed
//! `NotSupportedOnTarget` error at LISTENER CONSTRUCTION, before a handshake is
//! ever possible (blocked on issue #5930, an `HttpsConfigurator`
//! class-subclassing FFI gap — see `_kernel_jvm/http_server.l`'s module
//! header). The tests below cover that rejection instead.
//!
//! Every raw JDK reflection helper below (`nullOfClass`/`makeTypedArray1`/
//! `invoke2`/`invoke3`) mirrors the same bridge `_kernel_jvm/http_server.l`
//! uses internally to build a client-side trust store without an
//! `impl X509TrustManager for Record` (see that kernel's module header for
//! why: a real, verified JVM auto-FFI/codegen gap, not a style choice).
@test_module
package Std.HttpServer.TlsJvmTests

import Std.Core
import Std.Tls
import Std.HttpServer
import Std.Testing

extern type JCertificateFactory = "java.security.cert.CertificateFactory"

extern type JX509Certificate = "java.security.cert.X509Certificate"

extern type JByteArrayInputStream = "java.io.ByteArrayInputStream"

extern type JKeyStore = "java.security.KeyStore"

extern type JTrustManagerFactory = "javax.net.ssl.TrustManagerFactory"

extern type JTrustManager = "javax.net.ssl.TrustManager"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSecureRandom = "java.security.SecureRandom"

extern type JSSLSocketFactory = "javax.net.ssl.SSLSocketFactory"

extern type JSSLSocket = "javax.net.ssl.SSLSocket"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JString = "java.lang.String"

extern type JThread = "java.lang.Thread"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JReflectArray = "java.lang.reflect.Array"

extern type JObject = "java.lang.Object"

extern type JCharacter = "java.lang.Character"

// Self-signed RSA 2048 certificate, CN=test-rsa, valid 2026-07-16..2036-07-13.
// Same fixture as tls_tests.l; duplicated rather than shared because
// lyric-stdlib/tests/*.l suites are self-contained source, no shared
// fixture modules.
val rsaCert = """
-----BEGIN CERTIFICATE-----
MIIDBzCCAe+gAwIBAgIUDO4hKdbmesejzWOGU8z7H2gwVQQwDQYJKoZIhvcNAQEL
BQAwEzERMA8GA1UEAwwIdGVzdC1yc2EwHhcNMjYwNzE2MjEzMTUzWhcNMzYwNzEz
MjEzMTUzWjATMREwDwYDVQQDDAh0ZXN0LXJzYTCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBAMOdR2CrWmdulgLWwwPkz37aEMcm9vJENZ9J6sd9lxkltvSt
glE3EczI1m4f6IJiuUYq7//lwyaowapYCJvc2kbkUOFGDJfxe2ELkMgwops7gDGH
5lDh3CKMCVkGmtuk0FT+rIruwR+XgnDcw5ifPFEFE7vq96CVjyExh/JOyD2IOYOS
hR4oPER/6UAlTcURTZDm+LDxXA8BtiCAwj9XRaITNPsztd4X2rv7+EQUa2So06+b
OYBcCyMLO1wg6yRNVLSrDK9liy0yHoYfwfheswysgUsD2boK5wpw/tm817Sn0bk2
UtzdbHpU7Kbs5lVASsUXVbHw+NhgrpaHBs7Vb18CAwEAAaNTMFEwHQYDVR0OBBYE
FLlqJyx1wcyMlE4DrwcrLleQzmeBMB8GA1UdIwQYMBaAFLlqJyx1wcyMlE4Drwcr
LleQzmeBMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAC/yP0CP
My6At2yb5iCxuTQYE7rgZtv1wPR4/DkMEG06irJFIbOv2V00YmfX/xdnjv7980k+
BTGqdTqdZDP96kjNW/YSc103Y2BUug8DjZTaVil1Dxo3XmVLtjBzLZbvT2vhNjpz
ksKTsW6nzvDpaOxIEe+OkzRQ8/9US9BHIMNjySoLfIYipTSjoYEqt2xBzk6Nww2+
DJCeysBvs+6jNHnvWmbRP3TytQx8tL4i2cnQAbzGj3pIqWw6hyySt/nJq2bQX7AM
qxdPKRzWq4cCAx7gncwiyQsqO53BksnG8uQn/uJsT4lP0txrrwJRClypoKRV6+jq
mPcVDnIORvhyajE=
-----END CERTIFICATE-----
"""

// Matching unencrypted PKCS8 RSA private key.
val rsaKey = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDDnUdgq1pnbpYC
1sMD5M9+2hDHJvbyRDWfSerHfZcZJbb0rYJRNxHMyNZuH+iCYrlGKu//5cMmqMGq
WAib3NpG5FDhRgyX8XthC5DIMKKbO4Axh+ZQ4dwijAlZBprbpNBU/qyK7sEfl4Jw
3MOYnzxRBRO76veglY8hMYfyTsg9iDmDkoUeKDxEf+lAJU3FEU2Q5viw8VwPAbYg
gMI/V0WiEzT7M7XeF9q7+/hEFGtkqNOvmzmAXAsjCztcIOskTVS0qwyvZYstMh6G
H8H4XrMMrIFLA9m6CucKcP7ZvNe0p9G5NlLc3Wx6VOym7OZVQErFF1Wx8PjYYK6W
hwbO1W9fAgMBAAECggEAAIapPxwAc7vAbbe5yx/8sNrvdq5vYCpnQdgZV1vsdyCc
75G0AoI7opZfzgq9UvSzm09Utyd7DNSHrVMoAwlrTPqAh7XANnO4WoP0FGqIiBLM
hVnX52ikm+8KRNyVhMFaeJkbY5tSBW2PcIljtNx10zqd1TOy2iu6p2+yXIYUT5GC
sqTO7L1pimk1wD4RoLhGXSnK8oYXPCPyxWLfDNNw8HR8XhR0Xc9ZZtPap+qVOO6V
g2aVGHqHojwB9C52TS2a3xTW+H9gj6H8Iao8Zd3Wj7GDubslf6iLO/12SUF0/V42
dQ1KDg9eLOox02OP142UlVd7C5bBIYStaqoOha4k+QKBgQD8oCqkhdVoVFaqDcJ1
3aVIBrqaVYJ8RnjFr61ar2CNvh0GhA9iPYUCc86WWNSEkJ0Z9mfV4x9ROqI9Hf9F
ythB9H4zQTz9brdlOsFUJj4nCiaBV1l8u1QVlp1oWWhMawhhjcNCZmvlp4Kv6Lfr
8RfOw7C1YCyzVn3kxhU3QaWJaQKBgQDGOiqrvxply7lBvEJldDmwEgH8LzfU1+ia
Dnhq9LD+o3oxIUKSF8+Yi7EDiqR2qhqrju+OnrOIVCJptDTL+qPrvlGrkffzdh7f
kjUI6JcjFburuwFtyjZ3MgcwvmQqmoe5SbF39nukuWU7XNnamwjcecdK8xrRoMQi
wDbB19oRhwKBgBz40Wsk3iCk63t9MHwL+1STUPs6K0jNXDRvvVXVHyGiV/nTU2BU
5dguJ9ceQOEjJKFBnQ7uiTzrmIeh1RDP/pUx0PdX2ALIm8fEQT/BUwdvJpNWzTB8
21vOdibtegSpkcB+XZJT5LPlzhsWeWFZuP1BfBaQ/Q9kL/P4s54urSlhAoGAaOzt
HU/gpzV48ES4WH928a32gwhzYySOKM20C9lNvtvFmC/kzvPvnO2EWz2N5IoR5/GW
+EUk/uqZ9J3AvKAFGIn7LPfs6WAC45C+peKH7bhZSIOKNBUvU1SV3cVJvAtkAD3z
xG4h8IV6AjwZzM73l8yWIyQfdArHByX7VgvtkA0CgYEA11lPJlkOv3u/g1788zDb
EMHKJlE8t0ACUGfhHcxkvzCDJA0uiZUZNCVnkJPKaq+ITAaCnqa2eGqLqcyFOo5N
cTeg+l0KrzjQe6Q2hOojgqg7mskbY4sZGno7Pv+syl9h0aDjdxCBaX+ROQkm79IR
doONW2QlEIagNnVFFGh2abM=
-----END PRIVATE KEY-----
"""

func freshIdentity(): Identity {
  match Identity.fromPem(rsaCert, rsaKey) {
    case Ok(id) -> id
    case Err(e) -> panic("fixture identity load failed: " + TlsError.message(e))
  }
}

// ---------------------------------------------------------------------------
// Reflection bridge (mirrors _kernel_jvm/http_server.l's own helpers; see
// module header for why this exists instead of a custom X509TrustManager
// `impl`).
// ---------------------------------------------------------------------------
func findMethodByNameAndArity(cls: in JClass, name: in String, arity: in Int): JMethod {
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  var found: Option[JMethod] = None
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      found = Some(value = m)
    }
    i = i + 1
  }
  match found {
    case Some(m) -> m
    case None -> panic("reflective method lookup failed for " + name + "/" + arity.toString())
  }
}

func nullOfClass(className: in String): JObject {
  val c: JClass = JClass.forName(className)
  val arr: JObject = JReflectArray.newInstance(c, 1)
  JReflectArray.get(arr, 0)
}

func emptyCharArrayObj(): JObject {
  val charClass: JClass = JCharacter.TYPE
  JReflectArray.newInstance(charClass, 0)
}

func makeTypedArray1[T](elemClassName: in String, v: in T): JObject {
  val elemClass: JClass = JClass.forName(elemClassName)
  val arr: JObject = JReflectArray.newInstance(elemClass, 1)
  JReflectArray.set(arr, 0, v)
  arr
}

func invoke2[A, B, C](target: in A, methodName: in String, arg0: in B, arg1: in C): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 2)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  m.invoke(target, argsList.toArray())
}

func invoke3[A, B, C, D](target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 3)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  m.invoke(target, argsList.toArray())
}

// A client SSLContext trusting `rsaCert` as its own CA — the raw-JDK
// stand-in for the not-yet-shipped `HttpClientBuilder.withCaCertificate`
// (#5877/#5878; module header).
func clientTrustContext(): JSSLContext {
  val cf: JCertificateFactory = JCertificateFactory.getInstance("X.509")
  val certIn = JByteArrayInputStream.new(encodeUtf8(rsaCert))
  val caCert: JX509Certificate = cf.generateCertificate(certIn)
  val trustKs: JKeyStore = JKeyStore.getInstance("PKCS12")
  val _load = invoke2(trustKs, "load", nullOfClass("java.io.InputStream"), emptyCharArrayObj())
  trustKs.setCertificateEntry("ca", caCert)
  val tmf: JTrustManagerFactory = JTrustManagerFactory.getInstance(JTrustManagerFactory.getDefaultAlgorithm())
  tmf.init(trustKs)
  val trustManagers: slice[JTrustManager] = tmf.getTrustManagers()
  val tmArr = makeTypedArray1("javax.net.ssl.TrustManager", trustManagers[0])
  val ctx: JSSLContext = JSSLContext.getInstance("TLS")
  val random: JSecureRandom = JSecureRandom.new()
  val _init = invoke3(ctx, "init", nullOfClass("[Ljavax.net.ssl.KeyManager;"), tmArr, random)
  ctx
}

test "startListenerTls builds a real HttpsServer that starts and stops cleanly" {
  val tls = TlsServerConfig(identity = freshIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  match startListenerTls("127.0.0.1", 8501, tls) {
    case Ok(listener) -> {
      assertTrue(true, "startListenerTls succeeded")
      stopListener(listener)
    }
    case Err(_) -> panic("expected Ok for a non-mTLS TlsServerConfig")
  }
}

test "startListenerTls terminates real TLS and serves a real HTTP response" {
  val tls = TlsServerConfig(identity = freshIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 8502, tls) {
    case Ok(l) -> l
    case Err(_) -> panic("expected Ok for a non-mTLS TlsServerConfig")
  }

  val serverThread = JThread.new(
    { ->
      val ctx = nextContext(listener)
      respondText(ctx, 200, "hello-tls")
      ()
    }
  )
  serverThread.start()
  JThread.sleep(300i64)

  val clientCtx = clientTrustContext()
  val sf: JSSLSocketFactory = clientCtx.getSocketFactory()
  val sock: JSSLSocket = sf.createSocket("127.0.0.1", 8502)
  sock.startHandshake()

  val outStream: JOutputStream = sock.getOutputStream()
  val req = encodeUtf8("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  outStream.write(req)
  outStream.flush()

  sock.setSoTimeout(5000)
  val ins: JInputStream = sock.getInputStream()
  val respBytes = ins.readAllBytes()
  val respStr = JString.new(respBytes, "UTF-8")
  sock.close()
  serverThread.join()

  assertTrue(respStr.contains("HTTP/1.1 200 OK"), "TLS-terminated response carries the 200 status line")
  assertTrue(respStr.contains("hello-tls"), "TLS-terminated response carries the expected body")

  stopListener(listener)
}

test "startListenerTls rejects requireClientCert as Unsupported" {
  val tls = TlsServerConfig(identity = freshIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = true)
  match startListenerTls("127.0.0.1", 8503, tls) {
    case Ok(_) -> panic("expected Err(NotSupportedOnTarget) for requireClientCert = true")
    case Err(e) -> match e {
      case NotSupportedOnTarget(message) -> assertTrue(message.contains("mutual TLS"), "NotSupportedOnTarget names mutual TLS")
    }
  }
}

test "startListenerTls rejects a clientCa request as Unsupported" {
  val ca = match Certificate.fromPem(rsaCert) {
    case Ok(c) -> c
    case Err(e) -> panic("fixture cert load failed: " + TlsError.message(e))
  }
  val tls = TlsServerConfig(identity = freshIdentity(), minVersion = Tls12, clientCa = Some(value = ca), requireClientCert = false)
  match startListenerTls("127.0.0.1", 8504, tls) {
    case Ok(_) -> panic("expected Err(NotSupportedOnTarget) for a clientCa request")
    case Err(e) -> match e {
      case NotSupportedOnTarget(message) -> assertTrue(message.contains("mutual TLS"), "NotSupportedOnTarget names mutual TLS")
    }
  }
}
