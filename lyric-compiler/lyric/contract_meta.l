// lyric/contract_meta.l — Lyric.ContractMeta bootstrap package.
//
// Implements the three functions that cli.l's `cmdPublicApiDiff` needs:
//   readFromFile(path)          — extract the Lyric.Contract JSON from a DLL
//   diffContracts(old, new)     — diff two JSON blobs; return rendered entries
//   hasBreakingChanges(entries) — pure check on the rendered entry list
//
// readFromFile and diffContracts shell out to `lyric --internal-contract-meta`
// which is handled by the F# bootstrap CLI.  ProcessCapture.runCapture is
// used so stdout can be captured without spawning a shell.
//
// Protocol:
//   read  <dll>                       → JSON string or "" (no contract)
//   diff  (old JSON and new JSON in
//          stdin, separated by \n---\n) → rendered entries separated by \n\n

@runtime_checked
package Lyric.ContractMeta

import Std.Core
import Std.Collections
import Std.Errors
import Std.File
import Std.Process
import Std.ProcessCapture
import Std.Environment as Environment
import Std.String as Str
import Lyric.CliShell as CliShell

// ─────────────────────────────────────────────────────────────────────────────
// §1. Subprocess helpers — thin wrappers over Lyric.CliShell.
// ─────────────────────────────────────────────────────────────────────────────
//
// Wrapper names are deliberately distinct from CliShell's public
// surface: when the local function and the cross-package alias share
// a name, the bootstrap resolver shadows the call site with the
// enclosing module's symbol, producing infinite recursion at runtime.

func cliShellExe(): String { CliShell.lyrExe() }

func cliShellArgs(subcmd: in List[String]): List[String] {
  CliShell.lyrArgs(subcmd)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. readFromFile
// ─────────────────────────────────────────────────────────────────────────────

/// Read the embedded `Lyric.Contract` JSON resource from `dllPath`.
/// Returns `Some(json)` if the resource is present, `None` otherwise.
@stable(since="0.1")
pub func readFromFile(path: in String): Option[String] {
  val subcmd: List[String] = newList()
  subcmd.add("--internal-contract-meta")
  subcmd.add("read")
  subcmd.add(path)
  val output = runCapture(cliShellExe(), cliShellArgs(subcmd), "")
  val trimmed = Str.trim(output)
  if Str.isEmpty(trimmed) {
    None
  } else {
    Some(value = trimmed)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. diffContracts
// ─────────────────────────────────────────────────────────────────────────────

/// Diff two Lyric.Contract JSON blobs.
/// Returns a list of rendered diff entries (each entry may be multi-line).
/// Entries are separated by blank lines in the subprocess output;
/// this function splits on `\n\n` and returns one entry per element.
@stable(since="0.1")
pub func diffContracts(oldJson: in String, newJson: in String): List[String] {
  val subcmd: List[String] = newList()
  subcmd.add("--internal-contract-meta")
  subcmd.add("diff")
  val stdin = oldJson + "\n---\n" + newJson
  val output = runCapture(cliShellExe(), cliShellArgs(subcmd), stdin)

  // Entries are separated by blank lines (\n\n).
  val rawParts = Str.split(output, "\n\n")
  val result: List[String] = newList()
  var i = 0
  while i < rawParts.length {
    val item = Str.trim(rawParts[i])
    if Str.isNotEmpty(item) {
      result.add(item)
    }
    i += 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. hasBreakingChanges
// ─────────────────────────────────────────────────────────────────────────────

/// Return true if any rendered entry represents a breaking change.
///
/// Breaking entries are those that:
///   - start with "  - " (removed item) and are not @experimental
///   - start with "  ~ " (changed signature) and are not @experimental
///   - contain "[breaking]" (contract-clause breaking change)
@stable(since="0.1")
pub func hasBreakingChanges(entries: in List[String]): Bool {
  var breaking = false
  for e in entries.toArray() {
    val isStructuralBreak =
      (Str.startsWith(e, "  - ") or Str.startsWith(e, "  ~ "))
      and not Str.contains(e, "[experimental]")
    val isContractBreak = Str.contains(e, "[breaking]")
    if isStructuralBreak or isContractBreak {
      breaking = true
    }
  }
  breaking
}
