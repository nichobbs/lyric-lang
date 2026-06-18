//! verifier/smt.l — SMT-LIB v2.6 emitter for the Lyric-VC IR.
//!
//! Targets Z3 by default; CVC5 consumes the same output.
//! (docs/15-phase-4-proof-plan.md §7.2)
//!
//! Mirrors compiler/src/Lyric.Verifier/Smt.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections

// ─────────────────────────────────────────────────────────────────────────────
// §1. Sort and identifier rendering.
// ─────────────────────────────────────────────────────────────────────────────
pub func smtRenderSort(s: in Sort): String {
  match s {
    case SBool -> "Bool"
    case SInt -> "Int"
    case SBitVec(w) -> "(_ BitVec " + intToString(w) + ")"
    // Float32/Float64 map to SMT Real (sound approximation).
    case SFloat32 -> "Real"
    case SFloat64 -> "Real"
    case SString -> "String"
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
    case SSlice(e) -> "(Array Int " + smtRenderSort(e) + ")"
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
      case None -> {
      }
    }
    i = i + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Literal and term rendering.
// ─────────────────────────────────────────────────────────────────────────────
// Render a Double as a valid SMT-LIB Real literal.
// SMT-LIB requires a decimal point: "1.0", not "1".  F#'s `double.ToString()`
// omits the decimal for whole-valued floats (e.g. 1.0 → "1"), which Z3 parses
// as an Int and produces a sort error in the Real theory.  NaN and ±Infinity
// are not representable in SMT Real and are replaced with "0.0" so the
// solver returns a diagnostic rather than crashing.  Scientific notation
// (e.g. "1E+20") is also invalid SMT-LIB Real; expand it to fixed-point.
func smtRenderFloat(f: in Double): String {
  val s = doubleToString(f)
  if s == "NaN" or s == "Infinity" or s == "-Infinity" {
    "0.0"
  } else {
    expandToDecimal(s)
  }
}

// True when the character at position `i` in `s` equals `expected`.
func charIs(s: in String, i: in Int, expected: in Char): Bool {
  match charAt(s, i) {
    case Some(c) -> c == expected
    case None -> false
  }
}

// Decimal digit value of a Char (0..9); returns 0 for non-digits.
func digitCharVal(c: in Char): Int {
  if c == '0' {
    0
  } else if c == '1' {
    1
  } else if c == '2' {
    2
  } else if c == '3' {
    3
  } else if c == '4' {
    4
  } else if c == '5' {
    5
  } else if c == '6' {
    6
  } else if c == '7' {
    7
  } else if c == '8' {
    8
  } else if c == '9' {
    9
  } else {
    0
  }
}

// Convert a float string (possibly in scientific notation) to SMT-LIB Real
// fixed-point form.  Returns the input unchanged when it already has a decimal
// point and no exponent.
func expandToDecimal(s: in String): String {
  var ePos = -1
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case Some(c) -> {
        if c == 'E' or c == 'e' {
          ePos = i
        }
      }
      case None -> {
      }
    }
    i = i + 1
  }
  if ePos < 0 {
    if s.contains(".") {
      s
    } else {
      s + ".0"
    }
  } else {
    val mPart = s.substring(0, ePos)
    val ePart = s.substring(ePos + 1, s.length)
    val negM = mPart.length > 0 and charIs(mPart, 0, '-')
    val mAbs = if negM { mPart.substring(1, mPart.length) } else { mPart }
    val prefix = if negM { "-" } else { "" }
    var dotAt = -1
    var k = 0
    while k < mAbs.length {
      if charIs(mAbs, k, '.') {
        dotAt = k
      }
      k = k + 1
    }
    val digits = if dotAt >= 0 { mAbs.substring(0, dotAt) + mAbs.substring(dotAt + 1, mAbs.length) } else { mAbs }
    val decFromLeft = if dotAt >= 0 { dotAt } else { mAbs.length }
    val eNeg = ePart.length > 0 and charIs(ePart, 0, '-')
    val eStart = if ePart.length > 0 and (charIs(ePart, 0, '+') or charIs(ePart, 0, '-')) { 1 } else { 0 }
    var expVal = 0
    var ei = eStart
    while ei < ePart.length {
      match charAt(ePart, ei) {
        case Some(c) -> {
          expVal = expVal * 10 + digitCharVal(c)
        }
        case None -> {
        }
      }
      ei = ei + 1
    }
    val newDec = if eNeg { decFromLeft - expVal } else { decFromLeft + expVal }
    shiftDecimal(prefix, digits, newDec)
  }
}

func shiftDecimal(prefix: in String, digits: in String, decPos: in Int): String {
  if decPos <= 0 {
    var zeros = ""
    var z = 0
    while z < -decPos {
      zeros = zeros + "0"
      z = z + 1
    }
    prefix + "0." + zeros + digits
  } else if decPos >= digits.length {
    var zeros = ""
    var z = 0
    while z < decPos - digits.length {
      zeros = zeros + "0"
      z = z + 1
    }
    prefix + digits + zeros + ".0"
  } else {
    prefix + digits.substring(0, decPos) + "." + digits.substring(decPos, digits.length)
  }
}

func smtRenderLit(lit: in Lit): String {
  match lit {
    case VLBool(true) -> "true"
    case VLBool(false) -> "false"
    case VLInt(n) -> {
      if n < 0i64 {
        "(- " + longToString(-n) + ")"
      } else {
        longToString(n)
      }
    }
    case VLFloat(f) -> smtRenderFloat(f)
    case VLString(s) -> "\"" + s.replace("\"", "\"\"") + "\""
    case VLUnit -> "unit"
  }
}

pub func smtRenderTerm(t: in Term): String {
  match t {
    case TVar(name, _) -> smtSanitize(name)
    case TLit(lit, _) -> smtRenderLit(lit)
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
        if i > 0 {
          binds = binds + " "
        }
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
        if i > 0 {
          bs = bs + " "
        }
        bs = bs + "(" + smtSanitize(binders[i].name) + " " + smtRenderSort(binders[i].sort) + ")"
        i = i + 1
      }
      "(forall (" + bs + ") " + smtRenderTerm(body) + ")"
    }
    case TExists(binders, body) -> {
      var bs = ""
      var i = 0
      while i < binders.count {
        if i > 0 {
          bs = bs + " "
        }
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
// Collect all free TVar occurrences in a term (deduplicated by name).
// Quantifier binders are scoped correctly: variables bound by forall/exists
// are not emitted as declare-const, even if they share a name with a free
// variable elsewhere in the term.
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
    case TLit(_, _) -> {
    }
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
      // Collect into a fresh scope with binders pre-marked so they are not
      // treated as free variables.  Any genuinely-free variables found in
      // the body or triggers are then merged into the outer seen/output.
      val innerSeen: Map[String, Bool] = newMap()
      var i = 0
      while i < binders.count {
        innerSeen.add(binders[i].name, true)
        i = i + 1
      }
      val innerOut: List[VarRef] = newList()
      i = 0
      while i < triggers.count {
        var j = 0
        while j < triggers[i].count {
          collectVarsIn(triggers[i][j], innerSeen, innerOut)
          j = j + 1
        }
        i = i + 1
      }
      collectVarsIn(body, innerSeen, innerOut)
      i = 0
      while i < innerOut.count {
        val v = innerOut[i]
        if not seen.containsKey(v.name) {
          seen.add(v.name, true)
          output.add(v)
        }
        i = i + 1
      }
    }
    case TExists(binders, body) -> {
      val innerSeen: Map[String, Bool] = newMap()
      var i = 0
      while i < binders.count {
        innerSeen.add(binders[i].name, true)
        i = i + 1
      }
      val innerOut: List[VarRef] = newList()
      collectVarsIn(body, innerSeen, innerOut)
      i = 0
      while i < innerOut.count {
        val v = innerOut[i]
        if not seen.containsKey(v.name) {
          seen.add(v.name, true)
          output.add(v)
        }
        i = i + 1
      }
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
        if i > 0 {
          paramText = paramText + " "
        }
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
        if i > 0 {
          ctorText = ctorText + " "
        }
        if ctor.fields.count == 0 {
          ctorText = ctorText + "(" + smtSanitize(ctor.name) + ")"
        } else {
          var fieldText = ""
          var j = 0
          while j < ctor.fields.count {
            if j > 0 {
              fieldText = fieldText + " "
            }
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

// True for sort names that are already declared by the SMT-LIB theory or by
// the verifier's preamble — never re-declare them.
func isBuiltinSortName(name: in String): Bool {
  name == "Bool" or name == "Int" or name == "Real" or name == "String" or name == "Unit" or name == "Tuple" or
    name == "Option" or
    name == "Array"
}

// Walk a sort, collecting every uninterpreted-sort name (SDatatype with no
// type-args, and SUninterp) into `seen`/`out`.  Generic SDatatype arity > 0
// is recursively walked into args, but its head name is not collected — the
// few cases that hit this path (Option/Tuple/Array) are already declared by
// the preamble.
func collectSortNames(s: in Sort, seen: in Map[String, Bool], outList: in List[String]): Unit {
  match s {
    case SBool -> ()
    case SInt -> ()
    case SBitVec(_) -> ()
    case SFloat32 -> ()
    case SFloat64 -> ()
    case SString -> ()
    case SDatatype(name, args) -> {
      if args.count == 0 {
        if not isBuiltinSortName(name) and not seen.containsKey(name) {
          seen.add(name, true)
          outList.add(name)
        }
      } else {
        var i = 0
        while i < args.count {
          collectSortNames(args[i], seen, outList)
          i = i + 1
        }
      }
    }
    case SSlice(e) -> collectSortNames(e, seen, outList)
    case SUninterp(name) -> {
      val sanitized = smtSanitize(name)
      if not isBuiltinSortName(sanitized) and not seen.containsKey(sanitized) {
        seen.add(sanitized, true)
        outList.add(sanitized)
      }
    }
  }
}

// Walk a term, collecting (a) every sort referenced (via sort positions on
// TVar/TLit, retSort on TApp, and binder sorts on TForall/TExists), and (b)
// every TApp call site that names a function not declared in `knownFuncs`.
// TApp call sites become declare-fun emissions so Z3 doesn't reject the use
// of an undeclared constant (#3843).
record TAppRef {
  name: String
  paramSorts: List[Sort]
  resultSort: Sort
}

func collectFromTerm(
  t: in Term,
  knownFuncs: in Map[String, Bool],
  seenSorts: in Map[String, Bool],
  outSorts: in List[String],
  seenFuncs: in Map[String, Bool],
  outFuncs: in List[TAppRef],
): Unit {
  match t {
    case TVar(_, s) -> collectSortNames(s, seenSorts, outSorts)
    case TLit(_, s) -> collectSortNames(s, seenSorts, outSorts)
    case TBuiltin(_, args) -> {
      var i = 0
      while i < args.count {
        collectFromTerm(args[i], knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
        i = i + 1
      }
    }
    case TApp(name, args, retSort) -> {
      collectSortNames(retSort, seenSorts, outSorts)
      var i = 0
      while i < args.count {
        collectFromTerm(args[i], knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
        i = i + 1
      }
      val sanitized = smtSanitize(name)
      if not knownFuncs.containsKey(sanitized) and not seenFuncs.containsKey(sanitized) {
        seenFuncs.add(sanitized, true)
        val paramSorts: List[Sort] = newList()
        var j = 0
        while j < args.count {
          paramSorts.add(sortOf(args[j]))
          j = j + 1
        }
        outFuncs.add(TAppRef(name = name, paramSorts = paramSorts, resultSort = retSort))
      }
    }
    case TLet(bindings, body) -> {
      var bi = 0
      while bi < bindings.count {
        collectFromTerm(bindings[bi].term, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
        bi = bi + 1
      }
      collectFromTerm(body, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
    }
    case TIte(c, a, b) -> {
      collectFromTerm(c, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
      collectFromTerm(a, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
      collectFromTerm(b, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
    }
    case TForall(binders, _, body) -> {
      var i = 0
      while i < binders.count {
        collectSortNames(binders[i].sort, seenSorts, outSorts)
        i = i + 1
      }
      collectFromTerm(body, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
    }
    case TExists(binders, body) -> {
      var i = 0
      while i < binders.count {
        collectSortNames(binders[i].sort, seenSorts, outSorts)
        i = i + 1
      }
      collectFromTerm(body, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)
    }
  }
}

// Render a goal as a self-contained SMT-LIB v2.6 file.
pub func smtRenderGoal(g: in Goal): String {
  var output = smtRenderPreamble()
  output = output + "; goal: " + g.label + "\n"
  output = output + "; kind: " + goalKindDisplay(g.kind) + "\n"

  // Build the claim: hypotheses => conclusion.
  val claim = goalAsImplication(g)

  // Collect (1) every uninterpreted sort name and (2) every TApp call site
  // whose function isn't already declared by a symbol.  Walking happens
  // before symbol/declare-const emission so the sort declarations land first
  // and every later use resolves cleanly (#3843).  `knownFuncs` seeds the
  // function-collector with the symbols already in g.symbols so we don't
  // double-declare a registered callee.
  val knownFuncs: Map[String, Bool] = newMap()
  var si = 0
  while si < g.symbols.count {
    match g.symbols[si] {
      case DeclUserFun(fname, _, _) -> {
        val key = smtSanitize(fname)
        if not knownFuncs.containsKey(key) {
          knownFuncs.add(key, true)
        }
      }
      case DeclDatatype(_, dtCtors) -> {
        // (declare-datatypes ...) defines both the constructor and each
        // field selector — record them as "known" so the unknown-TApp
        // scanner below doesn't redeclare them via declare-fun (#3843).
        var dci = 0
        while dci < dtCtors.count {
          val dctor = dtCtors[dci]
          val cKey = smtSanitize(dctor.name)
          if not knownFuncs.containsKey(cKey) {
            knownFuncs.add(cKey, true)
          }
          var dfi = 0
          while dfi < dctor.fields.count {
            val fKey = smtSanitize(dctor.fields[dfi].name)
            if not knownFuncs.containsKey(fKey) {
              knownFuncs.add(fKey, true)
            }
            dfi = dfi + 1
          }
          dci = dci + 1
        }
      }
    }
    si = si + 1
  }
  val seenSorts: Map[String, Bool] = newMap()
  val outSorts: List[String] = newList()
  val seenFuncs: Map[String, Bool] = newMap()
  val outFuncs: List[TAppRef] = newList()
  // Seed seenSorts with every datatype name registered in g.symbols, since
  // (declare-datatypes ...) declares its own sort — emitting an extra
  // (declare-sort X 0) for the same name is a redefinition error in z3.
  var sd = 0
  while sd < g.symbols.count {
    match g.symbols[sd] {
      case DeclDatatype(dtName, _) -> {
        val dtKey = smtSanitize(dtName)
        if not seenSorts.containsKey(dtKey) {
          seenSorts.add(dtKey, true)
        }
      }
      case _ -> ()
    }
    sd = sd + 1
  }
  // Include declared symbols in the sort-collection scan so a callee's
  // param/result sort gets declared.
  var sj = 0
  while sj < g.symbols.count {
    match g.symbols[sj] {
      case DeclUserFun(_, pSorts, rSort) -> {
        var pi = 0
        while pi < pSorts.count {
          collectSortNames(pSorts[pi], seenSorts, outSorts)
          pi = pi + 1
        }
        collectSortNames(rSort, seenSorts, outSorts)
      }
      case DeclDatatype(_, _) -> ()
    }
    sj = sj + 1
  }
  collectFromTerm(claim, knownFuncs, seenSorts, outSorts, seenFuncs, outFuncs)

  // Emit (declare-sort X 0) for each unknown sort name.
  var k = 0
  while k < outSorts.count {
    output = output + "(declare-sort " + outSorts[k] + " 0)\n"
    k = k + 1
  }

  // Emit registered symbol declarations.
  var i = 0
  while i < g.symbols.count {
    output = output + smtRenderSymbol(g.symbols[i]) + "\n"
    i = i + 1
  }

  // Emit (declare-fun ...) for each TApp callsite whose function wasn't
  // already declared by a symbol.  Without this Z3 reports the call as an
  // unknown constant ("unknown constant Amount (Int)") and the whole proof
  // attempt aborts before sat/unsat (#3843).
  k = 0
  while k < outFuncs.count {
    val fr = outFuncs[k]
    var paramText = ""
    var pi = 0
    while pi < fr.paramSorts.count {
      if pi > 0 {
        paramText = paramText + " "
      }
      paramText = paramText + smtRenderSort(fr.paramSorts[pi])
      pi = pi + 1
    }
    output = output + "(declare-fun " + smtSanitize(fr.name) + " (" + paramText + ") " + smtRenderSort(fr.resultSort) +
      ")\n"
    k = k + 1
  }

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
