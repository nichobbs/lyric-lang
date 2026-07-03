# Docker Client Library Design (Sketch)

**Status:** Phase 1 shipped (D-progress-541); Phase 2 planned

**Requires:** Lyric 0.1.1+ with Unix socket support in `Std.Http` (PR #3863)

## Summary

A type-safe, production-ready Docker API client library for Lyric that connects to the Docker daemon via Unix domain sockets (Linux/macOS) or named pipes (Windows). The library abstracts HTTP details and provides idiomatic Lyric functions with `Result[T, Error]` return types.

## Design Principles

1. **Zero TLS overhead** — Use Unix sockets for local daemon access, eliminating TLS ceremony.
2. **Type-safe by default** — Generated bindings from Docker's OpenAPI spec provide compile-time safety.
3. **Async-first** — All I/O operations are async; integrates naturally with Lyric's concurrency model.
4. **Ergonomic error handling** — `Result[T, DockerError]` with detailed error context.
5. **Cross-platform** — Single codebase: Unix sockets on Linux/macOS, named pipes on Windows.

## Architecture

```
lyric-docker/
├── src/
│   ├── docker.l               # High-level API (ping, systemInfo, list*)
│   ├── docker_api.l           # Generated from OpenAPI spec (Phase 2)
│   ├── sockets.l              # Connection helpers (Unix/Windows)
│   ├── _kernel/
│   │   ├── docker_kernel_net.l  # .NET extern boundary (if needed)
│   │   └── docker_kernel_jvm.l  # JVM extern boundary (Phase 6)
│   └── types.l                # Shared types (Container, Image, etc.)
└── tests/
    └── basic_operations_tests.l
```

### Packages

- **Docker** — Public API entry point; convenience functions.
- **Docker.Sockets** — Connection helpers (Unix socket / named pipe routing).
- **Docker.Api** — Generated client from OpenAPI spec (Phase 2).
- **Docker.Types** — Shared types (Container, Image, Network, etc.) (Phase 2).
- **Docker.Kernel.Net** — .NET extern boundary (Phase 2, if needed).
- **Docker.Kernel.Jvm** — JVM extern boundary (Phase 6).

## Phase 1 (Shipped)

### Connection

Three ways to connect:

1. **Standard Docker (priority order):**
   ```lyric
   val client = Docker.makeDockerClient()
   ```
   Automatically checks:
   - `DOCKER_HOST` environment variable (if set to `unix://` URL)
   - `/var/run/docker.sock` (default location)
   - `$XDG_RUNTIME_DIR/docker.sock` (rootless mode fallback)

2. **Rootless Docker (explicit):**
   ```lyric
   match Docker.makeRootlessDockerClient() {
     case Ok(client) -> // ...
     case Err(e) -> // $XDG_RUNTIME_DIR not set
   }
   ```

3. **Custom path:**
   ```lyric
   val client = Docker.makeDockerClientAt("/custom/docker.sock")
   ```

### DOCKER_HOST Support

The `DOCKER_HOST` environment variable is automatically detected and takes precedence:

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
lyric run examples/docker_client.l
```

Supported formats:
- `unix:///absolute/path/docker.sock` — Unix socket (absolute path)
- `unix://relative/docker.sock` — Unix socket (relative path)

### Basic Operations

- `ping(client)` — Test connectivity
- `systemInfo(client)` — Docker version and system info
- `listContainers(client)` — List containers (JSON)
- `listImages(client)` — List images (JSON)

### Error Handling

```lyric
pub record DockerError {
  pub val statusCode: Option[Int]
  pub val message: String
  pub val details: String  // Docker response body
}
```

All operations return `Result[T, DockerError]`.

## Phase 2 (Planned)

### Generated API Bindings

Use `lyric openapi` to generate typed client from Docker's OpenAPI 3.x spec:

```bash
curl -L https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json \
  -o docker-api-spec.json

lyric openapi docker-api-spec.json \
  -o lyric-docker/src/docker_api.l \
  --client-name DockerEngineClient \
  --package Docker.Api
```

This replaces JSON responses with strongly-typed records:

```lyric
pub record Container {
  pub val id: String
  pub val image: String
  pub val status: String
  pub val names: List[String]
  pub val ports: List[Port]
  // ... additional fields
}

pub async func createContainer(
  client: in HttpClient,
  config: in CreateContainerRequest
): Result[CreateContainerResponse, DockerError]
```

### Typed Operations

- **Containers:** `createContainer`, `startContainer`, `waitContainer`, `stopContainer`, `removeContainer`, `inspectContainer`, `getContainerLogs`, `execContainer`
- **Images:** `pullImage`, `buildImage`, `pushImage`, `removeImage`, `inspectImage`, `tagImage`
- **Networks:** `createNetwork`, `listNetworks`, `inspectNetwork`, `removeNetwork`, `connectNetwork`, `disconnectNetwork`
- **Volumes:** `createVolume`, `listVolumes`, `inspectVolume`, `removeVolume`, `pruneVolumes`
- **System:** `getInfo`, `getVersion`, `getEvents`, `prune`

### Response Types

```lyric
pub record SystemInfo {
  pub val serverVersion: String
  pub val os: String
  pub val architecture: String
  pub val containerCount: Int
  pub val imageCount: Int
  // ... additional fields
}

pub record ContainerCreateResponse {
  pub val id: String
  pub val warnings: List[String]
}

pub record Port {
  pub val ip: Option[String]
  pub val privatePort: Int
  pub val publicPort: Option[Int]
  pub val type: String  // "tcp" or "udp"
}
```

## Phase 3 (Future)

### Advanced Features

- **Streaming logs:** `tailContainerLogs(client, containerId): AsyncSeq[String]`
- **Event subscriptions:** `subscribeToEvents(client): AsyncSeq[DockerEvent]`
- **Compose support:** Deploy multi-container applications
- **Swarm management:** Service, stack, and node operations

### Progress Tracking

Open questions:

- **Q-D-001:** Should we auto-generate the OpenAPI client, or hand-write it for better ergonomics?
  - **Draft:** Auto-generate via `lyric openapi` in a CI step; check generated code into repo for reproducibility.
- **Q-D-002:** How to handle streaming responses (container logs, events)?
  - **Draft:** Use `AsyncSeq[T]` or lazy iterators; defer until Phase 3.
- **Q-D-003:** Windows named pipe support — should this be Phase 2 or Phase 3?
  - **Draft:** Phase 2; requires `System.IO.Pipes.NamedPipeClientStream` externs in `_kernel/net/`.

## Implementation Notes

### Unix Socket Routing

`Docker.Sockets.makeDockerClient()` returns:

```lyric
Std.Http.clientWithUnixSocket("/var/run/docker.sock")
```

This leverages `Std.Http.clientWithUnixSocket()` added in PR #3863, which configures `SocketsHttpHandler.ConnectCallback` to route HTTP requests through Unix domain sockets.

### API Versioning

Docker's API versioning scheme:
- `/v1.40/` — Docker 19.03 LTS (minimum supported)
- `/v1.41/` — Docker 20.10
- `/v1.42/` — Docker 20.10.x
- Latest is negotiated via `GET /version` response `ApiVersion` field

Phase 1 hardcodes `/v1.40/`; Phase 2 negotiates the version dynamically.

### Error Classification

Docker HTTP error responses follow a predictable shape:

```json
{
  "message": "error description",
  "detail": "optional additional context"
}
```

`DockerError` unpacks this into:
- `statusCode` — HTTP status (4xx, 5xx)
- `message` — docker.message field
- `details` — docker.detail field (or full response if not JSON)

### Async/Await Integration

All network I/O is `async`:

```lyric
val response = await Docker.listContainers(client)
```

This allows Lyric's virtual thread scheduler to park the carrier thread on I/O without blocking, enabling high concurrency.

## Testing Strategy

### Unit Tests

`tests/basic_operations_tests.l` (Phase 1):
- `testPingDockerDaemon()` — connectivity check
- `testGetSystemInfo()` — system info retrieval
- `testListContainers()` — container listing
- `testListImages()` — image listing
- `testRootlessDockerConnection()` — rootless mode (skipped if not available)

Run with:
```bash
lyric test --manifest lyric-docker/lyric.toml
```

### Integration Tests (Phase 2+)

Full end-to-end tests that:
1. Create a test container
2. Start/stop it
3. Inspect logs
4. Remove it
5. Verify cleanup

Gated on `DOCKER_AVAILABLE=1` environment variable.

### CI Integration

- Docker-in-Docker (dind) to run tests in CI
- Minimal test image: `alpine:latest`
- Timeout: 30s per test

## References

- Docker Engine API: https://docs.docker.com/engine/api/
- Docker API OpenAPI spec: https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json
- Docker Go client source: https://github.com/moby/moby/tree/master/client
- PR #3863: Unix socket support in Std.Http
- docs/54-docker-client-library-sketch.md (this file)

## Deployment

`lyric-docker` ships as a NuGet package bundled with Lyric releases:

```toml
[dependencies]
"Lyric.Docker" = { version = "0.1.0", workspace = true }
```

Or, consume directly from the repository in development:

```toml
[dependencies]
"Lyric.Docker" = { path = "../lyric-docker" }
```
