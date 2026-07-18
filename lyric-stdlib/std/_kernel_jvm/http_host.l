//! std/_kernel_jvm/http_host.l - JVM host boundary for HTTP client.
//!
//! Mirrors _kernel/http_host.l for the JVM target: the same public
//! surface (client construction, request building, the ten `*Safe`
//! wrappers, status/header/body accessors) over `java.net.http.HttpClient`
//! via the JVM auto-FFI.  The previous version routed every function
//! through phantom `lyric.stdlib.jvm.HttpClientHost` /
//! `HttpRequestBuilder` / `HttpResponseWrapper` classes that never existed
//! at runtime, which left Std.Http non-functional on this target
//! (docs/59 F-1c, docs/44 m-89).
//!
//! Representation choices:
//!
//!   - `HttpRequestMessage` is a pure-Lyric accumulation record rather
//!     than a `java.net.http.HttpRequest.Builder` alias: the JDK builder's
//!     only body-setting entry point is `method(name, publisher)`, so a
//!     later `hostWithStringBody` would need the method name back out of
//!     the builder, which the Builder interface cannot answer.  The real
//!     `HttpRequest` is built once, inside the send path.
//!   - `HttpResponseMessage` buffers status/headers/body eagerly at send
//!     time (`BodyHandlers.ofInputStream` + `readAllBytes`) — the same
//!     fully-buffered semantics as the .NET twin's default
//!     `HttpCompletionOption.ResponseContentRead`.  `ofInputStream` rather
//!     than `ofByteArray` because `HttpResponse.body()` is an erased
//!     generic (`()Ljava/lang/Object;`): a class-typed binding checkcast
//!     (`JInputStream`) is auto-FFI-expressible where an array checkcast
//!     (`[B`) is not.
//!
//! The JDK's synchronous `send(HttpRequest, BodyHandler)` blocks the
//! calling virtual thread (JEP 444); the JVM scheduler parks the carrier
//! thread on I/O without blocking the OS thread, so the `async` surface
//! below lowers to plain synchronous calls, as everywhere on this target.
//!
//! Cancellation is cooperative on this target: the JDK's synchronous
//! `send` accepts no cancellation token, so the `*WithCancel*` family
//! (a) polls the token before sending and before body reads, and (b) maps
//! a `makeCancelSourceTimeout` deadline onto `HttpRequest.Builder.timeout`
//! (the JDK's own in-flight request deadline, surfacing as
//! `HttpTimeoutException` -> `Err` through the `*Safe` wrappers).  An
//! explicit `cancelSource` fired while a request is already in flight is
//! observed at the next poll point rather than aborting the transfer —
//! the same cooperative-cancellation contract `_kernel_jvm/task.l`
//! documents for this target.
@axiom("java.net.http.HttpClient and javax.net.ssl / java.security TLS configuration operations conform to their documented JVM contracts")
package Std.HttpHost

import Std.Core
import Std.Collections
import Std.Task
import Std.Tls
import Std.TlsHost

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
extern type HttpClientHandle = "java.net.http.HttpClient"

extern type JHttpClientBuilder = "java.net.http.HttpClient$Builder"

extern type JRedirect = "java.net.http.HttpClient$Redirect"

// HTTP-version knob (docs/61 §5.1, D128 decision 4; #5879).  JDK 21 has no
// `HTTP_3` case — the JDK's own `HttpClient.Version` enum only distinguishes
// `HTTP_1_1`/`HTTP_2` — so `Std.Http.HttpVersion.Http3` has no dotnet-style
// "pin" here at all; it is refused entirely at the `Std.Http` layer before
// any kernel call is made (see `HttpClientImpl.unsupportedReason`).
extern type JHttpVersion = "java.net.http.HttpClient$Version"

extern type JHttpRequest = "java.net.http.HttpRequest"

extern type JHttpRequestBuilder = "java.net.http.HttpRequest$Builder"

extern type JBodyPublishers = "java.net.http.HttpRequest$BodyPublishers"

extern type JBodyHandlers = "java.net.http.HttpResponse$BodyHandlers"

extern type JHttpResponse = "java.net.http.HttpResponse"

extern type JHttpHeaders = "java.net.http.HttpHeaders"

extern type JOptional = "java.util.Optional"

extern type JURI = "java.net.URI"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JDuration = "java.time.Duration"

extern type JSystem = "java.lang.System"

/// Request under construction: method/URL/headers/body accumulate in
/// pure Lyric; the JDK `HttpRequest` is built once in the send path
/// (module header).  `timeoutNanos` (0 = none) carries a
/// `*WithCancel*` deadline onto `HttpRequest.Builder.timeout`.
pub record HttpRequestMessage {
  method: String
  url: String
  headerNames: List[String]
  headerValues: List[String]
  contentType: String
  body: String
  hasBody: Bool
  timeoutNanos: Long
}

/// Response, fully buffered at send time (module header).  `version` is
/// the negotiated wire protocol (docs/61 §5.1; #5879).
pub record HttpResponseMessage {
  status: Int
  jheaders: JHttpHeaders
  bodyBytes: slice[Byte]
  version: JHttpVersion
}

// =====================================================================
// Client construction.
// =====================================================================
// `version` (docs/61 §5.1, D128 decision 4; #5879): `HttpClient` is built
// immutably on this target — unlike the .NET twin's mutable
// `DefaultRequestVersion`/`DefaultVersionPolicy` properties, there is no
// post-construction way to change it — so every construction path takes the
// desired version up front rather than patching an already-built client.
func buildClient(followRedirects: in Bool, version: in JHttpVersion): HttpClientHandle {
  val b: JHttpClientBuilder = HttpClientHandle.newBuilder()
  val withRedirect: JHttpClientBuilder = if followRedirects {
    b.followRedirects(JRedirect.NORMAL)
  } else {
    b.followRedirects(JRedirect.NEVER)
  }
  val withVersion: JHttpClientBuilder = withRedirect.version(version)
  withVersion.build()
}

// #333 parity with the .NET twin: process-wide client singleton,
// initialised once in the package `.cctor` and reused on every request.
// Redirect-following by default, matching .NET's HttpClientHandler.
// `HTTP_2` matches the JDK's own out-of-the-box default (h2-or-lower,
// falling back to HTTP/1.1) — explicit here per docs/61 §5.1 for clarity
// rather than relying on the builder's implicit default.
val processClient: HttpClientHandle = buildClient(true, JHttpVersion.HTTP_2)

pub func hostDefaultClient(): HttpClientHandle {
  processClient
}

/// Redirect-following client.  `Redirect.NORMAL` follows same-or-safer
/// scheme redirects up to the JDK's internal hop cap; the cap itself is
/// process-wide (`-Djdk.httpclient.redirects.retrylimit`), not
/// per-client, so `maxRedirects` here selects between following
/// (positive) and not following (zero or negative) rather than setting
/// an exact hop count.
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_2)
}

pub func hostClientNoRedirects(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_2)
}

// ---------------------------------------------------------------------------
// HTTP/1.1 exact-pin variants (docs/61 §5.1, D128 decision 4; #5879) —
// mirrors `_kernel/http_host.l`'s `hostClient*Http11` family so `Std.Http`'s
// `HttpClientBuilder.build()` calls the same-named function on either
// kernel.
// ---------------------------------------------------------------------------
pub func hostClientHttp11(): HttpClientHandle {
  buildClient(true, JHttpVersion.HTTP_1_1)
}

pub func hostClientWithRedirectsHttp11(maxRedirects: in Int): HttpClientHandle {
  buildClient(maxRedirects > 0, JHttpVersion.HTTP_1_1)
}

pub func hostClientNoRedirectsHttp11(): HttpClientHandle {
  buildClient(false, JHttpVersion.HTTP_1_1)
}

// ---------------------------------------------------------------------------
// Unix domain socket support: not available on this target.
// `java.net.http.HttpClient` exposes no Unix-socket transport; until the
// JDK grows one, constructing such a client fails loudly rather than
// returning a client that silently dials TCP.  Tracked with the JVM
// parity umbrella, #2663.  Unsupported regardless of HTTP version, so the
// `*Http11` variants below fail the same way as their plain counterparts.
// ---------------------------------------------------------------------------
func unixSocketUnsupported(): HttpClientHandle {
  panic(
    "Std.Http: Unix domain socket clients are not supported on the JVM target: " +
      "java.net.http.HttpClient has no Unix-socket transport (tracked in #2663)"
  )
}

pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketAndRedirectsHttp11(socketPath: in String, maxRedirects: in Int): HttpClientHandle {
  unixSocketUnsupported()
}

pub func hostClientWithUnixSocketNoRedirectsHttp11(socketPath: in String): HttpClientHandle {
  unixSocketUnsupported()
}

// ---------------------------------------------------------------------------
// TLS client configuration (docs/61 §3.2, D128; phase 1.3, #5878) — the JVM
// twin of `_kernel/http_host.l`'s `applyTlsOptions`/`hostClientWithTls`.
//
// `Std.Http.HttpClientBuilder.build()` calls `hostSupportsTlsConfig()` BEFORE
// ever attempting kernel-level TLS wiring; it now returns `true` on this
// target, so `build()` routes a TLS-configured builder into
// `hostClientWithTls` below exactly as it already does on `--target dotnet`.
//
// Trust model, and why it differs in SHAPE from the dotnet kernel even
// though the OUTCOME (docs/61 §3.2/§4's policy matrix) is identical:
// `java.net.http.HttpClient` has no per-request certificate-validation
// CALLBACK the way `HttpClientHandler.ServerCertificateCustomValidationCallback`
// does — TLS trust on this target is configured once, structurally, via a
// `KeyStore` fed to a `TrustManagerFactory`, which the JDK's own PKIX path
// builder then validates every handshake against. So instead of mirroring
// `resolveTlsValidationDecision`'s "ask the platform, then decide whether to
// fall back to a custom chain" callback shape, this kernel builds the
// KeyStore itself:
//   - **Additive** (`withCaCertificate`): a KeyStore containing the
//     configured CA PLUS every certificate the platform's own default
//     `TrustManagerFactory` reports as an accepted issuer (`systemTrustAnchors`
//     below) — a chain that validates against EITHER trust anchor set
//     validates overall, matching "ADDITIONAL trust root" (`Std.Http`'s
//     `withCaCertificate` doc comment).
//   - **Exclusive** (`withExclusiveCaCertificate`): a KeyStore containing
//     ONLY the configured CA — the platform trust store is never consulted,
//     matching "REPLACES the platform trust store entirely".
//   - **Neither configured** (client identity and/or minTlsVersion only):
//     a `TrustManagerFactory` initialised with a `null` KeyStore, the
//     documented JDK idiom for "use the platform default" — identical
//     behaviour to an unconfigured client.
// `resolveCaMode` (below) still picks between these three exactly as it
// does on dotnet — the exclusive-wins precedence rule (#5975) is
// target-neutral pure logic and is reused, not re-derived.
//
// Hostname verification — the load-bearing security property #5950 fixed on
// dotnet — is NEVER at risk of the same regression here, for a structural
// reason rather than a callback discipline: `java.net.http.HttpClient`
// performs its own endpoint-identification check independently of whatever
// `SSLContext`/`SSLParameters` the caller supplies, and does so
// UNCONDITIONALLY — verified empirically (see `buildClientSslParameters`'s
// doc comment below): even installing a custom, all-trusting
// `X509TrustManager` and explicitly clearing
// `SSLParameters.setEndpointIdentificationAlgorithm` could not make this
// target accept a certificate issued for the wrong hostname. There is
// consequently no "callback that forgot to check hostname" bug class
// possible on this target at all — chain trust (KeyStore-driven) and
// hostname matching (enforced by the JDK's `HttpClient` implementation
// itself, never by kernel code) are two independent, non-overridable
// checks. `setEndpointIdentificationAlgorithm("HTTPS")` is still set
// explicitly on every non-insecure path below anyway, matching the
// defence-in-depth posture #5878 was asked to preserve, even though this
// target's own enforcement does not depend on it.
//
// `TlsCaMode`/`resolveCaMode`/`TlsValidationDecision`/`resolveTlsValidationDecision`
// remain declared (mirrored verbatim from the dotnet twin, as before) so
// `http_tls_client_tests.l`'s exhaustive #5950/#5975 regression coverage
// keeps running identically on both targets — target-neutral pure logic,
// no BCL dependency. `resolveCaMode` IS now genuinely consumed by
// `buildClientSslContext` below; `resolveTlsValidationDecision`/
// `TlsValidationDecision` are not — this target's real trust decision is
// the JDK's own PKIX path validator over the KeyStore built above, not a
// hand-rolled decision core, so there is nothing here for that callback
// shape to drive. It stays for cross-target parity of the tested pure
// function, not because a caller invokes it.
// ---------------------------------------------------------------------------
pub func hostSupportsTlsConfig(): Bool {
  true
}

pub enum TlsCaMode {
  case NoCaConfigured
  case AdditiveCa
  case ExclusiveCa
}

// Precedence rule when both `withCaCertificate` and
// `withExclusiveCaCertificate` are configured on the same builder
// (#5975) — mirrored verbatim from the dotnet twin; see that file's doc
// comment for the full rationale. Exclusive always wins. Genuinely
// consumed by `buildClientSslContext` below (module header).
@pure
pub func resolveCaMode(caCertificate: in Option[Certificate], exclusiveCaCertificate: in Option[Certificate]): TlsCaMode {
  match exclusiveCaCertificate {
    case Some(_) -> ExclusiveCa
    case None -> match caCertificate {
      case Some(_) -> AdditiveCa
      case None -> NoCaConfigured
    }
  }
}

pub enum TlsValidationDecision {
  case RejectImmediately
  case AcceptWithoutCustomChain
  case TryCustomChain
}

// Kept for cross-target #5950 regression parity in `http_tls_client_tests.l`
// (module header) — not called by this target's real wiring.
@pure
pub func resolveTlsValidationDecision(
  hostnameAndAvailabilityOk: in Bool, chainAlreadyOk: in Bool, caMode: in TlsCaMode
): TlsValidationDecision {
  if not hostnameAndAvailabilityOk {
    RejectImmediately
  } else {
    match caMode {
      case ExclusiveCa -> TryCustomChain
      case AdditiveCa ->
        if chainAlreadyOk {
          AcceptWithoutCustomChain
        } else {
          TryCustomChain
        }
      case NoCaConfigured ->
        if chainAlreadyOk {
          AcceptWithoutCustomChain
        } else {
          RejectImmediately
        }
    }
  }
}

// ---------------------------------------------------------------------------
// Reflection bridge (module header above; mirrored self-contained per this
// directory's per-file convention rather than shared with
// `_kernel_jvm/http_server.l`'s in-flight server-TLS counterpart).
//
// The JVM auto-FFI (`jvm/auto_ffi.l`) cannot construct or pass a
// reference-typed Java array (`Certificate[]`, `TrustManager[]`, `String[]`,
// `Class[]`) as a call ARGUMENT — a Lyric `slice[T]` for reference `T`
// always erases to `Object[]` at the call site, which the JDK rejects for
// any more specifically-typed array parameter (verified empirically against
// `KeyStore.setCertificateEntry`'s sibling `setKeyEntry`, `SSLContext.init`,
// `SSLParameters.setProtocols`, and `Proxy.newProxyInstance` — each throws
// "no matching...method" at COMPILE time, not just runtime). RETURNING an
// array from a call (`tmf.getTrustManagers()`, `kmf.getKeyManagers()`) is
// unaffected — only the argument direction is broken. `java.lang.reflect`
// sidesteps this: `Array.newInstance`/`Array.set` build a genuinely-typed
// array one element at a time (each call takes a single object or a class +
// int, never an array, so it scores fine), and `Method.invoke(Object,
// Object...)`'s varargs parameter erases to `Object[]` too — an exact match
// for a Lyric `slice[JObject]` argument, so relaying an already-built array
// through it needs no coercion at all. The same `Array.newInstance` +
// `Array.get` trick produces a genuine `null` reference of any class,
// standing in for Lyric's lack of a null literal (#4775) where the JDK API
// expects one (`KeyStore.load(null, password)` is the documented way to
// initialize an empty keystore; `TrustManagerFactory.init((KeyStore) null)`
// is the documented way to ask for the platform default trust store). A
// `null` reference carries no runtime type tag, so which class name
// `nullOfClass` is asked to build the (immediately-discarded) 1-element
// array from does not affect the `null` value it returns — `"java.lang.Object"`
// is used uniformly below for readability.
//
// A checkcast-on-assignment idiom appears throughout the code below
// (`val x: SpecificType = someReflectiveOrEraseGenericCall()`), matching the
// existing `val ex: HttpContext = l.queue.take()` idiom this file's own
// module header already documents for `JInputStream`/`HttpContext`: binding
// an `Object`-erased call result (a raw `Method.invoke`/`Array.get` return,
// or a JDK method whose declared return is a generic/erased type) directly
// to a more specific extern-typed `val` inserts the checkcast — this only
// works at a genuine call-expression assignment site, not through an
// intermediate `JObject`-typed local or a plain Lyric helper function
// (verified empirically; the type checker correctly rejects the latter as a
// real type mismatch, T0060).
// ---------------------------------------------------------------------------
extern type JObject = "java.lang.Object"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JReflectArray = "java.lang.reflect.Array"

extern type JInvocationHandler = "java.lang.reflect.InvocationHandler"

extern type JClassLoader = "java.lang.ClassLoader"

extern type JCharacterCls = "java.lang.Character"

extern type JKeyStore = "java.security.KeyStore"

extern type JTrustManagerFactory = "javax.net.ssl.TrustManagerFactory"

extern type JKeyManagerFactory = "javax.net.ssl.KeyManagerFactory"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSSLParameters = "javax.net.ssl.SSLParameters"

extern type JTrustManager = "javax.net.ssl.TrustManager"

extern type JSecureRandom = "java.security.SecureRandom"

extern type JCertificate = "java.security.cert.Certificate"

extern type JPrivateKey = "java.security.PrivateKey"

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
    case None -> panic("Std.HttpHost: reflective method lookup failed for " + name + "/" + arity.toString())
  }
}

// `TrustManagerFactory.init` has TWO one-argument overloads
// (`init(KeyStore)` / `init(ManagerFactoryParameters)`); arity alone does
// not disambiguate them, so this variant also matches the first
// parameter's declared type name.
func findMethodByNameArityAndParamType(cls: in JClass, name: in String, arity: in Int, paramClassName: in String): JMethod {
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  var found: Option[JMethod] = None
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      val ptypes: slice[JClass] = m.getParameterTypes()
      if ptypes[0].getName() == paramClassName {
        found = Some(value = m)
      }
    }
    i = i + 1
  }
  match found {
    case Some(m) -> m
    case None -> panic("Std.HttpHost: reflective method lookup failed for " + name + " with param type " + paramClassName)
  }
}

// A genuine `null` reference (module header) — the class name only shapes
// the scratch array `Array.newInstance` builds to extract it from.
func nullOfClass(className: in String): JObject {
  val c: JClass = JClass.forName(className)
  val arr: JObject = JReflectArray.newInstance(c, 1)
  JReflectArray.get(arr, 0)
}

// An empty `char[]` (boxed as Object), the "no password" argument to
// KeyStore/factory calls below.
func emptyCharArrayObj(): JObject {
  val charClass: JClass = JCharacterCls.TYPE
  JReflectArray.newInstance(charClass, 0)
}

// A genuinely-typed 1-element array of `elemClassName` holding `v`.
func makeTypedArray1[T](elemClassName: in String, v: in T): JObject {
  val elemClass: JClass = JClass.forName(elemClassName)
  val arr: JObject = JReflectArray.newInstance(elemClass, 1)
  JReflectArray.set(arr, 0, v)
  arr
}

// A genuinely-typed `String[]` holding every element of `values`, in order.
func makeStringArray(values: in List[String]): JObject {
  val elemClass: JClass = JClass.forName("java.lang.String")
  val arr: JObject = JReflectArray.newInstance(elemClass, values.count)
  var i = 0
  while i < values.count {
    JReflectArray.set(arr, i, values[i])
    i = i + 1
  }
  arr
}

func invoke1[A, B](target: in A, methodName: in String, arg0: in B): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 1)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  m.invoke(target, argsList.toArray())
}

func invoke1Typed[A, B](target: in A, methodName: in String, paramClassName: in String, arg0: in B): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameArityAndParamType(cls, methodName, 1, paramClassName)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  m.invoke(target, argsList.toArray())
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

func invoke4[A, B, C, D, E](target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D, arg3: in E): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 4)
  val argsList: List[JObject] = newList()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  argsList.add(arg3)
  m.invoke(target, argsList.toArray())
}

// Looks up a zero-argument method on a PUBLIC interface/superclass rather
// than `target.getClass()` — reflection's accessibility check is keyed on
// the `Method` object's DECLARING class, and the JDK's real
// `X509TrustManager` implementation backing `TrustManagerFactory` lives in
// a non-exported `sun.security.ssl` class (`getMethods()` on the concrete
// instance's own class throws `IllegalAccessException` at invoke time,
// verified empirically). Looking the method up through the PUBLIC
// `javax.net.ssl.X509TrustManager` interface's own `Method` object instead
// bypasses that module-encapsulation failure with no `--add-opens` JVM
// flag required — a documented, supported reflection idiom for calling
// public-interface methods on non-exported implementation classes.
func invokeInterfaceMethod0[A](target: in A, interfaceClassName: in String, methodName: in String): JObject {
  val ifaceClass: JClass = JClass.forName(interfaceClassName)
  val m = findMethodByNameAndArity(ifaceClass, methodName, 0)
  val emptyArgs: List[JObject] = newList()
  m.invoke(target, emptyArgs.toArray())
}

// ---------------------------------------------------------------------------
// KeyStore / TrustManagerFactory / KeyManagerFactory construction (module
// header: "additive" and "exclusive" CA trust as merged/replaced KeyStores).
// ---------------------------------------------------------------------------
func newEmptyPkcs12KeyStore(): JKeyStore {
  val ks: JKeyStore = JKeyStore.getInstance("PKCS12")
  val _load = invoke2(ks, "load", nullOfClass("java.io.InputStream"), emptyCharArrayObj())
  ks
}

func defaultTrustManagerFactory(): JTrustManagerFactory {
  val algo: String = JTrustManagerFactory.getDefaultAlgorithm()
  val tmf: JTrustManagerFactory = JTrustManagerFactory.getInstance(algo)
  val _init = invoke1Typed(tmf, "init", "java.security.KeyStore", nullOfClass("java.security.KeyStore"))
  tmf
}

// Every certificate the PLATFORM's own default trust manager accepts as an
// issuer — read via `defaultTrustManagerFactory` (which itself asks the JDK
// for its documented default trust store, honouring
// `javax.net.ssl.trustStore`/`trustStorePassword` when set) plus
// `invokeInterfaceMethod0` to call `getAcceptedIssuers()` on the (possibly
// module-hidden) implementation it returns.
func systemTrustAnchors(): slice[JCertificate] {
  val tmf = defaultTrustManagerFactory()
  val managers: slice[JTrustManager] = tmf.getTrustManagers()
  val issuersObj: JObject = invokeInterfaceMethod0(managers[0], "javax.net.ssl.X509TrustManager", "getAcceptedIssuers")
  val count = JReflectArray.getLength(issuersObj)
  val result: List[JCertificate] = newList()
  var i = 0
  while i < count {
    val c: JCertificate = JReflectArray.get(issuersObj, i)
    result.add(c)
    i = i + 1
  }
  result.toArray()
}

// ADDITIVE trust (`withCaCertificate`): `extraCa` plus every platform trust
// anchor — a chain valid against either set is accepted.
func buildAdditiveTrustKeyStore(extraCa: in JCertificate): JKeyStore {
  val ks = newEmptyPkcs12KeyStore()
  ks.setCertificateEntry("lyric-extra-ca", extraCa)
  val anchors = systemTrustAnchors()
  var i = 0
  while i < anchors.length {
    ks.setCertificateEntry("lyric-system-ca-" + i.toString(), anchors[i])
    i = i + 1
  }
  ks
}

// EXCLUSIVE trust (`withExclusiveCaCertificate`): ONLY `onlyCa` — the
// platform trust store is never consulted.
func buildExclusiveTrustKeyStore(onlyCa: in JCertificate): JKeyStore {
  val ks = newEmptyPkcs12KeyStore()
  ks.setCertificateEntry("lyric-exclusive-ca", onlyCa)
  ks
}

func trustManagerFactoryFor(ks: in JKeyStore): JTrustManagerFactory {
  val algo: String = JTrustManagerFactory.getDefaultAlgorithm()
  val tmf: JTrustManagerFactory = JTrustManagerFactory.getInstance(algo)
  val _init = invoke1Typed(tmf, "init", "java.security.KeyStore", ks)
  tmf
}

// Client identity (`withClientIdentity`, mTLS): a KeyStore holding
// `identity`'s certificate + private key under a fixed alias, the standard
// JDK way to feed a `KeyManagerFactory`. Mirrors the equivalent
// server-identity construction the phase-2 (#5880) JVM server-TLS kernel
// builds for `HttpsServer`, duplicated rather than shared per this
// directory's self-contained-per-file convention.
func buildClientIdentityKeyStore(identity: in Identity): JKeyStore {
  val handle = Identity.rawHandle(identity)
  val cert: JCertificate = handle.cert
  val privateKey: JPrivateKey = match handle.key {
    case Some(k) -> k
    case None -> panic("Std.HttpHost: client Identity has no private key (invariant violation)")
  }
  val ks = newEmptyPkcs12KeyStore()
  val certChainArr = makeTypedArray1("java.security.cert.Certificate", cert)
  val _setKey = invoke4(ks, "setKeyEntry", "lyric-client", privateKey, emptyCharArrayObj(), certChainArr)
  ks
}

func clientKeyManagerFactory(identity: in Identity): JKeyManagerFactory {
  val ks = buildClientIdentityKeyStore(identity)
  val algo: String = JKeyManagerFactory.getDefaultAlgorithm()
  val kmf: JKeyManagerFactory = JKeyManagerFactory.getInstance(algo)
  val _init = invoke2(kmf, "init", ks, emptyCharArrayObj())
  kmf
}

// ---------------------------------------------------------------------------
// Insecure all-trusting `X509TrustManager` (`withInsecureSkipVerify`, both
// keys of the dual-key policy set — docs/61 §4). Implementing
// `X509TrustManager` directly via `impl JX509TrustManager for Record` is
// NOT FFI-expressible on this target: every one of its methods
// (`checkClientTrusted`/`checkServerTrusted` take `X509Certificate[]`;
// `getAcceptedIssuers` returns one) hits the same reference-array-argument
// erasure gap `jvm/auto_ffi.l` has for any `impl <ExternInterface> for
// Record` method whose signature mentions a `slice[ExternType]` — verified
// empirically: calling such a method through the interface fails to
// compile with "no matching instance or inherited method" because the
// auto-FFI always encodes the parameter as `[Ljava/lang/Object;`, never the
// real `[Ljava/security/cert/X509Certificate;` descriptor (the same defect
// class #5931 documents against the phase-2 JVM server-TLS kernel's
// `X509KeyManager` attempt).
//
// `java.lang.reflect.Proxy` sidesteps this cleanly: `Proxy.newProxyInstance`
// builds a REAL `X509TrustManager` at runtime backed by a Lyric
// `InvocationHandler` — and `InvocationHandler.invoke(Object, Method,
// Object[])`'s only array parameter is genuinely `Object[]`, an EXACT match
// for a Lyric `slice[JObject]` argument, so `impl JInvocationHandler for
// Record` needs none of the reflection workarounds above and compiles
// through ordinary auto-FFI. Verified end-to-end against a real self-signed
// TLS peer (accepts) and a real wrong-hostname peer (still rejects — see
// `buildClientSslParameters`'s doc comment: hostname verification is
// enforced independently of trust-manager configuration on this target, so
// this all-trusting manager only ever disables CHAIN verification).
// ---------------------------------------------------------------------------
record AllTrustingHandler {
  marker: Bool
}

impl JInvocationHandler for AllTrustingHandler {
  func invoke(proxy: in JObject, method: in JMethod, args: in slice[JObject]): JObject {
    val name: String = method.getName()
    if name == "getAcceptedIssuers" {
      val cls: JClass = JClass.forName("java.security.cert.X509Certificate")
      val empty: JObject = JReflectArray.newInstance(cls, 0)
      empty
    } else {
      // checkClientTrusted / checkServerTrusted: returning normally (no
      // thrown CertificateException) is exactly "trusted, no questions
      // asked" — the documented all-trusting shape.
      proxy
    }
  }
}

func buildAllTrustingTrustManager(): JTrustManager {
  val cl: JClassLoader = JClassLoader.getSystemClassLoader()
  val tmClass: JClass = JClass.forName("javax.net.ssl.X509TrustManager")
  val ifacesArr = makeTypedArray1("java.lang.Class", tmClass)
  val handler: AllTrustingHandler = AllTrustingHandler(marker = true)
  val asHandler: JInvocationHandler = handler
  val proxyClass: JClass = JClass.forName("java.lang.reflect.Proxy")
  val m = findMethodByNameAndArity(proxyClass, "newProxyInstance", 3)
  val argsList: List[JObject] = newList()
  argsList.add(cl)
  argsList.add(ifacesArr)
  argsList.add(asHandler)
  val tm: JTrustManager = m.invoke(nullOfClass("java.lang.Object"), argsList.toArray())
  tm
}

// ---------------------------------------------------------------------------
// SSLContext / SSLParameters assembly.
// ---------------------------------------------------------------------------
func buildClientSslContext(
  caCertificate: in Option[Certificate],
  exclusiveCaCertificate: in Option[Certificate],
  clientIdentity: in Option[Identity],
  insecureSkipVerify: in Bool,
): JSSLContext {
  val trustManagersObj: JObject = if insecureSkipVerify {
    makeTypedArray1("javax.net.ssl.TrustManager", buildAllTrustingTrustManager())
  } else {
    val tmf = match resolveCaMode(caCertificate, exclusiveCaCertificate) {
      case ExclusiveCa -> match exclusiveCaCertificate {
        case Some(cert) -> trustManagerFactoryFor(buildExclusiveTrustKeyStore(Certificate.rawHandle(cert).cert))
        case None -> defaultTrustManagerFactory()
      }
      case AdditiveCa -> match caCertificate {
        case Some(cert) -> trustManagerFactoryFor(buildAdditiveTrustKeyStore(Certificate.rawHandle(cert).cert))
        case None -> defaultTrustManagerFactory()
      }
      case NoCaConfigured -> defaultTrustManagerFactory()
    }
    val tmObj: JObject = tmf.getTrustManagers()
    tmObj
  }
  val keyManagersObj: JObject = match clientIdentity {
    case Some(identity) -> {
      val kmObj: JObject = clientKeyManagerFactory(identity).getKeyManagers()
      kmObj
    }
    case None -> nullOfClass("java.lang.Object")
  }
  val ctx: JSSLContext = JSSLContext.getInstance("TLS")
  val random: JSecureRandom = JSecureRandom.new()
  val _init = invoke3(ctx, "init", keyManagersObj, trustManagersObj, random)
  ctx
}

// `SSLParameters.setProtocols` (docs/61 §3.2, `withMinTlsVersion`):
// `Tls13` pins to TLS 1.3 exactly; `Tls12` (and the unset default) floors
// at TLS 1.2 while still allowing negotiation up to 1.3, matching the
// dotnet twin's "leave the platform's TLS-1.2-or-newer default alone"
// floor semantics.
//
// Endpoint identification (docs/61 §4's dual-key insecure policy; the
// #5950-class security property): explicitly set to `"HTTPS"` on every
// non-insecure path, matching the defence-in-depth intent #5878 was asked
// to preserve. On the insecure path it is cleared to `""` (the SSLParameters
// javadoc's documented equivalent of `null`) — but empirically, on THIS
// target, clearing it has no observable effect: `java.net.http.HttpClient`
// enforces its own hostname check unconditionally regardless of the
// supplied `SSLParameters`/`SSLContext` (verified directly: an all-trusting
// custom `TrustManager` combined with an explicitly-cleared endpoint
// identification algorithm still rejected a real wrong-hostname certificate
// with "No subject alternative DNS name matching ... found"). So
// `withInsecureSkipVerify()` on `--target jvm` disables CHAIN verification
// only — hostname matching cannot be disabled through any public API on
// this target, which is STRICTER than docs/61 §4's baseline requirement
// ("disables peer chain verification and hostname matching together"), not
// a gap: there is no way to construct the unsafe combination this target's
// design explicitly warns against.
func buildClientSslParameters(ctx: in JSSLContext, minVersion: in Option[TlsVersion], insecureSkipVerify: in Bool): JSSLParameters {
  val params: JSSLParameters = ctx.getDefaultSSLParameters()
  val protocolValues: List[String] = newList()
  match minVersion {
    case Some(v) -> match v {
      case Tls13 -> protocolValues.add("TLSv1.3")
      case Tls12 -> {
        protocolValues.add("TLSv1.2")
        protocolValues.add("TLSv1.3")
      }
    }
    case None -> {
      protocolValues.add("TLSv1.2")
      protocolValues.add("TLSv1.3")
    }
  }
  val protocolsArr = makeStringArray(protocolValues)
  val _setProtocols = invoke1(params, "setProtocols", protocolsArr)
  if insecureSkipVerify {
    params.setEndpointIdentificationAlgorithm("")
  } else {
    params.setEndpointIdentificationAlgorithm("HTTPS")
  }
  params
}

// The single entry point for every TLS-configured client — mirrors
// `_kernel/http_host.l`'s `hostClientWithTls` signature exactly (`Std.Http`
// calls whichever kernel's copy the active `--target` resolves to). Redirect
// handling mirrors the existing non-TLS `hostClient*`/`hostClientWithRedirects`
// family: `noRedirects` wins outright, otherwise a positive `maxRedirects`
// follows redirects (the hop CAP itself is process-wide on this target —
// module header on `hostClientWithRedirects` above — not configurable
// per-client), and no explicit redirect configuration defaults to following,
// matching `hostDefaultClient`.
pub func hostClientWithTls(
  maxRedirects: in Option[Int],
  noRedirects: in Bool,
  pinHttp11: in Bool,
  caCertificate: in Option[Certificate],
  exclusiveCaCertificate: in Option[Certificate],
  clientIdentity: in Option[Identity],
  minTlsVersion: in Option[TlsVersion],
  insecureSkipVerify: in Bool,
): HttpClientHandle {
  val ctx = buildClientSslContext(caCertificate, exclusiveCaCertificate, clientIdentity, insecureSkipVerify)
  val params = buildClientSslParameters(ctx, minTlsVersion, insecureSkipVerify)
  val followRedirects = if noRedirects {
    false
  } else {
    match maxRedirects {
      case Some(n) -> n > 0
      case None -> true
    }
  }
  val version: JHttpVersion = if pinHttp11 {
    JHttpVersion.HTTP_1_1
  } else {
    JHttpVersion.HTTP_2
  }
  val b: JHttpClientBuilder = HttpClientHandle.newBuilder()
  val withRedirect: JHttpClientBuilder = if followRedirects {
    b.followRedirects(JRedirect.NORMAL)
  } else {
    b.followRedirects(JRedirect.NEVER)
  }
  val withVersion: JHttpClientBuilder = withRedirect.version(version)
  val withCtx: JHttpClientBuilder = withVersion.sslContext(ctx)
  val withParams: JHttpClientBuilder = withCtx.sslParameters(params)
  withParams.build()
}

// =====================================================================
// Request construction.
// =====================================================================
pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  val names: List[String] = newList()
  val values: List[String] = newList()
  HttpRequestMessage(
    method = httpMethod,
    url = url,
    headerNames = names,
    headerValues = values,
    contentType = "",
    body = "",
    hasBody = false,
    timeoutNanos = 0i64
  )
}

pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage {
  request.headerNames.add(key)
  request.headerValues.add(value)
  request
}

pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = contentType,
    body = body,
    hasBody = true,
    timeoutNanos = request.timeoutNanos
  )
}

func withTimeoutNanos(request: in HttpRequestMessage, nanos: in Long): HttpRequestMessage {
  HttpRequestMessage(
    method = request.method,
    url = request.url,
    headerNames = request.headerNames,
    headerValues = request.headerValues,
    contentType = request.contentType,
    body = request.body,
    hasBody = request.hasBody,
    timeoutNanos = nanos
  )
}

// =====================================================================
// Send path (internal).
// =====================================================================
func buildJavaRequest(request: in HttpRequestMessage): JHttpRequest {
  var b: JHttpRequestBuilder = JHttpRequest.newBuilder()
  b = b.uri(JURI.create(request.url))
  var i = 0
  while i < request.headerNames.count {
    val name: String = request.headerNames[i]
    val value: String = request.headerValues[i]
    b = b.header(name, value)
    i = i + 1
  }
  if request.timeoutNanos > 0i64 {
    b = b.timeout(JDuration.ofNanos(request.timeoutNanos))
  }
  if request.hasBody {
    b = b.header("Content-Type", request.contentType)
    b = b.method(request.method, JBodyPublishers.ofString(request.body))
  } else {
    b = b.method(request.method, JBodyPublishers.noBody())
  }
  b.build()
}

// Close on the failure path too, so a transfer aborted mid-body does not
// leak the connection's stream until GC (the _kernel_jvm/file_host.l
// hostReadAllBytes idiom, #4780).
func readAllAndClose(ins: in JInputStream): slice[Byte] {
  try {
    val bytes = ins.readAllBytes()
    ins.close()
    bytes
  } catch Bug as b {
    ins.close()
    panic(b.message)
  }
}

func doSend(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage {
  val jreq = buildJavaRequest(request)
  val resp: JHttpResponse = client.send(jreq, JBodyHandlers.ofInputStream())
  val ins: JInputStream = resp.body()
  val bytes = readAllAndClose(ins)
  HttpResponseMessage(status = resp.statusCode(), jheaders = resp.headers(), bodyBytes = bytes, version = resp.version())
}

// Apply a `makeCancelSourceTimeout` deadline as the JDK request timeout
// (module header).  A poll-race where the deadline elapses between the
// caller's `throwIfCancelled` and here still panics the same way the
// poll would, rather than handing `Duration.ofNanos` a non-positive value.
func withCancelDeadline(request: in HttpRequestMessage, token: in CancellationToken): HttpRequestMessage {
  if token.deadlineMs > 0i64 {
    val remaining = token.deadlineMs - JSystem.nanoTime()
    if remaining <= 0i64 {
      panic("OperationCanceledException: cancellation was requested")
    }
    withTimeoutNanos(request, remaining)
  } else {
    request
  }
}

func doGet(client: in HttpClientHandle, url: in String): HttpResponseMessage {
  doSend(client, hostMakeRequest("GET", url))
}

func doPostString(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): HttpResponseMessage {
  doSend(client, hostWithStringBody(hostMakeRequest("POST", url), contentType, body))
}

// =====================================================================
// Response accessors.
// =====================================================================
pub func hostStatusCode(response: in HttpResponseMessage): Int {
  response.status
}

/// `negotiatedVersion` (docs/61 §5.1; #5879): maps the JDK's
/// `HttpClient.Version` enum to the major-version int `Std.Http` matches
/// against `HttpVersion` (mirrors `_kernel/http_host.l`'s
/// `hostResponseVersionMajor`). JDK 21's enum has exactly two cases
/// (`HTTP_1_1`/`HTTP_2` — no `HTTP_3`), so anything that isn't `HTTP_2`
/// is `HTTP_1_1`.
pub func hostResponseVersionMajor(response: in HttpResponseMessage): Int {
  if response.version.equals(JHttpVersion.HTTP_2) {
    2
  } else {
    1
  }
}

/// First value of the named response header, or `""` if absent.
/// `java.net.http.HttpHeaders` is case-insensitive and carries content
/// headers in the same map, matching the .NET twin's two-collection
/// fallthrough.
pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String {
  val opt: JOptional = response.jheaders.firstValue(name)
  val value: String = opt.orElse("")
  value
}

func readBodyTextOf(response: in HttpResponseMessage): String {
  JString.new(response.bodyBytes, "UTF-8")
}

// ---------------------------------------------------------------------------
// V0012-safe wrappers — the public send/read surface, mirroring
// _kernel/http_host.l.  On JVM there is no CLR protected-region
// restriction; the try/catch here is the kernel's exception -> Result
// boundary, same division of labour as the .NET twin.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doSend(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doGet(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = doPostString(client, url, body, contentType))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = response.bodyBytes)
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle,
  request: in HttpRequestMessage,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = doSend(client, withCancelDeadline(hostMakeRequest("GET", url), token)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringWithCancelSafe(
  client: in HttpClientHandle,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): Result[HttpResponseMessage, String] {
  return try {
    throwIfCancelled(token)
    val request = hostWithStringBody(hostMakeRequest("POST", url), contentType, body)
    Ok(value = doSend(client, withCancelDeadline(request, token)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    throwIfCancelled(token)
    Ok(value = readBodyTextOf(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}
