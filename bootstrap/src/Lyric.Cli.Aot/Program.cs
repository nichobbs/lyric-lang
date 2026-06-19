// Track A A1.3 entry point.  Pure trampoline into the Lyric-compiled
// CLI dispatcher (`Lyric.Cli.Program.main`).
//
// Contract (#1082): this file must NOT contain path-discovery, DLL
// location, or any other domain logic.  Its only job is to parse argv
// and trampoline.
//
// Historical context: an earlier `BootstrapCliShim` auto-discovered the
// F# bootstrap `lyric.dll` so the now-removed `emitProject` subprocess
// hop could find its handler.  That hop went in-process with #1183
// Phase 4 (commit a4f3a63), so the shim is no longer load-bearing and
// the AOT entry point is back to a pure trampoline.  Callers that need
// the F# bootstrap subprocess for other paths (`--target jvm`,
// `LYRIC_FORCE_SUBPROCESS=1`) must export `LYRIC_CLI_DLL` themselves.

namespace Lyric.Cli.Aot;

public static class Program
{
#if BOOTSTRAP_ENTRY
    // Stage-1 phase-1 bootstrap build: trampoline into the minimal
    // Lyric.CliBootstrap entry (build + internal per-package emit only).  Its
    // emitted closure stays under the legacy stage-0's 64 KB string-heap limit,
    // so stage-0 emits it correctly; the resulting heap-correct compiler then
    // re-emits the full Lyric.Cli closure.  See scripts/bootstrap.sh.
    public static int Main(string[] args) => Lyric.CliBootstrap.Program.main(args);
#else
    public static int Main(string[] args) => Lyric.Cli.Program.main(args);
#endif
}
