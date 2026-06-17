//! Docker Engine API v1.40+ client bindings (generated).
//!
//! This module contains type-safe Lyric bindings for the Docker Engine REST API.
//! The bindings are generated from Docker's OpenAPI 3.x specification using:
//!
//!   lyric openapi docker-api-spec.json \
//!     -o src/docker_api.l \
//!     --client-name DockerEngineClient \
//!     --package Docker.Api
//!
//! Generation is a one-time manual step; regenerate when updating the Docker
//! API specification version.
//!
//! API Documentation: https://docs.docker.com/engine/api/v1.40/
//! OpenAPI Spec: https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json
//!
//! Phase 1 (current): Core container and image operations.
//! Phase 2: Volume, network, service, and compose operations.
//! Phase 3: Advanced diagnostics, logs streaming, and event subscriptions.

@runtime_checked
package Lyric.Docker.Api

import Std.Http
import Std.Json
import Std.Core

// Placeholder: Docker API types and client operations would be generated here.
// See: docs/54-docker-client-library-sketch.md (planned) for the full API surface.
//
// Generated operations will include:
//   - Containers: list, create, start, stop, remove, inspect, logs, exec
//   - Images: list, pull, push, build, remove, inspect, tag
//   - Networks: create, list, inspect, remove, connect, disconnect
//   - Volumes: create, list, inspect, remove
//   - System: info, version, ping
//   - Events: stream and subscribe to daemon events

/// Placeholder Docker API response type.
/// In the generated client, this would be replaced with strong-typed
/// container, image, and system response types from the OpenAPI spec.
pub record DockerResponsePlaceholder {
  /// Container or image ID (placeholder).
  pub val id: String
  /// Human-readable name (placeholder).
  pub val name: String
}

/// Placeholder: Connect to Docker and get system info.
/// This demonstrates the shape of generated API operations.
/// In Phase 1, we would generate proper operations for:
///   - GET /v1.40/containers/json
///   - POST /v1.40/containers/create
///   - GET /v1.40/images/json
///   - etc.
pub async func getSystemInfo(client: in Std.Http.HttpClient): Result[String, Std.Http.HttpError] {
  val response = await Std.Http.sendAsync(
    Std.Http.request(Std.Http.GET,
      Std.Http.Url.tryFrom("http://docker/v1.40/info") |> assertOk()
    )
  ) |> (match _ {
    case Err(e) -> return Err(error = e)
    case Ok(r) -> r
  })

  if Std.Http.HttpResponse.isSuccess(response) {
    await Std.Http.HttpResponse.bodyText(response) |> (match _ {
      case Err(e) -> return Err(error = Std.Http.ConnectionFailed(url = "http://docker/v1.40/info", message = e.message))
      case Ok(body) -> Ok(value = body)
    })
  } else {
    Err(error = Std.Http.BadStatus(
      url = "http://docker/v1.40/info",
      statusCode = Std.Http.HttpResponse.statusCode(response)
    ))
  }
}
