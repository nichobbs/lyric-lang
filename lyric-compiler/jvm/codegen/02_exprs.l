//! jvm/codegen_2_exprs.l — Jvm.Codegen: expression lowering.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! lowerExpr and its comparison, boolean-condition, if/block, interpolated-string,
//! and boxing helpers.
package Jvm.Codegen

import Std.Core
import Std.Collections
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
      insns.add(LDcmpl)
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
      insns.add(LFcmpl)
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
        val eqPs: List[JvmType] = newList()
        eqPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
        match op {
          case BEq -> insns.add(LIfne(label = trueLabel))
          case BNeq -> insns.add(LIfeq(label = trueLabel))
          case _ -> panic("Jvm.Codegen: unsupported String comparison op")
        }
      } else {
        match op {
          case BEq -> insns.add(LIfAcmpeq(label = trueLabel))
          case BNeq -> insns.add(LIfAcmpne(label = trueLabel))
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

// Emit the panic sequence for a string message already on the stack.
// Consumes the message from the stack, throws RuntimeException.
func emitPanicFromStack(ctx: in FuncCtx, insns: in List[LInsn]): Unit {
  // Message is on stack.  Store it to a temp slot so we can dup for ctor.
  val msgSlot = allocSlot(ctx, "__panic_msg_" + toString(ctx.slotTicker.count), JRef(className = "java/lang/String"))
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
          emitLoad(insns, slot, ty)
          ty
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
              match mapGet(ctx.ctors, name) {
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
        // Boolean short-circuit: lower to branch+const sequence.
        case BAnd -> {
          val falseL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          lowerExpr(ctx, insns, lhs)
          insns.add(LIfeq(label = falseL))
          lowerExpr(ctx, insns, rhs)
          insns.add(LIfeq(label = falseL))
          insns.add(LIconst(v = 1))
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = falseL))
          insns.add(LIconst(v = 0))
          insns.add(LLabel(name = afterL))
          JBoolean
        }
        case BOr -> {
          val trueL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          lowerExpr(ctx, insns, lhs)
          insns.add(LIfne(label = trueL))
          lowerExpr(ctx, insns, rhs)
          insns.add(LIfne(label = trueL))
          insns.add(LIconst(v = 0))
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = trueL))
          insns.add(LIconst(v = 1))
          insns.add(LLabel(name = afterL))
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
                val numTy = reconcileCmpOperands(ctx, insns, lhsTy, rhsTy)
                match numTy {
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
              val lhsSlot = allocSlot(ctx, "__add_lhs_" + toString(ctx.slotTicker.count), lhsTy)
              emitStore(insns, lhsSlot, lhsTy)
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
              lowerExpr(ctx, insns, rhs)
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
              lowerExpr(ctx, insns, rhs)
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
          // Null-coalescing: if lhs is non-null use it, else rhs.
          val lhsTy = lowerExpr(ctx, insns, lhs)
          val nullL = freshLabel(ctx)
          val afterL = freshLabel(ctx)
          insns.add(LDup)
          insns.add(LIfAcmpne(label = afterL))
          insns.add(LPop)
          lowerExpr(ctx, insns, rhs)
          insns.add(LLabel(name = afterL))
          lhsTy
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
                JRef(className = "java/lang/Object")
              }
            }
          }
        }
        case JArray(_) -> {
          // `arr.length` on a JVM array → `arraylength` (JInt).  Without
          // this, array length fell through to the JVoid arm below and
          // mis-stacked (e.g. a `byte[]` returned by an auto-FFI digest
          // call).  Any other member on an array is not meaningful.
          if memberName == "length" {
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
      val tupSlot = allocSlot(ctx, "__tuple_" + toString(ctx.slotTicker.count), JRef(className = "java/util/ArrayList"))
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
      val listSlot = allocSlot(ctx, "__list_" + toString(ctx.slotTicker.count), JRef(className = "java/util/ArrayList"))
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

    // ── Unsupported forms: panic at codegen time ──────────────────────────
    case EForall(_, _, _) -> {
      panic("Jvm.Codegen: EForall not supported in JVM codegen")
    }
    case EExists(_, _, _) -> {
      panic("Jvm.Codegen: EExists not supported in JVM codegen")
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
    case ELambda(_, _) -> {
      // General lambda lowering (closure class generation) is deferred.
      // The only supported lambda use is as a literal argument to Std.Jvm.catch,
      // which is handled by lowerCatchIntrinsic before lowerExpr is ever called.
      panic("Jvm.Codegen: ELambda not supported — pass lambdas directly to Std.Jvm.catch")
    }
    case ETypeApp(fn, _) -> {
      // Ignore type args and lower the function expression.
      lowerExpr(ctx, insns, fn)
    }
    case EIndex(recv, indices) -> {
      // Array/list indexing.
      val recvTy = lowerExpr(ctx, insns, recv)
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
              case _ -> {
                insns.add(LAaload)
                JRef(className = "java/lang/Object")
              }
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
func reconcileCmpOperands(ctx: in FuncCtx, insns: in List[LInsn], lhsTy: in JvmType, rhsTy: in JvmType): JvmType {
  val lhsPrim = numericPrimTy(lhsTy)
  val rhsPrim = numericPrimTy(rhsTy)
  if isRefJvm(lhsTy) and not (rhsPrim == JVoid) {
    // Unbox lhs (currently below rhs): spill rhs, unbox lhs, reload rhs.
    val rhsSlot = allocSlot(ctx, "__cmp_rhs_" + toString(ctx.slotTicker.count), rhsTy)
    emitStore(insns, rhsSlot, rhsTy)
    coerceArgTo(insns, lhsTy, rhsPrim)
    emitLoad(insns, rhsSlot, rhsTy)
    rhsPrim
  } else if isRefJvm(rhsTy) and not (lhsPrim == JVoid) {
    // Unbox rhs (on top of the stack) directly.
    coerceArgTo(insns, rhsTy, lhsPrim)
    lhsPrim
  } else {
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
      insns.add(LDcmpl)
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
      insns.add(LFcmpl)
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
        val eqPs: List[JvmType] = newList()
        eqPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
        match op {
          case BEq -> insns.add(LIfeq(label = failLabel))
          case BNeq -> insns.add(LIfne(label = failLabel))
          case _ -> insns.add(LNop)
        }
      } else {
        match op {
          case BEq -> insns.add(LIfAcmpne(label = failLabel))
          case BNeq -> insns.add(LIfAcmpeq(label = failLabel))
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
      lowerBoolCond(ctx, insns, cond, elseL)
      val _ = lowerExprOrBlock(ctx, insns, thenBranch)
      insns.add(LLabel(name = elseL))
      JVoid
    }
    case Some(elseBranch) -> {
      lowerBoolCond(ctx, insns, cond, elseL)
      val thenTy = lowerExprOrBlock(ctx, insns, thenBranch)
      match thenTy {
        case JVoid -> {
          // Void if-expression: nothing on the stack at the `afterL` join.
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = elseL))
          val _ = lowerExprOrBlock(ctx, insns, elseBranch)
          insns.add(LLabel(name = afterL))
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
          emitStore(insns, rslot, thenTy)
          insns.add(LGoto(label = afterL))
          insns.add(LLabel(name = elseL))
          val _ = lowerExprOrBlock(ctx, insns, elseBranch)
          emitStore(insns, rslot, thenTy)
          insns.add(LLabel(name = afterL))
          emitResultLoad(insns, rslot, thenTy)
          thenTy
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
  // Build with StringBuilder.
  insns.add(LNew(className = "java/lang/StringBuilder"))
  insns.add(LDup)
  val sbInitPs: List[JvmType] = newList()
  insns.add(LInvokespecial(owner = "java/lang/StringBuilder", name = "<init>", params = sbInitPs, ret = JVoid))
  var i = 0
  while i < segments.count {
    match segments[i] {
      case ISText(text, _) -> {
        insns.add(LPushString(s = text))
        val appPs: List[JvmType] = newList()
        appPs.add(JRef(className = "java/lang/String"))
        insns.add(
          LInvokevirtual(
            owner = "java/lang/StringBuilder",
            name = "append",
            params = appPs,
            ret = JRef(className = "java/lang/StringBuilder")
          )
        )
      }
      case ISExpr(e) -> {
        val eTy = lowerExpr(ctx, insns, e)
        // Convert to String via toString if not already a String.
        match eTy {
          case JRef(cls) -> {
            if not (cls == "java/lang/String") {
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
            insns.add(LNop)
          }
          case _ -> {
            // Box and toString.
            boxIfNeeded(insns, eTy)
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
      }
    }
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
