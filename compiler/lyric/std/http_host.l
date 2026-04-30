// std/http_host.l - trusted host-runtime boundary for HTTP.
//
// This file is deliberately narrow and reviewable. It exposes the host
// HTTP client primitives that Std.Http wraps in Result-returning APIs.
// Adding a host call here expands the trusted networking surface.

@axiom("System.Net.Http operations conform to their documented .NET contracts")
package Std.HttpHost

extern package System.Net.Http {
  pub exposed type HttpClient
  pub exposed type HttpRequestMessage
  pub exposed type HttpResponseMessage

  // Client construction is currently process-default. Future app-host
  // integration can supply configured clients from a wire/container.
  pub func defaultClient(): HttpClient

  pub func makeRequest(method: in String, url: in String): HttpRequestMessage
    requires: method.length > 0
    requires: url.length > 0

  pub func withHeader(
    request: in HttpRequestMessage,
    key: in String,
    value: in String
  ): HttpRequestMessage
    requires: key.length > 0

  pub func withStringBody(
    request: in HttpRequestMessage,
    contentType: in String,
    body: in String
  ): HttpRequestMessage
    requires: contentType.length > 0

  pub async func send(
    client: in HttpClient,
    request: in HttpRequestMessage
  ): HttpResponseMessage

  pub async func get(
    client: in HttpClient,
    url: in String
  ): HttpResponseMessage
    requires: url.length > 0

  pub async func postString(
    client: in HttpClient,
    url: in String,
    body: in String,
    contentType: in String
  ): HttpResponseMessage
    requires: url.length > 0
    requires: contentType.length > 0

  pub func statusCode(response: in HttpResponseMessage): Int

  pub async func readBodyText(response: in HttpResponseMessage): String
  pub async func readBodyBytes(response: in HttpResponseMessage): slice[Byte]
}
