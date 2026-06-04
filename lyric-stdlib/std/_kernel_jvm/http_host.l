//! std/_kernel_jvm/http_host.l - JVM host boundary for HTTP client.
//!
//! Mirrors _kernel/http_host.l for the JVM target.  All operations
//! route through lyric.stdlib.jvm.HttpClientHost, which wraps
//! java.net.http.HttpClient (Java 11+).
//!
//! HttpClient maps directly to java.net.http.HttpClient.
//!
//! HttpRequestMessage wraps a java.net.http.HttpRequest.Builder so that
//! headers and body can be accumulated before the final send() call
//! constructs the immutable HttpRequest.  (Java's HttpRequest is
//! immutable; the builder pattern is the JVM equivalent of .NET's
//! mutable HttpRequestMessage.)
//!
//! HttpResponseMessage wraps java.net.http.HttpResponse<byte[]> so that
//! both text and binary body reads share a single response object.
//!
//! Async functions lower to synchronous calls on the calling virtual
//! thread (JEP 444).  The shim calls HttpClient.send() (blocking) on
//! the virtual thread; the JVM scheduler parks the carrier thread on
//! I/O without blocking the OS thread.
@axiom("lyric.stdlib.jvm.HttpClientHost operations conform to their documented JVM / java.net.http contracts")
package Std.HttpHost

import Std.Task

extern type HttpClient = "java.net.http.HttpClient"

extern type HttpRequestMessage = "lyric.stdlib.jvm.HttpRequestBuilder"

extern type HttpResponseMessage = "lyric.stdlib.jvm.HttpResponseWrapper"

@externTarget("lyric.stdlib.jvm.HttpClientHost.defaultClient")
pub func hostDefaultClient(): HttpClient = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.makeRequest")
pub func hostMakeRequest(method: in String, url: in String): HttpRequestMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.withHeader")
pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.withStringBody")
pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage = ()

// Lowers to HttpClient.send(request.build(), BodyHandlers.ofByteArray())
// on the calling virtual thread.
@externTarget("lyric.stdlib.jvm.HttpClientHost.send")
pub async func hostSend(client: in HttpClient, request: in HttpRequestMessage): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.get")
pub async func hostGet(client: in HttpClient, url: in String): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.postString")
pub async func hostPostString(
  client: in HttpClient, url: in String, body: in String, contentType: in String
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.statusCode")
pub func hostStatusCode(response: in HttpResponseMessage): Int = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.readBodyText")
pub async func hostReadBodyText(response: in HttpResponseMessage): String = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.readBodyBytes")
pub async func hostReadBodyBytes(response: in HttpResponseMessage): slice[Byte] = ()

// -------------------------------------------------------------------------
// Cancellation-aware overloads.  Cancellation is propagated by
// interrupting the virtual thread (§14.3 of 18-jvm-emission.md), which
// causes the blocking HttpClient.send() to throw InterruptedException,
// bridged to Bug(Cancelled) by the runtime.
// -------------------------------------------------------------------------
@externTarget("lyric.stdlib.jvm.HttpClientHost.sendWithCancel")
pub async func hostSendWithCancel(
  client: in HttpClient, request: in HttpRequestMessage, token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.getWithCancel")
pub async func hostGetWithCancel(
  client: in HttpClient, url: in String, token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.postStringWithCancel")
pub async func hostPostStringWithCancel(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken,
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.readBodyTextWithCancel")
pub async func hostReadBodyTextWithCancel(response: in HttpResponseMessage, token: in CancellationToken): String = ()

// Builds an HttpClient with a redirect policy of NORMAL (follows up to
// maxRedirects hops; 0 disables following).
@externTarget("lyric.stdlib.jvm.HttpClientHost.clientWithRedirects")
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClient = ()

// Builds an HttpClient with redirect policy NEVER.
@externTarget("lyric.stdlib.jvm.HttpClientHost.clientNoRedirects")
pub func hostClientNoRedirects(): HttpClient = ()

// Returns the first value of the named response header, or "" if absent.
@externTarget("lyric.stdlib.jvm.HttpClientHost.responseHeader")
pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String = ()
