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

extern type HttpClientHandle = "java.net.http.HttpClient"

extern type HttpRequestMessage = "lyric.stdlib.jvm.HttpRequestBuilder"

extern type HttpResponseMessage = "lyric.stdlib.jvm.HttpResponseWrapper"

@externTarget("lyric.stdlib.jvm.HttpClientHost.defaultClient")
pub func hostDefaultClient(): HttpClientHandle = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.makeRequest")
pub func hostMakeRequest(method: in String, url: in String): HttpRequestMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.withHeader")
pub func hostWithHeader(request: in HttpRequestMessage, key: in String, value: in String): HttpRequestMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.withStringBody")
pub func hostWithStringBody(request: in HttpRequestMessage, contentType: in String, body: in String): HttpRequestMessage = ()

// Lowers to HttpClient.send(request.build(), BodyHandlers.ofByteArray())
// on the calling virtual thread.
@externTarget("lyric.stdlib.jvm.HttpClientHost.send")
pub async func hostSend(client: in HttpClientHandle, request: in HttpRequestMessage): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.get")
pub async func hostGet(client: in HttpClientHandle, url: in String): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.postString")
pub async func hostPostString(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
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
  client: in HttpClientHandle, request: in HttpRequestMessage, token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.getWithCancel")
pub async func hostGetWithCancel(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.postStringWithCancel")
pub async func hostPostStringWithCancel(
  client: in HttpClientHandle,
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
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClientHandle = ()

// Builds an HttpClient with redirect policy NEVER.
@externTarget("lyric.stdlib.jvm.HttpClientHost.clientNoRedirects")
pub func hostClientNoRedirects(): HttpClientHandle = ()

// ---------------------------------------------------------------------------
// Unix domain socket support (Phase 2 - JVM implementation TBD).
// These stubs maintain API parity with .NET; JVM implementation to follow
// as part of lyric-stdlib JVM kernel completion (issue #2663 band J2-J3).
// ---------------------------------------------------------------------------
@externTarget("lyric.stdlib.jvm.HttpClientHost.clientWithUnixSocket")
pub func hostClientWithUnixSocket(socketPath: in String): HttpClientHandle = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.clientWithUnixSocketAndRedirects")
pub func hostClientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClientHandle = ()

@externTarget("lyric.stdlib.jvm.HttpClientHost.clientWithUnixSocketNoRedirects")
pub func hostClientWithUnixSocketNoRedirects(socketPath: in String): HttpClientHandle = ()

// Returns the first value of the named response header, or "" if absent.
@externTarget("lyric.stdlib.jvm.HttpClientHost.responseHeader")
pub func hostResponseHeader(response: in HttpResponseMessage, name: in String): String = ()

// ---------------------------------------------------------------------------
// V0012-safe wrappers — mirrors _kernel/http_host.l.
//
// On JVM, virtual threads have no CLR protected-region restriction, so these
// can use await-in-try directly.  They exist to provide a uniform Std.HttpHost
// surface between .NET and JVM targets.
// ---------------------------------------------------------------------------
pub async func hostSendSafe(client: in HttpClientHandle, request: in HttpRequestMessage): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await hostSend(client, request))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetSafe(client: in HttpClientHandle, url: in String): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await hostGet(client, url))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostPostStringSafe(
  client: in HttpClientHandle, url: in String, body: in String, contentType: in String
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await hostPostString(client, url, body, contentType))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextSafe(response: in HttpResponseMessage): Result[String, String] {
  return try {
    Ok(value = await hostReadBodyText(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyBytesSafe(response: in HttpResponseMessage): Result[slice[Byte], String] {
  return try {
    Ok(value = await hostReadBodyBytes(response))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostSendWithCancelSafe(
  client: in HttpClientHandle, request: in HttpRequestMessage, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await hostSendWithCancel(client, request, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostGetWithCancelSafe(
  client: in HttpClientHandle, url: in String, token: in CancellationToken
): Result[HttpResponseMessage, String] {
  return try {
    Ok(value = await hostGetWithCancel(client, url, token))
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
    Ok(value = await hostPostStringWithCancel(client, url, body, contentType, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}

pub async func hostReadBodyTextWithCancelSafe(
  response: in HttpResponseMessage, token: in CancellationToken
): Result[String, String] {
  return try {
    Ok(value = await hostReadBodyTextWithCancel(response, token))
  } catch Bug as b {
    Err(error = b.message)
  }
}
