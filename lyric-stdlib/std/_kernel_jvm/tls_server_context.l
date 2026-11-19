//! std/_kernel_jvm/tls_server_context.l - JVM server `SSLContext` construction.
//!
//! The one place on this target that turns a `Std.Tls` `Identity` (and,
//! for mutual TLS, a client-CA `Certificate`) into a `javax.net.ssl.SSLContext`
//! for a server: the `KeyManagerFactory`/`KeyStore` reflection bridge and the
//! TLS 1.2 floor check, moved here from `_kernel_jvm/http_server.l` (slice S1
//! of docs/73, D621) so that BOTH `Std.TcpHost` (the TLS accept path) and
//! `Std.HttpServer` import it. Before the move `Std.TcpHost` imported
//! `Std.HttpServer` for these helpers, which made it impossible for
//! `Std.HttpServer` to import `Std.TcpHost` (the shared driver of
//! docs/73 section 1.2) without an import cycle.
//!
//! `Std.HttpServer` re-exports the public surface (`pub use`), so
//! `serverSslContextFromConfig[Mtls]`, `ServerSslContext` and the
//! `@experimental` `rawContext` accessor are unchanged for their callers
//! (`lyric-web`'s Undertow kernel, `tls_server_jvm_tests.l`).
//!
//! Why reflection: the JVM auto-FFI cannot construct or pass a
//! reference-typed Java array (`Certificate[]`, `KeyManager[]`) as a call
//! argument - only primitive arrays get the erasure-aware coercion (a Lyric
//! `slice[T]` of references erases to `Object[]`, which the JDK rejects for a
//! `Certificate[]`-typed parameter; verified against `KeyStore.setKeyEntry`
//! and `SSLContext.init`). `java.lang.reflect` sidesteps this: `Array.newInstance`
//! and `Array.set` build a genuinely typed array one element at a time, and
//! `Method.invoke(Object, Object...)` takes an `Object[]` that a Lyric
//! `slice[JObject]` matches exactly. The same `Array.newInstance` +
//! `Array.get` trick produces a genuine `null` where the JDK API expects one
//! (`KeyStore.load(null, password)`, #4775).
//!
//! A custom `impl X509KeyManager for Record` was rejected: `impl
//! <ExternInterface>` codegen does not resolve a `slice[ExternType]`
//! parameter through the file's extern map (#5931), and the plain
//! `X509KeyManager` interface triggers `SSLContextImpl`'s legacy wrapper path
//! that fails every handshake under a modern `SSLEngine`-based server; the JDK
//! wants an `X509ExtendedKeyManager`, an abstract class `impl` cannot target
//! (#5930). `KeyManagerFactory` returns a correctly typed `KeyManager[]`
//! and never asks Lyric to implement the interface.
@axiom("java.security.KeyStore, javax.net.ssl.KeyManagerFactory, TrustManagerFactory and SSLContext, and java.lang.reflect operations conform to their documented JVM contracts")
@io
package Std.TlsServerContext

import Std.Core
import Std.Collections
import Std.Tls
import Std.TlsHost

extern type JCertificate = "java.security.cert.Certificate"

extern type JPrivateKey = "java.security.PrivateKey"

extern type JKeyStore = "java.security.KeyStore"

extern type JKeyManager = "javax.net.ssl.KeyManager"

extern type JKeyManagerFactory = "javax.net.ssl.KeyManagerFactory"

extern type JTrustManager = "javax.net.ssl.TrustManager"

extern type JTrustManagerFactory = "javax.net.ssl.TrustManagerFactory"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSSLParameters = "javax.net.ssl.SSLParameters"

extern type JSecureRandom = "java.security.SecureRandom"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JReflectArray = "java.lang.reflect.Array"

extern type JObject = "java.lang.Object"

extern type JArrayList = "java.util.ArrayList"

extern type JCharacter = "java.lang.Character"

// =====================================================================
// java.lang.reflect bridge for building a server SSLContext (module
// header).
// =====================================================================
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
    case None -> panic("Std.TlsServerContext: reflective method lookup failed for " + name + "/" + arity.toString())
  }
}

// A genuine `null` reference of `className`, via a fresh 1-element array
// (reference array elements are JVM-spec zero-initialized to null) —
// stands in for Lyric's lack of a null literal (#4775).
func nullOfClass(className: in String): JObject {
  val c: JClass = JClass.forName(className)
  val arr: JObject = JReflectArray.newInstance(c, 1)
  JReflectArray.get(arr, 0)
}

// An empty `char[]` (boxed as Object), used as the "no password" argument
// to KeyStore/KeyManagerFactory calls below — built via reflection so it
// never has to pass through a Lyric `slice[Char]` binding (module header:
// any array argument to a plain-`Object`-typed parameter position hits
// the same erasure gap as reference-array parameters).
func emptyCharArrayObj(): JObject {
  val charClass: JClass = JCharacter.TYPE
  JReflectArray.newInstance(charClass, 0)
}

// Builds a genuinely-typed 1-element array of `elemClassName` holding `v`.
func makeTypedArray1[T](elemClassName: in String, v: in T): JObject {
  val elemClass: JClass = JClass.forName(elemClassName)
  val arr: JObject = JReflectArray.newInstance(elemClass, 1)
  JReflectArray.set(arr, 0, v)
  arr
}

func invoke2[A, B, C](target: in A, methodName: in String, arg0: in B, arg1: in C): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 2)
  val argsList: JArrayList = JArrayList.new()
  argsList.add(arg0)
  argsList.add(arg1)
  m.invoke(target, argsList.toArray())
}

func invoke3[A, B, C, D](target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 3)
  val argsList: JArrayList = JArrayList.new()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  m.invoke(target, argsList.toArray())
}

func invoke4[A, B, C, D, E](
  target: in A, methodName: in String, arg0: in B, arg1: in C, arg2: in D, arg3: in E
): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameAndArity(cls, methodName, 4)
  val argsList: JArrayList = JArrayList.new()
  argsList.add(arg0)
  argsList.add(arg1)
  argsList.add(arg2)
  argsList.add(arg3)
  m.invoke(target, argsList.toArray())
}

// Builds an in-memory PKCS12 keystore holding `identity`'s cert + private
// key under a fixed alias — the standard JDK way to feed a
// `KeyManagerFactory` (module header explains why this goes through the
// keystore/factory path rather than a custom `KeyManager` impl).
func buildIdentityKeyStore(identity: in Identity): JKeyStore {
  val handle = identity.rawHandle()
  val cert: JCertificate = handle.cert
  val privateKey: JPrivateKey = match handle.key {
    case Some(k) -> k
    case None -> panic(
      "Std.TlsServerContext: server Identity has no private key (invariant violation)"
    )
  }
  val ks: JKeyStore = JKeyStore.getInstance("PKCS12")
  val nullStream = nullOfClass("java.io.InputStream")
  val _load = invoke2(ks, "load", nullStream, emptyCharArrayObj())
  val certChainArr = makeTypedArray1("java.security.cert.Certificate", cert)
  val _setKey = invoke4(ks, "setKeyEntry", "lyric-server", privateKey, emptyCharArrayObj(), certChainArr)
  ks
}

func protocolNameFor(v: in TlsVersion): String {
  match v {
    case Tls12 -> "TLS"
    case Tls13 -> "TLSv1.3"
  }
}

// The protocol floor `Std.Tls`'s `TlsVersion` variants guarantee: never
// below TLS 1.2, regardless of the JDK algorithm name `protocolNameFor`
// selects. Kept as an explicit literal (not derived from any JDK API) so
// the guarantee doesn't depend on how a particular provider or JVM vendor
// happens to compute its "default" set (module header on
// `assertProtocolFloor` explains why an even stronger, actively-restricting
// fix isn't reachable yet).
func minTlsProtocols(): List[String] {
  val allowed: List[String] = newList()
  allowed.add("TLSv1.2")
  allowed.add("TLSv1.3")
  allowed
}

// `SSLContext.getInstance(protocolNameFor(minVersion)).init(...)` computes
// its "default" enabled-protocol set (what `HttpsConfigurator`'s
// no-override `configure()` below actually applies to every accepted
// connection) from this JVM's `jdk.tls.disabledAlgorithms` security
// property AT `init()` TIME — captured once, not implicit magic, but also
// not something `startListenerTls` controls. If that property has been
// weakened (a deployment misconfiguration, or a JDK vendor whose "TLS"/
// "TLSv1.3" algorithm defaults differ from mainline OpenJDK's), the
// resulting context could silently negotiate down to TLSv1.1/TLSv1.0/SSLv3
// even though `protocolNameFor` asked for a TLS-1.2-or-newer floor (#5997).
//
// The idiomatic JSSE fix is to override `HttpsConfigurator.configure(...)`
// to call `params.setProtocols(["TLSv1.2", "TLSv1.3"])` explicitly (exactly
// how `_kernel_jvm/http_host.l`'s `buildClientSslParameters` pins the
// client side) instead of trusting `getDefaultSSLParameters()`. That fix
// is not reachable here: it requires subclassing the concrete
// `HttpsConfigurator` class, which the JVM backend's `impl <ExternType>
// for Record` does not support (issue #5930 — the same class-subclassing
// gap the mTLS rejection above names).
//
// Until #5930 ships, this assertion is the strongest guarantee actually
// enforceable: it inspects the SAME `getDefaultSSLParameters()` value
// `HttpsConfigurator`'s default `configure()` is about to hand every
// connection, and panics loudly — refusing to start the listener — rather
// than silently accepting a floor weaker than `minTlsProtocols()`
// specifies. This turns an implicit, unverified trust in the ambient JDK
// default into an explicit, checked one: `startListenerTls` never serves a
// single connection under a misconfigured floor.
func assertProtocolFloor(actual: in slice[String]): Unit {
  val allowed = minTlsProtocols()
  var i = 0
  while i < actual.length {
    val p = actual[i]
    if not listContains(allowed, p) {
      panic(
        "Std.TlsServerContext: this JVM's SSLContext default protocol set includes " + p +
          ", below the TLS 1.2 floor startListenerTls guarantees -- check this JVM's " +
          "jdk.tls.disabledAlgorithms security property (docs/61, issue #5997)"
      )
    }
    i = i + 1
  }
}

// Shared `KeyManagerFactory`/`SSLContext.init`/floor-assertion core for
// BOTH `buildServerSslContext` (no client-cert trust, `tmArr` a null
// `TrustManager[]`) and `buildServerSslContextWithClientCa` (`tmArr` a
// real one-element `TrustManager[]` pinned to the configured client CA).
// Factored out after issue #6563 (a REQUIRED PR-6560 review finding): the
// two callers had independently duplicated this sequence, and the mTLS
// copy silently omitted the `assertProtocolFloor` call the non-mTLS one
// had — every mTLS listener lost the TLS-1.2-floor guarantee #5997 adds
// for the non-mTLS path, with no test exercising the mTLS context's
// protocol set to catch it. A single core makes that class of divergence
// structurally impossible: there is now exactly one `SSLContext.init` +
// floor-check call site for server contexts on this target.
func buildServerSslContextCore(identity: in Identity, minVersion: in TlsVersion, tmArr: in JObject): JSSLContext {
  val ks = buildIdentityKeyStore(identity)
  val kmf: JKeyManagerFactory = JKeyManagerFactory.getInstance(JKeyManagerFactory.getDefaultAlgorithm())
  val _init = invoke2(kmf, "init", ks, emptyCharArrayObj())
  val keyManagers: slice[JKeyManager] = kmf.getKeyManagers()
  val kmArr = makeTypedArray1("javax.net.ssl.KeyManager", keyManagers[0])
  val ctx: JSSLContext = JSSLContext.getInstance(protocolNameFor(minVersion))
  val random: JSecureRandom = JSecureRandom.new()
  val _ctxInit = invoke3(ctx, "init", kmArr, tmArr, random)
  val defaultParams: JSSLParameters = ctx.getDefaultSSLParameters()
  val actualProtocols: slice[String] = defaultParams.getProtocols()
  assertProtocolFloor(actualProtocols)
  ctx
}

// Build a server-identity SSLContext from `identity`, enforcing
// `minVersion` by selecting the JDK protocol algorithm name accordingly
// (`"TLS"` negotiates the JDK's full supported range — TLS 1.2 and 1.3
// today — matching the `Tls12` floor; `"TLSv1.3"` restricts negotiation
// to that version alone), then explicitly verifying the resulting
// context's actual default protocol set never dips below TLS 1.2
// (`assertProtocolFloor` above) rather than trusting it implicitly. No
// client-cert trust manager is configured; the context trusts no client
// certificates, which is inert since nothing requests one without
// `HttpsParameters.setNeedClientAuth`. This function itself never builds
// client-cert trust — callers that need mTLS use the sibling
// `buildServerSslContextWithClientCa`/`serverSslContextFromConfigMtls`
// (#6017) instead. It is `Std.HttpServer.startListenerTls`'s own
// `HttpsServer`/`HttpsConfigurator` path (below) that still cannot host
// mTLS at all — blocked on the unrelated #5930 class-subclassing gap, not
// a limitation of this function or of the JVM target generally.
func buildServerSslContext(identity: in Identity, minVersion: in TlsVersion): JSSLContext {
  val tmArr = nullOfClass("[Ljavax.net.ssl.TrustManager;")
  buildServerSslContextCore(identity, minVersion, tmArr)
}

/// An opaque, server-identity `javax.net.ssl.SSLContext` built from a
/// `Std.Tls` `Identity` + `TlsVersion` (optionally with client-cert trust
/// pinned to a `Certificate`, via `serverSslContextFromConfigMtls`).
/// Exposed so OTHER JVM server kernels in this project — specifically
/// `lyric-web`'s Undertow kernel, which drives
/// `Undertow.Builder.addHttpsListener(port, host, sslContext)` rather than
/// `com.sun.net.httpserver.HttpsServer` — can reuse the
/// `KeyManagerFactory`/`TrustManagerFactory`/`KeyStore`/`java.lang.reflect`
/// extern wiring above (module header) instead of re-declaring the whole
/// boundary a second time. A context built by the non-mTLS
/// `serverSslContextFromConfig` carries no client-cert trust configuration,
/// which is inert on its own: the per-server client-auth wiring
/// (`HttpsServer.setNeedClientAuth` vs Undertow's XNIO
/// `SSL_CLIENT_AUTH_MODE`) still differs per server implementation and is
/// each caller's own responsibility to set.
@experimental
pub opaque type ServerSslContext {
  ctx: JSSLContext
}

/// Build a server-identity `SSLContext` from a certificate/key `Identity`
/// and a minimum protocol version. Non-mTLS only (see `ServerSslContext`);
/// callers that support mutual TLS call `serverSslContextFromConfigMtls`
/// instead. Reuses `buildServerSslContext` — the exact same construction
/// `startListenerTls` uses for its own `HttpsServer`.
@experimental
pub func serverSslContextFromConfig(identity: in Identity, minVersion: in TlsVersion): ServerSslContext {
  ServerSslContext(ctx = buildServerSslContext(identity, minVersion))
}

// Builds a trust-only PKCS12 keystore holding `clientCa` under a fixed
// alias — the standard JDK way to feed a `TrustManagerFactory` pinned to
// exactly one CA rather than the platform default trust store. Mirrors
// `buildIdentityKeyStore`'s pattern but with `setCertificateEntry` (a
// trusted-cert entry, no private key) instead of `setKeyEntry`; neither
// argument here is an array, so this calls straight through auto-FFI with
// no `java.lang.reflect` bridging needed (module header).
func buildClientCaKeyStore(clientCa: in Certificate): JKeyStore {
  val handles = clientCa.rawHandles()
  val ks: JKeyStore = JKeyStore.getInstance("PKCS12")
  val nullStream = nullOfClass("java.io.InputStream")
  val _load = invoke2(ks, "load", nullStream, emptyCharArrayObj())
  var i = 0
  while i < handles.count {
    val handle: CertHandle = handles[i]
    val cert: JCertificate = handle.cert
    ks.setCertificateEntry("lyric-client-ca-" + i.toString(), cert)
    i = i + 1
  }
  ks
}

// Build a server SSLContext with client-cert trust pinned to `clientCa`
// (mutual TLS, docs/61 §6.3 phase 2.3 / issue #6017): the same
// KeyManagerFactory-backed server identity + TLS-1.2-floor enforcement as
// `buildServerSslContext` (via the shared `buildServerSslContextCore`),
// plus a TrustManagerFactory over `buildClientCaKeyStore`'s keystore in
// place of the `null` TrustManager array. `makeTypedArray1` (module
// header) builds the genuinely-typed `TrustManager[]` `SSLContext.init`
// needs, mirroring the `KeyManager[]` construction the core performs for
// `KeyManager[]`.
func buildServerSslContextWithClientCa(
  identity: in Identity, minVersion: in TlsVersion, clientCa: in Certificate
): JSSLContext {
  val trustKs = buildClientCaKeyStore(clientCa)
  val tmf: JTrustManagerFactory = JTrustManagerFactory.getInstance(JTrustManagerFactory.getDefaultAlgorithm())
  tmf.init(trustKs)
  val trustManagers: slice[JTrustManager] = tmf.getTrustManagers()
  val tmArr = makeTypedArray1("javax.net.ssl.TrustManager", trustManagers[0])
  buildServerSslContextCore(identity, minVersion, tmArr)
}

/// Build a server-identity `SSLContext` with client-cert trust pinned to
/// `clientCa` (mutual TLS). Companion to `serverSslContextFromConfig` for
/// callers that support mTLS — currently `lyric-web`'s Undertow kernel
/// (`Web.Kernel.Runtime.serveTls`, issue #6017). `Std.HttpServer`'s own
/// `startListenerTls` (`com.sun.net.httpserver.HttpsServer`) still rejects
/// mTLS for the separate, harder `HttpsConfigurator` class-subclassing gap
/// (#5930) — this function does not touch that path.
@experimental
pub func serverSslContextFromConfigMtls(
  identity: in Identity, minVersion: in TlsVersion, clientCa: in Certificate
): ServerSslContext {
  ServerSslContext(ctx = buildServerSslContextWithClientCa(identity, minVersion, clientCa))
}

/// Kernel-boundary accessor for the underlying `javax.net.ssl.SSLContext`.
/// `pub` and `@experimental`, like `serverSslContextFromConfigMtls` it comes
/// with: `lyric-web`'s Undertow kernel (`Web.Kernel.Runtime.serveTls`) is a
/// separate project and binds the returned value to its own
/// `extern type = "javax.net.ssl.SSLContext"`, which `internal` would hide
/// from it (D437). Stdlib code reaches it the same way. Not part of the
/// stable surface: a `lyric-web` constructor path that needs no raw context
/// (docs/73's pure-Lyric server) removes it.
@experimental
pub func ServerSslContext.rawContext(s: in ServerSslContext): JSSLContext {
  s.ctx
}
