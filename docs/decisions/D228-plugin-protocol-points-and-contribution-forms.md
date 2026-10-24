# D228 - Plugin protocol points (docs/69 P4): supervised sessions, routing through grants, and the `each`/`key` contribution forms

**Status:** shipped. Extends D207; implements docs/69 §4.3 and §14.

## Context

D207 shipped plugin points in process and wasm mode, but a protocol point
(docs/69 §4.3) only had `openProtocolPlugin`, which returned a process nothing
supervised, and offered no way for the host to apply a plugin's grants to the
requests that arrive in the plugin's own protocol. Three further gaps stopped an
LSP host from working at all:

- `Std.Process` piped children were read and written in lines only, so LSP's
  Content-Length framing could not cross the pipe.
- `RpcPeer.call` queued the other side's requests until its own response
  arrived. An LSP client calling `workspace/executeCommand` therefore deadlocked
  against a server that sends `workspace/applyEdit` first.
- `Std.Console.readLine` caught a host `Bug` in the public module, so no
  `--target native` program that read lines could be built (D-N-003), protocol
  plugins included.

docs/69 §14 also specified two wire forms that had not been built.

## Decision

1. **Supervised protocol sessions.** `Std.Plugin` gains `ProtocolSession`,
   created by `openProtocolSession(host, pointId, pluginId)` or the generated
   `open<P>Session(host, pluginId)`.
   - `protocolProcess(session)` returns the running process. When the process
     has exited, it counts a crash and restarts the plugin with process mode's
     backoff and `maxRestarts` limit.
   - Each start increments `session.generation`, which tells the client to repeat
     its protocol's handshake.
   - `closeProtocolSession` stops the process without counting a crash, and so
     does `stopPlugin`.
   - A second session on a running plugin is `Protocol`, and so is `callPlugin`
     on a protocol point.
   - `openProtocolPlugin` stays as the unsupervised form.
   - The session reuses the plugin's `PluginProcessState`, so crash accounting
     and shutdown are the same code as process mode.
2. **One point per protocol plugin.** A plugin implementing a protocol point
   implements no other point; `registerPlugin` refuses such a manifest as
   `ManifestInvalid`. Its stdin and stdout carry its own protocol, so the
   process cannot also serve `plugin/hello` and point calls.
3. **Routing through grants.** `callCapabilityAs(host, pluginId, method, params)`
   runs the exact path a plugin's own `cap/...` call takes: grant lookup,
   revocation, the generated server with its `requires:` guards, and the
   provider.
   - `Lyric.PluginExpand` generates a typed `<C>As { host, pluginId }` record per
     capability, with the same methods as `<C>Client`.
   - Capabilities on a protocol point are therefore enforced wherever the host
     routes a request through them, with no protocol-specific code in
     `Std.Plugin`.
   - A plugin of any point can be served this way.
4. **No handshake on a protocol channel.** The grants decided at registration
   are the ones `callCapabilityAs` applies. No `plugin/hello` is sent, since the
   protocol owns the channel.
5. **Byte-level piped I/O.** `Std.Process` gains `pipedReadBytes`,
   `pipedReadBytesWithin` and `pipedWriteBytes` on all three kernels, and
   `lyric-rt` gains `lyric_process_piped_read_bytes_within` and
   `lyric_process_piped_write_bytes` (POSIX, Win32 and the wasm32 stubs).
   - Line and byte reads share one buffer of the child's stdout, so they mix
     freely on every target and nothing is lost.
   - Rejecting a mix was the alternative. It was not chosen because handing a
     stream to a framing after reading a line-oriented banner is a real use.
   - `Std.JsonRpc.Stdio` gains `newContentLengthTransportOverProcess` and
     `newNdjsonTransportOverProcess`.
   - The dotnet kernel now reads stdout as raw bytes. As a consequence a lone
     `\r` no longer ends a line, matching the JVM and native kernels, and stdout
     is always decoded as UTF-8.
6. **Serving while a call waits.** `setServeDuringCall(peer, true)` makes `call`
   dispatch the requests and notifications that arrive while it waits. A batch
   is answered as one batch.
   - The default stays queueing, so `lyric-mcp` and the plugin runtime are
     unchanged.
   - The alternative was an LSP-specific transport that answers requests itself,
     as `Std.Plugin`'s child transport does for `cap/...`. It was rejected
     because the deadlock is a JSON-RPC property, not an LSP one.
7. **`Std.Console.readLine` on native.** Each console kernel gains
   `hostReadLineResult`, and `readLine` matches on it. The managed kernels catch
   the host failure; the native kernel returns it as an `Err`.
8. **`contributes[T] each name = e`.** `e` is a `List[T]` that joins the
   collection as one entry.
   - Ordering clauses, `remove`, `reorder` and replacement act on the whole
     block. An empty list contributes nothing.
   - `each` and `key` are contextual words: `contributes[T] each = e` is an entry
     named `each`.
   - The expansion builds the list in a generated package-private function, so
     neither backend needs new codegen.
9. **Keyed contributions, `contributes[T] key "k" name = e`.** These also make
   `T` available as `<T>ByKey: Map[String, T]`.
   - A keyed entry stays in the ordered list, so the list and the map agree.
   - The key must be a plain string literal (**P0348**).
   - `each` and `key` cannot be combined (**P0349**), because a key names one
     value.
   - A key repeated for one type is **W0028**. A binding named `<T>ByKey` is
     **W0020**, reusing the collection-clash code.

## Consequences

- `examples/plugins/lsp` is a complete editor and language server.
  `scripts/ci/plugin-lsp-e2e.sh` runs it with dotnet and JVM hosts.
  `scripts/ci/plugin-protocol-e2e.sh` covers sessions and routing on every pair
  of dotnet, JVM and native hosts with dotnet, JVM, native and wasm plugins.
- Two problems found on the way predate this work and stay open:
  - Wire member initialisers are not type-checked, so an `each` entry whose
    value is not a `List[T]` fails at run time rather than at compile time.
  - A dotted reference to a collection inside a template under an aliased
    include (`Mw.count`) is not renamed.
- The Win32 byte-I/O functions compile in the Windows CI job; they could not be
  compiled where this was written.
