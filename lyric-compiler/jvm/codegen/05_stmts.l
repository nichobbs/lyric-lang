//! jvm/codegen_5_stmts.l — Jvm.Codegen: statement and block lowering.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! Assignment-expression lowering, statement lowering, local pattern binding,
//! try/catch lowering, and block lowering.
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

// ─────────────────────────────────────────────────────────────────────────────
// §5d. Assignment expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerAssignExpr(ctx: in FuncCtx, insns: in List[LInsn], target: in Expr, op: in AssignOp, value: in Expr): JvmType {
  match target.kind {
    case EPath(path) -> {
      val name = lastSegment(path)
      match lookupSlot(ctx, name) {
        case Some(slot) -> {
          val ty = match lookupType(ctx, name) { case Some(t) -> t; case None -> JRef(className = "java/lang/Object") }
          match op {
            case AssEq -> {
              lowerExpr(ctx, insns, value)
              emitStore(insns, slot, ty)
            }
            case AssPlus -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong -> insns.add(LLadd)
                case JDouble -> insns.add(LDadd)
                case _ -> insns.add(LIadd)
              }
              emitStore(insns, slot, ty)
            }
            case AssMinus -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong -> insns.add(LLsub)
                case JDouble -> insns.add(LDsub)
                case _ -> insns.add(LIsub)
              }
              emitStore(insns, slot, ty)
            }
            case AssStar -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong -> insns.add(LLmul)
                case JDouble -> insns.add(LDmul)
                case _ -> insns.add(LImul)
              }
              emitStore(insns, slot, ty)
            }
            case AssSlash -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong -> insns.add(LLdiv)
                case JDouble -> insns.add(LDdiv)
                case _ -> insns.add(LIdiv)
              }
              emitStore(insns, slot, ty)
            }
            case AssPercent -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong -> insns.add(LLrem)
                case _ -> insns.add(LIrem)
              }
              emitStore(insns, slot, ty)
            }
          }
          JVoid
        }
        case None -> {
          // Unknown variable — lower the value but don't store it.
          lowerExpr(ctx, insns, value)
          insns.add(LPop)
          JVoid
        }
      }
    }
    case _ -> {
      // Complex assignment targets (member, index) not yet supported.
      lowerExpr(ctx, insns, value)
      insns.add(LPop)
      JVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Statement lowering.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerStmt(ctx: in FuncCtx, insns: in List[LInsn], stmt: in Statement): Unit {
  match stmt.kind {

    // ── Local bindings ─────────────────────────────────────────────────────
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val initTy = lowerExpr(ctx, insns, init)
          lowerLocalPatBind(ctx, insns, pat, initTy, tyOpt)
        }
        case LBLet(name, tyOpt, init) -> {
          val initTy = lowerExpr(ctx, insns, init)
          val ty = match tyOpt { case Some(te) -> typeExprToJvm(te, ctx.pkgName); case None -> initTy }
          val slot = allocSlot(ctx, name, ty)
          emitStore(insns, slot, ty)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          val ty = match tyOpt { case Some(te) -> typeExprToJvm(te, ctx.pkgName); case None -> JInt }
          match initOpt {
            case Some(init) -> {
              val initTy = lowerExpr(ctx, insns, init)
              val slot = allocSlot(ctx, name, ty)
              emitStore(insns, slot, ty)
            }
            case None -> {
              val slot = allocSlot(ctx, name, ty)
              match ty {
                case JLong -> {
                  insns.add(LLconst(v = 0i64))
                  emitStore(insns, slot, ty)
                }
                case JDouble -> {
                  insns.add(LDconst(v = 0.0))
                  emitStore(insns, slot, ty)
                }
                case JRef(_) -> {
                  insns.add(LAconstNull)
                  emitStore(insns, slot, ty)
                }
                case JArray(_) -> {
                  insns.add(LAconstNull)
                  emitStore(insns, slot, ty)
                }
                case JVoid -> insns.add(LNop)
                case _ -> {
                  insns.add(LIconst(v = 0))
                  emitStore(insns, slot, ty)
                }
              }
            }
          }
        }
      }
    }

    // ── Return ─────────────────────────────────────────────────────────────
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          val ty = lowerExpr(ctx, insns, e)
          emitReturn(insns, ty)
        }
        case None -> {
          insns.add(LReturn)
        }
      }
    }

    // ── Expression statement ───────────────────────────────────────────────
    case SExpr(e) -> {
      val ty = lowerExpr(ctx, insns, e)
      match ty {
        case JVoid -> insns.add(LNop)
        case _ -> insns.add(LPop)
      }
    }

    // ── While loop ─────────────────────────────────────────────────────────
    case SWhile(_, cond, body) -> {
      val loopL = freshLabel(ctx)
      val afterL = freshLabel(ctx)
      insns.add(LLabel(name = loopL))
      lowerBoolCond(ctx, insns, cond, afterL)
      ctx.loopBreak.add(afterL)
      ctx.loopCont.add(loopL)
      lowerBlock(ctx, insns, body)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      insns.add(LGoto(label = loopL))
      insns.add(LLabel(name = afterL))
    }

    // ── For loop (over array) ──────────────────────────────────────────────
    case SFor(_, pat, iter, body) -> {
      val iterTy = lowerExpr(ctx, insns, iter)
      match iterTy {
        case JArray(elemArr) -> {
          // Array: index-based loop.
          val arrSlot = allocSlot(ctx, "__arr_" + toString(ctx.slotTicker.count), iterTy)
          emitStore(insns, arrSlot, iterTy)
          val iSlot = allocSlot(ctx, "__for_i_" + toString(ctx.slotTicker.count), JInt)
          insns.add(LIconst(v = 0))
          emitStore(insns, iSlot, JInt)
          val lenSlot = allocSlot(ctx, "__for_len_" + toString(ctx.slotTicker.count), JInt)
          emitLoad(insns, arrSlot, iterTy)
          insns.add(LArraylength)
          emitStore(insns, lenSlot, JInt)
          val loopLA = freshLabel(ctx)
          val endLA = freshLabel(ctx)
          insns.add(LLabel(name = loopLA))
          emitLoad(insns, iSlot, JInt)
          emitLoad(insns, lenSlot, JInt)
          insns.add(LIfIcmpge(label = endLA))
          emitLoad(insns, arrSlot, iterTy)
          emitLoad(insns, iSlot, JInt)
          insns.add(LAaload)
          val elemTyA = JRef(className = "java/lang/Object")
          val elemSlotA = allocSlot(ctx, "__for_elem_" + toString(ctx.slotTicker.count), elemTyA)
          emitStore(insns, elemSlotA, elemTyA)
          lowerPatternBind(ctx, insns, pat, elemSlotA, elemTyA)
          lowerBlock(ctx, insns, body)
          emitLoad(insns, iSlot, JInt)
          insns.add(LIconst(v = 1))
          insns.add(LIadd)
          emitStore(insns, iSlot, JInt)
          insns.add(LGoto(label = loopLA))
          insns.add(LLabel(name = endLA))
        }
        case _ -> {
          // Iterable<Object>: use iterator()/hasNext()/next().
          // Works for both ArrayList and async-generator Iterable classes.
          val iterableClass = "java/lang/Iterable"
          val iteratorClass = "java/util/Iterator"
          val objTy = JRef(className = "java/lang/Object")
          val iterableSlot = allocSlot(ctx, "__iterable_" + toString(ctx.slotTicker.count), objTy)
          emitStore(insns, iterableSlot, objTy)
          // Call .iterator() to get an Iterator.
          emitLoad(insns, iterableSlot, objTy)
          val iterPs: List[JvmType] = newList()
          insns.add(
            LInvokeinterface(
              owner = iterableClass,
              name = "iterator",
              params = iterPs,
              ret = JRef(className = iteratorClass),
              argCount = 1
            )
          )
          val itorSlot = allocSlot(ctx, "__itor_" + toString(ctx.slotTicker.count), objTy)
          emitStore(insns, itorSlot, objTy)
          val loopLB = freshLabel(ctx)
          val endLB = freshLabel(ctx)
          insns.add(LLabel(name = loopLB))
          // hasNext()
          emitLoad(insns, itorSlot, objTy)
          val hnPs: List[JvmType] = newList()
          insns.add(LInvokeinterface(owner = iteratorClass, name = "hasNext", params = hnPs, ret = JBoolean, argCount = 1))
          insns.add(LIfeq(label = endLB))
          // next()
          emitLoad(insns, itorSlot, objTy)
          val nextPs: List[JvmType] = newList()
          insns.add(
            LInvokeinterface(
              owner = iteratorClass,
              name = "next",
              params = nextPs,
              ret = JRef(className = "java/lang/Object"),
              argCount = 1
            )
          )
          val elemTyB = JRef(className = "java/lang/Object")
          val elemSlotB = allocSlot(ctx, "__for_elem_" + toString(ctx.slotTicker.count), elemTyB)
          emitStore(insns, elemSlotB, elemTyB)
          lowerPatternBind(ctx, insns, pat, elemSlotB, elemTyB)
          lowerBlock(ctx, insns, body)
          insns.add(LGoto(label = loopLB))
          insns.add(LLabel(name = endLB))
        }
      }
    }

    // ── Loop (unconditional) ───────────────────────────────────────────────
    case SLoop(_, body) -> {
      val loopL3 = freshLabel(ctx)
      insns.add(LLabel(name = loopL3))
      lowerBlock(ctx, insns, body)
      insns.add(LGoto(label = loopL3))
    }

    // ── Assignment statement ───────────────────────────────────────────────
    case SAssign(target, op, value) -> {
      lowerAssignExpr(ctx, insns, target, op, value)
      insns.add(LNop)
    }

    // ── Throw ──────────────────────────────────────────────────────────────
    case SThrow(e) -> {
      lowerExpr(ctx, insns, e)
      insns.add(LAthrow)
    }

    // ── Break / continue ──────────────────────────────────────────────────
    case SBreak(_) -> {
      if ctx.loopBreak.count > 0 {
        insns.add(LGoto(label = ctx.loopBreak[ctx.loopBreak.count - 1]))
      } else {
        insns.add(LNop)
      }
    }

    case SContinue(_) -> {
      if ctx.loopCont.count > 0 {
        insns.add(LGoto(label = ctx.loopCont[ctx.loopCont.count - 1]))
      } else {
        insns.add(LNop)
      }
    }

    // ── Scope block ────────────────────────────────────────────────────────
    case SScope(_, body) -> {
      lowerBlock(ctx, insns, body)
    }

    // ── Defer ───────────────────────────────────────────────────────────────
    // `defer { D }` must run D at scope exit on every path (fall-off, return,
    // break/continue, exception unwind).  The MSIL backend lowers this to
    // `try { rest } finally { D }` (#1477); the JVM backend does not yet have
    // the equivalent lowering (it needs JVM return-through-finally first).
    // Running the body inline here would be a silent miscompile, so fail loudly
    // and point at the tracking issue rather than emitting wrong code.
    case SDefer(_) -> {
      panic(
        "Jvm.Codegen: `defer` is not yet supported on --target jvm — it " +
          "would require running the deferred block at scope exit (try/finally " +
          "lowering + return-through-finally).  Implemented for --target dotnet " +
          "in #1477; JVM parity is tracked in #1833.  Compile this program with " +
          "--target dotnet, or avoid `defer` on the JVM target for now."
      )
    }

    // ── Try/catch ─────────────────────────────────────────────────────────
    case STry(body, catches, finally_) -> {
      lowerTryCatch(ctx, insns, body, catches, finally_)
    }

    // ── Invariant annotation (runtime: skip) ──────────────────────────────
    case SInvariant(_) -> insns.add(LNop)

    // ── Inline item declaration (skip in bootstrap) ───────────────────────
    case SItem(_) -> insns.add(LNop)

    // ── Rule statement (skip) ─────────────────────────────────────────────
    case SRule(_, _) -> insns.add(LNop)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6a. Local pattern binding.
// ─────────────────────────────────────────────────────────────────────────────
func lowerLocalPatBind(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  pat: in Pattern,
  initTy: in JvmType,
  tyOpt: in Option[TypeExpr],
): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      val ty = match tyOpt { case Some(te) -> typeExprToJvm(te, ctx.pkgName); case None -> initTy }
      val slot = allocSlot(ctx, name, ty)
      emitStore(insns, slot, ty)
    }
    case PWildcard -> {
      // Discard the value.
      match initTy {
        case JVoid -> insns.add(LNop)
        case _ -> insns.add(LPop)
      }
    }
    case _ -> {
      // Complex pattern: store to a temp slot then bind.
      val tmpSlot = allocSlot(ctx, "__tmp_" + toString(ctx.slotTicker.count), initTy)
      emitStore(insns, tmpSlot, initTy)
      lowerPatternBind(ctx, insns, pat, tmpSlot, initTy)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Try/catch lowering.
// ─────────────────────────────────────────────────────────────────────────────
// Try/catch in *expression* position: `try { … } catch … ` whose value is the
// trailing expression of the try body or of a matching catch body.  Each arm's
// value is routed through a result local so the operand stack is empty at the
// `afterL` join (the StackMapTable declares an empty stack there — see
// lowerIfExpr).  Finally blocks are handled by the statement form only; callers
// pass try/finally-as-value through `lowerStmt` instead.
func lowerTryCatchExpr(ctx: in FuncCtx, insns: in List[LInsn], body: in Block, catches: in List[CatchClause]): JvmType {
  val startL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  val rslotName = "__try_r_" + afterL
  var rslot = -1

  insns.add(LLabel(name = startL))
  val resultTy = lowerBlockExpr(ctx, insns, body)
  match resultTy {
    case JVoid -> ()
    case _ -> {
      rslot = allocSlot(ctx, rslotName, resultTy)
      emitStore(insns, rslot, resultTy)
    }
  }
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = endL))

  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerL = freshLabel(ctx)
    insns.add(LLabel(name = handlerL))
    val exTy = JRef(className = "java/lang/Throwable")
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlot(ctx, bname, exTy)
        emitStore(insns, exSlot, exTy)
      }
      case None -> insns.add(LPop)
    }
    val catchBodyTy = lowerBlockExpr(ctx, insns, c.body)
    match resultTy {
      case JVoid -> ()
      case _ -> {
        if rslot < 0 {
          rslot = allocSlot(ctx, rslotName, resultTy)
        }
        // Use the lowered catch-body type for the store so an arm whose
        // actual produced kind differs from the try-body type (a documented
        // type-checker gap) emits the matching `istore`/`astore` variant
        // and the JVM verifier doesn't reject a mismatched store (#1681).
        // The result slot is sized by `resultTy`; widths must match, which
        // the type-checker normally guarantees.
        //
        // KNOWN LIMITATION (#2042): when `catchBodyTy == JVoid` and
        // `resultTy != JVoid`, the catch body evaluated in statement mode and
        // pushed nothing onto the operand stack.  Falling back to
        // `emitStore(insns, rslot, resultTy)` will still pop a value that
        // isn't there, producing the same class of VerifyError this PR fixed
        // for the non-void case.  This path is guarded by the type-checker
        // guarantee that widths must match; when the documented type-checker
        // gap allows a mismatch here, the generated class will fail to load.
        // Fix pending the underlying type-checker repair.
        match catchBodyTy {
          case JVoid -> emitStore(insns, rslot, resultTy)
          case _ -> emitStore(insns, rslot, catchBodyTy)
        }
      }
    }
    insns.add(LGoto(label = afterL))
    val catchClass = if c.typeName == "Bug" { "java/lang/Throwable" } else { lyricNameToJvm(c.typeName) }
    insns.add(LTryCatch(startLabel = startL, endLabel = endL, handlerLabel = handlerL, catchClass = catchClass))
    i = i + 1
  }

  insns.add(LLabel(name = afterL))
  match resultTy {
    case JVoid -> ()
    case _ -> {
      if rslot >= 0 {
        emitResultLoad(insns, rslot, resultTy)
      }
    }
  }
  resultTy
}

func lowerTryCatch(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  body: in Block,
  catches: in List[CatchClause],
  finally_: in Option[Block],
): Unit {
  val startL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  val afterL = freshLabel(ctx)

  insns.add(LLabel(name = startL))
  lowerBlock(ctx, insns, body)
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = endL))

  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerL = freshLabel(ctx)
    insns.add(LLabel(name = handlerL))
    // The exception is on the stack.
    val exTy = JRef(className = "java/lang/Throwable")
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlot(ctx, bname, exTy)
        emitStore(insns, exSlot, exTy)
      }
      case None -> {
        insns.add(LPop)
      }
    }
    lowerBlock(ctx, insns, c.body)
    insns.add(LGoto(label = afterL))
    // Register exception table entry for this catch arm.
    // Specific catches only cover the try body ([startL, endL)).
    // typeName is a dotted class name string like "java.lang.Exception".
    // The Lyric `Bug` panic type (raised by `panic(...)`, which lowers to a
    // `new java/lang/RuntimeException`) has no JVM class of its own — map it
    // to `java/lang/Throwable` so the exception-table entry resolves at class
    // load (otherwise: NoClassDefFoundError: Bug).  This mirrors the MSIL
    // backend mapping `Bug` to `System.Exception`.
    val catchClass = if c.typeName == "Bug" { "java/lang/Throwable" } else { lyricNameToJvm(c.typeName) }
    insns.add(LTryCatch(startLabel = startL, endLabel = endL, handlerLabel = handlerL, catchClass = catchClass))
    i = i + 1
  }

  // When a finally block is present, emit a catch-all handler that runs
  // the finally block then rethrows, covering the try body and all catch
  // bodies.  The range [startL, finallyExL) excludes the handler itself,
  // preventing recursive dispatch into it.
  //
  // Normal-path execution reaches afterL, where the finally block is
  // emitted once more (duplicate copy, identical to javac's strategy).
  match finally_ {
    case None -> {
      insns.add(LLabel(name = afterL))
    }
    case Some(fb) -> {
      val finallyExL = freshLabel(ctx)
      insns.add(LLabel(name = finallyExL))
      val exTy = JRef(className = "java/lang/Throwable")
      val tmpName = "__finally_ex_" + toString(ctx.labelTicker.count)
      val tmpSlot = allocSlot(ctx, tmpName, exTy)
      emitStore(insns, tmpSlot, exTy)
      lowerBlock(ctx, insns, fb)
      emitLoad(insns, tmpSlot, exTy)
      insns.add(LAthrow)
      // Catch-all entry: covers try body ([startL, endL)) and all catch
      // handler bodies ([endL, finallyExL)).  endLabel = finallyExL means
      // the handler code itself is not covered (self-exclusion).
      insns.add(LTryCatch(startLabel = startL, endLabel = finallyExL, handlerLabel = finallyExL, catchClass = ""))
      // Normal path: finally runs here after successful try/catch completion.
      insns.add(LLabel(name = afterL))
      lowerBlock(ctx, insns, fb)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Block lowering.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerBlock(ctx: in FuncCtx, insns: in List[LInsn], block: in Block): Unit {
  var i = 0
  while i < block.statements.count {
    lowerStmt(ctx, insns, block.statements[i])
    i = i + 1
  }
}
