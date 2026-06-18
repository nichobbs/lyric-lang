//! bench_synth_bridge.l — text-protocol bridge for the F# SelfHostedBench.fs shim.
//! Wraps Lyric.BenchSynth.synthesizeBench and serialises the result to a
//! line-oriented protocol so the F# shim avoids CLR reflection on Lyric union types.
//!
//! synthesizeBenchToProtocol protocol:
//!   "nobench\n<line>\n<col>"          — @bench_module annotation missing
//!   "usermain\n<line>\n<col>"         — user declared func main()
//!   "parsefail\n<code>|<sev>|<line>|<col>|<msg>"  (one diag per line)
//!   "ok\n<benchCount>\n<synthesized source>"
package Lyric.BenchSynthBridge

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.BenchSynth

func diagLine(d: in Diagnostic): String {
  val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
  d.code + "|" + sev + "|" + toString(d.span.startPos.line) + "|" + toString(d.span.startPos.column) + "|" + d.message
}

pub func synthesizeBenchToProtocol(source: in String, runs: in Int, warmup: in Int, filter: in String): String {
  match synthesizeBench(source, runs, warmup, filter) {
    case NoBenchModule(span) -> "nobench\n" + toString(span.startPos.line) + "\n" + toString(span.startPos.column)
    case BenchUserMainExists(span) -> "usermain\n" + toString(span.startPos.line) + "\n" + toString(span.startPos.column)
    case BenchParseFailures(diags) -> {
      var s = "parsefail"
      var i = 0
      while i < diags.count {
        s = s + "\n" + diagLine(diags[i])
        i = i + 1
      }
      s
    }
    case BenchSynthesised(src, benchCount) -> "ok\n" + toString(benchCount) + "\n" + src
  }
}
