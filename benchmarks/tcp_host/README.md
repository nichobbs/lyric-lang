# Std.TcpHost loopback benchmark

`tcp_loopback.l` measures the `Std.TcpHost` transport on its own (no HTTP above it): a server
task echoes every chunk and the main thread is the client, over `127.0.0.1` on an ephemeral
port. It is the B1 microbenchmark of `docs/73-jvm-pure-lyric-server-plan.md` and is not part of
CI.

It prints one `key=value` line per measurement:

- `tcp.ping_us`: mean round trip of a 1-byte message in microseconds (lower is better);
- `tcp.echo_<size>_mib_s`: MiB/s of payload echoed with messages of 64, 1024, 16384 and 262144
  bytes (higher is better).

Each figure is the best of three rounds after a warm-up pass, so JIT time is excluded.

## Running

```sh
lyric run benchmarks/tcp_host/tcp_loopback.l --target dotnet
lyric run benchmarks/tcp_host/tcp_loopback.l --target jvm
lyric run benchmarks/tcp_host/tcp_loopback.l --target native   # needs clang and lyric-rt
```

Run each target on an otherwise idle machine and compare the lines. The acceptance bar of
docs/73 slice S1 is that the JVM figures are no worse than twice the dotnet figures (latency at
most twice, throughput at least half). The recorded numbers are in
`docs/progress/2026-11-19-tcphost-server-ready.md`.
