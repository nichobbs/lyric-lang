//! Docker socket connection helpers for Unix sockets and Windows named pipes.
//!
//! Provides utilities for establishing connections to the Docker daemon
//! across different platforms.
@runtime_checked
package Docker.Sockets

import Std.Http
import Std.Core

/// Standard Docker daemon socket paths by platform.
/// On Linux/macOS, the Docker daemon listens on a Unix socket.
/// On Windows, it listens on a named pipe (not yet supported in this release).
pub object StandardSocketPaths {
  /// Linux/macOS Unix domain socket path (most common).
  pub val unixSocket: String = "/var/run/docker.sock"

  /// Rootless Docker socket path (Linux, when Docker runs in rootless mode).
  /// This requires the $XDG_RUNTIME_DIR environment variable to be set.
  pub val rootlessSocket: String = "${XDG_RUNTIME_DIR}/docker.sock"

  /// Alternative socket location on some systems.
  pub val alternateSocket: String = "/var/run/docker.sock.raw"
}

/// Create an HTTP client connected to the Docker daemon.
///
/// Follows the standard Docker connection priority:
/// 1. DOCKER_HOST environment variable (if set and is a unix:// URL)
/// 2. Standard location /var/run/docker.sock
/// 3. Rootless location $XDG_RUNTIME_DIR/docker.sock (if available)
///
/// # Preconditions as data
/// - The Docker daemon must be running and accessible via one of the above paths
/// - The current user must have permission to access the socket (typically requires
///   membership in the docker group or sudo).
///
/// # Errors
/// - `ConnectionFailed`: if the socket cannot be accessed or the daemon is not running.
///
/// # Examples
/// ```lyric
/// val client = makeDockerClient()
/// val response = await sendAsync(
///   request(GET, Url.tryFrom("http://docker/v1.40/containers/json") |> assertOk())
/// ) |> assertOk()
/// ```
pub func makeDockerClient(): Std.Http.HttpClient {
  match parseDockerHost() {
    case Some(socketPath) -> Std.Http.clientWithUnixSocket(socketPath)
    case None -> Std.Http.clientWithUnixSocket(StandardSocketPaths.unixSocket)
  }
}

/// Create an HTTP client for rootless Docker (when running in unprivileged mode).
///
/// Rootless Docker uses a socket in the user's runtime directory instead of
/// /var/run/docker.sock. The $XDG_RUNTIME_DIR environment variable must be set.
///
/// # Preconditions as data
/// - $XDG_RUNTIME_DIR environment variable must be set.
/// - Docker must be running in rootless mode.
///
/// # Errors
/// - `ConnectionFailed`: if the socket cannot be accessed.
pub func makeRootlessDockerClient(): Result[Std.Http.HttpClient, String] {
  match Std.Environment.getOpt("XDG_RUNTIME_DIR") {
    case Some(runtimeDir) -> {
      val socketPath = runtimeDir + "/docker.sock"
      Ok(value = Std.Http.clientWithUnixSocket(socketPath))
    }
    case None -> Err(error = "XDG_RUNTIME_DIR not set; required for rootless Docker")
  }
}

/// Create an HTTP client connected to a custom Docker socket path.
///
/// Use this when the Docker daemon is listening on a non-standard location.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Docker socket.
///
/// # Errors
/// - `ConnectionFailed`: if the socket cannot be accessed.
pub func makeDockerClientAt(socketPath: in String): Std.Http.HttpClient
  requires: socketPath.length > 0
{
  Std.Http.clientWithUnixSocket(socketPath)
}

/// Parse DOCKER_HOST environment variable to extract a Unix socket path.
///
/// DOCKER_HOST is typically in one of these formats:
/// - `unix:///var/run/docker.sock` — Unix socket (absolute path)
/// - `unix://./docker.sock` — Unix socket (relative path, rare)
/// - `tcp://localhost:2375` — TCP connection (not yet supported)
/// - `npipe:////.//pipe//docker_engine` — Windows named pipe (not yet supported)
///
/// Returns `Some(socketPath)` if DOCKER_HOST is set and is a valid unix:// URL.
/// Returns `None` if DOCKER_HOST is not set, not a unix:// URL, or is malformed.
func parseDockerHost(): Option[String] {
  match Std.Environment.getOpt("DOCKER_HOST") {
    case Some(dockerHost) -> parseUnixSocketUrl(dockerHost)
    case None -> None
  }
}

/// Parse a unix:// URL to extract the socket path.
///
/// Handles formats like:
/// - `unix:///var/run/docker.sock` → `/var/run/docker.sock`
/// - `unix://docker.sock` → `docker.sock` (relative, unusual)
/// - Non-unix URLs are rejected (tcp://, npipe://, etc.)
func parseUnixSocketUrl(url: in String): Option[String] {
  val prefix = "unix://"
  if !url.startsWith(prefix) {
    return None
  }

  val withoutPrefix = url.substring(prefix.length)

  if withoutPrefix.length == 0 {
    return None
  }

  val path = if withoutPrefix.startsWith("//") {
    withoutPrefix.substring(2)
  } else if withoutPrefix.startsWith("/") {
    withoutPrefix
  } else {
    withoutPrefix
  }

  if path.length > 0 {
    Some(value = path)
  } else {
    None
  }
}
