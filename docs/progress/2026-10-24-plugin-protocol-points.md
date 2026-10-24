# Plugins P4: protocol points, an LSP host, and the `each`/`key` contribution forms (D228)

- **Protocol sessions** (`Std.Plugin`):
  - `ProtocolSession`, with `openProtocolSession`, `protocolProcess` and
    `closeProtocolSession`, supervises a protocol plugin with process mode's
    restart rules. `generation` changes with each start.
  - `callCapabilityAs` applies a plugin's grant, revocations and guards to a
    request that reached the host in the plugin's own protocol.
  - A protocol plugin implements that one point.
  - `Lyric.PluginExpand` generates `<C>As` per capability and `open<P>Session`
    per protocol point.
- **LSP example**: `examples/plugins/lsp`.
  - The editor (`Editor.Lang` API and `Editor.Host`) hosts a TODO language
    server whose `workspace/applyEdit` requests go through the `WorkspaceEdit`
    capability: granted, refused by the guard, and revoked.
  - `scripts/ci/plugin-lsp-e2e.sh` passes its 12 checks with dotnet and JVM
    hosts.
- **Byte-level piped I/O**:
  - `Std.Process`: `pipedReadBytes`, `pipedReadBytesWithin` and
    `pipedWriteBytes` on dotnet, JVM and native. Line and byte reads share one
    buffer.
  - `Std.JsonRpc.Stdio`: Content-Length and NDJSON transports over a child
    process.
  - `lyric-rt`: byte read and write functions on POSIX, Win32 and wasm32.
- **`Std.JsonRpc.setServeDuringCall`**: a waiting `call` answers the other
  side's requests. Without it an LSP client deadlocks.
- **`Std.Console.readLine` builds for `--target native`**, through a
  `hostReadLineResult` kernel seam.
- **Wire forms** (docs/01 §10.5):
  - `contributes[T] each name = e` contributes a list as one ordered block.
  - `contributes[T] key "k" name = e` adds `<T>ByKey: Map[String, T]`.
  - New diagnostics: P0348, P0349, W0028.
- **Tests**:

  | Suite | Result |
  |---|---|
  | `plugin_protocol_e2e_tests.l` | 9/9 on every host/plugin pair (dotnet, JVM, native hosts; dotnet, JVM, native, wasm plugins) |
  | `process_piped_bytes_tests.l` | 7 cases, on dotnet, JVM and native |
  | `json_rpc_tests.l` | 34/34 |
  | `wire_expand_self_test.l` | 55/55 |
  | `wire_templates_self_test.l` | 12/12 on dotnet and JVM |
  | `plugin_expand_self_test.l` | 43/43 |

- **CI**:
  - The protocol suite runs in `plugin-suites.sh`, the native job and the wasm32
    job.
  - The LSP example runs in `plugin-suites.sh`.
  - The byte-I/O suite runs in the dotnet, JVM and native stdlib steps.
- **Docs**:
  - D228; docs/69 §4.3, §8, §14 and §16; docs/01 §10.5 and §15.
  - Book chapters 11, 12 and 33, and appendix B.
