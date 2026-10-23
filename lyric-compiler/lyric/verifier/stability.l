//! verifier/stability.l — stability-annotation analysis (Q011 / D040).
//!
//! Recognises @stable(since="X.Y") and @experimental on pub items and
//! enforces the one-way rule: a non-experimental pub function may not
//! call an @experimental item declared in the same source file.
//!
//! Diagnostic codes:
//!   S0001 — stable pub func calls @experimental callee in same package.
//!   S0002 — @stable and @experimental both present on the same item.
//!
//! Mirrors compiler/src/Lyric.Verifier/StabilityCheck.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Stability levels.
// ─────────────────────────────────────────────────────────────────────────────
pub union StabilityLevel {
  case Stable(since: String)
  case Experimental
  case Unmarked
}

pub func stabilityIsExperimental(lvl: in StabilityLevel): Bool {
  match lvl {
    case Experimental -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Reading stability from annotations.
// ─────────────────────────────────────────────────────────────────────────────
pub func stabilityOfAnnotations(anns: in List[Annotation]): StabilityLevel {
  var hasStable = false
  var hasExptl = false
  var sinceVal = ""
  var i = 0
  while i < anns.count {
    val a = anns[i]
    val segCount = a.name.segments.count
    if segCount == 1 {
      val seg = a.name.segments[0]
      if seg == "stable" {
        hasStable = true
        // Look for since="X.Y" arg.
        var j = 0
        while j < a.args.count {
          match a.args[j] {
            case AAName(argName, value, _) -> {
              if argName == "since" {
                match value {
                  case AVString(s, _) -> {
                    sinceVal = s
                  }
                  case _ -> {
                  }
                }
              }
            }
            case _ -> {
            }
          }
          j = j + 1
        }
      }
      if seg == "experimental" {
        hasExptl = true
      }
    }
    i = i + 1
  }
  if hasExptl and hasStable {
    // Conflict — return Experimental conservatively.
    Experimental
  } else if hasExptl {
    Experimental
  } else if hasStable {
    Stable(since = sinceVal)
  } else {
    Unmarked
  }
}

pub func stabilityOfItem(item: in Item): StabilityLevel {
  stabilityOfAnnotations(item.annotations)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func itemIsPub(item: in Item): Bool {
  match item.visibility {
    case Some(VisPub(_)) -> true
    case Some(VisInternal(_)) -> false
    case None -> false
  }
}

pub record CallRef {
  pub name: String
  pub span: Span
  pub argCount: Int
  // The call's arguments, which pair with a callee's parameters by name and
  // position (`Lyric.Parser.callDefaultsFilled`).
  pub args: List[CallArg]
  // ─────────────────────────────────────────────────────────────────────────────
  // §4. Expression walker — collect (callee-name, span) from call sites.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub func collectCallNames(body: in FunctionBody, output: in List[CallRef]): Unit {
  match body {
    case FBExpr(expr) -> visitExpr(expr, output)
    case FBBlock(blk) -> visitBlock(blk, output)
  }
}

func visitExpr(e: in Expr, output: in List[CallRef]): Unit {
  match e.kind {
    case ECall(fn, args) -> {
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            output.add(CallRef(name = path.segments[0], span = e.span, argCount = args.count, args = args))
          }
        }
        case _ -> {
        }
      }
      visitExpr(fn, output)
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, v, _) -> visitExpr(v, output)
          case CAPositional(v) -> visitExpr(v, output)
        }
        i = i + 1
      }
    }
    case EParen(inner) -> visitExpr(inner, output)
    case ETry(inner) -> visitExpr(inner, output)
    case EOld(inner) -> visitExpr(inner, output)
    case EPropagate(inner) -> visitExpr(inner, output)
    case EAwait(inner) -> visitExpr(inner, output)
    case EYield(inner) -> visitExpr(inner, output)
    case ESpawn(inner) -> visitExpr(inner, output)
    case ETuple(exprs) -> visitExprs(exprs, output)
    case EList(exprs) -> visitExprs(exprs, output)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      visitExpr(cond, output)
      visitEOB(thenBranch, output)
      match elseBranch {
        case Some(eb) -> visitEOB(eb, output)
        case None -> {
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      visitExpr(scrutinee, output)
      var i = 0
      while i < arms.count {
        visitEOB(arms[i].body, output)
        match arms[i].guard {
          case Some(g) -> visitExpr(g, output)
          case None -> {
          }
        }
        i = i + 1
      }
    }
    case EForall(_, whereExpr, body, _) -> {
      match whereExpr {
        case Some(w) -> visitExpr(w, output)
        case None -> {
        }
      }
      visitExpr(body, output)
    }
    case EExists(_, whereExpr, body, _) -> {
      match whereExpr {
        case Some(w) -> visitExpr(w, output)
        case None -> {
        }
      }
      visitExpr(body, output)
    }
    case ETypeApp(fn, _) -> visitExpr(fn, output)
    case EIndex(recv, idxs) -> {
      visitExpr(recv, output)
      visitExprs(idxs, output)
    }
    case EMember(recv, _) -> visitExpr(recv, output)
    case EPrefix(_, operand) -> visitExpr(operand, output)
    case EBinop(_, lhs, rhs) -> {
      visitExpr(lhs, output)
      visitExpr(rhs, output)
    }
    case EAssign(target, _, value) -> {
      visitExpr(target, output)
      visitExpr(value, output)
    }
    case EBlock(blk) -> visitBlock(blk, output)
    case EUnsafe(blk) -> visitBlock(blk, output)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(x) -> visitExpr(x, output)
          case ISText(_, _) -> {
          }
        }
        i = i + 1
      }
    }
    case ELambda(_, body) -> visitBlock(body, output)
    case ERange(rb) -> {
      match rb {
        case RBClosed(a, b) -> {
          visitExpr(a, output)
          visitExpr(b, output)
        }
        case RBHalfOpen(a, b, _) -> {
          visitExpr(a, output)
          visitExpr(b, output)
        }
        case RBLowerOpen(b) -> visitExpr(b, output)
        case RBUpperOpen(a) -> visitExpr(a, output)
      }
    }
    case ELiteral(_) -> {
    }
    case EPath(_) -> {
    }
    case ESelf -> {
    }
    case EResult -> {
    }
    case EError -> {
    }
  }
}

func visitExprs(exprs: in List[Expr], output: in List[CallRef]): Unit {
  var i = 0
  while i < exprs.count {
    visitExpr(exprs[i], output)
    i = i + 1
  }
}

func visitEOB(eob: in ExprOrBlock, output: in List[CallRef]): Unit {
  match eob {
    case EOBExpr(x) -> visitExpr(x, output)
    case EOBBlock(b) -> visitBlock(b, output)
  }
}

func visitBlock(blk: in Block, output: in List[CallRef]): Unit {
  var i = 0
  while i < blk.statements.count {
    visitStmt(blk.statements[i], output)
    i = i + 1
  }
}

func visitStmt(st: in Statement, output: in List[CallRef]): Unit {
  match st.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> visitExpr(init, output)
        case LBLet(_, _, init) -> visitExpr(init, output)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> visitExpr(init, output)
            case None -> {
            }
          }
        }
      }
    }
    case SAssign(target, _, value) -> {
      visitExpr(target, output)
      visitExpr(value, output)
    }
    case SReturn(valueOpt) -> {
      match valueOpt {
        case Some(v) -> visitExpr(v, output)
        case None -> {
        }
      }
    }
    case SBreak(_) -> {
    }
    case SContinue(_) -> {
    }
    case SThrow(x) -> visitExpr(x, output)
    case STry(body, catches, finally_) -> {
      visitBlock(body, output)
      var i = 0
      while i < catches.count {
        visitBlock(catches[i].body, output)
        i = i + 1
      }
      match finally_ {
        case None -> {
        }
        case Some(fb) -> visitBlock(fb, output)
      }
    }
    case SDefer(body) -> visitBlock(body, output)
    case SScope(_, body) -> visitBlock(body, output)
    case SFor(_, _, iter, body) -> {
      visitExpr(iter, output)
      visitBlock(body, output)
    }
    case SWhile(_, cond, body) -> {
      visitExpr(cond, output)
      visitBlock(body, output)
    }
    case SLoop(_, body) -> visitBlock(body, output)
    case SInvariant(x) -> visitExpr(x, output)
    case SExpr(x) -> visitExpr(x, output)
    case SRule(lhs, rhs) -> {
      visitExpr(lhs, output)
      visitExpr(rhs, output)
    }
    case SItem(_) -> {
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Check S0002: @stable + @experimental conflict.
// ─────────────────────────────────────────────────────────────────────────────
func checkConflicts(file: in SourceFile, diag: in List[Diagnostic]): Unit {
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    var hasStable = false
    var hasExptl = false
    var exptlSpan = item.span
    var j = 0
    while j < item.annotations.count {
      val a = item.annotations[j]
      if a.name.segments.count == 1 {
        val seg = a.name.segments[0]
        if seg == "stable" {
          hasStable = true
        }
        if seg == "experimental" {
          hasExptl = true
          exptlSpan = a.span
        }
      }
      j = j + 1
    }
    if hasStable and hasExptl {
      diag.add(errorDiagnostic("S0002", "item carries both @stable and @experimental; pick one", exptlSpan))
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Check S0001: stable pub func calls @experimental callee.
// ─────────────────────────────────────────────────────────────────────────────
// One declaration of a name a call may reach: a function, with how many
// arguments a call of it may pass, or another item (a record's
// constructor), with `paramCount` -1.
record StabilityEntry {
  name: String
  paramCount: Int
  requiredCount: Int
  paramNames: List[String]
  hasDefault: List[Bool]
  experimental: Bool
}

func checkCallGraph(file: in SourceFile, diag: in List[Diagnostic]): Unit {
  // Every declaration by name: a name may be declared more than once —
  // overloads of different arity, or, in a file no type check has rejected
  // yet, a duplicate (#8341).
  val entries: List[StabilityEntry] = newList()
  val noNames: List[String] = newList()
  val noFlags: List[Bool] = newList()
  for item in file.items {
    val experimental = stabilityIsExperimental(stabilityOfItem(item))
    match item.kind {
      case IFunc(fn) -> {
        var required = 0
        val names: List[String] = newList()
        val defaults: List[Bool] = newList()
        for p in fn.params {
          names.add(p.name)
          defaults.add(isSome(p.dflt))
          if not isSome(p.dflt) {
            required = required + 1
          }
        }
        entries.add(
          StabilityEntry(
            name = fn.name,
            paramCount = fn.params.count,
            requiredCount = required,
            paramNames = names,
            hasDefault = defaults,
            experimental = experimental
          )
        )
      }
      case _ -> match itemKindName(item.kind) {
        case Some(name) -> entries.add(
          StabilityEntry(
            name = name,
            paramCount = -1,
            requiredCount = 0,
            paramNames = noNames,
            hasDefault = noFlags,
            experimental = experimental
          )
        )
        case None -> ()
      }
    }
  }

  // Check each pub non-experimental func.
  for item in file.items {
    if itemIsPub(item) and not stabilityIsExperimental(stabilityOfItem(item)) {
      match item.kind {
        case IFunc(fn) -> match fn.body {
          case Some(body) -> {
            val calls: List[CallRef] = newList()
            collectCallNames(body, calls)
            for cr in calls {
              if callReachesExperimental(entries, cr) {
                diag.add(
                  errorDiagnostic(
                    "S0001",
                    "stable pub func '" + fn.name + "' calls @experimental '" + cr.name + "'; mark '" + fn.name +
                      "' @experimental or promote '" +
                      cr.name +
                      "' to @stable",
                    cr.span
                  )
                )
              }
            }
          }
          case None -> ()
        }
        case _ -> ()
      }
    }
  }
}

// Whether a declaration the call `cr` may reach is `@experimental`: among
// the functions of its name, every one the call fits (`callDefaultsFilled`),
// and any other item of its name.  The type checker binds the call to one of
// the functions it fits by the rule of D208 (a call supplying every
// parameter first, then the fewest defaults filled), but only after the
// argument types have ruled some out, which this check cannot see, so each
// counts.  Declarations in the package's other files are not seen here.
func callReachesExperimental(entries: in List[StabilityEntry], cr: in CallRef): Bool {
  for e in entries {
    if e.name == cr.name {
      val reached = e.paramCount < 0 or callDefaultsFilled(e.paramNames, e.hasDefault, 0, cr.args) >= 0
      if reached and e.experimental {
        return true
      }
    }
  }
  false
}

func itemKindName(kind: in ItemKind): Option[String] {
  match kind {
    case IFunc(fn) -> Some(value = fn.name)
    case IRecord(rd) -> Some(value = rd.name)
    case IExposedRec(rd) -> Some(value = rd.name)
    case IUnion(un) -> Some(value = un.name)
    case IEnum(en) -> Some(value = en.name)
    case IOpaque(op) -> Some(value = op.name)
    case IInterface(iface) -> Some(value = iface.name)
    case IDistinctType(dt) -> Some(value = dt.name)
    case ITypeAlias(ta) -> Some(value = ta.name)
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func checkStabilityFile(file: in SourceFile): List[Diagnostic] {
  val diag: List[Diagnostic] = newList()
  checkConflicts(file, diag)
  checkCallGraph(file, diag)
  diag
}
