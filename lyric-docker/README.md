# lyric-docker — Docker API Client for Lyric

A type-safe Docker API client for Lyric, built on Unix domain socket support in `Std.Http`.

## Overview

`lyric-docker` provides convenient, strongly-typed access to the Docker daemon via the Docker Engine REST API. It abstracts away HTTP details and provides intuitive Lyric-idiomatic functions for common operations.

### Features (Phase 1)

- ✅ Unix socket connections (Linux/macOS)
- ✅ Rootless Docker support
- ✅ System info and ping operations
- ✅ Container and image listing
- ✅ Error handling via `Result[T, DockerError]`

### Planned Features (Phase 2+)

- Strongly-typed container and image operations (from OpenAPI spec generation)
- Volume, network, and service management
- Event subscriptions and log streaming
- Windows named pipe support

## Installation

Add to your `lyric.toml`:

```toml
[dependencies]
"Lyric.Docker" = { workspace = true }
```

## Quick Start

```lyric
import Lyric.Docker
import Lyric.Docker.Sockets
import Std.Core

pub func main(): Int {
  val client = Lyric.Docker.makeDockerClient()
  
  match await Lyric.Docker.ping(client) {
    case Ok(_) -> {
      println("✓ Connected to Docker")
      match await Lyric.Docker.systemInfo(client) {
        case Ok(info) -> println("System: " + info)
        case Err(e) -> println("Error: " + e.message)
      }
      0
    }
    case Err(e) -> {
      println("✗ Docker connection failed: " + e.message)
      1
    }
  }
}
```

## Connection

### Standard Docker (Recommended)

```lyric
val client = Lyric.Docker.makeDockerClient()
```

This automatically follows the standard Docker connection priority:
1. `DOCKER_HOST` environment variable, if set:
   - a `tcp://host:port` URL routes to `makeDockerClientTcp` (validating `host:port` — see below);
   - a `unix://` URL routes to the named Unix socket.
2. Standard location `/var/run/docker.sock` (Linux/macOS)
3. Rootless location `$XDG_RUNTIME_DIR/docker.sock` (if available)

A `tcp://` `DOCKER_HOST` is never silently ignored: it used to fall through to
the default Unix socket when set, which meant `makeDockerClient()` connected
to the wrong daemon (or none) with no error. It now always routes to the TCP
client.

`DOCKER_HOST` is environment input, not a programming error, so a malformed
`tcp://` value is reportable rather than fatal:

```lyric
pub func tryMakeDockerClient(): Result[DockerClient, DockerError]
pub func makeDockerClient(): DockerClient
```

`tryMakeDockerClient` returns `Err` (naming `DOCKER_HOST` and the bad value)
for a malformed `tcp://host:port` — one that fails `isHostPort` — instead of
tripping `makeDockerClientTcp`'s own precondition. `makeDockerClient`
delegates to it and `panic`s with that same message on `Err`; use
`tryMakeDockerClient` directly when a malformed `DOCKER_HOST` should be
handled rather than crash the process.

### Specifying Docker Host via Environment Variable

Set `DOCKER_HOST` to override the default socket location:

```bash
export DOCKER_HOST=unix:///custom/docker.sock
export DOCKER_HOST=tcp://127.0.0.1:2375
```

Supported formats:
- `unix:///path/to/docker.sock` — Unix socket (absolute path)
- `unix://docker.sock` — Unix socket (relative path)
- `tcp://host:port` — TCP, routed to `makeDockerClientTcp` (see "TCP Connections" below)

Named pipe transport is planned for a future release.

### TCP Connections

```lyric
val client = Lyric.Docker.makeDockerClientTcp("127.0.0.1:2375")
```

`hostPort` must satisfy `isHostPort`: a hostname, IPv4 literal, or bracketed
IPv6 literal (`[::1]`), followed by `:` and a port `1..=65535`. This rejects
`/`, `?`, `@`, an embedded scheme, or anything else that would inject into
the client's request base URL — `makeDockerClientTcp` panics rather than
building a client against an unintended endpoint.

```lyric
pub func isHostPort(hostPort: in String): Bool
```

### Rootless Docker

```lyric
match Lyric.Docker.makeRootlessDockerClient() {
  case Ok(client) -> // Use client...
  case Err(e) -> println("Error: " + e)
}
```

Explicitly targets `$XDG_RUNTIME_DIR/docker.sock` for rootless Docker. Use this when you want to ensure rootless mode is used and get an error if it's not available.

### Custom Socket Path

```lyric
val client = Lyric.Docker.makeDockerClientAt("/custom/path/docker.sock")
```

## API Surface

### System Operations

- `ping(client)` — Verify Docker daemon connectivity
- `systemInfo(client)` — Get system information and Docker version

### Container IDs

Every function that takes a container reference (start/stop/wait/remove/logs)
takes a validated `ContainerId`, not a raw `String`. Obtain one from
`createContainer`/`createContainerWithNetwork` (which return
`Result[ContainerId, DockerError]`), or validate a caller-supplied ID or name
(from user input, a config file, or a prior `docker ps`) yourself:

```lyric
pub opaque type ContainerId
pub func ContainerId.tryFrom(raw: in String): Result[ContainerId, DockerError]
pub func ContainerId.toString(id: in ContainerId): String
```

`ContainerId.tryFrom` accepts exactly the shapes the Docker Engine API
accepts as a container reference:
- a full 64-character hex ID (SHA-256);
- a unique hex prefix of any other length;
- a container name (`[a-zA-Z0-9][a-zA-Z0-9_.-]+`).

`isValidContainerId` (the fixed-length 12-or-64-char lowercase-hex check)
is deprecated in favor of `ContainerId`: it rejects a valid hex prefix of
any other length and rejects every container name outright. It is kept for
source compatibility.

### Container Operations

- `listContainers(client)` — List all containers
- `createContainer(client, image, env, binds)` — Create a container from an image with env vars and volume binds, using the Docker default network. Returns the new container's validated `ContainerId`.
- `createContainerWithNetwork(client, image, env, binds, networkMode)` — Create a container, additionally pinning its NetworkMode (e.g. `"none"` for full isolation, or a named Docker network); an empty `networkMode` keeps the Docker default. Also validates `image`/`env`/`binds` up front (see "Container creation preconditions" below).
- `startContainer(client, containerId)` — Start a created container
- `waitContainer(client, containerId, timeoutSec)` — Block until a container exits (or `timeoutSec` elapses); returns its exit code
- `stopContainer(client, containerId, timeoutSec)` — Stop a running container, giving it up to `timeoutSec` seconds to exit gracefully before Docker sends SIGKILL
- `removeContainer(client, containerId)` — Remove a container
- `getContainerLogs(client, containerId)` — Fetch a container's combined stdout/stderr logs
- Future: `inspectContainer`, `execContainer`, etc.

#### `waitContainer`/`stopContainer` timeouts

Both take `timeoutSec: in Int` with `requires: timeoutSec > 0`; `waitContainer` also requires `timeoutSec <= 2147483` (the cancellation timer is in milliseconds).

- `stopContainer`'s `timeoutSec` is Docker's own graceful-stop grace period
  (the `/stop` endpoint's `t` query parameter): Docker sends SIGTERM, waits
  up to `timeoutSec` seconds, then sends SIGKILL.
- `waitContainer`'s underlying `/wait` endpoint blocks server-side for as
  long as the container runs, so there is no server-side bound to pass
  through. `timeoutSec` instead bounds the *client-side* wait for a
  response, via the connection's own `sendWithCancel` — it cancels the
  pending HTTP request once `timeoutSec` elapses, surfacing as `Err`. It
  does not, and cannot, stop the container itself or bound how long the
  daemon takes to notice the container exited.

#### Container creation preconditions

`createContainerBodyWithNetwork` (and `createContainer`/
`createContainerWithNetwork`, which call it) requires:
- `image` is non-empty;
- every `env` entry contains `=` (`KEY=VALUE` shape);
- every `binds` entry is shaped `src:dst` or `src:dst:mode`, with every
  colon-separated part non-empty.

A violation panics rather than sending a malformed request body to Docker.

### Image Operations

- `listImages(client)` — List all images
- Future: `pullImage`, `pushImage`, `buildImage`, `removeImage`, etc.

## Roadmap

**Phase 1 (Current):** Core convenience wrappers over basic Docker API endpoints.

**Phase 2:** Generate strongly-typed API bindings from Docker's OpenAPI 3.x specification using `lyric openapi`:

```bash
# Download Docker's OpenAPI spec
curl -L https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json \
  -o docker-api-spec.json

# Generate Lyric bindings
lyric openapi docker-api-spec.json \
  -o lyric-docker/src/docker_api_generated.l \
  --client-name DockerEngineClient \
  --package Docker.Api.Generated
```

**Phase 3:** Advanced operations (events, logs streaming, compose, Swarm).

## Examples

See `examples/docker/` for runnable examples (coming soon):

- `list_containers.l` — List and inspect containers
- `pull_and_run.l` — Pull an image and run a container
- `health_check.l` — Monitor container health

## Error Handling

All API operations return `Result[T, DockerError]` with detailed error information:

```lyric
pub record DockerError {
  pub val statusCode: Option[Int]    // HTTP status code if available
  pub val message: String             // Human-readable error message
  pub val details: String             // Docker response body or additional context
}
```

## Demultiplexing container logs

`getContainerLogs` runs a non-TTY container's raw `/logs` bytes through
`demultiplexDockerStream(bytes: in slice[Byte]): Result[String, String]`,
which decodes Docker's framed stdout/stderr multiplex format. It returns
`Err` when:
- the buffer ends with a truncated frame (a header shorter than 8 bytes, or
  a header whose declared size runs past the end of the buffer) — this used
  to be silently treated as a clean end of stream, returning `Ok` with
  whatever output preceded the truncation;
- a frame's stream-type byte is neither `1` (stdout) nor `2` (stderr) — this
  used to be silently skipped rather than treated as malformed input;
- the accumulated output exceeds a 64 MiB cap (`maxDemultiplexedStreamBytes`)
  — there was previously no cap on total decoded output.

## Unix Socket Support

`lyric-docker` depends on Unix socket support in `Std.Http.clientWithUnixSocket()`, which is available in Lyric 0.1.1+. This enables direct connection to the Docker daemon without needing TCP networking or TLS certificates.

### How It Works

1. Creates an `HttpClient` connected to `/var/run/docker.sock` via `System.Net.Sockets.UnixDomainSocketEndPoint`
2. Routes all HTTP requests through the Unix socket
3. Parses JSON responses and presents typed Lyric results

## License

Apache 2.0 (same as the Lyric project)

## See Also

- [Docker Engine API Reference](https://docs.docker.com/engine/api/)
- [Docker OpenAPI Specification](https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json)
- [Lyric Std.Http Unix Socket Support](../lyric-stdlib/std/http.l)
