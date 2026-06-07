//! verifier_bridge.l — text-protocol bridge between the self-hosted
//! Lyric.Verifier and the F# CLI host (SelfHostedVerifier.fs).
//!
//! proveToProtocol(source, allowUnverified) serialises a ProofSummary to a
//! newline-delimited text protocol that F# can parse without sharing CLR types:
//!
//!   ok
//!   level=<display-string>
//!   diag|<code>|<error|warning>|<line>|<col>|<message>
//!   result|discharged|<label>|<line>|<col>
//!   result|counterexample|<label>|<line>|<col>|<model-escaped>
//!   result|unknown|<label>|<line>|<col>|<reason-escaped>
//!
//! On any failure the first line is "err" followed by a message.
package Lyric.VerifierBridge

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Verifier

func escapeNl(s: in String): String {
  var r = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '\n' {
      r = r + "\\n"
    } else if c == '|' {
      r = r + "\\|"
    } else {
      r = r + ("" + c)
    }
    i = i + 1
  }
  r
}

func levelDisplay(lvl: in VerificationLevel): String {
  match lvl {
    case VLRuntimeChecked -> "runtime_checked"
    case VLProofRequired -> "proof_required"
    case VLProofRequiredUnsafe -> "proof_required(unsafe_blocks_allowed)"
    case VLProofRequiredChecked -> "proof_required(checked_arithmetic)"
    case VLAxiom -> "@axiom"
  }
}

pub func proveToProtocol(source: in String, allowUnverified: in Bool): String {
  val summary = proveSourceWithOptions(source, allowUnverified)

  val lines: List[String] = newList()
  lines.add("ok")
  lines.add("level=" + levelDisplay(summary.level))

  var di = 0
  while di < summary.diagnostics.count {
    val d = summary.diagnostics[di]
    val sev = match d.severity { case DiagError -> "error"; case DiagWarning -> "warning" }
    lines.add(
      "diag|" + d.code + "|" + sev + "|" + ("" + d.span.startPos.line) + "|" + ("" + d.span.startPos.column) + "|" +
        escapeNl(d.message)
    )
    di = di + 1
  }

  var ri = 0
  while ri < summary.results.count {
    val r = summary.results[ri]
    val gl = r.goal
    val ln = "" + gl.origin.startPos.line
    val col = "" + gl.origin.startPos.column
    match r.outcome {
      case Discharged -> {
        lines.add("result|discharged|" + escapeNl(gl.label) + "|" + ln + "|" + col)
      }
      case Counterexample(model) -> {
        lines.add("result|counterexample|" + escapeNl(gl.label) + "|" + ln + "|" + col + "|" + escapeNl(model))
      }
      case Unknown(reason) -> {
        lines.add("result|unknown|" + escapeNl(gl.label) + "|" + ln + "|" + col + "|" + escapeNl(reason))
      }
    }
    ri = ri + 1
  }

  var buf = ""
  var i = 0
  while i < lines.count {
    if i > 0 {
      buf = buf + "\n"
    }
    buf = buf + lines[i]
    i = i + 1
  }
  buf
}
