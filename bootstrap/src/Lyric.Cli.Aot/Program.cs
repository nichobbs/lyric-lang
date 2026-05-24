// Track A A1.3 entry point.  Trampoline into the Lyric-compiled CLI
// dispatcher (`Lyric.Cli.Program.main`).
//
// Before trampolining, `BootstrapCliShim` sets LYRIC_BIN + LYRIC_CLI_DLL
// when the F# bootstrap CLI (`lyric.dll` from the sibling `Lyric.Cli`
// project) is discoverable at a well-known relative path.  This routes
// `emitProject`'s `--internal-project-build` subprocess to the F#
// `Program.fs` handler, which is the only current handler for multi-package
// compilation.  Without these vars the subprocess would re-enter this binary,
// which does not handle internal flags and would print usage + exit 1.
//
// The shim is a developer convenience that violates the "keep the AOT
// entry point tiny" intent; it should disappear once `--internal-project-build`
// is migrated into the self-hosted CLI dispatcher.  Tracked in #1131.

using System;
using System.IO;
using System.Reflection;

namespace Lyric.Cli.Aot;

public static class Program
{
    public static int Main(string[] args)
    {
        BootstrapCliShim();
        return Lyric.Cli.Program.main(args);
    }

    private static void BootstrapCliShim()
    {
        if (Environment.GetEnvironmentVariable("LYRIC_CLI_DLL") is not null)
            return;

        // Layout (framework-dependent build):
        //   AOT:   <repo>/bootstrap/src/Lyric.Cli.Aot/bin/<cfg>/net10.0/lyric.dll
        //   F# CLI: <repo>/bootstrap/src/Lyric.Cli/bin/<cfg>/net10.0/lyric.dll
        //
        // Five GetDirectoryName calls from the assembly Location reach bootstrap/src/.
        var loc = Assembly.GetEntryAssembly()?.Location;
        if (string.IsNullOrEmpty(loc)) return;

        var up = loc;
        for (var i = 0; i < 5; i++)
            up = Path.GetDirectoryName(up) ?? "";
        if (string.IsNullOrEmpty(up)) return;

        var cliBase = Path.Combine(up, "Lyric.Cli", "bin");
        if (!Directory.Exists(cliBase)) return;

        var cfgDirs = Directory.GetDirectories(cliBase);
        Array.Sort(cfgDirs);
        foreach (var cfg in cfgDirs)
        {
            var dll = Path.Combine(cfg, "net10.0", "lyric.dll");
            if (!File.Exists(dll)) continue;
            Environment.SetEnvironmentVariable("LYRIC_BIN", "dotnet");
            Environment.SetEnvironmentVariable("LYRIC_CLI_DLL", dll);
            return;
        }
    }
}
