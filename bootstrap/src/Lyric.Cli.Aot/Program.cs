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
    // LyricBuildVersion.Value is generated at compile time from MSBuild's
    // $(Version) property (see the GenerateLyricBuildVersion target in
    // Lyric.Cli.Aot.csproj) — a plain `ldstr` constant, not a runtime
    // attribute lookup, so it survives Native AOT trimming. Forwarding it as
    // an env var (rather than a new argv flag) keeps this file a pure
    // trampoline per the #1082 contract: no path-discovery or domain logic,
    // just relaying build metadata the self-hosted CLI can't otherwise see.
    //
    // The compiler is recursive over the syntax tree (the type checker, the
    // lowering passes and the emitters each descend one frame group per nesting
    // level), so the stack it needs grows with the depth of the user's
    // expressions: a 160-term `a + b + ...` chain is a 160-deep tree.  A
    // process's main-thread stack is whatever the platform gives it (1 MB on
    // Windows, `ulimit -s` elsewhere, 8 MB typically), which a legitimate
    // program can exceed, so the CLI runs on a thread whose stack is sized for
    // the compiler instead.  The size is address space reserved up front;
    // pages are committed as they are touched.
    const int CompilerStackBytes = 512 * 1024 * 1024;

    public static int Main(string[] args)
    {
        System.Environment.SetEnvironmentVariable("LYRIC_BUILD_VERSION", LyricBuildVersion.Value);
        int exitCode = 0;
        var worker = new System.Threading.Thread(
            () => { exitCode = Lyric.Cli.Program.main(args); },
            CompilerStackBytes);
        try
        {
            worker.Start();
        }
        catch (System.OutOfMemoryException)
        {
            // The address space (`ulimit -v`, a container limit) cannot hold
            // the reservation: run on the main thread's own stack instead.
            return Lyric.Cli.Program.main(args);
        }
        worker.Join();
        return exitCode;
    }
}
