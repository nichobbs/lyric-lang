//! Docker client — High-level API for Docker daemon operations.
//!
//! Provides convenience functions and types for interacting with the Docker daemon.
//! Abstracts away HTTP details and provides typed results via Result[T, DockerError].
//!
//! # Connection
//!
//! The Docker daemon is accessed via Unix domain sockets by default:
//!   - Linux/macOS: /var/run/docker.sock
//!   - Rootless Docker: $XDG_RUNTIME_DIR/docker.sock
//!   - Custom: specify via makeDockerClientAt()
//!
//! # Examples
//!
//! ```lyric
//! val client = Docker.makeDockerClient()
//! match await Docker.ping(client) {
//!   case Ok(version) -> println("Docker API version: " + version)
//!   case Err(e) -> println("Error: " + e.message)
//! }
//! ```
@runtime_checked
package Lyric.Docker

import Std.Http
import Std.Core
import Lyric.Docker.Api
import Lyric.Docker.Sockets

/// Docker error type — encapsulates HTTP errors with Docker-specific context.
pub record DockerError {
  /// HTTP status code (if available).
  pub val statusCode: Option[Int]
  /// Error message.
  pub val message: String
  /// Docker error details from response body (if available).
  pub val details: String
}

/// Create a new Docker error from an HTTP error.
func fromHttpError(httpError: in Std.Http.HttpError, details: in String = ""): DockerError {
  match httpError {
    case Std.Http.ConnectionFailed(url, message) ->
      DockerError(statusCode = None, message = message, details = details)
    case Std.Http.BadStatus(url, statusCode) ->
      DockerError(statusCode = Some(value = statusCode), message = "HTTP " + statusCode.toString(), details = details)
    case Std.Http.InvalidUrl(url) ->
      DockerError(statusCode = None, message = "Invalid Docker URL: " + url, details = details)
    case _ ->
      DockerError(statusCode = None, message = "Unknown Docker error", details = details)
  }
}

/// Connect to the Docker daemon using the default Unix socket.
pub func makeDockerClient(): Std.Http.HttpClient {
  Docker.Sockets.makeDockerClient()
}

/// Connect to the Docker daemon in rootless mode.
pub func makeRootlessDockerClient(): Result[Std.Http.HttpClient, DockerError] {
  match Docker.Sockets.makeRootlessDockerClient() {
    case Ok(client) -> Ok(value = client)
    case Err(message) -> Err(error = DockerError(statusCode = None, message = message, details = ""))
  }
}

/// Connect to the Docker daemon at a custom socket path.
pub func makeDockerClientAt(socketPath: in String): Std.Http.HttpClient
  requires: socketPath.length > 0
{
  Docker.Sockets.makeDockerClientAt(socketPath)
}

/// Ping the Docker daemon to verify connectivity.
///
/// Returns the Docker API version on success, or a DockerError on failure.
pub async func ping(client: in Std.Http.HttpClient): Result[String, DockerError] {
  val response = await Std.Http.sendAsync(
    Std.Http.request(Std.Http.GET,
      Std.Http.Url.tryFrom("http://docker/v1.40/ping") |> assertOk()
    )
  ) |> (match _ {
    case Err(e) -> return Err(error = fromHttpError(e))
    case Ok(r) -> r
  })

  if Std.Http.HttpResponse.isSuccess(response) {
    Ok(value = "connected")
  } else {
    val statusCode = Std.Http.HttpResponse.statusCode(response)
    match await Std.Http.HttpResponse.bodyText(response) {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "Ping failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          Std.Http.ConnectionFailed(url = "http://docker/v1.40/ping", message = ioErr.message)
        ))
    }
  }
}

/// Get Docker system information.
///
/// Returns JSON-formatted system info including Docker version, OS, and kernel info.
pub async func systemInfo(client: in Std.Http.HttpClient): Result[String, DockerError] {
  val response = await Docker.Api.getSystemInfo(client) |> (match _ {
    case Ok(body) -> Ok(value = body)
    case Err(httpErr) -> Err(error = fromHttpError(httpErr))
  })
  response
}

/// List all containers.
///
/// Phase 1 placeholder: Returns JSON array of container objects.
/// Phase 2 will provide typed Container records.
pub async func listContainers(client: in Std.Http.HttpClient): Result[String, DockerError] {
  val response = await Std.Http.sendAsync(
    Std.Http.request(Std.Http.GET,
      Std.Http.Url.tryFrom("http://docker/v1.40/containers/json") |> assertOk()
    )
  ) |> (match _ {
    case Err(e) -> return Err(error = fromHttpError(e))
    case Ok(r) -> r
  })

  if Std.Http.HttpResponse.isSuccess(response) {
    match await Std.Http.HttpResponse.bodyText(response) {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          Std.Http.ConnectionFailed(url = "http://docker/v1.40/containers/json", message = ioErr.message)
        ))
    }
  } else {
    val statusCode = Std.Http.HttpResponse.statusCode(response)
    match await Std.Http.HttpResponse.bodyText(response) {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "List containers failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          Std.Http.ConnectionFailed(url = "http://docker/v1.40/containers/json", message = ioErr.message)
        ))
    }
  }
}

/// List all images.
///
/// Phase 1 placeholder: Returns JSON array of image objects.
/// Phase 2 will provide typed Image records.
pub async func listImages(client: in Std.Http.HttpClient): Result[String, DockerError] {
  val response = await Std.Http.sendAsync(
    Std.Http.request(Std.Http.GET,
      Std.Http.Url.tryFrom("http://docker/v1.40/images/json") |> assertOk()
    )
  ) |> (match _ {
    case Err(e) -> return Err(error = fromHttpError(e))
    case Ok(r) -> r
  })

  if Std.Http.HttpResponse.isSuccess(response) {
    match await Std.Http.HttpResponse.bodyText(response) {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          Std.Http.ConnectionFailed(url = "http://docker/v1.40/images/json", message = ioErr.message)
        ))
    }
  } else {
    val statusCode = Std.Http.HttpResponse.statusCode(response)
    match await Std.Http.HttpResponse.bodyText(response) {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "List images failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          Std.Http.ConnectionFailed(url = "http://docker/v1.40/images/json", message = ioErr.message)
        ))
    }
  }
}
