// Track A A1.3 entry point.  Trivial trampoline into the Lyric-compiled
// CLI dispatcher.  The Lyric emitter publishes `Lyric.Cli.Program.main`
// as a public static `int main(string[])`, so we just forward.
//
// Keeping this file tiny matters: anything we add here lives in the
// AOT binary's "C# layer" and would block deleting the F# CLI
// scaffolding in A1.4.  Forward-only is the entire surface.

namespace Lyric.Cli.Aot;

public static class Program
{
    public static int Main(string[] args)
        => Lyric.Cli.Program.main(args);
}
