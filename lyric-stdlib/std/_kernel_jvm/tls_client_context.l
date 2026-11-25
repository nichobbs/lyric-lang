//! std/_kernel_jvm/tls_client_context.l - JVM client `SSLContext` construction.
//!
//! The one place on this target that turns a client trust decision (the
//! platform trust store, an additional CA, only a given CA, or nothing at all)
//! and an optional mTLS `Identity` into a `javax.net.ssl.SSLContext` and the
//! `SSLParameters` (protocol floor, endpoint identification) a client socket
//! needs: the client twin of `Std.TlsServerContext`. It lived in
//! `_kernel_jvm/http_host.l` (`java.net.http.HttpClient`) until docs/72 slice 4
//! gave `Std.TcpHost` a client TLS path (`hostConnectTls`), which needs the same
//! construction for a raw `SSLSocket`; both now call it, so there is one site
//! that decides what a client trusts.
//!
//! Trust model: a JVM client has no per-handshake validation callback, so trust
//! is configured structurally, as a `KeyStore` fed to a `TrustManagerFactory`
//! that the JDK's PKIX path builder validates every handshake against.
//!
//!   - `PlatformTrust`: a `TrustManagerFactory` initialised with a `null`
//!     `KeyStore`, the JDK idiom for the default trust store (`cacerts`, or
//!     `javax.net.ssl.trustStore` when set).
//!   - `AdditiveTrust`: a `KeyStore` holding the given CA certificates PLUS every
//!     accepted issuer of the platform's own trust manager; a chain valid
//!     against either set verifies.
//!   - `ExclusiveTrust`: a `KeyStore` holding ONLY the given CA certificates.
//!   - `NoVerification`: an all-trusting `X509TrustManager` (below).
//!
//! Hostname verification is separate from trust and is NOT on by default for a
//! raw `SSLSocket` (only `java.net.http.HttpClient` enforces it unconditionally,
//! whatever the `SSLParameters`): `clientSslParameters` sets the endpoint
//! identification algorithm to `HTTPS` on every verifying path and clears it
//! only for `NoVerification`, and a caller must apply those parameters to the
//! socket (`SSLSocket.setSSLParameters`) before the handshake.
//!
//! Why reflection: the JVM auto-FFI cannot construct or pass a reference-typed
//! Java array (`Certificate[]`, `TrustManager[]`, `String[]`, `Class[]`) as a
//! call ARGUMENT, since a Lyric `slice[T]` of references always erases to
//! `Object[]` at the call site. `java.lang.reflect` sidesteps this (see
//! `Std.TlsServerContext`'s header for the full account): `Array.newInstance`/
//! `Array.set` build a genuinely typed array one element at a time, and
//! `Method.invoke(Object, Object...)` takes an `Object[]` that a Lyric
//! `slice[JObject]` matches exactly. Returning an array from a call is
//! unaffected.
@axiom("java.security.KeyStore, javax.net.ssl.KeyManagerFactory, TrustManagerFactory and SSLContext, and java.lang.reflect operations conform to their documented JVM contracts")
@io
package Std.TlsClientContext

import Std.Core
import Std.Collections
import Std.Tls
import Std.TlsHost

// ---------------------------------------------------------------------------
// Reflection bridge (module header above; self-contained per this directory's
// per-file convention, like `_kernel_jvm/tls_server_context.l`'s).
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
extern type JSystem = "java.lang.System"

extern type JObject = "java.lang.Object"

// A generic argument is not a `JObject` on its own; an `ArrayList` takes
// any value (null included) through the extern boundary and still yields a
// genuine `Object[]` for reflective calls.
extern type JArrayList = "java.util.ArrayList"

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
  var matchCount = 0
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      found = Some(value = m)
      matchCount = matchCount + 1
    }
    i = i + 1
  }
  if matchCount > 1 {
    panic(
      "Std.TlsClientContext: ambiguous reflective method lookup for " + name + "/" + arity.toString() + " — " +
        matchCount.toString() +
        " overloads matched"
    )
  }
  match found {
    case Some(m) -> m
    case None -> panic("Std.TlsClientContext: reflective method lookup failed for " + name + "/" + arity.toString())
  }
}

// `TrustManagerFactory.init` has TWO one-argument overloads
// (`init(KeyStore)` / `init(ManagerFactoryParameters)`); arity alone does
// not disambiguate them, so this variant also matches the first
// parameter's declared type name.
func findMethodByNameArityAndParamType(
  cls: in JClass, name: in String, arity: in Int, paramClassName: in String
): JMethod {
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  var found: Option[JMethod] = None
  var matchCount = 0
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      val ptypes: slice[JClass] = m.getParameterTypes()
      if ptypes[0].getName() == paramClassName {
        found = Some(value = m)
        matchCount = matchCount + 1
      }
    }
    i = i + 1
  }
  if matchCount > 1 {
    panic(
      "Std.TlsClientContext: ambiguous reflective method lookup for " + name + " with param type " + paramClassName +
        " — " +
        matchCount.toString() +
        " overloads matched"
    )
  }
  match found {
    case Some(m) -> m
    case None -> panic(
      "Std.TlsClientContext: reflective method lookup failed for " + name + " with param type " +
        paramClassName
    )
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
  val argsList: JArrayList = JArrayList.new()
  argsList.add(arg0)
  m.invoke(target, argsList.toArray())
}

func invoke1Typed[A, B](target: in A, methodName: in String, paramClassName: in String, arg0: in B): JObject {
  val cls: JClass = target.getClass()
  val m = findMethodByNameArityAndParamType(cls, methodName, 1, paramClassName)
  val argsList: JArrayList = JArrayList.new()
  argsList.add(arg0)
  m.invoke(target, argsList.toArray())
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

// Every certificate of a `Std.Tls.Certificate` (a CA bundle carries several)
// as its own trusted-certificate entry, under `aliasPrefix` plus its index.
func addTrustedCertificates(ks: in JKeyStore, aliasPrefix: in String, certs: in List[CertHandle]): Unit {
  var i = 0
  while i < certs.count {
    val handle: CertHandle = certs[i]
    val c: JCertificate = handle.cert
    ks.setCertificateEntry(aliasPrefix + i.toString(), c)
    i = i + 1
  }
}

// ADDITIVE trust (`withCaCertificate`): `extraCa` plus every platform trust
// anchor — a chain valid against either set is accepted.
func buildAdditiveTrustKeyStore(extraCa: in List[CertHandle]): JKeyStore {
  val ks = newEmptyPkcs12KeyStore()
  addTrustedCertificates(ks, "lyric-extra-ca-", extraCa)
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
func buildExclusiveTrustKeyStore(onlyCa: in List[CertHandle]): JKeyStore {
  val ks = newEmptyPkcs12KeyStore()
  addTrustedCertificates(ks, "lyric-exclusive-ca-", onlyCa)
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
// server-identity construction the JVM server-TLS context
// (`tls_server_context.l`, #5880) builds for the server, duplicated rather than shared per this
// directory's self-contained-per-file convention.
func buildClientIdentityKeyStore(identity: in Identity): JKeyStore {
  val handle = Identity.rawHandle(identity)
  val cert: JCertificate = handle.cert
  val privateKey: JPrivateKey = match handle.key {
    case Some(k) -> k
    case None -> panic(
      "Std.TlsClientContext: client Identity has no private key (invariant violation)"
    )
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

// A genuine `java.lang.Object`-typed box around `v` (any Lyric value,
// primitive or reference) — needed because `InvocationHandler.invoke`'s
// return type is `Object`, and the JDK's proxy dispatch throws
// `ClassCastException` if the returned value is not assignment-compatible
// with the interface method's OWN declared return type (`String` for
// `toString`, `int`/boxed-then-unboxed for `hashCode`, `boolean` for
// `equals`) — a plain Lyric `String`/`Bool`/`Int` value does not
// type-check directly against a `JObject`-declared position (verified;
// T0060), so it is boxed one element at a time via the same
// `java.lang.reflect.Array` idiom this file already uses for typed-array
// construction, then read back through it (`Array.get` on a `List[JObject]`
// specifically mis-resolves the checkcast target to a bogus same-package
// class rather than `java.lang.Object` — a JVM backend bug reproduced in
// isolation; `Array.get` on a reflectively-built array does not hit it).
func boxAsObject[T](v: in T): JObject {
  val cls: JClass = JClass.forName("java.lang.Object")
  val arr: JObject = JReflectArray.newInstance(cls, 1)
  JReflectArray.set(arr, 0, v)
  JReflectArray.get(arr, 0)
}

// The JDK routes `Object`'s own methods (`toString`/`hashCode`/`equals`)
// through `InvocationHandler.invoke` too, not just the interface's own
// abstract methods — any code that logs, hashes, or compares the proxy
// (a `HashMap` using it as a key, a debugger, `Object.toString()` in a
// log line) reaches this dispatch. The original version of this handler
// returned `proxy` itself for anything other than `getAcceptedIssuers`,
// which is wrong for every one of these: `proxy` is not assignable to
// `String` (`toString`) or to boxed `Integer`/`Boolean`
// (`hashCode`/`equals`), so the JDK's own assignment-compatibility check
// throws `ClassCastException` the moment any of them is invoked. Dispatch
// explicitly by method name instead:
impl JInvocationHandler for AllTrustingHandler {
  func invoke(proxy: in JObject, method: in JMethod, args: in slice[JObject]): JObject {
    val name: String = method.getName()
    if name == "getAcceptedIssuers" {
      val cls: JClass = JClass.forName("java.security.cert.X509Certificate")
      val empty: JObject = JReflectArray.newInstance(cls, 0)
      empty
    } else if name == "checkClientTrusted" or name == "checkServerTrusted" {
      // Both are declared `void`; the JDK ignores whatever `invoke`
      // returns for a `void`-declared interface method, so any value is
      // safe here. Returning normally (no thrown `CertificateException`)
      // is exactly "trusted, no questions asked" — the documented
      // all-trusting shape.
      nullOfClass("java.lang.Object")
    } else if name == "toString" {
      val description: String = "AllTrustingHandler(insecureSkipVerify proxy)"
      boxAsObject(description)
    } else if name == "hashCode" {
      val identity: Int = JSystem.identityHashCode(proxy)
      boxAsObject(identity)
    } else if name == "equals" {
      // Intended: identity comparison against `args[0]` (matching
      // `Object.equals`'s default contract, consistent with the
      // identity-based `hashCode` above). NOT implemented that way: reading
      // `args[0]` — indexing a `slice[T]` whose element type resolves to
      // exactly `java.lang.Object` — throws `NoClassDefFoundError` for a
      // bogus same-package class name at runtime, a confirmed JVM backend
      // codegen bug independent of how the read is phrased (a bound `val`,
      // an inline comparison operand, and an inline call argument were all
      // tried and all fail identically; a `List[JObject]` index read hits
      // the exact same fault). No FFI workaround exists: passing `args`
      // itself into a helper call (to extract the element via reflection
      // instead) fails too, for the unrelated, already-documented reason
      // that the auto-FFI cannot pass a `slice[T]` value as a call argument
      // at all. Falls back to `false` unconditionally instead — never
      // throws, and never wrongly claims equality with an unrelated,
      // wrongly-typed object (the safer of the two failure modes); the
      // cost is a reflexivity-contract violation (`x.equals(x)` should be
      // `true`) that this proxy's only real consumer — `SSLContext.init`,
      // which never calls `equals` on an installed `TrustManager` — cannot
      // observe. `getAcceptedIssuers`/`checkClientTrusted`/
      // `checkServerTrusted` (the methods the TLS handshake path actually
      // invokes) are unaffected by this.
      val neverEqual: Bool = false
      boxAsObject(neverEqual)
    } else {
      // `X509TrustManager` declares no other methods; this is an
      // unreachable, defensive fallback rather than a silent `proxy`
      // return that could throw for a future JDK method this file hasn't
      // been updated for.
      nullOfClass("java.lang.Object")
    }
  }
}

@unsafe_ffi
func buildAllTrustingTrustManager(): JTrustManager {
  val cl: JClassLoader = JClassLoader.getSystemClassLoader()
  val tmClass: JClass = JClass.forName("javax.net.ssl.X509TrustManager")
  val ifacesArr = makeTypedArray1("java.lang.Class", tmClass)
  val handler: AllTrustingHandler = AllTrustingHandler(marker = true)
  val asHandler: JInvocationHandler = handler
  val proxyClass: JClass = JClass.forName("java.lang.reflect.Proxy")
  val m = findMethodByNameAndArity(proxyClass, "newProxyInstance", 3)
  val argsList: List[JObject] = newList()
  argsList.add(externAsObject(cl))
  argsList.add(ifacesArr)
  argsList.add(externAsObject(asHandler))
  val tm: JTrustManager = m.invoke(nullOfClass("java.lang.Object"), argsList.toArray())
  tm
}

// ---------------------------------------------------------------------------
// SSLContext / SSLParameters assembly.
// ---------------------------------------------------------------------------
/// What a client trusts. The certificates are the raw handles of
/// `Std.Tls.Certificate.rawHandles`.
pub union ClientTrustSource {
  case PlatformTrust
  case AdditiveTrust(anchors: List[CertHandle])
  case ExclusiveTrust(anchors: List[CertHandle])
  case NoVerification
}

/// A built client `SSLContext`.
pub opaque type ClientSslContext {
  ctx: JSSLContext
}

/// The underlying `SSLContext`.
pub func ClientSslContext.rawContext(c: in ClientSslContext): JSSLContext {
  c.ctx
}

/// Build the client `SSLContext` for `trust`, presenting `clientIdentity`
/// (mTLS) when given. A key store or identity the platform cannot load panics;
/// callers wrap the call.
pub func clientSslContext(trust: in ClientTrustSource, clientIdentity: in Option[Identity]): ClientSslContext {
  val trustManagersObj: JObject = match trust {
    case NoVerification -> makeTypedArray1(
      "javax.net.ssl.TrustManager",
      buildAllTrustingTrustManager()
    )
    case ExclusiveTrust(anchors) -> {
      val tmObj: JObject = trustManagerFactoryFor(buildExclusiveTrustKeyStore(anchors)).getTrustManagers()
      tmObj
    }
    case AdditiveTrust(anchors) -> {
      val tmObj: JObject = trustManagerFactoryFor(buildAdditiveTrustKeyStore(anchors)).getTrustManagers()
      tmObj
    }
    case PlatformTrust -> {
      val tmObj: JObject = defaultTrustManagerFactory().getTrustManagers()
      tmObj
    }
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
  ClientSslContext(ctx = ctx)
}

/// `SSLParameters` for a client socket or `HttpClient` over `ctx`
/// (`SSLContext.getDefaultSSLParameters`): the protocol floor and the endpoint
/// identification algorithm.
///
/// `minVersion`: `Tls13` pins TLS 1.3 exactly; `Tls12` (and `None`, the unset
/// default) floors at TLS 1.2 while still allowing 1.3, the floor the dotnet
/// kernel gets by leaving the platform default alone.
///
/// `verifyEndpoint` sets the endpoint identification algorithm to `HTTPS`, which
/// makes the JDK check the peer certificate against the host name the socket was
/// created for (RFC 6125); `false` clears it (`""`, the SSLParameters javadoc's
/// equivalent of `null`) and is for `NoVerification` only. `java.net.http.
/// HttpClient` enforces its own hostname check regardless, so for it `false`
/// disables chain verification only, which is stricter than docs/61 §4's
/// baseline; a raw `SSLSocket` honours the setting exactly.
pub func clientSslParameters(
  ctx: in JSSLContext, minVersion: in Option[TlsVersion], verifyEndpoint: in Bool
): JSSLParameters {
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
  if verifyEndpoint {
    params.setEndpointIdentificationAlgorithm("HTTPS")
  } else {
    params.setEndpointIdentificationAlgorithm("")
  }
  params
}
