// std/_kernel/http_host.l - host boundary for HTTP.
//
// This file is the audited extern boundary for `Std.Http`.  Every
// host-facing function below is either:
//
//   * a direct `@externTarget` to a single BCL method / property /
//     constructor (the trivial pass-through case), or
//   * a native Lyric helper that composes a sequence of those
//     primitives (the multi-step orchestration case — `hostMakeRequest`,
//     `hostWithStringBody`, etc.).
//
// G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
// the F# `Lyric.Stdlib.HttpClientHost` shim retires entirely.

@axiom("System.Net.Http operations conform to their documented .NET contracts")
package Std.HttpHost

import Std.Core
import Std.Task

// =====================================================================
// Extern types — BCL classes the helpers below reference.  Each one
// is the host-side type for a value that flows through Std.Http but
// stays opaque from the user's perspective.
// =====================================================================

extern type HttpClient          = "System.Net.Http.HttpClient"
extern type HttpClientHandler   = "System.Net.Http.HttpClientHandler"
extern type HttpRequestMessage  = "System.Net.Http.HttpRequestMessage"
extern type HttpResponseMessage = "System.Net.Http.HttpResponseMessage"
extern type HttpContent         = "System.Net.Http.HttpContent"
extern type StringContent       = "System.Net.Http.StringContent"
// `BclHttpMethod` rather than `HttpMethod` because `Std.Http`
// declares its own user-facing `pub enum HttpMethod { Get, Post, … }`
// and would shadow this extern.
extern type BclHttpMethod       = "System.Net.Http.HttpMethod"
extern type HttpHeaders         = "System.Net.Http.Headers.HttpHeaders"
extern type Encoding            = "System.Text.Encoding"

// =====================================================================
// Primitive externs (private to this kernel file).  These bind the
// individual BCL members; the public `host*` helpers compose them.
// =====================================================================

@externTarget("System.Text.Encoding.UTF8")
func utf8(): Encoding = ()

@externTarget("System.Net.Http.HttpMethod..ctor")
func newHttpMethod(name: in String): BclHttpMethod = ()

@externTarget("System.Net.Http.HttpRequestMessage..ctor")
func newRequest(method: in BclHttpMethod, url: in String): HttpRequestMessage = ()

@externTarget("System.Net.Http.HttpRequestMessage.Headers")
func requestHeaders(req: in HttpRequestMessage): HttpHeaders = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func headersTryAdd(h: in HttpHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.StringContent..ctor")
func newStringContent(body: in String, encoding: in Encoding, mediaType: in String): StringContent = ()

@externTarget("System.Net.Http.HttpRequestMessage.set_Content")
func setRequestContent(req: in HttpRequestMessage, content: in StringContent): Unit = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClient(): HttpClient = ()

@externTarget("System.Net.Http.HttpClient..ctor")
func newClientFromHandler(handler: in HttpClientHandler): HttpClient = ()

@externTarget("System.Net.Http.HttpClientHandler..ctor")
func newHandler(): HttpClientHandler = ()

@externTarget("System.Net.Http.HttpClientHandler.set_AllowAutoRedirect")
func setAllowAutoRedirect(h: in HttpClientHandler, v: in Bool): Unit = ()

@externTarget("System.Net.Http.HttpClientHandler.set_MaxAutomaticRedirections")
func setMaxAutomaticRedirections(h: in HttpClientHandler, n: in Int): Unit = ()

@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsync(client: in HttpClient, request: in HttpRequestMessage): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsyncCancel(client: in HttpClient, request: in HttpRequestMessage, token: in CancellationToken): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsync(client: in HttpClient, url: in String): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.GetAsync")
async func clientGetAsyncCancel(client: in HttpClient, url: in String, token: in CancellationToken): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsync(client: in HttpClient, url: in String, content: in StringContent): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpClient.PostAsync")
async func clientPostAsyncCancel(client: in HttpClient, url: in String, content: in StringContent, token: in CancellationToken): HttpResponseMessage = ()

@externTarget("System.Net.Http.HttpResponseMessage.StatusCode")
func responseStatusInt(response: in HttpResponseMessage): Int = ()

@externTarget("System.Net.Http.HttpResponseMessage.Content")
func responseContent(response: in HttpResponseMessage): HttpContent = ()

@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsString(c: in HttpContent): String = ()

@externTarget("System.Net.Http.HttpContent.ReadAsStringAsync")
async func contentReadAsStringCancel(c: in HttpContent, token: in CancellationToken): String = ()

@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytes(c: in HttpContent): slice[Byte] = ()

@externTarget("System.Net.Http.HttpContent.ReadAsByteArrayAsync")
async func contentReadAsBytesCancel(c: in HttpContent, token: in CancellationToken): slice[Byte] = ()

// =====================================================================
// Public host helpers — the names `Std.Http` resolves through
// `import Std.HttpHost as HostHttp`.  Each is either a thin alias or
// a multi-step composition that wraps the primitives above.
// =====================================================================

pub func hostDefaultClient(): HttpClient {
  newClient()
}

pub func hostMakeRequest(httpMethod: in String, url: in String): HttpRequestMessage {
  newRequest(newHttpMethod(httpMethod), url)
}

pub func hostWithHeader(
  request: in HttpRequestMessage,
  key: in String,
  value: in String
): HttpRequestMessage {
  val _ = headersTryAdd(requestHeaders(request), key, value)
  request
}

pub func hostWithStringBody(
  request: in HttpRequestMessage,
  contentType: in String,
  body: in String
): HttpRequestMessage {
  setRequestContent(request, newStringContent(body, utf8(), contentType))
  request
}

pub async func hostSend(
  client: in HttpClient,
  request: in HttpRequestMessage
): HttpResponseMessage {
  await clientSendAsync(client, request)
}

pub async func hostGet(
  client: in HttpClient,
  url: in String
): HttpResponseMessage {
  await clientGetAsync(client, url)
}

pub async func hostPostString(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String
): HttpResponseMessage {
  await clientPostAsync(client, url, newStringContent(body, utf8(), contentType))
}

pub func hostStatusCode(response: in HttpResponseMessage): Int {
  responseStatusInt(response)
}

pub async func hostReadBodyText(response: in HttpResponseMessage): String {
  await contentReadAsString(responseContent(response))
}

pub async func hostReadBodyBytes(response: in HttpResponseMessage): slice[Byte] {
  await contentReadAsBytes(responseContent(response))
}

// ---------------------------------------------------------------------------
// Phase C cancellation-aware overloads (D-progress-070).
// ---------------------------------------------------------------------------

pub async func hostSendWithCancel(
  client: in HttpClient,
  request: in HttpRequestMessage,
  token: in CancellationToken
): HttpResponseMessage {
  await clientSendAsyncCancel(client, request, token)
}

pub async func hostGetWithCancel(
  client: in HttpClient,
  url: in String,
  token: in CancellationToken
): HttpResponseMessage {
  await clientGetAsyncCancel(client, url, token)
}

pub async func hostPostStringWithCancel(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken
): HttpResponseMessage {
  await clientPostAsyncCancel(client, url, newStringContent(body, utf8(), contentType), token)
}

pub async func hostReadBodyTextWithCancel(
  response: in HttpResponseMessage,
  token: in CancellationToken
): String {
  await contentReadAsStringCancel(responseContent(response), token)
}

pub func hostClientWithRedirects(maxRedirects: in Int): HttpClient {
  val handler = newHandler()
  setAllowAutoRedirect(handler, true)
  setMaxAutomaticRedirections(handler, maxRedirects)
  newClientFromHandler(handler)
}

pub func hostClientNoRedirects(): HttpClient {
  val handler = newHandler()
  setAllowAutoRedirect(handler, false)
  newClientFromHandler(handler)
}

// `ResponseHeader` is parked: the BCL `TryGetValues` returns
// `IEnumerable<string>` via an out-param, which Lyric's FFI doesn't
// surface today (slice-of-string `out` param + IEnumerable<T>
// iteration).  Stays in the F# shim until a follow-up.
@externTarget("Lyric.Stdlib.HttpClientHost.ResponseHeader")
pub func hostResponseHeader(
  response: in HttpResponseMessage,
  name: in String
): String = ()
