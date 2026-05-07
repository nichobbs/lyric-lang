// modechecker_mode.l — verification levels and level computation.
// Mirrors compiler/src/Lyric.Verifier/Mode.fs.
package Lyric.ModeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Verification levels.
// ─────────────────────────────────────────────────────────────────────────────

// The four verification levels from docs/08-contract-semantics.md §3.1.
// Partial order: VLAxiom > VLProofRequired{,Unsafe,Checked} > VLRuntimeChecked.
pub union VerificationLevel {
  case VLRuntimeChecked
  case VLProofRequired
  case VLProofRequiredUnsafe
  case VLProofRequiredChecked
  case VLAxiom
}

pub func vlRank(lvl: in VerificationLevel): Int {
  match lvl {
    case VLRuntimeChecked       -> 0
    case VLProofRequired        -> 1
    case VLProofRequiredUnsafe  -> 1
    case VLProofRequiredChecked -> 1
    case VLAxiom                -> 2
  }
}

pub func vlIsProofRequired(lvl: in VerificationLevel): Bool {
  match lvl {
    case VLProofRequired        -> true
    case VLProofRequiredUnsafe  -> true
    case VLProofRequiredChecked -> true
    case _                      -> false
  }
}

// callee dominates caller iff callee.rank >= caller.rank (callee is at least as strict).
pub func vlDominates(callee: in VerificationLevel, caller: in VerificationLevel): Bool {
  vlRank(callee) >= vlRank(caller)
}

pub func vlDisplay(lvl: in VerificationLevel): String {
  match lvl {
    case VLRuntimeChecked       -> "@runtime_checked"
    case VLProofRequired        -> "@proof_required"
    case VLProofRequiredUnsafe  -> "@proof_required(unsafe_blocks_allowed)"
    case VLProofRequiredChecked -> "@proof_required(checked_arithmetic)"
    case VLAxiom                -> "@axiom"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Annotation helpers.
// ─────────────────────────────────────────────────────────────────────────────

// Look up the first annotation whose head is a single segment equal to `name`.
func findAnnotation(name: in String, anns: in List[Annotation]): Option[Annotation] {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return Some(value = a)
    }
    i = i + 1
  }
  None
}

// Return the bare-identifier modifier of a @proof_required(...) annotation,
// e.g. "unsafe_blocks_allowed" or "checked_arithmetic", or None.
func proofRequiredModifier(ann: in Annotation): Option[String] {
  var i = 0
  while i < ann.args.count {
    match ann.args[i] {
      case ABare(nm, _) -> { return Some(value = nm) }
      case _            -> {}
    }
    i = i + 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. File-level and function-level mode resolution.
// ─────────────────────────────────────────────────────────────────────────────

// Resolve the verification level of a source file from its file-level
// annotations.  Appends V0010/V0011 diagnostics to `diag` on errors.
pub func levelOfFile(file: in SourceFile, diag: in List[Diagnostic]): VerificationLevel {
  val anns      = file.fileAnnotations
  val runtimeOpt = findAnnotation("runtime_checked", anns)
  val proofOpt   = findAnnotation("proof_required",  anns)
  val axiomOpt   = findAnnotation("axiom",           anns)

  // V0010: conflicting level annotations.
  val candidates: List[Annotation] = newList()
  match runtimeOpt { case Some(a) -> { candidates.add(a) } case None -> {} }
  match proofOpt   { case Some(a) -> { candidates.add(a) } case None -> {} }
  match axiomOpt   { case Some(a) -> { candidates.add(a) } case None -> {} }
  if candidates.count >= 2 {
    val a1 = candidates[0]
    val a2 = candidates[1]
    diag.add(errorDiagnostic("V0010",
      "package declares both @" + a1.name.segments[0] +
      " and @" + a2.name.segments[0] + "; pick one",
      a2.span))
  }

  // Axiom wins.
  match axiomOpt {
    case Some(_) -> { return VLAxiom }
    case None    -> {}
  }

  // @proof_required (with optional modifier).
  match proofOpt {
    case Some(p) -> {
      match proofRequiredModifier(p) {
        case Some(mod) -> {
          if mod == "unsafe_blocks_allowed" { return VLProofRequiredUnsafe }
          if mod == "checked_arithmetic"    { return VLProofRequiredChecked }
          // V0011: unknown modifier.
          diag.add(errorDiagnostic("V0011",
            "unknown @proof_required modifier '" + mod +
            "'; expected unsafe_blocks_allowed or checked_arithmetic",
            p.span))
          return VLProofRequired
        }
        case None -> { return VLProofRequired }
      }
    }
    case None -> {}
  }

  // Default: @runtime_checked.
  VLRuntimeChecked
}

// Per-function level: same as the file unless the function carries @axiom.
pub func levelOfFunction(fileLevel: in VerificationLevel, fn: in FunctionDecl): VerificationLevel {
  var i = 0
  while i < fn.annotations.count {
    val a = fn.annotations[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "axiom" {
      return VLAxiom
    }
    i = i + 1
  }
  fileLevel
}

// Whether a function carries @pure.
pub func isFuncPure(fn: in FunctionDecl): Bool {
  var i = 0
  while i < fn.annotations.count {
    val a = fn.annotations[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "pure" {
      return true
    }
    i = i + 1
  }
  false
}
