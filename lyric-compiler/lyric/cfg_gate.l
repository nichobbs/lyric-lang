//! lyric/cfg_gate.l — @cfg-feature gating helpers used by the test runner.
//!
//! Detects when a package source file is entirely guarded by an inactive
//! `@cfg(feature = "X")` annotation so the test runner can substitute an
//! empty stub (allowing sibling-package imports to resolve) instead of
//! concatenating the gated source verbatim.
//!
//! The heuristic is intentionally lightweight (no full lex/parse) but it
//! must not produce false positives on text that happens to look like an
//! annotation while sitting inside a line comment.  See `isCfgGatedOut`
//! for the contract.  A package of several files is gated file by file on
//! the files' parses by the package merge (`Lyric.PackageMerge`, #8234).
//!
//! Extracted from `Lyric.Cli` (#1124) so the dedup + comment-aware
//! behaviour is testable from a self-test consumer rather than coupled
//! to the full CLI dispatcher.
package Lyric.CfgGate

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Cfg as Cfg

/// Returns the package-stub source used when an entire file is gated
/// out: a single `package <name>\n` line with no items.  Sibling packages
/// can still import `<name>` and resolve to an empty assembly.
@pure
@stable(since = "0.1")
pub func emptyPackageStub(pkgName: in String): String {
  "package " + pkgName + "\n"
}

/// True when `source` is a Lyric file whose file-level `@cfg(...)`
/// annotations, taken together, are false for `activeFeatures` (a single
/// `feature = "X"`, or an `any`/`all`/`not` composition), gating the whole file
/// (and therefore the package declaration it precedes) out of the build.
///
/// The file's `@cfg(...)` lines are found by text (one annotation per line, as
/// the formatter writes them, skipping `//` comments) and evaluated by
/// `Lyric.Cfg`, the same predicate grammar the compiler applies after parsing,
/// so a file gated by `any(...)`/`all(...)`/`not(...)` is skipped as well as one
/// gated by a single feature. A `target = "X"` atom counts as active (the real
/// per-target erasure runs later).
///
/// Returns false when:
///   - the file has no `package` declaration at column 0;
///   - no `@cfg(...)` line precedes that `package` declaration;
///   - the annotations hold for the active features, or are malformed.
@pure
@stable(since = "0.1")
pub func isCfgGatedOut(source: in String, activeFeatures: in List[String]): Bool {
  // Prepend "\n" so a leading "package " line still has a preceding newline
  // to anchor against.
  val searchable = "\n" + source
  match Str.indexOf(searchable, "\npackage ") {
    case None -> false
    case Some(pkgIdx) -> {
      // The `@cfg(...)` lines before `package` (one annotation per line, as
      // the formatter writes them), skipping `//` comments, then evaluated by
      // `Lyric.Cfg` so `any`/`all`/`not` compositions gate a file the same
      // way they do once it is parsed.
      val cfgLines: List[String] = newList()
      for line in Str.split(Str.substring(searchable, 0, pkgIdx), "\n") {
        val trimmed = Str.trim(line)
        if Str.startsWith(trimmed, "@cfg(") {
          cfgLines.add(trimmed)
        }
      }
      if cfgLines.count == 0 {
        false
      } else {
        Cfg.cfgLinesGateFileOut(Str.joinList("\n", cfgLines), activeFeatures)
      }
    }
  }
}

/// A file of a test-runner library package: its path and its contents.
/// Plain record because the stdlib has no general tuple type.
pub record CfgGateFile {
  path: String
  contents: String
}
