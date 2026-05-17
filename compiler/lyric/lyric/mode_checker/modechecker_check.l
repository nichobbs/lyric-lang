// modechecker_check.l — call-graph and structural checks.
// Mirrors compiler/src/Lyric.Verifier/ModeCheck.fs.
package Lyric.ModeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types.
// ─────────────────────────────────────────────────────────────────────────────

// Metadata the mode checker needs about each locally declared callee.
pub record CalleeInfo {
  name:   String
  level:  VerificationLevel
  isPure: Bool
}

// Simplified cross-package import metadata (replaces Imports.ImportedPackage
// for the self-hosted pipeline; only the name and level string are needed).
pub record ImportedMeta {
  name:  String
  level: String
}

// Result returned by the public entry points.
pub record ModeCheckResult {
  level:       VerificationLevel
  diagnostics: List[Diagnostic]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Callee table construction.
// ─────────────────────────────────────────────────────────────────────────────

// Build a Map<name, CalleeInfo> from the file's local function declarations.
pub func calleeTableOfFile(
  fileLevel: in VerificationLevel,
  file:      in SourceFile
): Map[String, CalleeInfo] {
  val m: Map[String, CalleeInfo] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val info = CalleeInfo(
          name   = fn.name,
          level  = levelOfFunction(fileLevel, fn),
          isPure = isFuncPure(fn))
        m.add(fn.name, info)
      }
      case _ -> {}
    }
    i = i + 1
  }
  m
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. AST walker — V0002/V0003 (call-graph and unsafe-block checks).
// ─────────────────────────────────────────────────────────────────────────────

// Context threaded through the expression/block walkers.
record WalkCtx {
  fnName:  String
  fnLevel: VerificationLevel
  callees: Map[String, CalleeInfo]
  diag:    List[Diagnostic]
}

// Check a single resolved callee against the V0002 call-graph rule.
func checkCallee(
  ctx:        in WalkCtx,
  calleeName: in String,
  span:       in Span
): Unit {
  match mapGet(ctx.callees, calleeName) {
    case None    -> {}   // unknown — skip conservatively (M4.1 deferral)
    case Some(info) -> {
      val admissible = vlDominates(info.level, ctx.fnLevel) or info.isPure
      if not admissible {
        ctx.diag.add(errorDiagnostic("V0002",
          "proof-required function '" + ctx.fnName +
          "' may not call '" + calleeName +
          "' (" + vlDisplay(info.level) +
          "); upgrade callee, mark @pure, or shift caller to @runtime_checked",
          span))
      }
    }
  }
}

// Walk an expression collecting V0002/V0003 diagnostics.
// Matches the depth-first traversal of ModeCheck.fs collectCalls.
func walkExprCalls(ctx: in WalkCtx, e: in Expr): Unit {
  match e.kind {
    case EAwait(inner) -> {
      ctx.diag.add(errorDiagnostic("V0002",
        "await not admitted in proof-required function '" + ctx.fnName + "'",
        e.span))
      walkExprCalls(ctx, inner)
    }
    case EYield(inner) -> {
      ctx.diag.add(errorDiagnostic("V0002",
        "yield not admitted in proof-required function '" + ctx.fnName + "': async generators are not in the VC fragment",
        e.span))
      walkExprCalls(ctx, inner)
    }
    case ESpawn(inner) -> {
      ctx.diag.add(errorDiagnostic("V0002",
        "spawn not admitted in proof-required function '" + ctx.fnName + "'",
        e.span))
      walkExprCalls(ctx, inner)
    }
    case ECall(fn, args) -> {
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            checkCallee(ctx, path.segments[0], e.span)
          }
        }
        case _ -> {}
      }
      walkExprCalls(ctx, fn)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CANamed(_, v, _) -> walkExprCalls(ctx, v)
          case CAPositional(v)  -> walkExprCalls(ctx, v)
        }
        ai = ai + 1
      }
    }
    case EUnsafe(blk) -> {
      match ctx.fnLevel {
        case VLProofRequiredUnsafe -> {}
        case _ -> {
          ctx.diag.add(errorDiagnostic("V0003",
            "unsafe block requires @proof_required(unsafe_blocks_allowed) on the package",
            e.span))
        }
      }
      walkBlockCalls(ctx, blk)
    }
    case EParen(inner)     -> walkExprCalls(ctx, inner)
    case ETry(inner)       -> walkExprCalls(ctx, inner)
    case EOld(inner)       -> walkExprCalls(ctx, inner)
    case EPropagate(inner) -> walkExprCalls(ctx, inner)
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        walkExprCalls(ctx, exprs[i])
        i = i + 1
      }
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        walkExprCalls(ctx, exprs[i])
        i = i + 1
      }
    }
    case EIf(cond, thenBranch, elseOpt, _) -> {
      walkExprCalls(ctx, cond)
      walkEobCalls(ctx, thenBranch)
      match elseOpt {
        case Some(eb) -> walkEobCalls(ctx, eb)
        case None     -> {}
      }
    }
    case EMatch(scrutinee, arms) -> {
      walkExprCalls(ctx, scrutinee)
      var ai = 0
      while ai < arms.count {
        val arm = arms[ai]
        walkEobCalls(ctx, arm.body)
        match arm.guard {
          case Some(g) -> walkExprCalls(ctx, g)
          case None    -> {}
        }
        ai = ai + 1
      }
    }
    case EForall(_, whereOpt, body) -> {
      walkExprCalls(ctx, body)
      match whereOpt {
        case Some(w) -> walkExprCalls(ctx, w)
        case None    -> {}
      }
    }
    case EExists(_, whereOpt, body) -> {
      walkExprCalls(ctx, body)
      match whereOpt {
        case Some(w) -> walkExprCalls(ctx, w)
        case None    -> {}
      }
    }
    case ETypeApp(fn, _)       -> walkExprCalls(ctx, fn)
    case EIndex(recv, indices) -> {
      walkExprCalls(ctx, recv)
      var ii = 0
      while ii < indices.count {
        walkExprCalls(ctx, indices[ii])
        ii = ii + 1
      }
    }
    case EMember(recv, _)  -> walkExprCalls(ctx, recv)
    case EPrefix(_, x)     -> walkExprCalls(ctx, x)
    case EBinop(_, l, r)   -> {
      walkExprCalls(ctx, l)
      walkExprCalls(ctx, r)
    }
    case EAssign(t, _, v)  -> {
      walkExprCalls(ctx, t)
      walkExprCalls(ctx, v)
    }
    case EBlock(blk)       -> walkBlockCalls(ctx, blk)
    case ELambda(_, body)  -> walkBlockCalls(ctx, body)
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(x)    -> walkExprCalls(ctx, x)
          case ISText(_, _) -> {}
        }
        si = si + 1
      }
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi)   -> { walkExprCalls(ctx, lo); walkExprCalls(ctx, hi) }
        case RBHalfOpen(lo, hi) -> { walkExprCalls(ctx, lo); walkExprCalls(ctx, hi) }
        case RBLowerOpen(hi)    -> walkExprCalls(ctx, hi)
        case RBUpperOpen(lo)    -> walkExprCalls(ctx, lo)
      }
    }
    case ELiteral(_) -> {}
    case EPath(_)    -> {}
    case ESelf       -> {}
    case EResult     -> {}
    case EError      -> {}
  }
}

func walkEobCalls(ctx: in WalkCtx, eob: in ExprOrBlock): Unit {
  match eob {
    case EOBExpr(e)    -> walkExprCalls(ctx, e)
    case EOBBlock(blk) -> walkBlockCalls(ctx, blk)
  }
}

func walkBlockCalls(ctx: in WalkCtx, blk: in Block): Unit {
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SLocal(binding) -> {
        match binding {
          case LBVal(_, _, init)  -> walkExprCalls(ctx, init)
          case LBLet(_, _, init)  -> walkExprCalls(ctx, init)
          case LBVar(_, _, initOpt) -> {
            match initOpt {
              case Some(init) -> walkExprCalls(ctx, init)
              case None       -> {}
            }
          }
        }
      }
      case SAssign(t, _, v)    -> { walkExprCalls(ctx, t); walkExprCalls(ctx, v) }
      case SReturn(valOpt)     -> {
        match valOpt {
          case Some(v) -> walkExprCalls(ctx, v)
          case None    -> {}
        }
      }
      case SThrow(x)           -> walkExprCalls(ctx, x)
      case STry(body, catches) -> {
        walkBlockCalls(ctx, body)
        var ci = 0
        while ci < catches.count {
          walkBlockCalls(ctx, catches[ci].body)
          ci = ci + 1
        }
      }
      case SDefer(body)        -> walkBlockCalls(ctx, body)
      case SScope(_, body)     -> walkBlockCalls(ctx, body)
      case SFor(_, _, iter, body) -> { walkExprCalls(ctx, iter); walkBlockCalls(ctx, body) }
      case SWhile(_, cond, body)  -> { walkExprCalls(ctx, cond); walkBlockCalls(ctx, body) }
      case SLoop(_, body)         -> walkBlockCalls(ctx, body)
      case SExpr(x)               -> walkExprCalls(ctx, x)
      case SInvariant(x)          -> walkExprCalls(ctx, x)
      case SRule(l, r)            -> { walkExprCalls(ctx, l); walkExprCalls(ctx, r) }
      case SBreak(_)    -> {}
      case SContinue(_) -> {}
      case SItem(_)     -> {}
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Check a single function (V0002/V0003/V0005).
// ─────────────────────────────────────────────────────────────────────────────

// V0005: walk a block looking for loops without `SInvariant` in their body.
func checkLoopInvariants(
  diag:   in List[Diagnostic],
  fnName: in String,
  blk:    in Block
): Unit {
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    match st.kind {
      case SFor(_, _, _, body) -> {
        if not bodyHasInvariant(body) {
          diag.add(errorDiagnostic("V0005",
            "loop in proof-required function '" + fnName +
            "' lacks an invariant: clause",
            st.span))
        }
        checkLoopInvariants(diag, fnName, body)
      }
      case SWhile(_, _, body) -> {
        if not bodyHasInvariant(body) {
          diag.add(errorDiagnostic("V0005",
            "loop in proof-required function '" + fnName +
            "' lacks an invariant: clause",
            st.span))
        }
        checkLoopInvariants(diag, fnName, body)
      }
      case SLoop(_, body) -> {
        if not bodyHasInvariant(body) {
          diag.add(errorDiagnostic("V0005",
            "loop in proof-required function '" + fnName +
            "' lacks an invariant: clause",
            st.span))
        }
        checkLoopInvariants(diag, fnName, body)
      }
      case STry(body, catches) -> {
        checkLoopInvariants(diag, fnName, body)
        var ci = 0
        while ci < catches.count {
          checkLoopInvariants(diag, fnName, catches[ci].body)
          ci = ci + 1
        }
      }
      case SDefer(body)    -> checkLoopInvariants(diag, fnName, body)
      case SScope(_, body) -> checkLoopInvariants(diag, fnName, body)
      case _ -> {}
    }
    i = i + 1
  }
}

func bodyHasInvariant(body: in Block): Bool {
  var i = 0
  while i < body.statements.count {
    match body.statements[i].kind {
      case SInvariant(_) -> { return true }
      case _             -> {}
    }
    i = i + 1
  }
  false
}

// Check one function for V0002/V0003/V0005.
// Only called when fnLevel is proof-required.
func checkFunctionCalls(
  fileLevel: in VerificationLevel,
  callees:   in Map[String, CalleeInfo],
  diag:      in List[Diagnostic],
  fn:        in FunctionDecl
): Unit {
  val fnLevel = levelOfFunction(fileLevel, fn)
  if not vlIsProofRequired(fnLevel) { return }

  val ctx = WalkCtx(
    fnName  = fn.name,
    fnLevel = fnLevel,
    callees = callees,
    diag    = diag)

  match fn.body {
    case None -> {}
    case Some(body) -> {
      match body {
        case FBExpr(e) -> walkExprCalls(ctx, e)
        case FBBlock(blk) -> {
          // Walk top-level statement expressions (matching F# checkFunction).
          var i = 0
          while i < blk.statements.count {
            val st = blk.statements[i]
            match st.kind {
              case SExpr(e)          -> walkExprCalls(ctx, e)
              case SAssign(t, _, v)  -> { walkExprCalls(ctx, t); walkExprCalls(ctx, v) }
              case SReturn(valOpt)   -> {
                match valOpt {
                  case Some(v) -> walkExprCalls(ctx, v)
                  case None    -> {}
                }
              }
              case SThrow(x)         -> walkExprCalls(ctx, x)
              case SLocal(binding)   -> {
                match binding {
                  case LBVal(_, _, init)    -> walkExprCalls(ctx, init)
                  case LBLet(_, _, init)    -> walkExprCalls(ctx, init)
                  case LBVar(_, _, initOpt) -> {
                    match initOpt {
                      case Some(init) -> walkExprCalls(ctx, init)
                      case None       -> {}
                    }
                  }
                }
              }
              case _ -> {}
            }
            i = i + 1
          }
          checkLoopInvariants(diag, fn.name, blk)
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. V0004 — @axiom function must not have a body.
// ─────────────────────────────────────────────────────────────────────────────

func checkAxiomBodies(
  fileLevel: in VerificationLevel,
  file:      in SourceFile,
  diag:      in List[Diagnostic]
): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(fileLevel, fn)
        match fnLevel {
          case VLAxiom -> {
            match fn.body {
              case Some(_) -> {
                diag.add(errorDiagnostic("V0004",
                  "@axiom function '" + fn.name + "' must not have a body",
                  fn.span))
              }
              case None -> {}
            }
          }
          case _ -> {}
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. V0006 — quantifier binders must have bounded domains.
// ─────────────────────────────────────────────────────────────────────────────

func isUnboundedDomain(te: in TypeExpr): Bool {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        nm == "Int"    or nm == "Long"   or nm == "Nat"    or
        nm == "Float"  or nm == "Double" or nm == "String" or
        nm == "UInt"   or nm == "ULong"
      } else {
        false
      }
    }
    case TRefined(_, _) -> false  // range subtype: bounded
    case TGenericApp(_, _) -> false
    case TArray(_, _) -> false
    case TSlice(_) -> false
    case _ -> false
  }
}

func walkExprQuantifiers(
  fileLevel: in VerificationLevel,
  diag:      in List[Diagnostic],
  e:         in Expr
): Unit {
  match e.kind {
    case EForall(binders, whereOpt, body) -> {
      var bi = 0
      while bi < binders.count {
        val b = binders[bi]
        if isUnboundedDomain(b.ty) {
          diag.add(errorDiagnostic("V0006",
            "quantifier binder '" + b.name +
            "' has unbounded domain in proof-required code; constrain to a slice, set, range subtype, or finite enum",
            b.span))
        }
        bi = bi + 1
      }
      walkExprQuantifiers(fileLevel, diag, body)
      match whereOpt {
        case Some(w) -> walkExprQuantifiers(fileLevel, diag, w)
        case None    -> {}
      }
    }
    case EExists(binders, whereOpt, body) -> {
      var bi = 0
      while bi < binders.count {
        val b = binders[bi]
        if isUnboundedDomain(b.ty) {
          diag.add(errorDiagnostic("V0006",
            "quantifier binder '" + b.name +
            "' has unbounded domain in proof-required code; constrain to a slice, set, range subtype, or finite enum",
            b.span))
        }
        bi = bi + 1
      }
      walkExprQuantifiers(fileLevel, diag, body)
      match whereOpt {
        case Some(w) -> walkExprQuantifiers(fileLevel, diag, w)
        case None    -> {}
      }
    }
    case EParen(inner)     -> walkExprQuantifiers(fileLevel, diag, inner)
    case EOld(inner)       -> walkExprQuantifiers(fileLevel, diag, inner)
    case ETry(inner)       -> walkExprQuantifiers(fileLevel, diag, inner)
    case EAwait(inner)     -> walkExprQuantifiers(fileLevel, diag, inner)
    case EYield(inner)     -> walkExprQuantifiers(fileLevel, diag, inner)
    case ESpawn(inner)     -> walkExprQuantifiers(fileLevel, diag, inner)
    case EPropagate(inner) -> walkExprQuantifiers(fileLevel, diag, inner)
    case ETuple(exprs)     -> walkExprQList(fileLevel, diag, exprs)
    case EList(exprs)      -> walkExprQList(fileLevel, diag, exprs)
    case EIf(cond, thenBranch, elseOpt, _) -> {
      walkExprQuantifiers(fileLevel, diag, cond)
      walkEobQuantifiers(fileLevel, diag, thenBranch)
      match elseOpt {
        case Some(eb) -> walkEobQuantifiers(fileLevel, diag, eb)
        case None     -> {}
      }
    }
    case EMatch(scrutinee, arms) -> {
      walkExprQuantifiers(fileLevel, diag, scrutinee)
      var ai = 0
      while ai < arms.count {
        val arm = arms[ai]
        walkEobQuantifiers(fileLevel, diag, arm.body)
        match arm.guard {
          case Some(g) -> walkExprQuantifiers(fileLevel, diag, g)
          case None    -> {}
        }
        ai = ai + 1
      }
    }
    case ECall(fn, args) -> {
      walkExprQuantifiers(fileLevel, diag, fn)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CANamed(_, v, _) -> walkExprQuantifiers(fileLevel, diag, v)
          case CAPositional(v)  -> walkExprQuantifiers(fileLevel, diag, v)
        }
        ai = ai + 1
      }
    }
    case ETypeApp(fn, _)       -> walkExprQuantifiers(fileLevel, diag, fn)
    case EIndex(recv, indices) -> {
      walkExprQuantifiers(fileLevel, diag, recv)
      walkExprQList(fileLevel, diag, indices)
    }
    case EMember(recv, _)  -> walkExprQuantifiers(fileLevel, diag, recv)
    case EPrefix(_, x)     -> walkExprQuantifiers(fileLevel, diag, x)
    case EBinop(_, l, r)   -> {
      walkExprQuantifiers(fileLevel, diag, l)
      walkExprQuantifiers(fileLevel, diag, r)
    }
    case EAssign(t, _, v)  -> {
      walkExprQuantifiers(fileLevel, diag, t)
      walkExprQuantifiers(fileLevel, diag, v)
    }
    case EBlock(blk)       -> walkBlockQuantifiers(fileLevel, diag, blk)
    case EUnsafe(blk)      -> walkBlockQuantifiers(fileLevel, diag, blk)
    case ELambda(_, body)  -> walkBlockQuantifiers(fileLevel, diag, body)
    case _                 -> {}
  }
}

func walkExprQList(
  fileLevel: in VerificationLevel,
  diag:      in List[Diagnostic],
  exprs:     in List[Expr]
): Unit {
  var i = 0
  while i < exprs.count {
    walkExprQuantifiers(fileLevel, diag, exprs[i])
    i = i + 1
  }
}

func walkEobQuantifiers(
  fileLevel: in VerificationLevel,
  diag:      in List[Diagnostic],
  eob:       in ExprOrBlock
): Unit {
  match eob {
    case EOBExpr(e)    -> walkExprQuantifiers(fileLevel, diag, e)
    case EOBBlock(blk) -> walkBlockQuantifiers(fileLevel, diag, blk)
  }
}

func walkBlockQuantifiers(
  fileLevel: in VerificationLevel,
  diag:      in List[Diagnostic],
  blk:       in Block
): Unit {
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    match st.kind {
      case SExpr(x)            -> walkExprQuantifiers(fileLevel, diag, x)
      case SAssign(t, _, v)    -> { walkExprQuantifiers(fileLevel, diag, t); walkExprQuantifiers(fileLevel, diag, v) }
      case SReturn(valOpt)     -> {
        match valOpt {
          case Some(v) -> walkExprQuantifiers(fileLevel, diag, v)
          case None    -> {}
        }
      }
      case SThrow(x)           -> walkExprQuantifiers(fileLevel, diag, x)
      case SLocal(binding)     -> {
        match binding {
          case LBVal(_, _, init)    -> walkExprQuantifiers(fileLevel, diag, init)
          case LBLet(_, _, init)    -> walkExprQuantifiers(fileLevel, diag, init)
          case LBVar(_, _, initOpt) -> {
            match initOpt {
              case Some(init) -> walkExprQuantifiers(fileLevel, diag, init)
              case None       -> {}
            }
          }
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

func checkQuantifierDomains(
  fileLevel: in VerificationLevel,
  file:      in SourceFile,
  diag:      in List[Diagnostic]
): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(fileLevel, fn)
        if vlIsProofRequired(fnLevel) {
          var ci = 0
          while ci < fn.contracts.count {
            match fn.contracts[ci] {
              case CCRequires(expr, _)  -> walkExprQuantifiers(fileLevel, diag, expr)
              case CCEnsures(expr, _)   -> walkExprQuantifiers(fileLevel, diag, expr)
              case CCWhen(expr, _)      -> walkExprQuantifiers(fileLevel, diag, expr)
              case CCDecreases(expr, _) -> walkExprQuantifiers(fileLevel, diag, expr)
              case CCRaises(_, _)       -> {}
            }
            ci = ci + 1
          }
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. V0009 — `assume` only in unsafe blocks in proof-required code.
// ─────────────────────────────────────────────────────────────────────────────

func walkExprAssume(
  diag:     in List[Diagnostic],
  inUnsafe: in Bool,
  e:        in Expr
): Unit {
  match e.kind {
    case ECall(callee, args) -> {
      match callee.kind {
        case EPath(path) -> {
          if path.segments.count == 1 and path.segments[0] == "assume" and not inUnsafe {
            diag.add(errorDiagnostic("V0009",
              "assume may only appear inside an unsafe { } block in proof-required code; wrap in unsafe { } or remove",
              e.span))
          }
        }
        case _ -> {}
      }
      walkExprAssume(diag, inUnsafe, callee)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CANamed(_, v, _) -> walkExprAssume(diag, inUnsafe, v)
          case CAPositional(v)  -> walkExprAssume(diag, inUnsafe, v)
        }
        ai = ai + 1
      }
    }
    case EUnsafe(blk)      -> walkBlockAssume(diag, true, blk)
    case EBlock(blk)       -> walkBlockAssume(diag, inUnsafe, blk)
    case EParen(inner)     -> walkExprAssume(diag, inUnsafe, inner)
    case EOld(inner)       -> walkExprAssume(diag, inUnsafe, inner)
    case ETry(inner)       -> walkExprAssume(diag, inUnsafe, inner)
    case EAwait(inner)     -> walkExprAssume(diag, inUnsafe, inner)
    case EYield(inner)     -> walkExprAssume(diag, inUnsafe, inner)
    case ESpawn(inner)     -> walkExprAssume(diag, inUnsafe, inner)
    case EPropagate(inner) -> walkExprAssume(diag, inUnsafe, inner)
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        walkExprAssume(diag, inUnsafe, exprs[i])
        i = i + 1
      }
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        walkExprAssume(diag, inUnsafe, exprs[i])
        i = i + 1
      }
    }
    case EIf(cond, thenBranch, elseOpt, _) -> {
      walkExprAssume(diag, inUnsafe, cond)
      walkEobAssume(diag, inUnsafe, thenBranch)
      match elseOpt {
        case Some(eb) -> walkEobAssume(diag, inUnsafe, eb)
        case None     -> {}
      }
    }
    case EMatch(scrutinee, arms) -> {
      walkExprAssume(diag, inUnsafe, scrutinee)
      var ai = 0
      while ai < arms.count {
        val arm = arms[ai]
        walkEobAssume(diag, inUnsafe, arm.body)
        match arm.guard {
          case Some(g) -> walkExprAssume(diag, inUnsafe, g)
          case None    -> {}
        }
        ai = ai + 1
      }
    }
    case EForall(_, whereOpt, body) -> {
      walkExprAssume(diag, inUnsafe, body)
      match whereOpt {
        case Some(w) -> walkExprAssume(diag, inUnsafe, w)
        case None    -> {}
      }
    }
    case EExists(_, whereOpt, body) -> {
      walkExprAssume(diag, inUnsafe, body)
      match whereOpt {
        case Some(w) -> walkExprAssume(diag, inUnsafe, w)
        case None    -> {}
      }
    }
    case ETypeApp(fn, _)       -> walkExprAssume(diag, inUnsafe, fn)
    case EIndex(recv, indices) -> {
      walkExprAssume(diag, inUnsafe, recv)
      var ii = 0
      while ii < indices.count {
        walkExprAssume(diag, inUnsafe, indices[ii])
        ii = ii + 1
      }
    }
    case EMember(recv, _)  -> walkExprAssume(diag, inUnsafe, recv)
    case EPrefix(_, x)     -> walkExprAssume(diag, inUnsafe, x)
    case EBinop(_, l, r)   -> {
      walkExprAssume(diag, inUnsafe, l)
      walkExprAssume(diag, inUnsafe, r)
    }
    case EAssign(t, _, v)  -> {
      walkExprAssume(diag, inUnsafe, t)
      walkExprAssume(diag, inUnsafe, v)
    }
    case ELambda(_, body)  -> walkBlockAssume(diag, inUnsafe, body)
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(x)    -> walkExprAssume(diag, inUnsafe, x)
          case ISText(_, _) -> {}
        }
        si = si + 1
      }
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi)   -> { walkExprAssume(diag, inUnsafe, lo); walkExprAssume(diag, inUnsafe, hi) }
        case RBHalfOpen(lo, hi) -> { walkExprAssume(diag, inUnsafe, lo); walkExprAssume(diag, inUnsafe, hi) }
        case RBLowerOpen(hi)    -> walkExprAssume(diag, inUnsafe, hi)
        case RBUpperOpen(lo)    -> walkExprAssume(diag, inUnsafe, lo)
      }
    }
    case ELiteral(_) -> {}
    case EPath(_)    -> {}
    case ESelf       -> {}
    case EResult     -> {}
    case EError      -> {}
  }
}

func walkEobAssume(
  diag:     in List[Diagnostic],
  inUnsafe: in Bool,
  eob:      in ExprOrBlock
): Unit {
  match eob {
    case EOBExpr(e)    -> walkExprAssume(diag, inUnsafe, e)
    case EOBBlock(blk) -> walkBlockAssume(diag, inUnsafe, blk)
  }
}

func walkBlockAssume(
  diag:     in List[Diagnostic],
  inUnsafe: in Bool,
  blk:      in Block
): Unit {
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    match st.kind {
      case SExpr(x)            -> walkExprAssume(diag, inUnsafe, x)
      case SAssign(t, _, v)    -> { walkExprAssume(diag, inUnsafe, t); walkExprAssume(diag, inUnsafe, v) }
      case SReturn(valOpt)     -> {
        match valOpt {
          case Some(v) -> walkExprAssume(diag, inUnsafe, v)
          case None    -> {}
        }
      }
      case SThrow(x)           -> walkExprAssume(diag, inUnsafe, x)
      case SInvariant(x)       -> walkExprAssume(diag, inUnsafe, x)
      case SLocal(binding)     -> {
        match binding {
          case LBVal(_, _, init)    -> walkExprAssume(diag, inUnsafe, init)
          case LBLet(_, _, init)    -> walkExprAssume(diag, inUnsafe, init)
          case LBVar(_, _, initOpt) -> {
            match initOpt {
              case Some(init) -> walkExprAssume(diag, inUnsafe, init)
              case None       -> {}
            }
          }
        }
      }
      case STry(body, catches)    -> {
        walkBlockAssume(diag, inUnsafe, body)
        var ci = 0
        while ci < catches.count {
          walkBlockAssume(diag, inUnsafe, catches[ci].body)
          ci = ci + 1
        }
      }
      case SDefer(body)           -> walkBlockAssume(diag, inUnsafe, body)
      case SScope(_, body)        -> walkBlockAssume(diag, inUnsafe, body)
      case SFor(_, _, iter, body) -> {
        walkExprAssume(diag, inUnsafe, iter)
        walkBlockAssume(diag, inUnsafe, body)
      }
      case SWhile(_, cond, body)  -> {
        walkExprAssume(diag, inUnsafe, cond)
        walkBlockAssume(diag, inUnsafe, body)
      }
      case SLoop(_, body)         -> walkBlockAssume(diag, inUnsafe, body)
      case SRule(l, r)            -> { walkExprAssume(diag, inUnsafe, l); walkExprAssume(diag, inUnsafe, r) }
      case SBreak(_)    -> {}
      case SContinue(_) -> {}
      case SItem(_)     -> {}
    }
    i = i + 1
  }
}

func checkAssumeUsage(
  fileLevel: in VerificationLevel,
  file:      in SourceFile,
  diag:      in List[Diagnostic]
): Unit {
  if not vlIsProofRequired(fileLevel) { return }
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(fileLevel, fn)
        if vlIsProofRequired(fnLevel) {
          match fn.body {
            case None -> {}
            case Some(body) -> {
              match body {
                case FBExpr(e)    -> walkExprAssume(diag, false, e)
                case FBBlock(blk) -> walkBlockAssume(diag, false, blk)
              }
            }
          }
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. V0001 — @proof_required package must not import @runtime_checked.
// ─────────────────────────────────────────────────────────────────────────────

func levelStringToMode(s: in String): VerificationLevel {
  if s == "proof_required"              { return VLProofRequired }
  if s == "proof_required_unsafe"       { return VLProofRequiredUnsafe }
  if s == "proof_required_checked"      { return VLProofRequiredChecked }
  if s == "axiom"                       { return VLAxiom }
  VLRuntimeChecked
}

func checkImportLevels(
  fileLevel: in VerificationLevel,
  file:      in SourceFile,
  imports:   in List[ImportedMeta],
  diag:      in List[Diagnostic]
): Unit {
  if not vlIsProofRequired(fileLevel) { return }
  var i = 0
  while i < file.imports.count {
    val imp = file.imports[i]
    val segs = imp.path.segments
    val pkgName: String =
      if segs.count == 0 {
        ""
      } else {
        var nm = segs[0]
        var si = 1
        while si < segs.count {
          nm = nm + "." + segs[si]
          si = si + 1
        }
        nm
      }
    if pkgName != "" {
      var ji = 0
      while ji < imports.count {
        if imports[ji].name == pkgName {
          val calleeLevel = levelStringToMode(imports[ji].level)
          match calleeLevel {
            case VLRuntimeChecked -> {
              diag.add(errorDiagnostic("V0001",
                "proof-required package may not import @runtime_checked package '" +
                pkgName +
                "'; mark callees @axiom or shift to @runtime_checked",
                imp.span))
            }
            case _ -> {}
          }
        }
        ji = ji + 1
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public entry points.
// ─────────────────────────────────────────────────────────────────────────────

pub func checkFileWithImports(
  file:    in SourceFile,
  imports: in List[ImportedMeta]
): ModeCheckResult {
  val diag: List[Diagnostic] = newList()
  val fileLevel = levelOfFile(file, diag)
  if not vlIsProofRequired(fileLevel) {
    return ModeCheckResult(level = fileLevel, diagnostics = diag)
  }
  val callees = calleeTableOfFile(fileLevel, file)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> checkFunctionCalls(fileLevel, callees, diag, fn)
      case _         -> {}
    }
    i = i + 1
  }
  checkAxiomBodies(fileLevel, file, diag)
  checkQuantifierDomains(fileLevel, file, diag)
  checkAssumeUsage(fileLevel, file, diag)
  checkImportLevels(fileLevel, file, imports, diag)
  ModeCheckResult(level = fileLevel, diagnostics = diag)
}

pub func checkFile(file: in SourceFile): ModeCheckResult {
  val imports: List[ImportedMeta] = newList()
  checkFileWithImports(file, imports)
}
