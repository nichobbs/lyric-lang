//! test_synth_bridge.l — text-protocol bridge for the F# SelfHostedTestSynth.fs shim.
//! Wraps Lyric.TestSynth.{synthesize, listEntries} and serialises results to a
//! line-oriented protocol so the F# shim avoids CLR reflection on Lyric union types.
//!
//! synthesizeToProtocol protocol:
//!   "notest\n<line>\n<col>"
//!   "usermain\n<line>\n<col>"
//!   "fixture\n<line>\n<col>"
//!   "parsefail\n<code>|<sev>|<line>|<col>|<msg>"  (one diag per line)
//!   "ok\n<testCount>\n<skipCount>\n<synthesized source>"
//!
//! listEntriesToProtocol protocol:
//!   "parsefail\n<diag>..."
//!   OR one entry per line: "test|<title>", "prop|<title>|<reason>", "fixture|<name>"
package Lyric.TestSynthBridge

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.TestSynth

func diagLine(d: in Diagnostic): String {
  val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
  d.code + "|" + sev + "|" + toString(d.span.startPos.line) + "|" + toString(d.span.startPos.column) + "|" + d.message
}

pub func synthesizeToProtocol(source: in String, filter: in String, hasFilter: in Bool): String {
  val filterOpt: Option[String] = if hasFilter { Some(value = filter) } else { None }
  match synthesize(source, filterOpt) {
    case NoTestModule(span) -> "notest\n" + toString(span.startPos.line) + "\n" + toString(span.startPos.column)
    case UserMainExists(span) -> "usermain\n" + toString(span.startPos.line) + "\n" + toString(span.startPos.column)
    case FixtureUnsupported(span) -> "fixture\n" + toString(span.startPos.line) + "\n" + toString(span.startPos.column)
    case ParseFailures(diags) -> {
      var s = "parsefail"
      var i = 0
      while i < diags.count {
        s = s + "\n" + diagLine(diags[i])
        i = i + 1
      }
      s
    }
    case Synthesised(src, testCount, skipCount) -> "ok\n" + toString(testCount) + "\n" + toString(skipCount) + "\n" + src
  }
}

pub func listEntriesToProtocol(source: in String): String {
  match listEntries(source) {
    case Err(diags) -> {
      var s = "parsefail"
      var i = 0
      while i < diags.count {
        s = s + "\n" + diagLine(diags[i])
        i = i + 1
      }
      s
    }
    case Ok(entries) -> {
      var s = ""
      var i = 0
      while i < entries.count {
        match entries[i] {
          case TestEntry(title) -> {
            s = s + "test|" + title + "\n"
          }
          case PropertyEntry(title, reason) -> {
            s = s + "prop|" + title + "|" + reason + "\n"
          }
          case FixtureEntry(name) -> {
            s = s + "fixture|" + name + "\n"
          }
        }
        i = i + 1
      }
      s
    }
  }
}
