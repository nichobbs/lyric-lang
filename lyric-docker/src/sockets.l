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

/// Create an HTTP client connected to the standard Docker daemon Unix socket.
///
/// # Preconditions as data
/// - The Docker daemon must be running and listening on /var/run/docker.sock
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
  Std.Http.clientWithUnixSocket(StandardSocketPaths.unixSocket)
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
