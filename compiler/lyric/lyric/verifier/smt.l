// verifier/smt.l — SMT-LIB v2.6 emitter for the Lyric-VC IR.
//
// Targets Z3 by default; CVC5 consumes the same output.
// (docs/15-phase-4-proof-plan.md §7.2)
//
// Mirrors compiler/src/Lyric.Verifier/Smt.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections

// ─────────────────────────────────────────────────────────────────────────────
// §1. Sort and identifier rendering.
// ─────────────────────────────────────────────────────────────────────────────

pub func smtRenderSort(s: in Sort): String {
  match s {
    case SBool     -> "Bool"
    case SInt      -> "Int"
    case SBitVec(w) -> "(_ BitVec " + intToString(w) + ")"
    // Float32/Float64 map to SMT Real (sound approximation).
    case SFloat32  -> "Real"
    case SFloat64  -> "Real"
    case SString   -> "String"
    case SDatatype(name, args) -> {
      if name == "Unit" and args.count == 0 {
        "Unit"
      } else if args.count == 0 {
        name
      } else {
        var output = "(" + name
        var i = 0
        while i < args.count {
          output = output + " " + smtRenderSort(args[i])
          i = i + 1
        }
        output + ")"
      }
    }
    case SSlice(e)    -> "(Array Int " + smtRenderSort(e) + ")"
    case SUninterp(n) -> smtSanitize(n)
  }
}

// Replace non-alphanumeric/non-underscore/non-dot chars with underscore.
pub func smtSanitize(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case Some(c) -> {
        if isLetter(c) or isDigit(c) or c == '_' or c == '.' {
          result = result + charToString(c)
        } else {
          result = result + "_"
        }
      }
      case None -> {}
    }
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Literal and term rendering.
// ─────────────────────────────────────────────────────────────────────────────

func smtRenderLit(lit: in Lit): String {
  match lit {
    case VLBool(true)  -> "true"
    case VLBool(false) -> "false"
    case VLInt(n)      -> {
      if n < 0i64 {
        "(- " + longToString(-n) + ")"
      } else {
        longToString(n)
      }
    }
    case VLFloat(f)    -> doubleToString(f)
    case VLString(s)   -> "\"" + s.replace("\"", "\"\"") + "\""
    case VLUnit        -> "unit"
  }
}

pub func smtRenderTerm(t: in Term): String {
  match t {
    case TVar(name, _)  -> smtSanitize(name)
    case TLit(lit, _)   -> smtRenderLit(lit)
    case TBuiltin(op, args) -> {
      if (builtinEq(op, BOpNot) or builtinEq(op, BOpNeg)) and args.count == 1 {
        "(" + builtinDisplay(op) + " " + smtRenderTerm(args[0]) + ")"
      } else if builtinEq(op, BOpSliceLength) and args.count == 1 {
        "(slice.length " + smtRenderTerm(args[0]) + ")"
      } else if builtinEq(op, BOpSliceIndex) and args.count == 2 {
        "(select " + smtRenderTerm(args[0]) + " " + smtRenderTerm(args[1]) + ")"
      } else {
        var output = "(" + builtinDisplay(op)
        var i = 0
        while i < args.count {
          output = output + " " + smtRenderTerm(args[i])
          i = i + 1
        }
        output + ")"
      }
    }
    case TApp(name, args, _) -> {
      if args.count == 0 {
        smtSanitize(name)
      } else {
        var output = "(" + smtSanitize(name)
        var i = 0
        while i < args.count {
          output = output + " " + smtRenderTerm(args[i])
          i = i + 1
        }
        output + ")"
      }
    }
    case TLet(bindings, body) -> {
      var binds = ""
      var i = 0
      while i < bindings.count {
        val b = bindings[i]
        if i > 0 { binds = binds + " " }
        binds = binds + "(" + smtSanitize(b.name) + " " + smtRenderTerm(b.term) + ")"
        i = i + 1
      }
      "(let (" + binds + ") " + smtRenderTerm(body) + ")"
    }
    case TIte(c, a, b) -> {
      "(ite " + smtRenderTerm(c) + " " + smtRenderTerm(a) + " " + smtRenderTerm(b) + ")"
    }
    case TForall(binders, _, body) -> {
      var bs = ""
      var i = 0
      while i < binders.count {
        if i > 0 { bs = bs + " " }
        bs = bs + "(" + smtSanitize(binders[i].name) + " " + smtRenderSort(binders[i].sort) + ")"
        i = i + 1
      }
      "(forall (" + bs + ") " + smtRenderTerm(body) + ")"
    }
    case TExists(binders, body) -> {
      var bs = ""
      var i = 0
      while i < binders.count {
        if i > 0 { bs = bs + " " }
        bs = bs + "(" + smtSanitize(binders[i].name) + " " + smtRenderSort(binders[i].sort) + ")"
        i = i + 1
      }
      "(exists (" + bs + ") " + smtRenderTerm(body) + ")"
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Free variable collection.
// ─────────────────────────────────────────────────────────────────────────────

// Collect all TVar occurrences in a term (deduplicated by name).
// Simplified: does not track quantifier binders — the extra declare-consts
// are harmless since quantifier variables shadow them within their scope.
pub func collectFreeVars(t: in Term): List[VarRef] {
  val seen: Map[String, Bool] = newMap()
  val result: List[VarRef] = newList()
  collectVarsIn(t, seen, result)
  result
}

pub record VarRef {
  pub name: String
  pub sort: Sort
}

func collectVarsIn(t: in Term, seen: in Map[String, Bool], output: in List[VarRef]): Unit {
  match t {
    case TVar(name, sort) -> {
      if not seen.containsKey(name) {
        seen.add(name, true)
        output.add(VarRef(name = name, sort = sort))
      }
    }
    case TLit(_, _) -> {}
    case TBuiltin(_, args) -> {
      var i = 0
      while i < args.count {
        collectVarsIn(args[i], seen, output)
        i = i + 1
      }
    }
    case TApp(_, args, _) -> {
      var i = 0
      while i < args.count {
        collectVarsIn(args[i], seen, output)
        i = i + 1
      }
    }
    case TLet(bindings, body) -> {
      var i = 0
      while i < bindings.count {
        collectVarsIn(bindings[i].term, seen, output)
        i = i + 1
      }
      collectVarsIn(body, seen, output)
    }
    case TIte(c, a, b) -> {
      collectVarsIn(c, seen, output)
      collectVarsIn(a, seen, output)
      collectVarsIn(b, seen, output)
    }
    case TForall(binders, triggers, body) -> {
      var i = 0
      while i < triggers.count {
        var j = 0
        while j < triggers[i].count {
          collectVarsIn(triggers[i][j], seen, output)
          j = j + 1
        }
        i = i + 1
      }
      collectVarsIn(body, seen, output)
    }
    case TExists(binders, body) -> {
      collectVarsIn(body, seen, output)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Symbol declaration rendering.
// ─────────────────────────────────────────────────────────────────────────────

func smtRenderSymbol(sym: in SymbolDecl): String {
  match sym {
    case DeclUserFun(name, paramSorts, resultSort) -> {
      var paramText = ""
      var i = 0
      while i < paramSorts.count {
        if i > 0 { paramText = paramText + " " }
        paramText = paramText + smtRenderSort(paramSorts[i])
        i = i + 1
      }
      "(declare-fun " + smtSanitize(name) + " (" + paramText + ") " + smtRenderSort(resultSort) + ")"
    }
    case DeclDatatype(name, ctors) -> {
      var ctorText = ""
      var i = 0
      while i < ctors.count {
        val ctor = ctors[i]
        if i > 0 { ctorText = ctorText + " " }
        if ctor.fields.count == 0 {
          ctorText = ctorText + "(" + smtSanitize(ctor.name) + ")"
        } else {
          var fieldText = ""
          var j = 0
          while j < ctor.fields.count {
            if j > 0 { fieldText = fieldText + " " }
            fieldText = fieldText + "(" + smtSanitize(ctor.fields[j].name) + " " + smtRenderSort(ctor.fields[j].sort) + ")"
            j = j + 1
          }
          ctorText = ctorText + "(" + smtSanitize(ctor.name) + " " + fieldText + ")"
        }
        i = i + 1
      }
      "(declare-datatypes ((" + smtSanitize(name) + " 0)) ((" + ctorText + ")))"
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Goal rendering (standalone file).
// ─────────────────────────────────────────────────────────────────────────────

pub func smtRenderPreamble(): String {
  "(set-logic ALL)\n(set-option :produce-models true)\n(declare-datatypes ((Unit 0)) (((unit))))\n"
}

// Render a goal as a self-contained SMT-LIB v2.6 file.
pub func smtRenderGoal(g: in Goal): String {
  var output = smtRenderPreamble()
  output = output + "; goal: " + g.label + "\n"
  output = output + "; kind: " + goalKindDisplay(g.kind) + "\n"

  // Emit symbol declarations.
  var i = 0
  while i < g.symbols.count {
    output = output + smtRenderSymbol(g.symbols[i]) + "\n"
    i = i + 1
  }

  // Build the claim: hypotheses => conclusion.
  val claim = goalAsImplication(g)

  // Collect free variables and emit declare-const.
  val freeVarList = collectFreeVars(claim)
  i = 0
  while i < freeVarList.count {
    val v = freeVarList[i]
    output = output + "(declare-const " + smtSanitize(v.name) + " " + smtRenderSort(v.sort) + ")\n"
    i = i + 1
  }

  output = output + "(assert (not " + smtRenderTerm(claim) + "))\n"
  output = output + "(check-sat)\n"
  output = output + "(get-model)\n"
  output
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Char helpers (needed by sanitizeIdent).
// ─────────────────────────────────────────────────────────────────────────────

func isLetter(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
}

func isDigit(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func charToString(c: in Char): String {
  c.toString()
}
