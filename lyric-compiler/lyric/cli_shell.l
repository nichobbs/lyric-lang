//! Shared subprocess helpers for shelling out to the `lyric` CLI from
//! within a self-hosted package.  Both `Lyric.Emitter` and
//! `Lyric.ContractMeta` use these to build the same `(exe, args)` tuple
//! regardless of whether the CLI is running as an AppHost-native launcher
//! or as a `dotnet exec <dll>` invocation.
@runtime_checked
package Lyric.CliShell

import Std.Core
import Std.Collections
import Std.Environment as Environment
import Std.String as Str

/// True when LYRIC_BIN is the AppHost-native launcher for LYRIC_CLI_DLL.
@stable(since = "0.1")
pub func lyrIsAppHost(): Bool {
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  val bin = Environment.getVarOrDefault("LYRIC_BIN", "")
  Str.isNotEmpty(bin) and cliDll == bin + ".dll"
}

/// The executable to invoke for a `lyric` subcommand.
/// In AppHost mode that's the native launcher; otherwise the dotnet
/// host (or "dotnet"/"lyric" by default).
@stable(since = "0.1")
pub func lyrExe(): String {
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) {
    val bin = Environment.getVarOrDefault("LYRIC_BIN", "")
    if Str.isNotEmpty(bin) and cliDll == bin + ".dll" {
      // AppHost mode: the native launcher IS the entry point for this DLL.
      bin
    } else {
      Environment.getVarOrDefault("LYRIC_BIN", "dotnet")
    }
  } else {
    Environment.getVarOrDefault("LYRIC_BIN", "lyric")
  }
}

/// Leading args that must precede any subcommand args.  Non-empty only
/// when running under an explicit dotnet host (not AppHost).
@stable(since = "0.1")
pub func lyrPrefixArgs(): List[String] {
  val prefix: List[String] = newList()
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if Str.isNotEmpty(cliDll) and not lyrIsAppHost() {
    prefix.add("exec")
    prefix.add(cliDll)
  }
  prefix
}

/// Build the full args list for a lyric subcommand invocation.
@stable(since = "0.1")
pub func lyrArgs(subcmd: in List[String]): List[String] {
  val all: List[String] = newList()
  for a in lyrPrefixArgs().toArray() {
    all.add(a)
  }
  for a in subcmd.toArray() {
    all.add(a)
  }
  all
}
