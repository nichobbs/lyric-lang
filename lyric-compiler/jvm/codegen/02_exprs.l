//! jvm/codegen/02_exprs.l — Jvm.Codegen: expression lowering.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! lowerExpr and its comparison, boolean-condition, if/block, interpolated-string,
//! and boxing helpers.
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
// Forward declarations: lowerExpr / lowerBlock / lowerStmt are mutually
// recursive.  In Lyric this is supported via the natural forward-reference
// rules — all three are in the same package and file, so they can call each
// other freely.
// Select the NaN-correct float/double compare opcode for `op`.
//
// `fcmpl`/`dcmpl` push -1 when either operand is NaN; `fcmpg`/`dcmpg` push +1.
// IEEE 754 §5.11 requires every NaN comparison to be false (except `!=`, which
// is true), so `<` and `<=` must use the "g" variant (NaN → +1, so the
// `iflt`/`ifle` branch is not taken → false) while `>`, `>=`, `==`, and `!=`
// use the "l" variant (NaN → -1, so `ifgt`/`ifge` are not taken → false, and
// `ifeq` for `==` is not taken while `ifne` for `!=` is — both correct).  This
// is the standard javac pattern.
func floatCmpInsn(op: in BinOp, isDouble: in Bool): LInsn {
  val useG = match op { case BLt -> true; case BLte -> true; case _ -> false }
  if isDouble {
    if useG {
      LDcmpg
    } else {
      LDcmpl
    }
  } else {
    if useG {
      LFcmpg
    } else {
      LFcmpl
    }
  }
}

// Lower a comparison expression.  lhs type determines which comparison is used.
func lowerCmp(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  op: in BinOp,
  lhsTy: in JvmType,
  trueLabel: in String,
  falseLabel: in String,
): Unit {
  match lhsTy {
    case JLong -> {
      insns.add(LLcmp)
      match op {
        case BEq -> insns.add(LIfeq(label = trueLabel))
        case BNeq -> insns.add(LIfne(label = trueLabel))
        case BLt -> insns.add(LIflt(label = trueLabel))
        case BLte -> insns.add(LIfle(label = trueLabel))
        case BGt -> insns.add(LIfgt(label = trueLabel))
        case BGte -> insns.add(LIfge(label = trueLabel))
        case _ -> panic("Jvm.Codegen: unsupported long comparison op")
      }
    }
    case JDouble -> {
      insns.add(floatCmpInsn(op, true))
      match op {
        case BEq -> insns.add(LIfeq(label = trueLabel))
        case BNeq -> insns.add(LIfne(label = trueLabel))
        case BLt -> insns.add(LIflt(label = trueLabel))
        case BLte -> insns.add(LIfle(label = trueLabel))
        case BGt -> insns.add(LIfgt(label = trueLabel))
        case BGte -> insns.add(LIfge(label = trueLabel))
        case _ -> panic("Jvm.Codegen: unsupported double comparison op")
      }
    }
    case JFloat -> {
      insns.add(floatCmpInsn(op, false))
      match op {
        case BEq -> insns.add(LIfeq(label = trueLabel))
        case BNeq -> insns.add(LIfne(label = trueLabel))
        case BLt -> insns.add(LIflt(label = trueLabel))
        case BLte -> insns.add(LIfle(label = trueLabel))
        case BGt -> insns.add(LIfgt(label = trueLabel))
        case BGte -> insns.add(LIfge(label = trueLabel))
        case _ -> panic("Jvm.Codegen: unsupported float comparison op")
      }
    }
    case JRef(cls) -> {
      // `String == / !=` must compare by value (`String.equals`), not by
      // reference (`if_acmpeq`): two equal strings built independently (e.g. a
      // computed digest vs. a literal) have distinct identities, so reference
      // equality would wrongly report them unequal.  Other reference types keep
      // identity comparison.  Operands are on the stack as [lhs, rhs].
      if cls == "java/lang/String" {
        match op {
          case BEq -> {
            val eqPs: List[JvmType] = newList()
            eqPs.add(JRef(className = "java/lang/Object"))
            insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
            insns.add(LIfne(label = trueLabel))
          }
          case BNeq -> {
            val eqPs2: List[JvmType] = newList()
            eqPs2.add(JRef(className = "java/lang/Object"))
            insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs2, ret = JBoolean))
            insns.add(LIfeq(label = trueLabel))
          }
          // Relational String comparison is lexicographic `compareTo` vs 0
          // (`a < b` in Std.Sort's string comparator previously emitted
          // `equals` + a nop placeholder — wrong result AND a stackmap
          // mismatch from the value left on the stack).
          case BLt -> {
            emitStringCompareTo(insns)
            insns.add(LIflt(label = trueLabel))
          }
          case BLte -> {
            emitStringCompareTo(insns)
            insns.add(LIfle(label = trueLabel))
          }
          case BGt -> {
            emitStringCompareTo(insns)
            insns.add(LIfgt(label = trueLabel))
          }
          case BGte -> {
            emitStringCompareTo(insns)
            insns.add(LIfge(label = trueLabel))
          }
          case _ -> panic("Jvm.Codegen: unsupported String comparison op")
        }
      } else {
        // Lyric `==` is VALUE equality on every reference type (String
        // compares by content; records/unions carry synthesized `equals`),
        // so erased/unknown reference operands dispatch through the
        // null-safe `Objects.equals` — identity (`if_acmpeq`) wrongly
        // reported two equal split-segment strings unequal
        // (`segs[i] == ".."` in lyric-storage's traversal guard).
        match op {
          case BEq -> {
            emitObjectsEquals(insns)
            insns.add(LIfne(label = trueLabel))
          }
          case BNeq -> {
            emitObjectsEquals(insns)
            insns.add(LIfeq(label = trueLabel))
          }
          case _ -> panic("Jvm.Codegen: unsupported reference comparison op")
        }
      }
    }
    case _ -> {
      // Integer comparison (int, bool, char, byte, short).
      match op {
        case BEq -> insns.add(LIfIcmpeq(label = trueLabel))
        case BNeq -> insns.add(LIfIcmpne(label = trueLabel))
        case BLt -> insns.add(LIfIcmplt(label = trueLabel))
        case BLte -> insns.add(LIfIcmple(label = trueLabel))
        case BGt -> insns.add(LIfIcmpgt(label = trueLabel))
        case BGte -> insns.add(LIfIcmpge(label = trueLabel))
        case _ -> panic("Jvm.Codegen: unsupported int comparison op")
      }
    }
  }
}

// Null-safe value equality on two reference operands already stacked
// [lhs, rhs]: `java.util.Objects.equals(Object, Object)Z`.
func emitObjectsEquals(insns: in List[LInsn]): Unit {
  val oePs: List[JvmType] = newList()
  oePs.add(JRef(className = "java/lang/Object"))
  oePs.add(JRef(className = "java/lang/Object"))
  insns.add(LInvokestatic(owner = "java/util/Objects", name = "equals", params = oePs, ret = JBoolean))
}

// `String.compareTo(String)I` on two String operands already stacked
// [lhs, rhs] — the lexicographic base for relational String comparisons.
func emitStringCompareTo(insns: in List[LInsn]): Unit {
  val ctPs: List[JvmType] = newList()
  ctPs.add(JRef(className = "java/lang/String"))
  insns.add(LInvokevirtual(owner = "java/lang/String", name = "compareTo", params = ctPs, ret = JInt))
}

// Emit the panic sequence for a string message already on the stack.
// Consumes the message from the stack, throws RuntimeException.
func emitPanicFromStack(ctx: in FuncCtx, insns: in List[LInsn]): Unit {
  // Message is on stack.  Store it to a temp slot so we can dup for ctor.
  val msgSlot = allocSlot(ctx, "__panic_msg_" + freshLabel(ctx), JRef(className = "java/lang/String"))
  emitStore(insns, msgSlot, JRef(className = "java/lang/String"))
  insns.add(LNew(className = "java/lang/RuntimeException"))
  insns.add(LDup)
  emitLoad(insns, msgSlot, JRef(className = "java/lang/String"))
  val rteps: List[JvmType] = newList()
  rteps.add(JRef(className = "java/lang/String"))
  insns.add(LInvokespecial(owner = "java/lang/RuntimeException", name = "<init>", params = rteps, ret = JVoid))
  insns.add(LAthrow)
}

// Lower a single expression.  Pushes exactly one value onto the operand
// stack (or nothing for JVoid).  Returns the JvmType of the pushed value.
pub func lowerExpr(ctx: in FuncCtx, insns: in List[LInsn], expr: in Expr): JvmType {
  match expr.kind {

    // ── Literals ──────────────────────────────────────────────────────────
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, suffix, _) -> {
          // An `i64`/`u64` suffix makes the literal a Long regardless of
          // magnitude: `5i64` must push a long (ldc2_w / lconst), not an int
          // (iconst).  Storing an int with `lstore` underflows the operand
          // stack ("Operand stack underflow"); a plain unsuffixed literal stays
          // an int when it fits in 32 bits.
          val isLong = match suffix { case I64 -> true; case U64 -> true; case _ -> false }
          if isLong {
            insns.add(LLconst(v = v))
            JLong
          } else if v >= -2147483648i64 and v <= 2147483647i64 {
            insns.add(LIconst(v = longToInt(v)))
            JInt
          } else {
            insns.add(LLconst(v = v))
            JLong
          }
        }
        case LFloat(v, suffix, _) -> {
          // An `f`-suffixed literal (`1.5f`) is a 32-bit Float; everything else
          // (plain, or `d`-suffixed) is a 64-bit Double.
          match suffix {
            case F32 -> {
              insns.add(LFconst(v = v))
              JFloat
            }
            case _ -> {
              insns.add(LDconst(v = v))
              JDouble
            }
          }
        }
        case LString(s) -> {
          insns.add(LPushString(s = s))
          JRef(className = "java/lang/String")
        }
        case LTripleString(s) -> {
          insns.add(LPushString(s = s))
          JRef(className = "java/lang/String")
        }
        case LRawString(s) -> {
          insns.add(LPushString(s = s))
          JRef(className = "java/lang/String")
        }
        case LBool(value) -> {
          if value {
            insns.add(LIconst(v = 1))
          } else {
            insns.add(LIconst(v = 0))
          }
          JBoolean
        }
        case LUnit -> {
          // Unit produces nothing on the stack.
          JVoid
        }
        case LChar(cp) -> {
          insns.add(LIconst(v = cp))
          JChar
        }
      }
    }

    // ── Parenthesised expression ───────────────────────────────────────────
    case EParen(inner) -> {
      lowerExpr(ctx, insns, inner)
    }

    // ── Path (variable or function reference) ─────────────────────────────
    case EPath(path) -> {
      val name = lastSegment(path)
      match lookupSlot(ctx, name) {
        case Some(slot) -> {
          val ty = match lookupType(ctx, name) { case Some(t) -> t; case None -> JRef(className = "java/lang/Object") }
          // Check if this is a hoisted var (by-ref capture in closures)
          match mapGet(ctx.hoistedCellSlot, name) {
            case Some(cellSlot) -> {
              // Load from cell[0]
              val cellElemTy = match mapGet(ctx.hoistedCellType, name) { case Some(t) -> t; case None -> ty }
              val cellType = JArray(elem = cellElemTy)
              emitLoad(insns, cellSlot, cellType)
              insns.add(LIconst(v = 0))
              emitArrayLoad(insns, cellElemTy)
              cellElemTy
            }
            case None -> {
              // Normal load
              emitLoad(insns, slot, ty)
              ty
            }
          }
        }
        case None -> {
          // Inside an instance method (a protected-type entry / helper), a bare
          // name that is a field of the receiver is `this.<name>`: load slot 0
          // and `getfield`.  Protected entries reference their fields by bare
          // name (`tokens`, not `self.tokens`), so without this the read fell to
          // the null fallback below and the value was lost (J3 M-3).
          match selfFieldType(ctx, name) {
            case Some(fty) -> {
              val selfCls = match ctx.selfClass { case Some(c) -> c; case None -> "" }
              insns.add(LAload(slot = 0))
              insns.add(LGetfield(owner = selfCls, name = name, t = fty))
              fty
            }
            case None -> {
              // A bare reference to a nullary union case (`Empty`, `None`) is a
              // construction, not a variable: `new Pkg/Union$Case; dup;
              // invokespecial <init>()V`.  Without this the case lowered to null and
              // any downstream `match` saw `instanceof Case == false` → "match not
              // exhaustive" (#1675).
              match ctorClassFor(ctx, name) {
                case Some(cls) -> {
                  val emptyArgs: List[CallArg] = newList()
                  lowerConstruction(ctx, insns, cls, emptyArgs)
                }
                case None -> {
                  // A bare reference to a module-level `val` resolves to a
                  // `getstatic` on the package host class (m-2).
                  match mapGet(ctx.moduleVals, name) {
                    case Some(vty) -> {
                      insns.add(LGetstatic(owner = ctx.pkgName, name = name, t = vty))
                      vty
                    }
                    case None -> {
                      // Package-qualified or genuinely unknown reference: null fallback.
                      insns.add(LAconstNull)
                      JRef(className = "java/lang/Object")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // ── Arithmetic / logic binary ops ─────────────────────────────────────
    case EBinop(op, lhs, rhs) -> {
      match op {
        // Boolean short-circuit: lower to branch+const sequence.  The result
        // is materialised through a local slot — never carried on the operand
        // stack across a branch — because the StackMapTable generator types
        // every branch-target frame with an EMPTY operand stack (the same
        // invariant lowerCmpExpr's slot materialisation upholds).  The old
        // `iconst_1; goto after; falseL: iconst_0; after:` form reached
        // `after` with {int} on the stack and failed verification
        // ("Inconsistent stackmap frames") whenever the and/or appeared in
        // value position, e.g. a match-arm result (#3044).
        case BAnd -> {
          val falseL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          val resSlot = allocSlot(ctx, "__and_" + freshLabel(ctx), JBoolean)
          lowerExpr(ctx, insns, lhs)
          insns.add(LIfeq(label = falseL))
          lowerExpr(ctx, insns, rhs)
          insns.add(LIfeq(label = falseL))
          insns.add(LIconst(v = 1))
          insns.add(LIstore(slot = resSlot))
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = falseL))
          insns.add(LIconst(v = 0))
          insns.add(LIstore(slot = resSlot))
          insns.add(LLabel(name = afterL))
          insns.add(LIload(slot = resSlot))
          JBoolean
        }
        case BOr -> {
          val trueL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          val resSlot = allocSlot(ctx, "__or_" + freshLabel(ctx), JBoolean)
          lowerExpr(ctx, insns, lhs)
          insns.add(LIfne(label = trueL))
          lowerExpr(ctx, insns, rhs)
          insns.add(LIfne(label = trueL))
          insns.add(LIconst(v = 0))
          insns.add(LIstore(slot = resSlot))
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = trueL))
          insns.add(LIconst(v = 1))
          insns.add(LIstore(slot = resSlot))
          insns.add(LLabel(name = afterL))
          insns.add(LIload(slot = resSlot))
          JBoolean
        }
        // Comparison ops — produce 0 or 1 on the stack.
        case BEq -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        case BNeq -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        case BLt -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        case BLte -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        case BGt -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        case BGte -> {
          lowerCmpExpr(ctx, insns, op, lhs, rhs)
        }
        // Arithmetic ops.
        case BAdd -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          match lhsTy {
            case JRef(cls) -> {
              if not (cls == "java/lang/String") {
                // A generic payload erased to `Object` used in numeric `+`
                // (e.g. `case Ok(v) -> v + 1`): unbox the lhs to the rhs's
                // primitive width and emit the numeric add.  `String` `+` is the
                // StringBuilder path below.
                val rhsTy = lowerExpr(ctx, insns, rhs)
                match rhsTy {
                  case JRef(_) -> {
                    // Both operands are references (e.g. an erased `Object`
                    // list element concatenated with a String, as in
                    // `Std.String.joinList`'s `xs[0] + sep`): `+` on
                    // references is string concatenation — mirror the MSIL
                    // backend's String.Concat lowering instead of panicking.
                    val rSlot = allocSlot(ctx, "__cat_rhs_" + freshLabel(ctx), rhsTy)
                    emitStore(insns, rSlot, rhsTy)
                    coerceToStringForConcat(insns, lhsTy)
                    val catSb: List[JvmType] = newList()
                    val lSlot = allocSlot(ctx, "__cat_lhs_" + freshLabel(ctx), JRef(className = "java/lang/String"))
                    emitStore(insns, lSlot, JRef(className = "java/lang/String"))
                    insns.add(LNew(className = "java/lang/StringBuilder"))
                    insns.add(LDup)
                    insns.add(LInvokespecial(owner = "java/lang/StringBuilder", name = "<init>", params = catSb, ret = JVoid))
                    emitLoad(insns, lSlot, JRef(className = "java/lang/String"))
                    val catAp: List[JvmType] = newList()
                    catAp.add(JRef(className = "java/lang/String"))
                    insns.add(
                      LInvokevirtual(
                        owner = "java/lang/StringBuilder",
                        name = "append",
                        params = catAp,
                        ret = JRef(className = "java/lang/StringBuilder")
                      )
                    )
                    emitLoad(insns, rSlot, rhsTy)
                    coerceToStringForConcat(insns, rhsTy)
                    insns.add(
                      LInvokevirtual(
                        owner = "java/lang/StringBuilder",
                        name = "append",
                        params = catAp,
                        ret = JRef(className = "java/lang/StringBuilder")
                      )
                    )
                    val catTs: List[JvmType] = newList()
                    insns.add(
                      LInvokevirtual(
                        owner = "java/lang/StringBuilder",
                        name = "toString",
                        params = catTs,
                        ret = JRef(className = "java/lang/String")
                      )
                    )
                    return JRef(className = "java/lang/String")
                  }
                  case _ -> ()
                }
                val numTy = reconcileCmpOperands(ctx, insns, lhsTy, rhsTy)
                match numTy {
                  case JRef(_) -> {
                    panic("BAdd: reference operand could not be reconciled to a numeric type")
                  }
                  case JLong -> {
                    insns.add(LLadd)
                    return JLong
                  }
                  case JDouble -> {
                    insns.add(LDadd)
                    return JDouble
                  }
                  case JFloat -> {
                    insns.add(LFadd)
                    return JFloat
                  }
                  case _ -> {
                    insns.add(LIadd)
                    return JInt
                  }
                }
              }
              // Store lhs (already on JVM stack) to a slot before building the StringBuilder.
              val lhsSlot = allocSlot(ctx, "__add_lhs_" + freshLabel(ctx), lhsTy)
              emitStore(insns, lhsSlot, lhsTy)
              // Lower and stringify the rhs BEFORE creating the StringBuilder:
              // a branchy rhs (a comparison, an if-expression) lands branch
              // targets, and the StackMapTable declares an empty operand stack
              // at every branch target — with the builder already on the stack
              // the frames disagree and the class fails verification.  The rhs
              // of a String `+` may also be a non-String value (an erased
              // `Object` slice element, a primitive): stringify before the
              // `append(String)` call or verification fails at the append.
              val rhsConcatTy = lowerExpr(ctx, insns, rhs)
              coerceToStringForConcat(insns, rhsConcatTy)
              val rhsSlot = allocSlot(ctx, "__add_rhs_" + freshLabel(ctx), JRef(className = "java/lang/String"))
              emitStore(insns, rhsSlot, JRef(className = "java/lang/String"))
              insns.add(LNew(className = "java/lang/StringBuilder"))
              insns.add(LDup)
              val sbInitPs: List[JvmType] = newList()
              insns.add(LInvokespecial(owner = "java/lang/StringBuilder", name = "<init>", params = sbInitPs, ret = JVoid))
              emitLoad(insns, lhsSlot, lhsTy)
              val appPs1: List[JvmType] = newList()
              appPs1.add(JRef(className = "java/lang/String"))
              insns.add(
                LInvokevirtual(
                  owner = "java/lang/StringBuilder",
                  name = "append",
                  params = appPs1,
                  ret = JRef(className = "java/lang/StringBuilder")
                )
              )
              emitLoad(insns, rhsSlot, JRef(className = "java/lang/String"))
              val appPs2: List[JvmType] = newList()
              appPs2.add(JRef(className = "java/lang/String"))
              insns.add(
                LInvokevirtual(
                  owner = "java/lang/StringBuilder",
                  name = "append",
                  params = appPs2,
                  ret = JRef(className = "java/lang/StringBuilder")
                )
              )
              val tsPs: List[JvmType] = newList()
              insns.add(
                LInvokevirtual(
                  owner = "java/lang/StringBuilder",
                  name = "toString",
                  params = tsPs,
                  ret = JRef(className = "java/lang/String")
                )
              )
              JRef(className = "java/lang/String")
            }
            case JLong -> {
              lowerExpr(ctx, insns, rhs)
              insns.add(LLadd)
              JLong
            }
            case JDouble -> {
              val rTy = lowerExpr(ctx, insns, rhs)
              coerceArgTo(insns, rTy, JDouble)
              insns.add(LDadd)
              JDouble
            }
            case JFloat -> {
              val rTy = lowerExpr(ctx, insns, rhs)
              coerceArgTo(insns, rTy, JFloat)
              insns.add(LFadd)
              JFloat
            }
            case _ -> {
              // Coerce like the JDouble/JFloat arms: the rhs may be an
              // erased-Object value (a lambda invoke's boxed return —
              // `result + f(1)` in closure_zero_overhead_self_test) and
              // `iadd` rejects a reference operand at verification.
              val rTy = lowerExpr(ctx, insns, rhs)
              coerceArgTo(insns, rTy, JInt)
              insns.add(LIadd)
              JInt
            }
          }
        }
        case BSub -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          match lhsTy {
            case JLong -> {
              insns.add(LLsub)
              JLong
            }
            case JDouble -> {
              insns.add(LDsub)
              JDouble
            }
            case JFloat -> {
              insns.add(LFsub)
              JFloat
            }
            case _ -> {
              insns.add(LIsub)
              JInt
            }
          }
        }
        case BMul -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          match lhsTy {
            case JLong -> {
              insns.add(LLmul)
              JLong
            }
            case JDouble -> {
              insns.add(LDmul)
              JDouble
            }
            case JFloat -> {
              insns.add(LFmul)
              JFloat
            }
            case _ -> {
              insns.add(LImul)
              JInt
            }
          }
        }
        case BDiv -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          match lhsTy {
            case JLong -> {
              insns.add(LLdiv)
              JLong
            }
            case JDouble -> {
              insns.add(LDdiv)
              JDouble
            }
            case JFloat -> {
              insns.add(LFdiv)
              JFloat
            }
            case JByte -> {
              val rhsSlot = allocSlot(ctx, "__div_rhs_" + freshLabel(ctx), JInt)
              emitStore(insns, rhsSlot, JInt)
              insns.add(LIconst(255))
              insns.add(LIand)
              emitLoad(insns, rhsSlot, JInt)
              insns.add(LIconst(255))
              insns.add(LIand)
              insns.add(LIdiv)
              JByte
            }
            case _ -> {
              insns.add(LIdiv)
              JInt
            }
          }
        }
        case BMod -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          match lhsTy {
            case JLong -> {
              insns.add(LLrem)
              JLong
            }
            case JDouble -> {
              insns.add(LDrem)
              JDouble
            }
            case JFloat -> {
              insns.add(LFrem)
              JFloat
            }
            case JByte -> {
              val rhsSlot = allocSlot(ctx, "__rem_rhs_" + freshLabel(ctx), JInt)
              emitStore(insns, rhsSlot, JInt)
              insns.add(LIconst(255))
              insns.add(LIand)
              emitLoad(insns, rhsSlot, JInt)
              insns.add(LIconst(255))
              insns.add(LIand)
              insns.add(LIrem)
              JByte
            }
            case _ -> {
              insns.add(LIrem)
              JInt
            }
          }
        }
        case BXor -> {
          lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          insns.add(LIxor)
          JInt
        }
        case BCoalesce -> {
          // Null-coalescing via a result slot with an empty operand stack at every branch target — every StackMapTable frame here assumes that (#4816); `ifnull`/`ifnonnull` are unary tests so no dup'd value is ever left stranded across a branch the way `if_acmpne`/`if_acmpeq` would.
          val lhsTy = lowerExpr(ctx, insns, lhs)
          // The join (result) slot uses the uniform Object[] "slice ABI" (see
          // coerceArgTo's JArray case) rather than lhs's concrete element type
          // (e.g. File[] from an extern call) — a List-derived rhs (`[]`) can
          // only ever produce Object[], and a concrete array is verifier-
          // covariant with Object[] at no bytecode cost, so normalizing here
          // is always safe and lets both arms agree on one declared type.
          val slotTy = match lhsTy { case JArray(_) -> JArray(elem = JRef(className = "java/lang/Object")); case _ -> lhsTy }
          val lhsSlot = allocSlot(ctx, "__coalesce_lhs_" + freshLabel(ctx), lhsTy)
          emitStore(insns, lhsSlot, lhsTy)
          val rslot = allocSlot(ctx, "__coalesce_r_" + freshLabel(ctx), slotTy)
          val nullL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          emitLoad(insns, lhsSlot, lhsTy)
          insns.add(LIfnull(label = nullL))
          emitLoad(insns, lhsSlot, lhsTy)
          coerceArgTo(insns, lhsTy, slotTy)
          emitStore(insns, rslot, slotTy)
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = nullL))
          val rhsTy = lowerExpr(ctx, insns, rhs)
          coerceArgTo(insns, rhsTy, slotTy)
          emitStore(insns, rslot, slotTy)
          insns.add(LLabel(name = afterL))
          emitResultLoad(insns, rslot, slotTy)
          slotTy
        }
        case BImplies -> {
          // p => q == !p || q
          val trueL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          lowerExpr(ctx, insns, lhs)
          insns.add(LIfeq(label = trueL))  // if lhs is false, result is true
          lowerExpr(ctx, insns, rhs)
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = trueL))
          insns.add(LIconst(v = 1))
          insns.add(LLabel(name = afterL))
          JBoolean
        }
      }
    }

    // ── Prefix ops ────────────────────────────────────────────────────────
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          val ty = lowerExpr(ctx, insns, operand)
          match ty {
            case JLong -> {
              insns.add(LLneg)
              JLong
            }
            case JDouble -> {
              insns.add(LDneg)
              JDouble
            }
            case JFloat -> {
              insns.add(LFneg)
              JFloat
            }
            case _ -> {
              insns.add(LIneg)
              JInt
            }
          }
        }
        case PreNot -> {
          lowerExpr(ctx, insns, operand)
          insns.add(LIconst(v = 1))
          insns.add(LIxor)
          JBoolean
        }
        case PreRef -> {
          // & (address-of) — not meaningful in JVM; lower the operand.
          lowerExpr(ctx, insns, operand)
        }
      }
    }

    // ── Function calls ────────────────────────────────────────────────────
    case ECall(fn, args) -> {
      lowerCall(ctx, insns, fn, args)
    }

    // ── Member access ─────────────────────────────────────────────────────
    case EMember(recv, memberName) -> {
      // Static-field read on an extern type (`JSystem.out`, `Duration.ZERO`):
      // when the receiver is a bare extern-type name (and not shadowed by a
      // local), resolve the member as a public static FIELD from JDK metadata
      // and emit `getstatic` — auto-FFI method resolution can't see fields,
      // and lowering a type name as a value has no meaning.
      match recv.kind {
        case EPath(rp) -> {
          val rn = lastSegment(rp)
          match lookupSlot(ctx, rn) {
            case Some(_) -> ()
            case None -> {
              match mapGet(ctx.externTypes, rn) {
                case Some(fqnDot) -> {
                  match loadClass(ctx.autoFfi, fqnDot) {
                    case Some(ci) -> {
                      match findStaticField(ctx.autoFfi, ci, memberName) {
                        case Some(f) -> {
                          val fTy = descStrToJvmType(f.descriptor)
                          insns.add(LGetstatic(owner = ci.binaryName, name = memberName, t = fTy))
                          return fTy
                        }
                        case None -> ()
                      }
                    }
                    case None -> ()
                  }
                }
                case None -> ()
              }
            }
          }
        }
        case _ -> ()
      }
      val recvTy = lowerExpr(ctx, insns, recv)
      match recvTy {
        case JRef(cls) -> {
          // TyException built-in members: .message and .typeName.
          if cls == "java/lang/Throwable" and memberName == "message" {
            val getMessagePs: List[JvmType] = newList()
            insns.add(
              LInvokevirtual(
                owner = "java/lang/Throwable",
                name = "getMessage",
                params = getMessagePs,
                ret = JRef(className = "java/lang/String")
              )
            )
            JRef(className = "java/lang/String")
          } else if cls == "java/lang/Throwable" and memberName == "typeName" {
            val getClassPs: List[JvmType] = newList()
            insns.add(
              LInvokevirtual(
                owner = "java/lang/Object",
                name = "getClass",
                params = getClassPs,
                ret = JRef(className = "java/lang/Class")
              )
            )
            val getSimplePs: List[JvmType] = newList()
            insns.add(
              LInvokevirtual(
                owner = "java/lang/Class",
                name = "getSimpleName",
                params = getSimplePs,
                ret = JRef(className = "java/lang/String")
              )
            )
            JRef(className = "java/lang/String")
          } else if memberName == "count" and (cls == "java/util/ArrayList" or cls == "java/util/HashMap" or cls == "java/util/HashSet" or cls == "java/util/List" or cls == "java/util/Set" or cls == "java/util/Collection") {
            // `xs.count` on a collection receiver → `size()` (JInt).  Without
            // an explicit intrinsic this fell through to the record-field
            // fallback, which left the receiver itself as the "value" — a
            // later compare then checkcast'd the collection to Integer and
            // failed at runtime (the buildArgString regression surfaced by
            // process_capture_jvm_self_test.l).  ArrayList/HashMap/HashSet
            // call size() virtually; the interface spellings dispatch via
            // invokeinterface.
            val szPs: List[JvmType] = newList()
            if cls == "java/util/List" or cls == "java/util/Set" or cls == "java/util/Collection" {
              insns.add(LInvokeinterface(owner = cls, name = "size", params = szPs, ret = JInt, argCount = 1))
            } else {
              insns.add(LInvokevirtual(owner = cls, name = "size", params = szPs, ret = JInt))
            }
            JInt
          } else if cls == "java/lang/String" and memberName == "length" {
            // String.length() returns int (I), not Object.  Resolving through
            // the generic record-field path below would emit `getfield` (no such
            // field) or fall back to Object — either breaks the comparison that
            // typically follows `s.length > 0`.  Pin the descriptor directly.
            val lenPs: List[JvmType] = newList()
            insns.add(LInvokevirtual(owner = "java/lang/String", name = "length", params = lenPs, ret = JInt))
            JInt
          } else {
            // Record field access: resolve the field's declared type from the
            // type registry (records are registered in `caseFields` keyed by
            // their JVM class name) and emit a `getfield` with the precise
            // descriptor.  Unknown receivers fall back to an Object result.
            match recordFieldType(ctx, cls, memberName) {
              case Some(fty) -> {
                if ctx.opaqueTypes.containsKey(cls) {
                  // Opaque types store fields privately as `$<name>` and expose
                  // them via `$<name>()T` accessor methods, so read through the
                  // accessor rather than a direct (illegal) `getfield` (J3 M-3).
                  val accPs: List[JvmType] = newList()
                  insns.add(LInvokevirtual(owner = cls, name = "$" + memberName, params = accPs, ret = fty))
                } else {
                  insns.add(LGetfield(owner = cls, name = memberName, t = fty))
                }
                fty
              }
              case None -> {
                // Erased-Object receiver fallback (#3044): a match binding on a
                // union payload (e.g. `case Ok(u2)` on `tryInto()`'s result) is
                // statically `Object`, so the precise class is unknown here.
                // When the member names a registered opaque-type field
                // (`field:<name>` in funcSigs, collected by `collectFileSigs`),
                // checkcast to the owner and read through its `$<name>()`
                // accessor — `field:` keys are registered only for opaque
                // types, which always accessor-route.  Mirrors the MSIL
                // `fieldTokensByName` fallback.  Anything else keeps the
                // legacy Object result.
                if cls == "java/lang/Object" {
                  match mapGet(ctx.funcSigs, "field:" + memberName) {
                    case Some(fsig) -> {
                      insns.add(LCheckcast(className = fsig.owner))
                      val fbPs: List[JvmType] = newList()
                      insns.add(LInvokevirtual(owner = fsig.owner, name = "$" + memberName, params = fbPs, ret = fsig.ret))
                      fsig.ret
                    }
                    case None -> {
                      if memberName == "count" or memberName == "length" {
                        // `.count` / `.length` on an erased-Object receiver (a
                        // match binding on a generic union payload, e.g.
                        // `case Ok(rb)` on `Result[List[Byte], _]`): the precise
                        // class is unknown statically, so dispatch on the runtime
                        // class via the synthesised `__lyricCount(Object)I`
                        // helper every package class carries.  The call is
                        // branch-free HERE — the dispatch's branches live in the
                        // helper, whose frames start from an empty stack — so
                        // this is safe even mid-expression with values already
                        // stacked (`i < pairs.count` in a while condition).
                        val lcPs: List[JvmType] = newList()
                        lcPs.add(JRef(className = "java/lang/Object"))
                        insns.add(LInvokestatic(owner = ctx.pkgName, name = "__lyricCount", params = lcPs, ret = JInt))
                        JInt
                      } else {
                        JRef(className = "java/lang/Object")
                      }
                    }
                  }
                } else {
                  JRef(className = "java/lang/Object")
                }
              }
            }
          }
        }
        case JArray(_) -> {
          // `arr.length` / `arr.count` on a JVM array → `arraylength` (JInt).
          // `count` is the Lyric slice-length member (`args.count` on the
          // entry point's `slice[String]` argv, #3303); `length` covers raw
          // JVM arrays such as a `byte[]` returned by an auto-FFI digest
          // call.  Without this, the member fell through to the JVoid arm
          // below and mis-stacked.  Any other member on an array is not
          // meaningful.
          if memberName == "length" or memberName == "count" {
            insns.add(LArraylength)
            JInt
          } else {
            JVoid
          }
        }
        case _ -> {
          // Primitive member access is not meaningful; return void.
          JVoid
        }
      }
    }

    // ── If / else ─────────────────────────────────────────────────────────
    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      lowerIfExpr(ctx, insns, cond, thenBranch, elseBranchOpt)
    }

    // ── Block expression ──────────────────────────────────────────────────
    case EBlock(block) -> {
      lowerBlockExpr(ctx, insns, block)
    }

    // ── Unsafe block (same as block for JVM) ──────────────────────────────
    case EUnsafe(block) -> {
      lowerBlockExpr(ctx, insns, block)
    }

    // ── Assignment expression ─────────────────────────────────────────────
    case EAssign(target, op, value) -> {
      lowerAssignExpr(ctx, insns, target, op, value)
    }

    // ── Tuple ─────────────────────────────────────────────────────────────
    case ETuple(exprs) -> {
      // A tuple's runtime representation is a `java/util/ArrayList` holding each
      // element boxed to `Object` (mirroring the MSIL backend's `List<object>`
      // representation).  `PTuple` patterns read elements back by index via
      // `get(i)`.  Element static types are erased to `Object`; precise typing is
      // re-established by the consuming context (pattern sub-binding, call-site
      // coercion to a declared parameter type).
      insns.add(LNew(className = "java/util/ArrayList"))
      insns.add(LDup)
      val tInitPs: List[JvmType] = newList()
      insns.add(LInvokespecial(owner = "java/util/ArrayList", name = "<init>", params = tInitPs, ret = JVoid))
      val tupSlot = allocSlot(ctx, "__tuple_" + freshLabel(ctx), JRef(className = "java/util/ArrayList"))
      insns.add(LAstore(slot = tupSlot))
      var ti = 0
      while ti < exprs.count {
        insns.add(LAload(slot = tupSlot))
        val elemTy = lowerExpr(ctx, insns, exprs[ti])
        boxIfNeeded(insns, elemTy)
        val tAddPs: List[JvmType] = newList()
        tAddPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokevirtual(owner = "java/util/ArrayList", name = "add", params = tAddPs, ret = JBoolean))
        insns.add(LPop)
        ti = ti + 1
      }
      insns.add(LAload(slot = tupSlot))
      JRef(className = "java/util/ArrayList")
    }

    // ── List literal ──────────────────────────────────────────────────────
    case EList(exprs) -> {
      // Emit ArrayList construction and populate it.
      insns.add(LNew(className = "java/util/ArrayList"))
      insns.add(LDup)
      val alInitPs: List[JvmType] = newList()
      insns.add(LInvokespecial(owner = "java/util/ArrayList", name = "<init>", params = alInitPs, ret = JVoid))
      val listSlot = allocSlot(ctx, "__list_" + freshLabel(ctx), JRef(className = "java/util/ArrayList"))
      insns.add(LAstore(slot = listSlot))
      var i = 0
      while i < exprs.count {
        insns.add(LAload(slot = listSlot))
        val elemTy = lowerExpr(ctx, insns, exprs[i])
        // Box primitives before adding to Object-typed list.
        boxIfNeeded(insns, elemTy)
        val addPs: List[JvmType] = newList()
        addPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokevirtual(owner = "java/util/ArrayList", name = "add", params = addPs, ret = JBoolean))
        insns.add(LPop)
        i = i + 1
      }
      insns.add(LAload(slot = listSlot))
      JRef(className = "java/util/ArrayList")
    }

    // ── Await / spawn (bootstrap: synchronous lowering) ───────────────────
    case EAwait(inner) -> {
      lowerExpr(ctx, insns, inner)
    }

    // ── Yield: meta-insn for async generators ─────────────────────────────
    case EYield(inner) -> {
      match ctx.genClass {
        case Some(_) -> {
          lowerExpr(ctx, insns, inner)
          insns.add(LYield)
          JVoid
        }
        case None -> {
          panic("Jvm.Codegen: 'yield' used outside an async generator body")
        }
      }
    }

    case ESpawn(inner) -> {
      lowerExpr(ctx, insns, inner)
    }

    // ── Propagate (?) — bootstrap: just lower inner ────────────────────────
    case ETry(inner) -> {
      lowerExpr(ctx, insns, inner)
    }

    case EPropagate(inner) -> {
      lowerExpr(ctx, insns, inner)
    }

    // ── Match expression ──────────────────────────────────────────────────
    case EMatch(scrutinee, arms) -> {
      lowerMatchExpr(ctx, insns, scrutinee, arms)
    }

    // ── Interpolated string ───────────────────────────────────────────────
    case EInterpolated(segments) -> {
      lowerInterpolated(ctx, insns, segments)
    }

    // ── Quantifiers ───────────────────────────────────────────────────────
    // `forall`/`exists` are proof-time quantifiers over possibly-unbounded
    // domains.  In `@runtime_checked` modules they are approximated as `true`
    // (a sound overapproximation — the assert passes, no false-negative
    // crash), matching the MSIL backend's resolution (#1506); W0002 informs
    // the user the clause is not enforced at runtime (#3227).
    case EForall(_, _, _) -> {
      Console.error(
        "W0002: forall quantifier in @runtime_checked contract is not evaluated at runtime " +
          "(sound overapproximation as true; consider restricting the domain or using @proof_required)"
      )
      insns.add(LIconst(v = 1))
      JBoolean
    }
    case EExists(_, _, _) -> {
      Console.error(
        "W0002: exists quantifier in @runtime_checked contract is not evaluated at runtime " +
          "(sound overapproximation as true; consider restricting the domain or using @proof_required)"
      )
      insns.add(LIconst(v = 1))
      JBoolean
    }
    case EOld(_) -> {
      panic("Jvm.Codegen: EOld not supported in JVM codegen")
    }
    case ESelf -> {
      insns.add(LAload(slot = 0))
      // Type `self` to the enclosing instance class when known so `self.field`
      // member access resolves the field's precise descriptor; otherwise the
      // erased Object receiver (records / unhosted contexts) is reported.
      match ctx.selfClass {
        case Some(cls) -> JRef(className = cls)
        case None -> JRef(className = "java/lang/Object")
      }
    }
    case EResult -> {
      // `result` is a contextual keyword: inside ensures clauses the contract
      // elaborator rewrites EResult to EPath([__lyric_result_N]) before codegen
      // sees it.  The only remaining case is a user-declared local or parameter
      // named "result" (valid because the pattern parser accepts KwResult in
      // binding position).  Check slots first; fall back to panic only when no
      // such binding exists (which should never happen after elaboration).
      match lookupSlot(ctx, "result") {
        case Some(slot) -> {
          val ty = match lookupType(ctx, "result") { case Some(t) -> t; case None -> JRef(className = "java/lang/Object") }
          emitLoad(insns, slot, ty)
          ty
        }
        case None -> {
          panic("Jvm.Codegen: EResult outside contract context")
        }
      }
    }
    case ELambda(lparams, lbody) -> {
      // J2b closures (#2665): a general lambda value lowers to a synthesised
      // inner class implementing the package's shared `Lyric$Lambda` functional
      // interface (uniform Object[]-packing ABI).  The class captures the free
      // `val`/param references of the enclosing scope as ctor-bound fields; the
      // closure object left on the stack IS the lambda value.  Calling it routes
      // through `lowerLambdaInvoke` (see 04_calls.l).  The literal-lambda
      // `Std.Jvm.catch` intrinsic is handled before lowerExpr is reached, so it
      // never lands here.
      lowerLambda(ctx, insns, lparams, lbody)
    }
    case ETypeApp(fn, _) -> {
      // Ignore type args and lower the function expression.
      lowerExpr(ctx, insns, fn)
    }
    case EIndex(recv, indices) -> {
      // Array/list indexing.
      val recvTy0 = lowerExpr(ctx, insns, recv)
      // A list receiver whose static type is imprecise (an erased-`Object`
      // match binding, or an imported type's in-package guess) must be cast
      // to `ArrayList` HERE — before the index is pushed, since checkcast
      // only reaches the stack top.  Without it the `ArrayList.get` below
      // fails verification ("Object is not assignable to ArrayList"; hit by
      // `pairs[idx]` on a match-bound `List[YamlPair]` payload).
      val recvTy = match recvTy0 {
        case JRef(c0) -> {
          if c0 == "java/lang/String" or c0 == "java/util/ArrayList" {
            recvTy0
          } else {
            insns.add(LCheckcast(className = "java/util/ArrayList"))
            JRef(className = "java/util/ArrayList")
          }
        }
        case _ -> recvTy0
      }
      if indices.count > 0 {
        lowerExpr(ctx, insns, indices[0])
        match recvTy {
          case JArray(elem) -> {
            // Primitive byte arrays (e.g. a JDK `byte[]` returned by an
            // auto-FFI call such as MessageDigest.digest) load via `baload`
            // and yield a `JByte`; reference arrays use `aaload`.
            match elem {
              case JByte -> {
                insns.add(LBaload)
                JByte
              }
              case JRef(elemCls) -> {
                // Preserve the element's reference type (e.g. `File.listFiles()`
                // yields `java.io.File[]` — indexing must report `java/io/File`,
                // not `Object`, so instance auto-FFI calls on the element
                // resolve against the real class).
                insns.add(LAaload)
                JRef(className = elemCls)
              }
              case _ -> {
                insns.add(LAaload)
                JRef(className = "java/lang/Object")
              }
            }
          }
          case JRef(idxCls) -> {
            if idxCls == "java/lang/String" {
              // `s[i]` on a String → charAt(int) (JChar).  Lowering through
              // the ArrayList.get path below emits an invokevirtual against
              // the wrong class and fails verification (surfaced by
              // Std.String.charAt on --target jvm).
              val caPs: List[JvmType] = newList()
              caPs.add(JInt)
              insns.add(LInvokevirtual(owner = "java/lang/String", name = "charAt", params = caPs, ret = JChar))
              JChar
            } else {
              // List-style indexing via ArrayList.get(int).
              val getPs: List[JvmType] = newList()
              getPs.add(JInt)
              insns.add(
                LInvokevirtual(
                  owner = "java/util/ArrayList",
                  name = "get",
                  params = getPs,
                  ret = JRef(className = "java/lang/Object")
                )
              )
              JRef(className = "java/lang/Object")
            }
          }
          case _ -> {
            // List-style indexing via ArrayList.get(int).
            val getPs: List[JvmType] = newList()
            getPs.add(JInt)
            insns.add(
              LInvokevirtual(
                owner = "java/util/ArrayList",
                name = "get",
                params = getPs,
                ret = JRef(className = "java/lang/Object")
              )
            )
            JRef(className = "java/lang/Object")
          }
        }
      } else {
        JRef(className = "java/lang/Object")
      }
    }
    case ERange(_) -> {
      panic("Jvm.Codegen: ERange not supported in JVM codegen")
    }
    case EError -> {
      insns.add(LAconstNull)
      JRef(className = "java/lang/Object")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Comparison expression helper.
// ─────────────────────────────────────────────────────────────────────────────
// True when one operand is an erased reference (a generic payload boxed to
// `Object`) and the other is a stack primitive — in which case the reference
// must be unboxed to the primitive's width before a numeric compare/arith op.
func numericPrimTy(ty: in JvmType): JvmType {
  match ty {
    case JLong -> JLong
    case JDouble -> JDouble
    case JFloat -> JFloat
    case JInt -> JInt
    case JByte -> JInt
    case JChar -> JInt
    case JShort -> JInt
    case JBoolean -> JBoolean
    case _ -> JVoid
  }
}

// Reconcile a comparison's two operand types when exactly one is an erased
// reference (a generic payload boxed to `Object`) and the other is a stack
// primitive: unbox the reference to the primitive's width so the numeric
// compare op (lcmp / dcmp / if_icmp…) sees two like-typed primitives rather
// than an `Object` it would reject at verification.  Both operands are already
// on the stack as [lhs, rhs]; returns the reconciled comparison type.
func isLongJvm(ty: in JvmType): Bool {
  match ty {
    case JLong -> true
    case _ -> false
  }
}

func isIntLikeJvm(ty: in JvmType): Bool {
  match ty {
    case JInt -> true
    case JByte -> true
    case JShort -> true
    case JChar -> true
    case _ -> false
  }
}

func reconcileCmpOperands(ctx: in FuncCtx, insns: in List[LInsn], lhsTy: in JvmType, rhsTy: in JvmType): JvmType {
  val lhsPrim = numericPrimTy(lhsTy)
  val rhsPrim = numericPrimTy(rhsTy)
  if isRefJvm(lhsTy) and not (rhsPrim == JVoid) {
    // Unbox lhs (currently below rhs): spill rhs, unbox lhs, reload rhs.
    val rhsSlot = allocSlot(ctx, "__cmp_rhs_" + freshLabel(ctx), rhsTy)
    emitStore(insns, rhsSlot, rhsTy)
    coerceArgTo(insns, lhsTy, rhsPrim)
    emitLoad(insns, rhsSlot, rhsTy)
    rhsPrim
  } else if isRefJvm(rhsTy) and not (lhsPrim == JVoid) {
    // Unbox rhs (on top of the stack) directly.
    coerceArgTo(insns, rhsTy, lhsPrim)
    lhsPrim
  } else if isLongJvm(lhsTy) and isIntLikeJvm(rhsTy) {
    // long vs int literal (`nv != 42`): widen the int on top with i2l or
    // `lcmp` sees (long_2nd, int) — VerifyError.
    insns.add(LI2l)
    JLong
  } else if isIntLikeJvm(lhsTy) and isLongJvm(rhsTy) {
    // int vs long: spill the long, widen the int, reload.
    val rhsSlotL = allocSlot(ctx, "__cmp_rhs_" + freshLabel(ctx), JLong)
    emitStore(insns, rhsSlotL, JLong)
    insns.add(LI2l)
    emitLoad(insns, rhsSlotL, JLong)
    JLong
  } else {
    // Both operands have the same primitive type (or both are Object-erased
    // references).  For the primitive case the caller emits the arithmetic
    // instruction directly against lhsTy.  The both-erased Object+Object case
    // (e.g. `case Ok(x) -> case Ok(y) -> x + y` on nested generic match arms)
    // is a known gap: both sides need to be unboxed to a primitive before the
    // arithmetic instruction, but no tested code path currently triggers it
    // (#2862).  Track the gap there; fix when a real reproducer is confirmed.
    lhsTy
  }
}

func lowerCmpExpr(ctx: in FuncCtx, insns: in List[LInsn], op: in BinOp, lhs: in Expr, rhs: in Expr): JvmType {
  val rawLhsTy = lowerExpr(ctx, insns, lhs)
  val rhsTy = lowerExpr(ctx, insns, rhs)
  val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
  val trueL = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  // Materialise the 0/1 boolean through a result local so the operand stack is
  // empty at the `trueL` / `afterL` branch targets.  Leaving the bool on the
  // stack across the join fails verification ("Current frame's stack size
  // doesn't match stackmap"), since the StackMapTable declares an empty stack
  // at every branch target (see lowerIfExpr).
  val rslot = allocSlot(ctx, "__cmp_r_" + afterL, JInt)
  lowerCmp(ctx, insns, op, lhsTy, trueL, afterL)
  // fall-through: comparison was false
  insns.add(LIconst(v = 0))
  emitStore(insns, rslot, JInt)
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = trueL))
  insns.add(LIconst(v = 1))
  emitStore(insns, rslot, JInt)
  insns.add(LLabel(name = afterL))
  emitLoad(insns, rslot, JInt)
  JBoolean
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. Boolean condition lowering (for if/while conditions).
//
// These functions compile a boolean condition directly into conditional branch
// instructions, without pushing an intermediate bool value onto the operand
// stack.  This avoids StackMapTable stack-depth mismatches at merge labels.
//
// lowerBoolCond:      jump to failLabel    if cond is FALSE; fall through if TRUE.
// lowerBoolCondTrue:  jump to succeedLabel if cond is TRUE;  fall through if FALSE.
// lowerCmpFail:       emit the branch-on-failure comparison for lowerBoolCond.
// ─────────────────────────────────────────────────────────────────────────────
// Branch to failLabel if the comparison encoded by `op` is NOT satisfied.
// Both operands must already be on the stack; both are consumed.
func lowerCmpFail(insns: in List[LInsn], op: in BinOp, lhsTy: in JvmType, failLabel: in String): Unit {
  match lhsTy {
    case JLong -> {
      insns.add(LLcmp)
      match op {
        case BEq -> insns.add(LIfne(label = failLabel))
        case BNeq -> insns.add(LIfeq(label = failLabel))
        case BLt -> insns.add(LIfge(label = failLabel))
        case BLte -> insns.add(LIfgt(label = failLabel))
        case BGt -> insns.add(LIfle(label = failLabel))
        case BGte -> insns.add(LIflt(label = failLabel))
        case _ -> insns.add(LNop)
      }
    }
    case JDouble -> {
      insns.add(floatCmpInsn(op, true))
      match op {
        case BEq -> insns.add(LIfne(label = failLabel))
        case BNeq -> insns.add(LIfeq(label = failLabel))
        case BLt -> insns.add(LIfge(label = failLabel))
        case BLte -> insns.add(LIfgt(label = failLabel))
        case BGt -> insns.add(LIfle(label = failLabel))
        case BGte -> insns.add(LIflt(label = failLabel))
        case _ -> insns.add(LNop)
      }
    }
    case JFloat -> {
      insns.add(floatCmpInsn(op, false))
      match op {
        case BEq -> insns.add(LIfne(label = failLabel))
        case BNeq -> insns.add(LIfeq(label = failLabel))
        case BLt -> insns.add(LIfge(label = failLabel))
        case BLte -> insns.add(LIfgt(label = failLabel))
        case BGt -> insns.add(LIfle(label = failLabel))
        case BGte -> insns.add(LIflt(label = failLabel))
        case _ -> insns.add(LNop)
      }
    }
    case JRef(cls) -> {
      // String `==`/`!=` is value comparison (`String.equals`), not identity.
      // See the matching note in `lowerCmp`.  Operands on stack as [lhs, rhs].
      if cls == "java/lang/String" {
        match op {
          case BEq -> {
            val eqPs: List[JvmType] = newList()
            eqPs.add(JRef(className = "java/lang/Object"))
            insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
            insns.add(LIfeq(label = failLabel))
          }
          case BNeq -> {
            val eqPs2: List[JvmType] = newList()
            eqPs2.add(JRef(className = "java/lang/Object"))
            insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs2, ret = JBoolean))
            insns.add(LIfne(label = failLabel))
          }
          // Relational String comparison — see the trueLabel twin above.
          case BLt -> {
            emitStringCompareTo(insns)
            insns.add(LIfge(label = failLabel))
          }
          case BLte -> {
            emitStringCompareTo(insns)
            insns.add(LIfgt(label = failLabel))
          }
          case BGt -> {
            emitStringCompareTo(insns)
            insns.add(LIfle(label = failLabel))
          }
          case BGte -> {
            emitStringCompareTo(insns)
            insns.add(LIflt(label = failLabel))
          }
          case _ -> insns.add(LNop)
        }
      } else {
        // Value equality via `Objects.equals` — see the trueLabel twin.
        match op {
          case BEq -> {
            emitObjectsEquals(insns)
            insns.add(LIfeq(label = failLabel))
          }
          case BNeq -> {
            emitObjectsEquals(insns)
            insns.add(LIfne(label = failLabel))
          }
          case _ -> insns.add(LNop)
        }
      }
    }
    case _ -> {
      match op {
        case BEq -> insns.add(LIfIcmpne(label = failLabel))
        case BNeq -> insns.add(LIfIcmpeq(label = failLabel))
        case BLt -> insns.add(LIfIcmpge(label = failLabel))
        case BLte -> insns.add(LIfIcmpgt(label = failLabel))
        case BGt -> insns.add(LIfIcmple(label = failLabel))
        case BGte -> insns.add(LIfIcmplt(label = failLabel))
        case _ -> insns.add(LNop)
      }
    }
  }
}

// Compile a boolean condition, branching to failLabel if it is false.
// Leaves the operand stack unchanged (no net stack effect).
func lowerBoolCond(ctx: in FuncCtx, insns: in List[LInsn], cond: in Expr, failLabel: in String): Unit {
  match cond.kind {
    case EBinop(op, lhs, rhs) -> {
      match op {
        case BAnd -> {
          lowerBoolCond(ctx, insns, lhs, failLabel)
          lowerBoolCond(ctx, insns, rhs, failLabel)
        }
        case BOr -> {
          val skipLabel = freshLabel(ctx)
          lowerBoolCondTrue(ctx, insns, lhs, skipLabel)
          lowerBoolCond(ctx, insns, rhs, failLabel)
          insns.add(LLabel(name = skipLabel))
        }
        case BEq -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BEq, lhsTy, failLabel)
        }
        case BNeq -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BNeq, lhsTy, failLabel)
        }
        case BLt -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BLt, lhsTy, failLabel)
        }
        case BLte -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BLte, lhsTy, failLabel)
        }
        case BGt -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BGt, lhsTy, failLabel)
        }
        case BGte -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmpFail(insns, BGte, lhsTy, failLabel)
        }
        case _ -> {
          lowerExpr(ctx, insns, cond)
          insns.add(LIfeq(label = failLabel))
        }
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNot -> lowerBoolCondTrue(ctx, insns, operand, failLabel)
        case _ -> {
          lowerExpr(ctx, insns, cond)
          insns.add(LIfeq(label = failLabel))
        }
      }
    }
    case EParen(inner) -> lowerBoolCond(ctx, insns, inner, failLabel)
    case _ -> {
      lowerExpr(ctx, insns, cond)
      insns.add(LIfeq(label = failLabel))
    }
  }
}

// Compile a boolean condition, branching to succeedLabel if it is true.
// Leaves the operand stack unchanged (no net stack effect).
func lowerBoolCondTrue(ctx: in FuncCtx, insns: in List[LInsn], cond: in Expr, succeedLabel: in String): Unit {
  match cond.kind {
    case EBinop(op, lhs, rhs) -> {
      match op {
        case BAnd -> {
          val failLabel = freshLabel(ctx)
          lowerBoolCond(ctx, insns, lhs, failLabel)
          lowerBoolCond(ctx, insns, rhs, failLabel)
          insns.add(LGoto(label = succeedLabel))
          insns.add(LLabel(name = failLabel))
        }
        case BOr -> {
          lowerBoolCondTrue(ctx, insns, lhs, succeedLabel)
          lowerBoolCondTrue(ctx, insns, rhs, succeedLabel)
        }
        case BEq -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BEq, lhsTy, succeedLabel, "")
        }
        case BNeq -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BNeq, lhsTy, succeedLabel, "")
        }
        case BLt -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BLt, lhsTy, succeedLabel, "")
        }
        case BLte -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BLte, lhsTy, succeedLabel, "")
        }
        case BGt -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BGt, lhsTy, succeedLabel, "")
        }
        case BGte -> {
          val rawLhsTy = lowerExpr(ctx, insns, lhs)
          val rhsTy = lowerExpr(ctx, insns, rhs)
          val lhsTy = reconcileCmpOperands(ctx, insns, rawLhsTy, rhsTy)
          lowerCmp(ctx, insns, BGte, lhsTy, succeedLabel, "")
        }
        case _ -> {
          lowerExpr(ctx, insns, cond)
          insns.add(LIfne(label = succeedLabel))
        }
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNot -> lowerBoolCond(ctx, insns, operand, succeedLabel)
        case _ -> {
          lowerExpr(ctx, insns, cond)
          insns.add(LIfne(label = succeedLabel))
        }
      }
    }
    case EParen(inner) -> lowerBoolCondTrue(ctx, insns, inner, succeedLabel)
    case _ -> {
      lowerExpr(ctx, insns, cond)
      insns.add(LIfne(label = succeedLabel))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5c. If expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExprOrBlock(ctx: in FuncCtx, insns: in List[LInsn], eob: in ExprOrBlock): JvmType {
  match eob {
    case EOBExpr(e) -> lowerExpr(ctx, insns, e)
    case EOBBlock(blk) -> lowerBlockExpr(ctx, insns, blk)
  }
}

// Discard a computed value from the operand stack with the width-correct
// opcode: category-2 values (long/double) take two stack slots, so `pop`
// on them fails verification — they need `pop2`.  No-op for void.
pub func discardValue(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JVoid -> ()
    case JLong -> insns.add(LPop2)
    case JDouble -> insns.add(LPop2)
    case _ -> insns.add(LPop)
  }
}

func lowerIfExpr(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock],
): JvmType {
  val elseL = freshLabel(ctx)
  val afterL = freshLabel(ctx)

  match elseBranchOpt {
    case None -> {
      // if-without-else is Unit-typed: the then-branch runs for its effect and
      // the join carries no value, so the empty-stack stackmap frame is correct.
      // The branch's trailing expression may still have produced a value (e.g.
      // `proc.destroyForcibly()` returns Process) — discard it so the
      // fall-through edge reaches the join with an empty stack; otherwise the
      // StackMapTable frames disagree at the join and verification fails.
      lowerBoolCond(ctx, insns, cond, elseL)
      val thenTy = lowerExprOrBlock(ctx, insns, thenBranch)
      if not endsWithReturn(insns) {
        discardValue(insns, thenTy)
      }
      insns.add(LLabel(name = elseL))
      JVoid
    }
    case Some(elseBranch) -> {
      lowerBoolCond(ctx, insns, cond, elseL)
      val thenTy = lowerExprOrBlock(ctx, insns, thenBranch)
      // Whether the then-arm unconditionally transferred control (e.g. both this
      // `if`'s arms `return`).  When it did, the `goto afterL` that would follow
      // it is dead; emitting the `afterL` join label below — when the else-arm
      // ALSO terminates — would leave an unreachable branch target at the
      // past-end bytecode offset, and the StackMapTable frame the verifier emits
      // for it points past the method body (VerifyError: bad offset, #2870).
      val thenTerminated = endsWithReturn(insns)
      match thenTy {
        case JVoid -> {
          // Void if-expression: nothing on the stack at the `afterL` join.
          if not thenTerminated {
            insns.add(LGoto(label = afterL))
          }
          insns.add(LLabel(name = elseL))
          val elseValTy = lowerExprOrBlock(ctx, insns, elseBranch)
          val elseTerminated = endsWithReturn(insns)
          // The else-arm may still have produced a value even though the
          // then-arm typed the whole `if` as void — discard it so the join's
          // empty-stack frame holds (same leak as the if-without-else form).
          if not elseTerminated {
            discardValue(insns, elseValTy)
          }
          // Only land the join label when at least one arm can reach it.  When
          // both arms terminated, the whole `if` is terminating: emitting the
          // join would create the past-end unreachable frame described above.
          if not (thenTerminated and elseTerminated) {
            insns.add(LLabel(name = afterL))
          }
          JVoid
        }
        case _ -> {
          // Value-producing if-expression: route both branch values through a
          // result local so the operand stack is *empty* at the `afterL` join.
          // The JVM StackMapTable this backend emits declares an empty operand
          // stack at every branch target, so leaving a value on the stack there
          // fails verification ("Inconsistent stackmap frames at branch target").
          // Storing into a local in each arm and reloading after the join keeps
          // the stack empty at the merge point.
          val rslot = allocSlot(ctx, "__if_r_" + afterL, thenTy)
          // A terminating then-arm (e.g. `if c { return x } else { … }`) already
          // transferred control and left nothing on the stack — its value never
          // reaches the join, so skip the result store + dead `goto`.
          if not thenTerminated {
            emitStore(insns, rslot, thenTy)
            insns.add(LGoto(label = afterL))
          }
          insns.add(LLabel(name = elseL))
          val elseTy = lowerExprOrBlock(ctx, insns, elseBranch)
          val elseTerminated = endsWithReturn(insns)
          // Mixed-arm if: the then-arm yields a value but the else-arm is
          // void (e.g. `if a { xs.add(true) } else if b { xs.add(false) }` —
          // the trailing else-if has no else, so it lowers as JVoid and
          // leaves NOTHING on the stack).  The checker only admits this
          // shape in statement position, so the whole `if` degrades to
          // void: there is no else-value to store, and reloading the
          // result after the join would hand the caller a value the
          // else-path never produced (the store below underflowed —
          // VerifyError, hit by Std.JsonHost's bool slice reader).
          val elseVoidMixed = match elseTy { case JVoid -> not elseTerminated; case _ -> false }
          if not elseTerminated {
            if not elseVoidMixed {
              coerceArgTo(insns, elseTy, thenTy)
              emitStore(insns, rslot, thenTy)
            }
          }
          // When both arms terminated, the `if` is itself terminating: do not
          // land the join label (and its past-end frame) and do not reload the
          // result, since control never arrives here (#2870).
          if not (thenTerminated and elseTerminated) {
            insns.add(LLabel(name = afterL))
            if not elseVoidMixed {
              emitResultLoad(insns, rslot, thenTy)
            }
          }
          if elseVoidMixed {
            JVoid
          } else {
            thenTy
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5c. Block expression lowering.
//      Returns the type of the trailing value (last SExpr), or JVoid.
// ─────────────────────────────────────────────────────────────────────────────
func lowerBlockExpr(ctx: in FuncCtx, insns: in List[LInsn], block: in Block): JvmType {
  val n = block.statements.count
  if n == 0 {
    return JVoid
  }
  // A `defer { … }` in a value-producing block must run on scope exit while the
  // block still yields its trailing value: route to the defer-aware helper,
  // which stashes the value, runs the deferred block, and reloads it (#1833).
  if blockHasDefer(block) {
    return lowerBlockExprWithDefer(ctx, insns, block, 0)
  }
  var i = 0
  while i < n - 1 {
    lowerStmt(ctx, insns, block.statements[i])
    i = i + 1
  }
  // Last statement: if SExpr, its value is the block value.  An STry in tail
  // position is `try { … } catch … ` used as an expression (e.g.
  // `return try { … } catch … `, which the parser wraps as EBlock([STry])):
  // lower it so its arms' values become the block value instead of being
  // popped as a statement.
  val last = block.statements[n - 1]
  match last.kind {
    case SExpr(e) -> {
      lowerExpr(ctx, insns, e)
    }
    case STry(body, catches, finally_) -> {
      match finally_ {
        case None -> lowerTryCatchExpr(ctx, insns, body, catches)
        case Some(_) -> {
          // try/finally in value position is uncommon; fall back to statement
          // lowering (value discarded) rather than mis-handling the finally.
          lowerStmt(ctx, insns, last)
          JVoid
        }
      }
    }
    case _ -> {
      lowerStmt(ctx, insns, last)
      JVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5f. Interpolated string lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerInterpolated(ctx: in FuncCtx, insns: in List[LInsn], segments: in List[InterpolatedSegment]): JvmType {
  if segments.count == 0 {
    insns.add(LPushString(s = ""))
    return JRef(className = "java/lang/String")
  }
  // Pass 1: lower every expression segment to a String temp while the operand
  // stack is empty.  A branchy segment expression (a comparison, an
  // if-expression) lands branch targets, and the StackMapTable declares an
  // empty operand stack at every branch target — lowering it with the
  // StringBuilder already on the stack makes the frames disagree and the
  // class fails verification (same discipline as the BAdd concat path).
  val exprSlots: List[Int] = newList()
  var pi = 0
  while pi < segments.count {
    match segments[pi] {
      case ISExpr(e) -> {
        val eTy = lowerExpr(ctx, insns, e)
        coerceToStringForConcat(insns, eTy)
        val eSlot = allocSlot(ctx, "__interp_" + freshLabel(ctx), JRef(className = "java/lang/String"))
        emitStore(insns, eSlot, JRef(className = "java/lang/String"))
        exprSlots.add(eSlot)
      }
      case _ -> ()
    }
    pi = pi + 1
  }
  // Pass 2: build with StringBuilder, appending literal text and the
  // pre-stringified expression temps in segment order.
  insns.add(LNew(className = "java/lang/StringBuilder"))
  insns.add(LDup)
  val sbInitPs: List[JvmType] = newList()
  insns.add(LInvokespecial(owner = "java/lang/StringBuilder", name = "<init>", params = sbInitPs, ret = JVoid))
  val appPs: List[JvmType] = newList()
  appPs.add(JRef(className = "java/lang/String"))
  var i = 0
  var ei = 0
  while i < segments.count {
    match segments[i] {
      case ISText(text, _) -> {
        insns.add(LPushString(s = text))
      }
      case ISExpr(_) -> {
        emitLoad(insns, exprSlots[ei], JRef(className = "java/lang/String"))
        ei = ei + 1
      }
    }
    insns.add(
      LInvokevirtual(
        owner = "java/lang/StringBuilder",
        name = "append",
        params = appPs,
        ret = JRef(className = "java/lang/StringBuilder")
      )
    )
    i = i + 1
  }
  val finalTsPs: List[JvmType] = newList()
  insns.add(
    LInvokevirtual(
      owner = "java/lang/StringBuilder",
      name = "toString",
      params = finalTsPs,
      ret = JRef(className = "java/lang/String")
    )
  )
  JRef(className = "java/lang/String")
}

// Stringify the top-of-stack value for a StringBuilder `append(String)` call:
// a String is left as-is; any other reference (an erased `Object` slice
// element, an extern value) calls `Object.toString`; a primitive goes through
// `String.valueOf(<primitive>)` (no boxing).  `JVoid` (nothing on the stack)
// is a type-checker/lowering bug and panics (#4685).
func coerceToStringForConcat(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JRef(c) -> {
      if not (c == "java/lang/String") {
        val tsPs: List[JvmType] = newList()
        insns.add(
          LInvokevirtual(
            owner = "java/lang/Object",
            name = "toString",
            params = tsPs,
            ret = JRef(className = "java/lang/String")
          )
        )
      }
    }
    case JVoid -> panic("Jvm.Codegen: string-concatenation operand lowered to void — a Unit-typed operand should have been rejected by the type checker")
    // A void operand left nothing on the stack; silently pushing "" here
    // would mask a type-checker or lowering bug as wrong output (#4685).
    case JArray(_) -> {
      // An array is a reference: stringify via Object.toString like any
      // non-String JRef.  Falling into the primitive arm below would emit
      // String.valueOf(int) with an array reference on the stack — a
      // verification failure (#4712).
      val atPs: List[JvmType] = newList()
      insns.add(
        LInvokevirtual(
          owner = "java/lang/Object",
          name = "toString",
          params = atPs,
          ret = JRef(className = "java/lang/String")
        )
      )
    }
    case _ -> {
      // String.valueOf(<primitive>) — no boxing, unlike Object.toString on a
      // boxed wrapper (keeps the closure zero-overhead boxing gate flat).
      val voPs: List[JvmType] = newList()
      voPs.add(stringValueOfParam(ty))
      insns.add(
        LInvokestatic(
          owner = "java/lang/String",
          name = "valueOf",
          params = voPs,
          ret = JRef(className = "java/lang/String")
        )
      )
    }
  }
}

// The String.valueOf overload parameter for a primitive operand: byte/short
// widen to the int overload; everything else uses its exact overload.
func stringValueOfParam(ty: in JvmType): JvmType {
  match ty {
    case JLong -> JLong
    case JDouble -> JDouble
    case JFloat -> JFloat
    case JBoolean -> JBoolean
    case JChar -> JChar
    case _ -> JInt
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5g. Boxing helper.
// ─────────────────────────────────────────────────────────────────────────────
// Box a primitive type sitting on the stack into its wrapper object.
func boxIfNeeded(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JInt -> insns.add(LBoxInt)
    case JLong -> insns.add(LBoxLong)
    case JDouble -> insns.add(LBoxDouble)
    case JFloat -> insns.add(LBoxFloat)
    case JBoolean -> insns.add(LBoxBool)
    case JByte -> insns.add(LBoxByte)
    case JChar -> insns.add(LBoxChar)
    case JShort -> insns.add(LBoxShort)
    case _ -> insns.add(LNop)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5j. Lambda / closure lowering (J2b, #2665).
// ─────────────────────────────────────────────────────────────────────────────
// The shared functional interface every lambda in a package implements.  A
// uniform Object[]-packing ABI (`invoke([Ljava/lang/Object;)Ljava/lang/Object;`)
// makes construction and invocation agree for any arity, with generics erased to
// `Object` (J4) — primitives are boxed in and checkcast+unboxed out.  One such
// interface is emitted per package (see `emitLambdaInterfaceIfNeeded`).
pub func lambdaIfaceName(pkgName: in String): String {
  pkgName + "/Lyric$Lambda"
}

pub func lambdaIfaceMethod(): String {
  "invoke"
}

// Does the package name list already contain `nm`?
func nameInList(xs: in List[String], nm: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == nm {
      return true
    }
    i = i + 1
  }
  false
}

func addNameOnceJvm(xs: in List[String], nm: in String): Unit {
  if not nameInList(xs, nm) {
    xs.add(nm)
  }
}

// ── Free-variable / bound-name collection over the lambda body ───────────────
// `collectRefNames*` accumulate every single-segment `EPath` reference (a bare
// identifier) reachable in the body; `collectBoundNames*` accumulate the names
// the body binds locally (its own `val`/`var`/`let`, `for`/`match` pattern
// bindings, and nested-lambda params).  The capture set is the references that
// are neither bound nor lambda params yet resolve to an enclosing-scope slot.
func collectRefNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        addNameOnceJvm(acc, path.segments[0])
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectRefNamesExpr(lhs, acc)
      collectRefNamesExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> collectRefNamesExpr(operand, acc)
    // Parens were invisible to capture collection; the name read as null/zero (#4798).
    case EParen(inner) -> collectRefNamesExpr(inner, acc)
    case ECall(fn, args) -> {
      collectRefNamesExpr(fn, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ex) -> collectRefNamesExpr(ex, acc)
          case CANamed(_, ex, _) -> collectRefNamesExpr(ex, acc)
        }
        i = i + 1
      }
    }
    case EMember(recv, _) -> collectRefNamesExpr(recv, acc)
    case EIndex(recv, idxs) -> {
      collectRefNamesExpr(recv, acc)
      var i = 0
      while i < idxs.count {
        collectRefNamesExpr(idxs[i], acc)
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectRefNamesExpr(fn, acc)
    case EAssign(target, _, value) -> {
      collectRefNamesExpr(target, acc)
      collectRefNamesExpr(value, acc)
    }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectRefNamesExpr(cond, acc)
      collectRefNamesEob(thenB, acc)
      match elseOpt {
        case Some(eb) -> collectRefNamesEob(eb, acc)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectRefNamesExpr(scrut, acc)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectRefNamesExpr(g, acc)
          case None -> ()
        }
        collectRefNamesEob(arms[i].body, acc)
        i = i + 1
      }
    }
    case EBlock(block) -> collectRefNamesBlock(block, acc)
    case EUnsafe(block) -> collectRefNamesBlock(block, acc)
    case EAwait(inner) -> collectRefNamesExpr(inner, acc)
    case ESpawn(inner) -> collectRefNamesExpr(inner, acc)
    case ETry(inner) -> collectRefNamesExpr(inner, acc)
    case EYield(inner) -> collectRefNamesExpr(inner, acc)
    case EPropagate(inner) -> collectRefNamesExpr(inner, acc)
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        collectRefNamesExpr(exprs[i], acc)
        i = i + 1
      }
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        collectRefNamesExpr(exprs[i], acc)
        i = i + 1
      }
    }
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(ex) -> collectRefNamesExpr(ex, acc)
          case ISText(_) -> ()
        }
        i = i + 1
      }
    }
    case ELambda(_, lbody) -> collectRefNamesBlock(lbody, acc)
    case _ -> ()
  }
}

func collectRefNamesEob(eob: in ExprOrBlock, acc: in List[String]): Unit {
  match eob {
    case EOBExpr(ex) -> collectRefNamesExpr(ex, acc)
    case EOBBlock(b) -> collectRefNamesBlock(b, acc)
  }
}

func collectRefNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectRefNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectRefNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding { case LBVal(_, _, init) -> collectRefNamesExpr(init, acc); case LBLet(_, _, init) -> collectRefNamesExpr(init, acc); case LBVar(_, _, init) -> match init { case Some(ie) -> collectRefNamesExpr(ie, acc); case None -> () } }
    case SAssign(target, _, value) -> {
      collectRefNamesExpr(target, acc)
      collectRefNamesExpr(value, acc)
    }
    case SReturn(value) -> match value { case Some(v) -> collectRefNamesExpr(v, acc); case None -> () }
    case SThrow(ex) -> collectRefNamesExpr(ex, acc)
    case STry(body, catches, finallyOpt) -> {
      collectRefNamesBlock(body, acc)
      var i = 0
      while i < catches.count {
        collectRefNamesBlock(catches[i].body, acc)
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> collectRefNamesBlock(fb, acc)
        case None -> ()
      }
    }
    case SDefer(body) -> collectRefNamesBlock(body, acc)
    case SScope(_, body) -> collectRefNamesBlock(body, acc)
    case SFor(_, _, iter, body) -> {
      collectRefNamesExpr(iter, acc)
      collectRefNamesBlock(body, acc)
    }
    case SWhile(_, cond, body) -> {
      collectRefNamesExpr(cond, acc)
      collectRefNamesBlock(body, acc)
    }
    case SLoop(_, body) -> collectRefNamesBlock(body, acc)
    case SInvariant(ex) -> collectRefNamesExpr(ex, acc)
    case SExpr(ex) -> collectRefNamesExpr(ex, acc)
    case SRule(lhs, rhs) -> {
      collectRefNamesExpr(lhs, acc)
      collectRefNamesExpr(rhs, acc)
    }
    case _ -> ()
  }
}

func collectBoundNamesPattern(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      addNameOnceJvm(acc, name)
      match inner {
        case Some(ip) -> collectBoundNamesPattern(ip, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectBoundNamesPattern(args[i], acc)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, pat, _) -> collectBoundNamesPattern(pat, acc)
          case RPFShort(name, _) -> addNameOnceJvm(acc, name)
        }
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectBoundNamesPattern(patterns[i], acc)
        i = i + 1
      }
    }
    case PParen(inner) -> collectBoundNamesPattern(inner, acc)
    case PTypeTest(inner, _) -> collectBoundNamesPattern(inner, acc)
    case POr(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectBoundNamesPattern(patterns[i], acc)
        i = i + 1
      }
    }
    case _ -> ()
  }
}

func collectBoundNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectBoundNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectBoundNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding { case LBVal(pat, _, _) -> collectBoundNamesPattern(pat, acc); case LBLet(name, _, _) -> addNameOnceJvm(acc, name); case LBVar(name, _, _) -> addNameOnceJvm(acc, name) }
    case SFor(_, pat, _, body) -> {
      collectBoundNamesPattern(pat, acc)
      collectBoundNamesBlock(body, acc)
    }
    case SWhile(_, _, body) -> collectBoundNamesBlock(body, acc)
    case SLoop(_, body) -> collectBoundNamesBlock(body, acc)
    case SScope(_, body) -> collectBoundNamesBlock(body, acc)
    case SDefer(body) -> collectBoundNamesBlock(body, acc)
    case STry(body, catches, finallyOpt) -> {
      collectBoundNamesBlock(body, acc)
      var i = 0
      while i < catches.count {
        match catches[i].bindName {
          case Some(nm) -> addNameOnceJvm(acc, nm)
          case None -> ()
        }
        collectBoundNamesBlock(catches[i].body, acc)
        i = i + 1
      }
      match finallyOpt {
        case Some(fb) -> collectBoundNamesBlock(fb, acc)
        case None -> ()
      }
    }
    case SExpr(e) -> collectBoundNamesExpr(e, acc)
    case _ -> ()
  }
}

// Walk an expression for nested `ELambda` nodes and add their params to `acc`.
// This ensures a lambda param introduced inside an expression statement is
// counted as bound when computing the outer lambda's capture set.
func collectBoundNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case ELambda(lparams, lbody) -> {
      var i = 0
      while i < lparams.count {
        addNameOnceJvm(acc, lparams[i].name)
        i = i + 1
      }
      collectBoundNamesBlock(lbody, acc)
    }
    case ECall(fn, args) -> {
      collectBoundNamesExpr(fn, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ae) -> collectBoundNamesExpr(ae, acc)
          case CANamed(_, ae, _) -> collectBoundNamesExpr(ae, acc)
        }
        i = i + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectBoundNamesExpr(lhs, acc)
      collectBoundNamesExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> collectBoundNamesExpr(operand, acc)
    case EParen(inner) -> collectBoundNamesExpr(inner, acc)
    case EMember(recv, _) -> collectBoundNamesExpr(recv, acc)
    case ETypeApp(fn, _) -> collectBoundNamesExpr(fn, acc)
    case EIf(cond, thenB, elseOpt, _) -> {
      collectBoundNamesExpr(cond, acc)
      match thenB {
        case EOBExpr(te) -> collectBoundNamesExpr(te, acc)
        case EOBBlock(tb) -> collectBoundNamesBlock(tb, acc)
      }
      match elseOpt {
        case Some(eb) -> match eb { case EOBExpr(ee) -> collectBoundNamesExpr(ee, acc); case EOBBlock(eblk) -> collectBoundNamesBlock(eblk, acc) }
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectBoundNamesExpr(scrut, acc)
      var i = 0
      while i < arms.count {
        collectBoundNamesPattern(arms[i].pattern, acc)
        match arms[i].body {
          case EOBExpr(ae) -> collectBoundNamesExpr(ae, acc)
          case EOBBlock(ab) -> collectBoundNamesBlock(ab, acc)
        }
        i = i + 1
      }
    }
    case EBlock(block) -> collectBoundNamesBlock(block, acc)
    case EUnsafe(block) -> collectBoundNamesBlock(block, acc)
    case EList(elems) -> {
      var i = 0
      while i < elems.count {
        collectBoundNamesExpr(elems[i], acc)
        i = i + 1
      }
    }
    case ETuple(elems) -> {
      var i = 0
      while i < elems.count {
        collectBoundNamesExpr(elems[i], acc)
        i = i + 1
      }
    }
    case EIndex(recv, idxs) -> {
      collectBoundNamesExpr(recv, acc)
      var i = 0
      while i < idxs.count {
        collectBoundNamesExpr(idxs[i], acc)
        i = i + 1
      }
    }
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(ex) -> collectBoundNamesExpr(ex, acc)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case EAssign(target, _, value) -> {
      collectBoundNamesExpr(target, acc)
      collectBoundNamesExpr(value, acc)
    }
    case EAwait(inner) -> collectBoundNamesExpr(inner, acc)
    case ESpawn(inner) -> collectBoundNamesExpr(inner, acc)
    case ETry(inner) -> collectBoundNamesExpr(inner, acc)
    case EYield(inner) -> collectBoundNamesExpr(inner, acc)
    case EPropagate(inner) -> collectBoundNamesExpr(inner, acc)
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hoisting pre-pass: detect `var` bindings referenced inside any lambda in the
// enclosing function.  These must be hoisted to heap-allocated cells so mutations
// are observed through the closure (by-ref capture, epic #1877 Stage 2).
// ─────────────────────────────────────────────────────────────────────────────
// Collect all names referenced inside any lambda in an expression.
func collectInLambdaNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case ELambda(_, body) -> {
      // Walk the lambda body and collect all referenced names.
      collectRefNamesBlock(body, acc)
    }
    case ECall(fn, args) -> {
      collectInLambdaNamesExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex) -> collectInLambdaNamesExpr(ex, acc)
          case CANamed(_, ex, _) -> collectInLambdaNamesExpr(ex, acc)
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectInLambdaNamesExpr(lhs, acc)
      collectInLambdaNamesExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> collectInLambdaNamesExpr(operand, acc)
    case EParen(inner) -> collectInLambdaNamesExpr(inner, acc)
    case EMember(recv, _) -> collectInLambdaNamesExpr(recv, acc)
    case EIf(cond, thenB, elseOpt, _) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesOrdBlock(thenB, acc)
      match elseOpt {
        case Some(eb) -> collectInLambdaNamesOrdBlock(eb, acc)
        case None -> ()
      }
    }
    case EBlock(block) -> collectInLambdaNamesBlock(block, acc)
    case EUnsafe(block) -> collectInLambdaNamesBlock(block, acc)
    case EMatch(scr, arms) -> {
      collectInLambdaNamesExpr(scr, acc)
      var ai = 0
      while ai < arms.count {
        match arms[ai].guard {
          case Some(guardExpr) -> collectInLambdaNamesExpr(guardExpr, acc)
          case None -> ()
        }
        collectInLambdaNamesOrdBlock(arms[ai].body, acc)
        ai = ai + 1
      }
    }
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectInLambdaNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectInLambdaNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectInLambdaNamesExpr(recv, acc)
      var ii = 0
      while ii < indices.count {
        collectInLambdaNamesExpr(indices[ii], acc)
        ii = ii + 1
      }
    }
    case EAwait(inner) -> collectInLambdaNamesExpr(inner, acc)
    case EYield(inner) -> collectInLambdaNamesExpr(inner, acc)
    case ESpawn(inner) -> collectInLambdaNamesExpr(inner, acc)
    case ETry(inner) -> collectInLambdaNamesExpr(inner, acc)
    case EPropagate(inner) -> collectInLambdaNamesExpr(inner, acc)
    case EAssign(target, _, v) -> {
      collectInLambdaNamesExpr(target, acc)
      collectInLambdaNamesExpr(v, acc)
    }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> collectInLambdaNamesExpr(ex, acc)
          case _ -> ()
        }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> collectInLambdaNamesExpr(fn, acc)
    case _ -> ()
  }
}

func collectInLambdaNamesOrdBlock(ob: in ExprOrBlock, acc: in List[String]): Unit {
  match ob {
    case EOBExpr(ex) -> collectInLambdaNamesExpr(ex, acc)
    case EOBBlock(blk) -> collectInLambdaNamesBlock(blk, acc)
  }
}

func collectInLambdaNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectInLambdaNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectInLambdaNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> collectInLambdaNamesExpr(init, acc)
        case LBLet(_, _, init) -> collectInLambdaNamesExpr(init, acc)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> collectInLambdaNamesExpr(init, acc)
            case None -> ()
          }
        }
      }
    }
    case SAssign(target, _, v) -> {
      collectInLambdaNamesExpr(target, acc)
      collectInLambdaNamesExpr(v, acc)
    }
    case SReturn(eOpt) -> match eOpt { case Some(e) -> collectInLambdaNamesExpr(e, acc); case None -> () }
    case SExpr(e) -> collectInLambdaNamesExpr(e, acc)
    case SThrow(e) -> collectInLambdaNamesExpr(e, acc)
    case SWhile(_, cond, body) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesBlock(body, acc)
    }
    case SLoop(_, body) -> collectInLambdaNamesBlock(body, acc)
    case SFor(_, _, iter, body) -> {
      collectInLambdaNamesExpr(iter, acc)
      collectInLambdaNamesBlock(body, acc)
    }
    case SScope(_, body) -> {
      collectInLambdaNamesBlock(body, acc)
    }
    case SDefer(body) -> {
      collectInLambdaNamesBlock(body, acc)
    }
    case STry(body, catches, finally_) -> {
      collectInLambdaNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count {
        collectInLambdaNamesBlock(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> collectInLambdaNamesBlock(fb, acc)
        case None -> ()
      }
    }
    case SInvariant(e) -> collectInLambdaNamesExpr(e, acc)
    case _ -> ()
  }
}

// The capture set: free references resolving to an enclosing slot, minus the
// lambda's own params and any names bound inside the body.  Order-preserving and
// deduped so capture-field / ctor-arg / load ordering stays consistent.
func lambdaCaptureNamesJvm(ctx: in FuncCtx, lparams: in List[LambdaParam], body: in Block): List[String] {
  val refs: List[String] = newList()
  collectRefNamesBlock(body, refs)
  val bound: List[String] = newList()
  var p = 0
  while p < lparams.count {
    addNameOnceJvm(bound, lparams[p].name)
    p = p + 1
  }
  collectBoundNamesBlock(body, bound)
  val caps: List[String] = newList()
  var i = 0
  while i < refs.count {
    val nm = refs[i]
    if not nameInList(bound, nm) {
      // A free name is captured by value when it is an enclosing local/param
      // slot, OR a field of the enclosing receiver class (`selfClass`) — the
      // latter occurs when the lambda lives in a record-method / protected-entry
      // body and references a bare field name (#2864).  Both are snapshotted
      // into the closure's ctor-bound capture fields.
      // Stage 4: Also check for hoisted `var` cells from enclosing scope
      // (multi-level nesting: a nested lambda may capture a `var` that was hoisted
      // in the enclosing lambda's scope).
      if ctx.slots.containsKey(nm) {
        addNameOnceJvm(caps, nm)
      } else if ctx.hoistedCellSlot.containsKey(nm) {
        // Hoisted var: re-capture the cell reference for multi-level nesting.
        addNameOnceJvm(caps, nm)
      } else {
        match selfFieldType(ctx, nm) {
          case Some(_) -> addNameOnceJvm(caps, nm)
          case None -> ()
        }
      }
    }
    i = i + 1
  }
  caps
}

// Lower a lambda value: synthesise a closure inner class implementing the
// package's shared `Lyric$Lambda` interface, register it in `ctx.closureAcc`,
// then emit `new` + capture-load + `invokespecial <init>` so the closure object
// is left on the stack.  Returns the closure's static type (the shared iface).
func lowerLambda(ctx: in FuncCtx, insns: in List[LInsn], lparams: in List[LambdaParam], body: in Block): JvmType {
  val ifaceName = lambdaIfaceName(ctx.pkgName)
  val idx = ctx.closureAcc.count
  // Use `$Lambda$<n>` nesting under the package host class so the binary name is
  // unique and not mistaken for a user record/union.
  val closureClass = ctx.pkgName + "$Lambda$" + toString(idx)
  // Claim index `idx` in the package-shared accumulator now: lowering the body
  // below recurses into any nested lambdas, which append to the same list, so
  // the slot must be reserved up front for `$Lambda$<n>` names to stay unique.
  // The placeholder is overwritten with the finished closure at the end.
  val placeholderCaps: List[LClosureCapture] = newList()
  val placeholderParams: List[JvmType] = newList()
  val placeholderInsns: List[LInsn] = newList()
  ctx.closureAcc.add(
    LClosure(
      closureClass = closureClass,
      ifaceClass = ifaceName,
      ifaceMethod = lambdaIfaceMethod(),
      captures = placeholderCaps,
      methodParams = placeholderParams,
      methodRet = JRef(className = "java/lang/Object"),
      bodyInsns = placeholderInsns,
      bodyMaxLocals = 0
    )
  )

  val caps = lambdaCaptureNamesJvm(ctx, lparams, body)
  // Capture types come from the enclosing scope (by value, per §5.4 / docs/01:
  // `val` bindings are captured by value).  A captured `var` that is hoisted
  // (referenced inside a lambda) is captured by reference: the closure field
  // holds the cell array, not the value.  Mutation-after-capture is reflected
  // through the cell (epic #1877 Stage 2).
  val captures: List[LClosureCapture] = newList()
  var ci = 0
  while ci < caps.count {
    val cn = caps[ci]
    // Check if this capture is a hoisted cell
    match mapGet(ctx.hoistedCellSlot, cn) {
      case Some(_) -> {
        // Hoisted var: capture the cell array, not the value
        val elemTy = match mapGet(ctx.hoistedCellType, cn) {
          case Some(t) -> t
          case None -> JRef(className = "java/lang/Object")
        }
        val cellType = JArray(elem = elemTy)
        captures.add(LClosureCapture(captureName = cn, captureType = cellType))
      }
      case None -> {
        // Normal capture: get the enclosing-scope type
        val cty = match lookupType(ctx, cn) {
          case Some(t) -> t
          case None -> match selfFieldType(ctx, cn) { case Some(ft) -> ft; case None -> JRef(className = "java/lang/Object") }
        }
        captures.add(LClosureCapture(captureName = cn, captureType = cty))
      }
    }
    ci = ci + 1
  }

  // ── Build the closure body (`invoke(Object[])Object`) in a fresh ctx ─────────
  // Slot 0 = this, slot 1 = the Object[] args; the prologue unpacks args into
  // the lambda-param locals and reads capture fields into capture locals.
  val bodyCtx = makeFuncCtx(
    ctx.pkgName,
    closureClass,
    ctx.funcSigs,
    ctx.caseFields,
    ctx.ctors,
    ctx.externTypes,
    ctx.autoFfi,
    JRef(className = "java/lang/Object"),
    ctx.moduleVals,
    ctx.opaqueTypes,
    ctx.closureAcc
  )
  // Propagate the enclosing scope's recorded generic instantiations into the
  // closure body so a captured var-bound `match`/`?` scrutinee still unboxes its
  // erased payload inside the lambda (#4945) — otherwise the payload stays boxed
  // and arithmetic on it string-concats or VerifyErrors, the pre-#4877 bug.
  // Lambda params shadow outer names (they get a fresh slot and identity), so a
  // param that reuses an outer var name must NOT inherit the outer instantiation;
  // exclude every param name.  A body-local rebind of an outer name is
  // self-correcting: `recordVarGenericArgs` overwrites the entry at the bind site.
  val __closureParamNames: Map[String, Bool] = newMap()
  var __cpi = 0
  while __cpi < lparams.count {
    __closureParamNames.add(lparams[__cpi].name, true)
    __cpi = __cpi + 1
  }
  for __vk in mapKeys(ctx.varGenericArgs) {
    if not __closureParamNames.containsKey(__vk) {
      match mapGet(ctx.varGenericArgs, __vk) {
        case Some(__vargs) -> bodyCtx.varGenericArgs.add(__vk, __vargs)
        case None -> {
        }
      }
    }
  }
  // Reserve slot 0 (this) and slot 1 (Object[] args).
  allocSlot(bodyCtx, "__closure_this", JRef(className = closureClass))
  val argsSlot = allocSlot(bodyCtx, "__closure_args", JArray(elem = JRef(className = "java/lang/Object")))

  val bodyInsns: List[LInsn] = newList()
  // Unpack each lambda param from args[i].  Annotated params unbox to their
  // declared JVM type; un-annotated params stay `Object` (the J4 erased model —
  // numeric binops / comparisons unbox on demand via reconcileCmpOperands).
  var pi = 0
  while pi < lparams.count {
    val lp = lparams[pi]
    val pty = match lp.ty {
      case Some(te) -> typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes)
      case None -> JRef(className = "java/lang/Object")
    }
    val pslot = allocSlot(bodyCtx, lp.name, pty)
    bodyInsns.add(LAload(slot = argsSlot))
    bodyInsns.add(LIconst(v = pi))
    bodyInsns.add(LAaload)
    // args[i] is Object; coerce to the param's (possibly primitive) type.
    coerceArgTo(bodyInsns, JRef(className = "java/lang/Object"), pty)
    emitStore(bodyInsns, pslot, pty)
    pi = pi + 1
  }
  // Read each capture field into a local of the capture's type.
  // For hoisted cells, the local stores the cell array itself; access inside
  // the closure body will go through cell[0].
  var cj = 0
  while cj < captures.count {
    val cap = captures[cj]
    // Check if this capture is a hoisted cell
    val isHoistedCell = match mapGet(ctx.hoistedCellType, cap.captureName) { case Some(_) -> true; case None -> false }
    if isHoistedCell {
      bodyCtx.captureCellNames.add(cap.captureName)
    }
    val cslot = allocSlot(bodyCtx, cap.captureName, cap.captureType)
    bodyInsns.add(LAload(slot = 0))
    bodyInsns.add(LGetfield(owner = closureClass, name = cap.captureName, t = cap.captureType))
    emitStore(bodyInsns, cslot, cap.captureType)
    // For hoisted cells, also record the cell slot and element type in the body context
    if isHoistedCell {
      val elemTy = match mapGet(ctx.hoistedCellType, cap.captureName) {
        case Some(t) -> t
        case None -> JRef(className = "java/lang/Object")
      }
      bodyCtx.hoistedCellSlot.add(cap.captureName, cslot)
      bodyCtx.hoistedCellType.add(cap.captureName, elemTy)
    }
    cj = cj + 1
  }
  // Lower the lambda body in expression position; box the value to Object and
  // return it (Unit lambdas push null).
  val tailTy = lowerBlockExpr(bodyCtx, bodyInsns, body)
  match tailTy {
    case JVoid -> bodyInsns.add(LAconstNull)
    case _ -> boxIfNeeded(bodyInsns, tailTy)
  }
  bodyInsns.add(LAreturn)

  val methodParams: List[JvmType] = newList()
  methodParams.add(JArray(elem = JRef(className = "java/lang/Object")))
  val closure = LClosure(
    closureClass = closureClass,
    ifaceClass = ifaceName,
    ifaceMethod = lambdaIfaceMethod(),
    captures = captures,
    methodParams = methodParams,
    methodRet = JRef(className = "java/lang/Object"),
    bodyInsns = bodyInsns,
    bodyMaxLocals = bodyCtx.slotTicker.count
  )
  ctx.closureAcc[idx] = closure

  // ── Construct the closure at the lambda site ─────────────────────────────────
  insns.add(LNew(className = closureClass))
  insns.add(LDup)
  var ck = 0
  while ck < captures.count {
    val cap = captures[ck]
    // Load the captured value to pass to the closure ctor.  A local/param is
    // read from its slot; an enclosing-receiver field (`selfClass`) is read via
    // `aload_0; getfield selfClass.<name>` (#2864 — record-method / protected-
    // entry lambdas capturing a bare field).  For hoisted vars, the capture type
    // is the cell array (by reference), so load the cell slot directly.
    val isHoistedCell = match mapGet(ctx.hoistedCellSlot, cap.captureName) { case Some(_) -> true; case None -> false }
    if isHoistedCell {
      match mapGet(ctx.hoistedCellSlot, cap.captureName) {
        case Some(cellSlot) -> {
          val cellType = cap.captureType
          emitLoad(insns, cellSlot, cellType)
        }
        case None -> insns.add(LAconstNull)
      }
    } else {
      match lookupSlot(ctx, cap.captureName) {
        case Some(s) -> emitLoad(insns, s, cap.captureType)
        case None -> {
          val selfCls = match ctx.selfClass { case Some(c) -> c; case None -> "" }
          insns.add(LAload(slot = 0))
          insns.add(LGetfield(owner = selfCls, name = cap.captureName, t = cap.captureType))
        }
      }
    }
    ck = ck + 1
  }
  val ctorPs: List[JvmType] = newList()
  var cp = 0
  while cp < captures.count {
    ctorPs.add(captures[cp].captureType)
    cp = cp + 1
  }
  insns.add(LInvokespecial(owner = closureClass, name = "<init>", params = ctorPs, ret = JVoid))
  JRef(className = ifaceName)
}
