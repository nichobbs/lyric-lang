// std/http_host.l - trusted host-runtime boundary for HTTP.
//
// This file is deliberately narrow and reviewable. It exposes the host
// HTTP client primitives that Std.Http wraps in Result-returning APIs.
//
// Each routine forwards to a `Lyric.Stdlib.HttpClientHost::*` static
// (D-progress-052).  Names are deliberately distinct from Std.Http's
// user-facing `send` / `withHeader` / etc. because the alias rewriter
// (`import Std.HttpHost as HostHttp`) collapses `HostHttp.foo(...)`
// to bare `foo(...)`, and Std.Http's wrappers would collide if the
// names matched.

@axiom("System.Net.Http operations conform to their documented .NET contracts")
package Std.HttpHost

import Std.Task

extern type HttpClient          = "System.Net.Http.HttpClient"
extern type HttpRequestMessage  = "System.Net.Http.HttpRequestMessage"
extern type HttpResponseMessage = "System.Net.Http.HttpResponseMessage"

@externTarget("Lyric.Stdlib.HttpClientHost.DefaultClient")
pub func hostDefaultClient(): HttpClient = ()

@externTarget("Lyric.Stdlib.HttpClientHost.MakeRequest")
pub func hostMakeRequest(method: in String, url: in String): HttpRequestMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.WithHeader")
pub func hostWithHeader(
  request: in HttpRequestMessage,
  key: in String,
  value: in String
): HttpRequestMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.WithStringBody")
pub func hostWithStringBody(
  request: in HttpRequestMessage,
  contentType: in String,
  body: in String
): HttpRequestMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.Send")
pub async func hostSend(
  client: in HttpClient,
  request: in HttpRequestMessage
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.Get")
pub async func hostGet(
  client: in HttpClient,
  url: in String
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.PostString")
pub async func hostPostString(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.StatusCode")
pub func hostStatusCode(response: in HttpResponseMessage): Int = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ReadBodyText")
pub async func hostReadBodyText(response: in HttpResponseMessage): String = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ReadBodyBytes")
pub async func hostReadBodyBytes(response: in HttpResponseMessage): slice[Byte] = ()

// ---------------------------------------------------------------------------
// Phase C cancellation-aware overloads (D-progress-070).  Each mirrors
// its non-cancellable counterpart and accepts a `CancellationToken` from
// `Std.Task` (re-imported above) that the BCL HttpClient honours.
// Cancellation surfaces as `OperationCanceledException` in the host,
// caught as `Bug` on the Lyric side and surfaced as
// `HttpError.ConnectionFailed` (with the message describing
// cancellation).
// ---------------------------------------------------------------------------

@externTarget("Lyric.Stdlib.HttpClientHost.SendWithCancel")
pub async func hostSendWithCancel(
  client: in HttpClient,
  request: in HttpRequestMessage,
  token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.GetWithCancel")
pub async func hostGetWithCancel(
  client: in HttpClient,
  url: in String,
  token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.PostStringWithCancel")
pub async func hostPostStringWithCancel(
  client: in HttpClient,
  url: in String,
  body: in String,
  contentType: in String,
  token: in CancellationToken
): HttpResponseMessage = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ReadBodyTextWithCancel")
pub async func hostReadBodyTextWithCancel(
  response: in HttpResponseMessage,
  token: in CancellationToken
): String = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ClientWithRedirects")
pub func hostClientWithRedirects(maxRedirects: in Int): HttpClient = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ClientNoRedirects")
pub func hostClientNoRedirects(): HttpClient = ()

@externTarget("Lyric.Stdlib.HttpClientHost.ResponseHeader")
pub func hostResponseHeader(
  response: in HttpResponseMessage,
  name: in String
): String = ()
