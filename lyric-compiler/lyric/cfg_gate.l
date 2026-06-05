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
//! and `assembleDirectoryPackageSources` for the contracts.
//!
//! Extracted from `Lyric.Cli` (#1124) so the dedup + comment-aware
//! behaviour is testable from a self-test consumer rather than coupled
//! to the full CLI dispatcher.
package Lyric.CfgGate

import Std.Core
import Std.Collections
import Std.String as Str

/// Returns the package-stub source used when an entire file is gated
/// out: a single `package <name>\n` line with no items.  Sibling packages
/// can still import `<name>` and resolve to an empty assembly.
@pure
@stable(since = "0.1")
pub func emptyPackageStub(pkgName: in String): String {
  "package " + pkgName + "\n"
}

/// True when `source` is a Lyric file that begins with an
/// `@cfg(feature = "X")` annotation whose feature is NOT in
/// `activeFeatures`, gating the whole file (and therefore the package
/// declaration it precedes) out of the build.
///
/// The detection is a string heuristic — full lex/parse is reserved for
/// the emitter — but it filters out two classes of false positive:
///
///   1. `@cfg(...)` text inside a line comment (`// note: removed
///      @cfg(feature = "x")`), which the old heuristic would have
///      matched if the comment happened to anchor at column 0.
///   2. Active features: the first `@cfg` whose feature IS in the
///      active set is skipped so a later inactive `@cfg` annotation
///      preceding the same `package` declaration can still gate the
///      file out.
///
/// Known limitation: the comment filter only skips `@cfg` occurrences
/// inside `//` line comments via `cfgIsInLineComment`; `@cfg` text inside
/// a `/* … */` block comment is treated as a real annotation.  In practice
/// block comments before `package` are unusual, so this is left as a
/// documented edge case rather than a full tokenizer-level filter.
///
/// Returns false when:
///   - the file has no `package` declaration at column 0;
///   - no eligible `@cfg(feature = "...")` annotation precedes that
///     `package` declaration;
///   - every eligible annotation references a currently-active feature.
@pure
@stable(since = "0.1")
pub func isCfgGatedOut(source: in String, activeFeatures: in List[String]): Bool {
  // Prepend "\n" so a leading "package " or "@cfg" line still has a
  // preceding newline we can anchor against.  Indices below are into
  // `searchable`, not `source`.
  val searchable = "\n" + source
  val cfgMark = "@cfg(feature = \""
  val pkgMark = "\npackage "

  val pkgIdxOpt = Str.indexOf(searchable, pkgMark)
  match pkgIdxOpt {
    case None -> return false
    case Some(pkgIdx) -> {
      // Walk the prefix [0, pkgIdx) looking for @cfg(feature = "X")
      // occurrences that are NOT inside a // line comment.  The first
      // inactive feature found gates the file; active features are
      // skipped (a later inactive @cfg might still gate).
      var scan = 0
      var result = false
      var done = false
      while not done and scan < pkgIdx {
        val tail = Str.substring(searchable, scan, pkgIdx - scan)
        val relOpt = Str.indexOf(tail, cfgMark)
        match relOpt {
          case None -> {
            done = true
          }
          case Some(relIdx) -> {
            val cfgIdx = scan + relIdx
            if cfgIsInLineComment(searchable, cfgIdx) {
              // False positive inside a // comment — skip past this
              // occurrence and keep scanning.
              scan = cfgIdx + cfgMark.length
            } else {
              // Real @cfg annotation candidate — extract the feature
              // name (the text between the opening and closing quote).
              val cfgStart = cfgIdx + cfgMark.length
              val afterCfg = Str.substring(searchable, cfgStart, searchable.length - cfgStart)
              val closeOpt = Str.indexOf(afterCfg, "\"")
              match closeOpt {
                case None -> {
                  done = true
                }
                case Some(closeIdx) -> {
                  val featName = Str.substring(afterCfg, 0, closeIdx)
                  if featureIsActive(featName, activeFeatures) {
                    // Active feature: this annotation doesn't gate the
                    // file; keep scanning for a later inactive one.
                    scan = cfgIdx + cfgMark.length
                  } else {
                    result = true
                    done = true
                  }
                }
              }
            }
          }
        }
      }
      return result
    }
  }
}

/// True when `pos` in `s` lies after a `//` line-comment marker on the
/// same physical line.
func cfgIsInLineComment(s: in String, pos: in Int): Bool {
  // Walk back to the start of the current physical line.
  var lineStart = pos
  while lineStart > 0 and s[lineStart - 1] != '\n' {
    lineStart = lineStart - 1
  }
  // Look for "//" in [lineStart, pos).
  var i = lineStart
  while i + 1 < pos {
    if s[i] == '/' and s[i + 1] == '/' {
      return true
    }
    i = i + 1
  }
  false
}

func featureIsActive(name: in String, activeFeatures: in List[String]): Bool {
  var i = 0
  while i < activeFeatures.count {
    if activeFeatures[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

/// A single (path, contents) pair input to
/// `assembleDirectoryPackageSources`.  Plain record because the
/// stdlib has no general tuple type.
pub record CfgGateFile {
  path: String
  contents: String
}

/// Result of assembling a directory package's source files with
/// `@cfg`-gated files filtered out.  When every file in the directory
/// is gated, `sources` carries a single `package <name>\n` stub so
/// downstream imports still resolve.  When some files survive, gated
/// files are dropped entirely (no per-file stub) so the merged source
/// has exactly one `package` declaration — fixing #1124.
pub record DirPackageAssembly {
  /// The source texts to feed into the emitter for this package, in
  /// the same order the input files were sorted.
  sources: List[String]
  /// Paths of files that were filtered out because of an inactive
  /// `@cfg` feature.  Empty when nothing was gated.
  gatedFiles: List[String]
}

/// Assemble the source list for a directory package, dropping any file
/// that is entirely gated by an inactive `@cfg` feature.  If every file
/// is gated, returns a single-element list with the empty-package stub
/// so sibling packages that `import` this one still resolve to a valid
/// (empty) assembly.
///
/// `filesAndContents` is a list of (path, source) pairs in the order
/// the caller wants them concatenated — typically alphabetical for
/// determinism.  `pkgName` is the declared package name used in the
/// stub.
@pure
@stable(since = "0.1")
pub func assembleDirectoryPackageSources(
  filesAndContents: in List[CfgGateFile],
  pkgName: in String,
  activeFeatures: in List[String],
): DirPackageAssembly {
  val keptSources: List[String] = newList()
  val gatedFiles: List[String] = newList()

  var i = 0
  while i < filesAndContents.count {
    val item = filesAndContents[i]
    if isCfgGatedOut(item.contents, activeFeatures) {
      gatedFiles.add(item.path)
    } else {
      keptSources.add(item.contents)
    }
    i = i + 1
  }

  if keptSources.count == 0 and gatedFiles.count > 0 {
    // Every file was gated — emit one stub so imports resolve.
    keptSources.add(emptyPackageStub(pkgName))
  }

  DirPackageAssembly(sources = keptSources, gatedFiles = gatedFiles)
}
