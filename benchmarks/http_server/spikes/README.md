# docs/73 S0 spikes (throwaway, not shipped)

Evidence for `docs/progress/2026-11-24-http-server-baseline.md`. Nothing here is imported by product code.

- `split/` - spike (a): a reduced shared driver (`Std.SpikeServer`) over a three-target kernel seam
  (`Std.SpikeServerHost`), loaded through `LYRIC_STD_PATH` on the dotnet, JVM and native stdlib source
  loaders, then built per package. Run `split/run.sh`.
- `pinning/` - spike (b): a TLS echo server over `Std.TcpHost` on the JVM and a client fleet, run with
  `-Djdk.tracePinnedThreads=full` and with a one-carrier virtual-thread scheduler. Run `pinning/pinning.sh`.
- `crosserror/` - spike (c): the cross-error-type nested match of `lyric-web/src/web.l` (~2455) in its exact shape and in a two-package variant. Run `crosserror/run.sh`; it prints the expected results on a compiler without the miscompile.
