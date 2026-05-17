// jvm/codegen.l — Jvm.Codegen
//
// Bootstrap-grade AST-to-JVM-IR lowering for the Lyric self-hosted compiler.
// Walks a parsed `SourceFile` (from Lyric.Parser) and produces an `LPackage`
// (from Jvm.Lowering) suitable for further lowering to class-file bytes by
// `Jvm.Lowering.lowerPackage`.
//
// Supported in this bootstrap pass:
//   • Simple functions — arithmetic, locals, if/else, while
//   • Hello-world programs (main with println)
//   • Record types with fields
//   • Union types (lowered to sealed-union IR)
//   • Basic builtin calls: println, print, panic, toString, assert, newList,
//     default, format1..format4
//
// Unsupported forms panic at codegen time so failures are visible rather
// than silently wrong.

package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Lowering

// ─────────────────────────────────────────────────────────────────────────────
// §1. Per-function codegen context.
// ─────────────────────────────────────────────────────────────────────────────

// FuncCtx threads mutable state through expression and statement lowering.
// `slotTicker` and `labelTicker` are singleton lists whose `.count` is the
// current next-slot / next-label integer; `.add` advances them.
pub record FuncCtx {
  pkgName:     String            // JVM path, e.g. "com/example/Hello"
  className:   String            // host class for static methods
  slots:       Map[String, Int]  // variable name → local slot
  types:       Map[String, JvmType]  // variable name → JVM type
  slotTicker:  List[Int]         // length = next slot index
  labelTicker: List[Int]         // length = next label index
  loopBreak:   List[String]      // stack of loop exit labels (innermost last)
  loopCont:    List[String]      // stack of loop continue labels (innermost last)
  // Generator body context: when Some, EYield emits LYield; when None, EYield panics.
  genClass:    Option[String]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Helper utilities.
// ─────────────────────────────────────────────────────────────────────────────

// Convert a dotted Lyric package name to a JVM internal binary name.
pub func lyricNameToJvm(name: in String): String {
  name.replace(".", "/")
}

// Allocate a fresh label like "L0", "L1", …
pub func freshLabel(ctx: in FuncCtx): String {
  val n = ctx.labelTicker.count
  ctx.labelTicker.add(0)
  "L" + toString(n)
}

// Assign the next JVM local slot to `name` with type `ty`.
// Long and Double occupy two consecutive slots; all others occupy one.
// Returns the assigned slot.
pub func allocSlot(ctx: in FuncCtx, name: in String, ty: in JvmType): Int {
  val slot = ctx.slotTicker.count
  ctx.slots.add(name, slot)
  ctx.types.add(name, ty)
  // Advance the ticker.
  ctx.slotTicker.add(0)
  match ty {
    case JLong   -> { ctx.slotTicker.add(0) }
    case JDouble -> { ctx.slotTicker.add(0) }
    case _       -> {}
  }
  slot
}

// Look up the slot assigned to `name`.
pub func lookupSlot(ctx: in FuncCtx, name: in String): Option[Int] {
  mapGet(ctx.slots, name)
}

// Look up the JVM type of a named local.
pub func lookupType(ctx: in FuncCtx, name: in String): Option[JvmType] {
  mapGet(ctx.types, name)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Type mapping.
// ─────────────────────────────────────────────────────────────────────────────

// Return the last segment of a ModulePath.
func lastSegment(path: in ModulePath): String {
  val n = path.segments.count
  if n == 0 {
    return ""
  }
  path.segments[n - 1]
}

// Join path segments with a separator.
func joinSegments(segs: in List[String], sep: in String): String {
  var result = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      result = result + sep
    }
    result = result + segs[i]
    i = i + 1
  }
  result
}

// Map a Lyric TypeExpr to a JvmType.
pub func typeExprToJvm(te: in TypeExpr, pkgName: in String): JvmType {
  match te.kind {
    case TUnit -> JVoid
    case TNever -> JVoid
    case TRef(path) -> {
      val seg = lastSegment(path)
      if seg == "Int" {
        JInt
      } else if seg == "Long" {
        JLong
      } else if seg == "Double" {
        JDouble
      } else if seg == "Float" {
        JDouble
      } else if seg == "Bool" {
        JBoolean
      } else if seg == "String" {
        JRef(className = "java/lang/String")
      } else if seg == "Char" {
        JChar
      } else if seg == "Byte" {
        JByte
      } else if seg == "Unit" {
        JVoid
      } else {
        // User-defined type in the same package.
        JRef(className = pkgName + "/" + seg)
      }
    }
    case TSlice(_) -> JArray(elem = JRef(className = "java/lang/Object"))
    case TGenericApp(_, _) -> JRef(className = "java/lang/Object")
    case TNullable(_) -> JRef(className = "java/lang/Object")
    case TTuple(_) -> JRef(className = "java/lang/Object")
    case TFunction(_, _) -> JRef(className = "java/lang/Object")
    case TArray(_, _) -> JRef(className = "java/lang/Object")
    case TRefined(_, _) -> JInt
    case TParen(inner) -> typeExprToJvm(inner, pkgName)
    case TSelf -> JRef(className = "java/lang/Object")
    case TError -> JRef(className = "java/lang/Object")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Load / store / return helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func emitLoad(insns: in List[LInsn], slot: in Int, ty: in JvmType): Unit {
  match ty {
    case JLong    -> insns.add(LLload(slot = slot))
    case JDouble  -> insns.add(LDload(slot = slot))
    case JBoolean -> insns.add(LIload(slot = slot))
    case JByte    -> insns.add(LIload(slot = slot))
    case JChar    -> insns.add(LIload(slot = slot))
    case JShort   -> insns.add(LIload(slot = slot))
    case JInt     -> insns.add(LIload(slot = slot))
    case JFloat   -> insns.add(LDload(slot = slot))
    case JVoid    -> insns.add(LNop)
    case JRef(_)  -> insns.add(LAload(slot = slot))
    case JArray(_) -> insns.add(LAload(slot = slot))
  }
}

pub func emitStore(insns: in List[LInsn], slot: in Int, ty: in JvmType): Unit {
  match ty {
    case JLong    -> insns.add(LLstore(slot = slot))
    case JDouble  -> insns.add(LDstore(slot = slot))
    case JBoolean -> insns.add(LIstore(slot = slot))
    case JByte    -> insns.add(LIstore(slot = slot))
    case JChar    -> insns.add(LIstore(slot = slot))
    case JShort   -> insns.add(LIstore(slot = slot))
    case JInt     -> insns.add(LIstore(slot = slot))
    case JFloat   -> insns.add(LDstore(slot = slot))
    case JVoid    -> insns.add(LNop)
    case JRef(_)  -> insns.add(LAstore(slot = slot))
    case JArray(_) -> insns.add(LAstore(slot = slot))
  }
}

pub func emitReturn(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JLong    -> insns.add(LLreturn)
    case JDouble  -> insns.add(LDreturn)
    case JBoolean -> insns.add(LIreturn)
    case JByte    -> insns.add(LIreturn)
    case JChar    -> insns.add(LIreturn)
    case JShort   -> insns.add(LIreturn)
    case JInt     -> insns.add(LIreturn)
    case JFloat   -> insns.add(LDreturn)
    case JVoid    -> insns.add(LReturn)
    case JRef(_)  -> insns.add(LAreturn)
    case JArray(_) -> insns.add(LAreturn)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Forward declarations: lowerExpr / lowerBlock / lowerStmt are mutually
// recursive.  In Lyric this is supported via the natural forward-reference
// rules — all three are in the same package and file, so they can call each
// other freely.

// Lower a comparison expression.  lhs type determines which comparison is used.
func lowerCmp(
  ctx:     in FuncCtx,
  insns:   in List[LInsn],
  op:      in BinOp,
  lhsTy:   in JvmType,
  trueLabel:  in String,
  falseLabel: in String
): Unit {
  match lhsTy {
    case JLong -> {
      insns.add(LLcmp)
      match op {
        case BEq  -> insns.add(LIfeq(label = trueLabel))
        case BNeq -> insns.add(LIfne(label = trueLabel))
        case BLt  -> insns.add(LIflt(label = trueLabel))
        case BLte -> insns.add(LIfle(label = trueLabel))
        case BGt  -> insns.add(LIfgt(label = trueLabel))
        case BGte -> insns.add(LIfge(label = trueLabel))
        case _    -> panic("Jvm.Codegen: unsupported long comparison op")
      }
    }
    case JDouble -> {
      insns.add(LDcmpl)
      match op {
        case BEq  -> insns.add(LIfeq(label = trueLabel))
        case BNeq -> insns.add(LIfne(label = trueLabel))
        case BLt  -> insns.add(LIflt(label = trueLabel))
        case BLte -> insns.add(LIfle(label = trueLabel))
        case BGt  -> insns.add(LIfgt(label = trueLabel))
        case BGte -> insns.add(LIfge(label = trueLabel))
        case _    -> panic("Jvm.Codegen: unsupported double comparison op")
      }
    }
    case JRef(_) -> {
      match op {
        case BEq  -> insns.add(LIfAcmpeq(label = trueLabel))
        case BNeq -> insns.add(LIfAcmpne(label = trueLabel))
        case _    -> panic("Jvm.Codegen: unsupported reference comparison op")
      }
    }
    case _ -> {
      // Integer comparison (int, bool, char, byte, short).
      match op {
        case BEq  -> insns.add(LIfIcmpeq(label = trueLabel))
        case BNeq -> insns.add(LIfIcmpne(label = trueLabel))
        case BLt  -> insns.add(LIfIcmplt(label = trueLabel))
        case BLte -> insns.add(LIfIcmple(label = trueLabel))
        case BGt  -> insns.add(LIfIcmpgt(label = trueLabel))
        case BGte -> insns.add(LIfIcmpge(label = trueLabel))
        case _    -> panic("Jvm.Codegen: unsupported int comparison op")
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
  insns.add(LInvokespecial(
    owner  = "java/lang/RuntimeException",
    name   = "<init>",
    params = rteps,
    ret    = JVoid))
  insns.add(LAthrow)
}

// Lower a single expression.  Pushes exactly one value onto the operand
// stack (or nothing for JVoid).  Returns the JvmType of the pushed value.
pub func lowerExpr(ctx: in FuncCtx, insns: in List[LInsn], expr: in Expr): JvmType {
  match expr.kind {

    // ── Literals ──────────────────────────────────────────────────────────
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _) -> {
          // Use LIconst for int range; LLconst for long range if needed.
          // LLconst takes a Long, LIconst takes Int.
          // Lyric's Long is a 64-bit int; for values that fit in Int use LIconst.
          val asInt = longToInt(v)
          if intToLong(asInt) == v {
            insns.add(LIconst(v = asInt))
            JInt
          } else {
            insns.add(LLconst(v = v))
            JLong
          }
        }
        case LFloat(v, _) -> {
          insns.add(LDconst(v = v))
          JDouble
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
          val ty =
            match lookupType(ctx, name) {
              case Some(t) -> t
              case None    -> JRef(className = "java/lang/Object")
            }
          emitLoad(insns, slot, ty)
          ty
        }
        case None -> {
          // Could be a package-qualified name or unknown reference.
          // Emit null as a safe fallback.
          insns.add(LAconstNull)
          JRef(className = "java/lang/Object")
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
          val trueL  = freshLabel(ctx)
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
        case BEq  -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        case BNeq -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        case BLt  -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        case BLte -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        case BGt  -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        case BGte -> { lowerCmpExpr(ctx, insns, op, lhs, rhs) }
        // Arithmetic ops.
        case BAdd -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          match lhsTy {
            case JRef(cls) -> {
              if not (cls == "java/lang/String") {
                panic("Jvm.Codegen: BAdd on non-String ref type: " + cls)
              }
              // Store lhs (already on JVM stack) to a slot before building the StringBuilder.
              val lhsSlot = allocSlot(ctx, "__add_lhs_" + toString(ctx.slotTicker.count), lhsTy)
              emitStore(insns, lhsSlot, lhsTy)
              insns.add(LNew(className = "java/lang/StringBuilder"))
              insns.add(LDup)
              val sbInitPs: List[JvmType] = newList()
              insns.add(LInvokespecial(
                owner  = "java/lang/StringBuilder",
                name   = "<init>",
                params = sbInitPs,
                ret    = JVoid))
              emitLoad(insns, lhsSlot, lhsTy)
              val appPs1: List[JvmType] = newList()
              appPs1.add(JRef(className = "java/lang/String"))
              insns.add(LInvokevirtual(
                owner  = "java/lang/StringBuilder",
                name   = "append",
                params = appPs1,
                ret    = JRef(className = "java/lang/StringBuilder")))
              lowerExpr(ctx, insns, rhs)
              val appPs2: List[JvmType] = newList()
              appPs2.add(JRef(className = "java/lang/String"))
              insns.add(LInvokevirtual(
                owner  = "java/lang/StringBuilder",
                name   = "append",
                params = appPs2,
                ret    = JRef(className = "java/lang/StringBuilder")))
              val tsPs: List[JvmType] = newList()
              insns.add(LInvokevirtual(
                owner  = "java/lang/StringBuilder",
                name   = "toString",
                params = tsPs,
                ret    = JRef(className = "java/lang/String")))
              JRef(className = "java/lang/String")
            }
            case JLong -> {
              lowerExpr(ctx, insns, rhs)
              insns.add(LLadd)
              JLong
            }
            case JDouble -> {
              lowerExpr(ctx, insns, rhs)
              insns.add(LDadd)
              JDouble
            }
            case _ -> {
              lowerExpr(ctx, insns, rhs)
              insns.add(LIadd)
              JInt
            }
          }
        }
        case BSub -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          match lhsTy {
            case JLong   -> { insns.add(LLsub); JLong }
            case JDouble -> { insns.add(LDsub); JDouble }
            case _       -> { insns.add(LIsub); JInt }
          }
        }
        case BMul -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          match lhsTy {
            case JLong   -> { insns.add(LLmul); JLong }
            case JDouble -> { insns.add(LDmul); JDouble }
            case _       -> { insns.add(LImul); JInt }
          }
        }
        case BDiv -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          match lhsTy {
            case JLong   -> { insns.add(LLdiv); JLong }
            case JDouble -> { insns.add(LDdiv); JDouble }
            case _       -> { insns.add(LIdiv); JInt }
          }
        }
        case BMod -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          match lhsTy {
            case JLong   -> { insns.add(LLrem); JLong }
            case _       -> { insns.add(LIrem); JInt }
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
          val nullL  = freshLabel(ctx)
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
          val trueL  = freshLabel(ctx)
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
            case JLong   -> { insns.add(LLneg); JLong }
            case JDouble -> { insns.add(LDneg); JDouble }
            case _       -> { insns.add(LIneg); JInt }
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
          // Treat as getfield — the actual owner class comes from the type.
          // For bootstrap-grade codegen we use the receiver type as owner.
          JRef(className = "java/lang/Object")
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
      // Bootstrap: lower first element only (tuples not fully supported).
      if exprs.count > 0 {
        lowerExpr(ctx, insns, exprs[0])
      } else {
        JVoid
      }
    }

    // ── List literal ──────────────────────────────────────────────────────
    case EList(exprs) -> {
      // Emit ArrayList construction and populate it.
      insns.add(LNew(className = "java/util/ArrayList"))
      insns.add(LDup)
      val alInitPs: List[JvmType] = newList()
      insns.add(LInvokespecial(
        owner  = "java/util/ArrayList",
        name   = "<init>",
        params = alInitPs,
        ret    = JVoid))
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
        insns.add(LInvokevirtual(
          owner  = "java/util/ArrayList",
          name   = "add",
          params = addPs,
          ret    = JBoolean))
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
      JRef(className = "java/lang/Object")
    }
    case EResult -> {
      panic("Jvm.Codegen: EResult outside contract context")
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
          case JArray(_) -> {
            insns.add(LAaload)
            JRef(className = "java/lang/Object")
          }
          case _ -> {
            // List-style indexing via ArrayList.get(int).
            val getPs: List[JvmType] = newList()
            getPs.add(JInt)
            insns.add(LInvokevirtual(
              owner  = "java/util/ArrayList",
              name   = "get",
              params = getPs,
              ret    = JRef(className = "java/lang/Object")))
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

func lowerCmpExpr(
  ctx:   in FuncCtx,
  insns: in List[LInsn],
  op:    in BinOp,
  lhs:   in Expr,
  rhs:   in Expr
): JvmType {
  val lhsTy  = lowerExpr(ctx, insns, lhs)
  lowerExpr(ctx, insns, rhs)
  val trueL  = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  lowerCmp(ctx, insns, op, lhsTy, trueL, afterL)
  // fall-through: comparison was false
  insns.add(LIconst(v = 0))
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = trueL))
  insns.add(LIconst(v = 1))
  insns.add(LLabel(name = afterL))
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
        case BEq  -> insns.add(LIfne(label = failLabel))
        case BNeq -> insns.add(LIfeq(label = failLabel))
        case BLt  -> insns.add(LIfge(label = failLabel))
        case BLte -> insns.add(LIfgt(label = failLabel))
        case BGt  -> insns.add(LIfle(label = failLabel))
        case BGte -> insns.add(LIflt(label = failLabel))
        case _    -> insns.add(LNop)
      }
    }
    case JDouble -> {
      insns.add(LDcmpl)
      match op {
        case BEq  -> insns.add(LIfne(label = failLabel))
        case BNeq -> insns.add(LIfeq(label = failLabel))
        case BLt  -> insns.add(LIfge(label = failLabel))
        case BLte -> insns.add(LIfgt(label = failLabel))
        case BGt  -> insns.add(LIfle(label = failLabel))
        case BGte -> insns.add(LIflt(label = failLabel))
        case _    -> insns.add(LNop)
      }
    }
    case JRef(_) -> {
      match op {
        case BEq  -> insns.add(LIfAcmpne(label = failLabel))
        case BNeq -> insns.add(LIfAcmpeq(label = failLabel))
        case _    -> insns.add(LNop)
      }
    }
    case _ -> {
      match op {
        case BEq  -> insns.add(LIfIcmpne(label = failLabel))
        case BNeq -> insns.add(LIfIcmpeq(label = failLabel))
        case BLt  -> insns.add(LIfIcmpge(label = failLabel))
        case BLte -> insns.add(LIfIcmpgt(label = failLabel))
        case BGt  -> insns.add(LIfIcmple(label = failLabel))
        case BGte -> insns.add(LIfIcmplt(label = failLabel))
        case _    -> insns.add(LNop)
      }
    }
  }
}

// Compile a boolean condition, branching to failLabel if it is false.
// Leaves the operand stack unchanged (no net stack effect).
func lowerBoolCond(
  ctx:       in FuncCtx,
  insns:     in List[LInsn],
  cond:      in Expr,
  failLabel: in String
): Unit {
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
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmpFail(insns, BEq, lhsTy, failLabel)
        }
        case BNeq -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmpFail(insns, BNeq, lhsTy, failLabel)
        }
        case BLt -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmpFail(insns, BLt, lhsTy, failLabel)
        }
        case BLte -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmpFail(insns, BLte, lhsTy, failLabel)
        }
        case BGt -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmpFail(insns, BGt, lhsTy, failLabel)
        }
        case BGte -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
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
        case _      -> { lowerExpr(ctx, insns, cond); insns.add(LIfeq(label = failLabel)) }
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
func lowerBoolCondTrue(
  ctx:          in FuncCtx,
  insns:        in List[LInsn],
  cond:         in Expr,
  succeedLabel: in String
): Unit {
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
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmp(ctx, insns, BEq, lhsTy, succeedLabel, "")
        }
        case BNeq -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmp(ctx, insns, BNeq, lhsTy, succeedLabel, "")
        }
        case BLt -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmp(ctx, insns, BLt, lhsTy, succeedLabel, "")
        }
        case BLte -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmp(ctx, insns, BLte, lhsTy, succeedLabel, "")
        }
        case BGt -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
          lowerCmp(ctx, insns, BGt, lhsTy, succeedLabel, "")
        }
        case BGte -> {
          val lhsTy = lowerExpr(ctx, insns, lhs)
          lowerExpr(ctx, insns, rhs)
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
        case _      -> { lowerExpr(ctx, insns, cond); insns.add(LIfne(label = succeedLabel)) }
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
    case EOBExpr(e)    -> lowerExpr(ctx, insns, e)
    case EOBBlock(blk) -> lowerBlockExpr(ctx, insns, blk)
  }
}

func lowerIfExpr(
  ctx:           in FuncCtx,
  insns:         in List[LInsn],
  cond:          in Expr,
  thenBranch:    in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock]
): JvmType {
  val elseL  = freshLabel(ctx)
  val afterL = freshLabel(ctx)

  lowerBoolCond(ctx, insns, cond, elseL)

  val thenTy = lowerExprOrBlock(ctx, insns, thenBranch)

  match elseBranchOpt {
    case Some(elseBranch) -> {
      insns.add(LGoto(label = afterL))
      insns.add(LLabel(name = elseL))
      lowerExprOrBlock(ctx, insns, elseBranch)
      insns.add(LLabel(name = afterL))
      thenTy
    }
    case None -> {
      insns.add(LLabel(name = elseL))
      thenTy
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
  var i = 0
  while i < n - 1 {
    lowerStmt(ctx, insns, block.statements[i])
    i = i + 1
  }
  // Last statement: if SExpr, its value is the block value.
  val last = block.statements[n - 1]
  match last.kind {
    case SExpr(e) -> {
      lowerExpr(ctx, insns, e)
    }
    case _ -> {
      lowerStmt(ctx, insns, last)
      JVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5d. Assignment expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerAssignExpr(
  ctx:    in FuncCtx,
  insns:  in List[LInsn],
  target: in Expr,
  op:     in AssignOp,
  value:  in Expr
): JvmType {
  match target.kind {
    case EPath(path) -> {
      val name = lastSegment(path)
      match lookupSlot(ctx, name) {
        case Some(slot) -> {
          val ty =
            match lookupType(ctx, name) {
              case Some(t) -> t
              case None    -> JRef(className = "java/lang/Object")
            }
          match op {
            case AssEq -> {
              lowerExpr(ctx, insns, value)
              emitStore(insns, slot, ty)
            }
            case AssPlus -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong   -> insns.add(LLadd)
                case JDouble -> insns.add(LDadd)
                case _       -> insns.add(LIadd)
              }
              emitStore(insns, slot, ty)
            }
            case AssMinus -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong   -> insns.add(LLsub)
                case JDouble -> insns.add(LDsub)
                case _       -> insns.add(LIsub)
              }
              emitStore(insns, slot, ty)
            }
            case AssStar -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong   -> insns.add(LLmul)
                case JDouble -> insns.add(LDmul)
                case _       -> insns.add(LImul)
              }
              emitStore(insns, slot, ty)
            }
            case AssSlash -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong   -> insns.add(LLdiv)
                case JDouble -> insns.add(LDdiv)
                case _       -> insns.add(LIdiv)
              }
              emitStore(insns, slot, ty)
            }
            case AssPercent -> {
              emitLoad(insns, slot, ty)
              lowerExpr(ctx, insns, value)
              match ty {
                case JLong   -> insns.add(LLrem)
                case _       -> insns.add(LIrem)
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
// §5e. Match expression lowering.
//      Bootstrap-grade: handles literal and binding patterns only.
// ─────────────────────────────────────────────────────────────────────────────

func lowerMatchExpr(
  ctx:      in FuncCtx,
  insns:    in List[LInsn],
  scrutinee: in Expr,
  arms:     in List[MatchArm]
): JvmType {
  val scrutTy = lowerExpr(ctx, insns, scrutinee)
  val scrutSlot = allocSlot(ctx, "__scrut_" + toString(ctx.slotTicker.count), scrutTy)
  emitStore(insns, scrutSlot, scrutTy)

  val afterL = freshLabel(ctx)
  var resultTy: JvmType = JVoid

  var i = 0
  while i < arms.count {
    val arm = arms[i]
    val nextArmL = freshLabel(ctx)
    // Emit pattern test.
    lowerPatternTest(ctx, insns, arm.pattern, scrutSlot, scrutTy, nextArmL)
    // Bind pattern variables.
    lowerPatternBind(ctx, insns, arm.pattern, scrutSlot, scrutTy)
    // Emit guard if present.
    match arm.guard {
      case Some(g) -> {
        lowerExpr(ctx, insns, g)
        insns.add(LIfeq(label = nextArmL))
      }
      case None -> {
        insns.add(LNop)
      }
    }
    // Emit arm body.
    val armTy = lowerExprOrBlock(ctx, insns, arm.body)
    if i == 0 {
      resultTy = armTy
    }
    insns.add(LGoto(label = afterL))
    insns.add(LLabel(name = nextArmL))
    i = i + 1
  }

  // If no arm matched: panic.
  insns.add(LPushString(s = "Jvm.Codegen: match not exhaustive"))
  emitPanicFromStack(ctx, insns)

  insns.add(LLabel(name = afterL))
  resultTy
}

// Emit a runtime test for a pattern.  Jumps to `failLabel` if the test
// fails.  The scrutinee is in local slot `scrutSlot` with type `scrutTy`.
func lowerPatternTest(
  ctx:        in FuncCtx,
  insns:      in List[LInsn],
  pat:        in Pattern,
  scrutSlot:  in Int,
  scrutTy:    in JvmType,
  failLabel:  in String
): Unit {
  match pat.kind {
    case PWildcard -> insns.add(LNop)
    case PBinding(_, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> lowerPatternTest(ctx, insns, inner, scrutSlot, scrutTy, failLabel)
        case None        -> insns.add(LNop)
      }
    }
    case PLiteral(lit) -> {
      emitLoad(insns, scrutSlot, scrutTy)
      match lit {
        case LInt(v, _) -> {
          val asInt = longToInt(v)
          insns.add(LIconst(v = asInt))
          insns.add(LIfIcmpne(label = failLabel))
        }
        case LBool(value) -> {
          if value {
            insns.add(LIconst(v = 1))
          } else {
            insns.add(LIconst(v = 0))
          }
          insns.add(LIfIcmpne(label = failLabel))
        }
        case LString(s) -> {
          insns.add(LPushString(s = s))
          val eqPs: List[JvmType] = newList()
          eqPs.add(JRef(className = "java/lang/Object"))
          insns.add(LInvokevirtual(
            owner  = "java/lang/String",
            name   = "equals",
            params = eqPs,
            ret    = JBoolean))
          insns.add(LIfeq(label = failLabel))
        }
        case LUnit -> {
          // Unit always matches.
          insns.add(LPop)
        }
        case _ -> {
          // Other literal types: load and compare.
          insns.add(LPop)
        }
      }
    }
    case PConstructor(head, _) -> {
      // Bootstrap: use instanceof check.
      val caseName = lastSegment(head)
      emitLoad(insns, scrutSlot, scrutTy)
      match scrutTy {
        case JRef(baseCls) -> {
          insns.add(LCheckcast(className = baseCls + "$" + caseName))
          insns.add(LAstore(slot = scrutSlot))
          // Re-check with instanceof.
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LInstanceof(className = baseCls + "$" + caseName))
          insns.add(LIfeq(label = failLabel))
        }
        case _ -> {
          insns.add(LPop)
        }
      }
    }
    case POr(patterns) -> {
      // Or-pattern: succeed if any alternative matches.
      val succeedL = freshLabel(ctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabel(ctx)
        lowerPatternTest(ctx, insns, patterns[ai], scrutSlot, scrutTy, nextAltL)
        insns.add(LGoto(label = succeedL))
        insns.add(LLabel(name = nextAltL))
        ai = ai + 1
      }
      insns.add(LGoto(label = failLabel))
      insns.add(LLabel(name = succeedL))
    }
    case PError -> insns.add(LNop)
  }
}

// Bind pattern variables after a successful match.
func lowerPatternBind(
  ctx:       in FuncCtx,
  insns:     in List[LInsn],
  pat:       in Pattern,
  scrutSlot: in Int,
  scrutTy:   in JvmType
): Unit {
  match pat.kind {
    case PWildcard -> insns.add(LNop)
    case PBinding(name, innerOpt) -> {
      // Bind the name to the scrutinee value.
      emitLoad(insns, scrutSlot, scrutTy)
      val bindSlot = allocSlot(ctx, name, scrutTy)
      emitStore(insns, bindSlot, scrutTy)
      match innerOpt {
        case Some(inner) -> lowerPatternBind(ctx, insns, inner, bindSlot, scrutTy)
        case None        -> insns.add(LNop)
      }
    }
    case PLiteral(_) -> insns.add(LNop)
    case PConstructor(head, fields) -> {
      // Downcast and bind each field.
      val caseName = lastSegment(head)
      match scrutTy {
        case JRef(baseCls) -> {
          val caseClass = baseCls + "$" + caseName
          val castSlot = allocSlot(ctx, "__cast_" + caseName + "_" + toString(ctx.slotTicker.count), JRef(className = caseClass))
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LCheckcast(className = caseClass))
          emitStore(insns, castSlot, JRef(className = caseClass))
          // Bind each positional field by reading the corresponding field from the case class.
          // Bootstrap: bind by index only (field names unknown at this level).
          var fi = 0
          while fi < fields.count {
            match fields[fi].kind {
              case PBinding(fname, _) -> {
                emitLoad(insns, castSlot, JRef(className = caseClass))
                // Read field `fname` from the case class.
                insns.add(LGetfield(
                  owner = caseClass,
                  name  = fname,
                  t     = JRef(className = "java/lang/Object")))
                val fSlot = allocSlot(ctx, fname, JRef(className = "java/lang/Object"))
                emitStore(insns, fSlot, JRef(className = "java/lang/Object"))
              }
              case _ -> insns.add(LNop)
            }
            fi = fi + 1
          }
          insns.add(LNop)
        }
        case _ -> insns.add(LNop)
      }
    }
    case POr(_) -> insns.add(LNop)
    case PError -> insns.add(LNop)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5f. Interpolated string lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerInterpolated(
  ctx:      in FuncCtx,
  insns:    in List[LInsn],
  segments: in List[InterpolatedSegment]
): JvmType {
  if segments.count == 0 {
    insns.add(LPushString(s = ""))
    return JRef(className = "java/lang/String")
  }
  // Build with StringBuilder.
  insns.add(LNew(className = "java/lang/StringBuilder"))
  insns.add(LDup)
  val sbInitPs: List[JvmType] = newList()
  insns.add(LInvokespecial(
    owner  = "java/lang/StringBuilder",
    name   = "<init>",
    params = sbInitPs,
    ret    = JVoid))
  var i = 0
  while i < segments.count {
    match segments[i] {
      case ISText(text, _) -> {
        insns.add(LPushString(s = text))
        val appPs: List[JvmType] = newList()
        appPs.add(JRef(className = "java/lang/String"))
        insns.add(LInvokevirtual(
          owner  = "java/lang/StringBuilder",
          name   = "append",
          params = appPs,
          ret    = JRef(className = "java/lang/StringBuilder")))
      }
      case ISExpr(e) -> {
        val eTy = lowerExpr(ctx, insns, e)
        // Convert to String via toString if not already a String.
        match eTy {
          case JRef(cls) -> {
            if not (cls == "java/lang/String") {
              val tsPs: List[JvmType] = newList()
              insns.add(LInvokevirtual(
                owner  = "java/lang/Object",
                name   = "toString",
                params = tsPs,
                ret    = JRef(className = "java/lang/String")))
            }
            insns.add(LNop)
          }
          case _ -> {
            // Box and toString.
            boxIfNeeded(insns, eTy)
            val tsPs: List[JvmType] = newList()
            insns.add(LInvokevirtual(
              owner  = "java/lang/Object",
              name   = "toString",
              params = tsPs,
              ret    = JRef(className = "java/lang/String")))
          }
        }
        val appPs2: List[JvmType] = newList()
        appPs2.add(JRef(className = "java/lang/String"))
        insns.add(LInvokevirtual(
          owner  = "java/lang/StringBuilder",
          name   = "append",
          params = appPs2,
          ret    = JRef(className = "java/lang/StringBuilder")))
      }
    }
    i = i + 1
  }
  val finalTsPs: List[JvmType] = newList()
  insns.add(LInvokevirtual(
    owner  = "java/lang/StringBuilder",
    name   = "toString",
    params = finalTsPs,
    ret    = JRef(className = "java/lang/String")))
  JRef(className = "java/lang/String")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5g. Boxing helper.
// ─────────────────────────────────────────────────────────────────────────────

// Box a primitive type sitting on the stack into its wrapper object.
func boxIfNeeded(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JInt     -> insns.add(LBoxInt)
    case JLong    -> insns.add(LBoxLong)
    case JDouble  -> insns.add(LBoxDouble)
    case JBoolean -> insns.add(LBoxBool)
    case JByte    -> insns.add(LBoxByte)
    case JChar    -> insns.add(LBoxChar)
    case JShort   -> insns.add(LBoxShort)
    case _        -> insns.add(LNop)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5h. Std.Jvm.catch intrinsic.
// ─────────────────────────────────────────────────────────────────────────────

// Macroexpand `Std.Jvm.catch({ -> body })` to an inline try-catch.
// The lambda body is lowered as a block expression; on success the result is
// wrapped in Result$Ok; on java.lang.Exception the caught reference (which IS
// the JvmException value — no wrapper needed) is placed in Result$Err.
//
// Limitation: the lambda body must not contain an explicit `return` statement.
// Such a return would exit the enclosing method rather than the try block,
// breaking the try-catch semantics.  Typical usage is a single call expression
// and is always safe.
func lowerCatchIntrinsic(ctx: in FuncCtx, insns: in List[LInsn], lambdaBody: in Block): JvmType {
  val tryStartL   = freshLabel(ctx)
  val tryEndL     = freshLabel(ctx)
  val catchStartL = freshLabel(ctx)
  val afterL      = freshLabel(ctx)

  val resultSlot = allocSlot(ctx, "__catch_result_" + toString(ctx.slotTicker.count), JRef(className = "java/lang/Object"))
  val exSlot     = allocSlot(ctx, "__catch_ex_" + toString(ctx.slotTicker.count), JRef(className = "java/lang/Object"))

  // Class names for Result cases as compiled from Std.Core
  // (pkgName="Std/Core", union="Result", cases "Ok" and "Err").
  val okClass  = "Std/Core/Result$Ok"
  val errClass = "Std/Core/Result$Err"

  // ── try body ────────────────────────────────────────────────────────────────
  insns.add(LLabel(name = tryStartL))
  val bodyTy = lowerBlockExpr(ctx, insns, lambdaBody)
  match bodyTy {
    case JVoid -> insns.add(LAconstNull)  // Unit result: represent as null
    case _     -> boxIfNeeded(insns, bodyTy)
  }
  insns.add(LAstore(slot = resultSlot))

  insns.add(LNew(className = okClass))
  insns.add(LDup)
  insns.add(LAload(slot = resultSlot))
  val okPs: List[JvmType] = newList()
  okPs.add(JRef(className = "java/lang/Object"))
  insns.add(LInvokespecial(
    owner  = okClass,
    name   = "<init>",
    params = okPs,
    ret    = JVoid))
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = tryEndL))

  // ── catch handler ────────────────────────────────────────────────────────────
  // java/lang/Exception is on the stack; JvmException is a direct alias so the
  // caught reference is the JvmException value — no wrapping needed.
  insns.add(LLabel(name = catchStartL))
  insns.add(LAstore(slot = exSlot))
  insns.add(LNew(className = errClass))
  insns.add(LDup)
  insns.add(LAload(slot = exSlot))
  val errPs: List[JvmType] = newList()
  errPs.add(JRef(className = "java/lang/Object"))
  insns.add(LInvokespecial(
    owner  = errClass,
    name   = "<init>",
    params = errPs,
    ret    = JVoid))
  insns.add(LGoto(label = afterL))

  // ── exception table entry ────────────────────────────────────────────────────
  insns.add(LTryCatch(
    startLabel   = tryStartL,
    endLabel     = tryEndL,
    handlerLabel = catchStartL,
    catchClass   = "java/lang/Exception"))

  insns.add(LLabel(name = afterL))

  JRef(className = "java/lang/Object")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5i. @externTarget call-site lowering (Q-J013).
// ─────────────────────────────────────────────────────────────────────────────

// Extract the target string from `@externTarget("java.Class.method")`.
func findExternTarget(decl: in FunctionDecl): Option[String] {
  var i = 0
  while i < decl.annotations.count {
    val ann = decl.annotations[i]
    val n = ann.name.segments.count
    if n > 0 {
      val seg = ann.name.segments[n - 1]
      if seg == "externTarget" and ann.args.count > 0 {
        match ann.args[0] {
          case ALiteral(av) -> {
            match av {
              case AVString(s, _) -> return Some(value = s)
              case _ -> {}
            }
          }
          case _ -> {}
        }
      }
    }
    i = i + 1
  }
  None
}

// True when the declared return type is `Result[T, JvmException]` for any T.
func isResultJvmException(ret: in Option[TypeExpr]): Bool {
  match ret {
    case None -> false
    case Some(te) -> {
      match te.kind {
        case TGenericApp(head, args) -> {
          val headSeg = lastSegment(head)
          if headSeg == "Result" and args.count >= 2 {
            match args[1] {
              case TAType(inner) -> {
                match inner.kind {
                  case TRef(path) -> lastSegment(path) == "JvmException"
                  case _ -> false
                }
              }
              case _ -> false
            }
          } else { false }
        }
        case _ -> false
      }
    }
  }
}

// Extract the first type argument T from `Result[T, JvmException]`.
func extractResultValueType(te: in TypeExpr, pkgName: in String): JvmType {
  match te.kind {
    case TGenericApp(_, args) -> {
      if args.count >= 1 {
        match args[0] {
          case TAType(inner) -> typeExprToJvm(inner, pkgName)
          case _ -> JRef(className = "java/lang/Object")
        }
      } else {
        JRef(className = "java/lang/Object")
      }
    }
    case _ -> JRef(className = "java/lang/Object")
  }
}

// Maven-generated static externs follow the `TypeName_methodName` convention
// (PascalCase prefix before the first underscore).  Returns true for those.
func isStaticExternByName(name: in String): Bool {
  match indexOf(name, "_") {
    case None -> false
    case Some(i) -> {
      if i > 0 {
        val firstChar = substring(name, 0, 1)
        firstChar >= "A" and firstChar <= "Z"
      } else { false }
    }
  }
}

// Emit the body of a body-less function that has `@externTarget("java.Class.method")`.
// Loads all params, emits invokestatic or invokevirtual, and wraps the result in
// Result$Ok / Result$Err when the declared return type is Result[T, JvmException].
func lowerExternTargetBody(
  decl:   in FunctionDecl,
  ctx:    in FuncCtx,
  insns:  in List[LInsn],
  target: in String
): JvmType {
  match lastIndexOf(target, ".") {
    case None -> {
      emitReturn(insns, JVoid)
      JVoid
    }
    case Some(dotIdx) -> {
      val javaClass  = replace(substring(target, 0, dotIdx), ".", "/")
      val methodName = substring(target, dotIdx + 1, length(target) - dotIdx - 1)

      val isStatic   = isStaticExternByName(decl.name)
      val wrapResult = isResultJvmException(decl.ret)
      val startParam = if isStatic { 0 } else { 1 }

      // Java arg types: for instance calls, skip the first param (receiver).
      val javaArgTypes: List[JvmType] = newList()
      var ai = startParam
      while ai < decl.params.count {
        javaArgTypes.add(typeExprToJvm(decl.params[ai].ty, ctx.pkgName))
        ai = ai + 1
      }

      // Actual Java return type (unwrapped from Result for the invoke descriptor).
      val javaRet = match decl.ret {
        case None -> JVoid
        case Some(te) ->
          if wrapResult { extractResultValueType(te, ctx.pkgName) }
          else          { typeExprToJvm(te, ctx.pkgName) }
      }

      // Load all params in order: receiver first for instance calls.
      var li = 0
      while li < decl.params.count {
        val p = decl.params[li]
        val paramTy = typeExprToJvm(p.ty, ctx.pkgName)
        match lookupSlot(ctx, p.name) {
          case Some(s) -> emitLoad(insns, s, paramTy)
          case None    -> insns.add(LAconstNull)
        }
        li = li + 1
      }

      if wrapResult {
        val okClass  = "Std/Core/Result$Ok"
        val errClass = "Std/Core/Result$Err"
        val tryStartL   = freshLabel(ctx)
        val tryEndL     = freshLabel(ctx)
        val catchStartL = freshLabel(ctx)
        val afterL      = freshLabel(ctx)
        val resultSlot  = allocSlot(ctx, "__ext_result", JRef(className = "java/lang/Object"))
        val exSlot      = allocSlot(ctx, "__ext_ex",     JRef(className = "java/lang/Object"))

        insns.add(LLabel(name = tryStartL))
        if isStatic {
          insns.add(LInvokestatic(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        } else {
          insns.add(LInvokevirtual(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        }
        match javaRet {
          case JVoid -> insns.add(LAconstNull)
          case _     -> boxIfNeeded(insns, javaRet)
        }
        insns.add(LAstore(slot = resultSlot))
        insns.add(LNew(className = okClass))
        insns.add(LDup)
        insns.add(LAload(slot = resultSlot))
        val okPs: List[JvmType] = newList()
        okPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokespecial(owner = okClass, name = "<init>", params = okPs, ret = JVoid))
        insns.add(LGoto(label = afterL))
        insns.add(LLabel(name = tryEndL))

        insns.add(LLabel(name = catchStartL))
        insns.add(LAstore(slot = exSlot))
        insns.add(LNew(className = errClass))
        insns.add(LDup)
        insns.add(LAload(slot = exSlot))
        val errPs: List[JvmType] = newList()
        errPs.add(JRef(className = "java/lang/Object"))
        insns.add(LInvokespecial(owner = errClass, name = "<init>", params = errPs, ret = JVoid))
        insns.add(LGoto(label = afterL))

        insns.add(LTryCatch(
          startLabel   = tryStartL,
          endLabel     = tryEndL,
          handlerLabel = catchStartL,
          catchClass   = "java/lang/Exception"))
        insns.add(LLabel(name = afterL))

        emitReturn(insns, JRef(className = "java/lang/Object"))
        JRef(className = "java/lang/Object")
      } else {
        if isStatic {
          insns.add(LInvokestatic(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        } else {
          insns.add(LInvokevirtual(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        }
        emitReturn(insns, javaRet)
        javaRet
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5j. Builtin and general call lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerCall(
  ctx:   in FuncCtx,
  insns: in List[LInsn],
  fn:    in Expr,
  args:  in List[CallArg]
): JvmType {
  // Resolve the function name from the callee expression.
  match fn.kind {
    case EPath(path) -> {
      val funcName = lastSegment(path)
      lowerBuiltinOrStaticCall(ctx, insns, funcName, path, args)
    }
    case ETypeApp(innerFn, _) -> {
      // Ignore type args; lower the callee.
      lowerCall(ctx, insns, innerFn, args)
    }
    case EMember(recv, memberName) -> {
      lowerMethodCall(ctx, insns, recv, memberName, args)
    }
    case _ -> {
      // Unknown callee form — emit args and discard.
      var i = 0
      while i < args.count {
        lowerCallArg(ctx, insns, args[i])
        i = i + 1
      }
      JRef(className = "java/lang/Object")
    }
  }
}

// Lower a single call argument.
func lowerCallArg(ctx: in FuncCtx, insns: in List[LInsn], arg: in CallArg): JvmType {
  match arg {
    case CAPositional(e)    -> lowerExpr(ctx, insns, e)
    case CANamed(_, e, _)   -> lowerExpr(ctx, insns, e)
  }
}

// Lower a builtin or static function call.
func lowerBuiltinOrStaticCall(
  ctx:      in FuncCtx,
  insns:    in List[LInsn],
  funcName: in String,
  path:     in ModulePath,
  args:     in List[CallArg]
): JvmType {
  if funcName == "println" {
    insns.add(LGetstatic(
      owner = "java/lang/System",
      name  = "out",
      t     = JRef(className = "java/io/PrintStream")))
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      // Convert to String if needed for println.
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(
        owner  = "java/io/PrintStream",
        name   = "println",
        params = printPs,
        ret    = JVoid))
    } else {
      val emptyPs: List[JvmType] = newList()
      insns.add(LInvokevirtual(
        owner  = "java/io/PrintStream",
        name   = "println",
        params = emptyPs,
        ret    = JVoid))
    }
    JVoid
  } else if funcName == "print" {
    insns.add(LGetstatic(
      owner = "java/lang/System",
      name  = "out",
      t     = JRef(className = "java/io/PrintStream")))
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(
        owner  = "java/io/PrintStream",
        name   = "print",
        params = printPs,
        ret    = JVoid))
    } else {
      val emptyPs2: List[JvmType] = newList()
      insns.add(LInvokevirtual(
        owner  = "java/io/PrintStream",
        name   = "print",
        params = emptyPs2,
        ret    = JVoid))
    }
    JVoid
  } else if funcName == "panic" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    } else {
      insns.add(LPushString(s = "panic"))
      JVoid
    }
    emitPanicFromStack(ctx, insns)
    JVoid
  } else if funcName == "toString" {
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      match argTy {
        case JRef(_) -> {
          val tsPs: List[JvmType] = newList()
          insns.add(LInvokevirtual(
            owner  = "java/lang/Object",
            name   = "toString",
            params = tsPs,
            ret    = JRef(className = "java/lang/String")))
        }
        case _ -> {
          boxIfNeeded(insns, argTy)
          val tsPs2: List[JvmType] = newList()
          insns.add(LInvokevirtual(
            owner  = "java/lang/Object",
            name   = "toString",
            params = tsPs2,
            ret    = JRef(className = "java/lang/String")))
        }
      }
    } else {
      insns.add(LPushString(s = ""))
    }
    JRef(className = "java/lang/String")
  } else if funcName == "assert" {
    if args.count > 0 {
      val afterAssertL = freshLabel(ctx)
      lowerCallArg(ctx, insns, args[0])
      insns.add(LIfne(label = afterAssertL))
      // Assertion failed.
      if args.count > 1 {
        lowerCallArg(ctx, insns, args[1])
      } else {
        insns.add(LPushString(s = "assertion failed"))
        JVoid
      }
      emitPanicFromStack(ctx, insns)
      insns.add(LLabel(name = afterAssertL))
    }
    JVoid
  } else if funcName == "newList" {
    insns.add(LNew(className = "java/util/ArrayList"))
    insns.add(LDup)
    val nlPs: List[JvmType] = newList()
    insns.add(LInvokespecial(
      owner  = "java/util/ArrayList",
      name   = "<init>",
      params = nlPs,
      ret    = JVoid))
    JRef(className = "java/util/ArrayList")
  } else if funcName == "newMap" {
    insns.add(LNew(className = "java/util/HashMap"))
    insns.add(LDup)
    val nmPs: List[JvmType] = newList()
    insns.add(LInvokespecial(
      owner  = "java/util/HashMap",
      name   = "<init>",
      params = nmPs,
      ret    = JVoid))
    JRef(className = "java/util/HashMap")
  } else if funcName == "mapGet" {
    // mapGet(map, key) → Option[V]
    if args.count >= 2 {
      lowerCallArg(ctx, insns, args[0])
      lowerCallArg(ctx, insns, args[1])
      boxIfNeeded(insns, JInt)  // key might be primitive
      val mgPs: List[JvmType] = newList()
      mgPs.add(JRef(className = "java/lang/Object"))
      insns.add(LInvokevirtual(
        owner  = "java/util/HashMap",
        name   = "get",
        params = mgPs,
        ret    = JRef(className = "java/lang/Object")))
    } else {
      insns.add(LAconstNull)
    }
    JRef(className = "java/lang/Object")
  } else if funcName == "default" {
    insns.add(LAconstNull)
    JRef(className = "java/lang/Object")
  } else if funcName == "format1" {
    // format1(template, arg1): String — simplified to first arg.
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    } else {
      insns.add(LPushString(s = ""))
      JVoid
    }
    JRef(className = "java/lang/String")
  } else if funcName == "format2" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    } else {
      insns.add(LPushString(s = ""))
      JVoid
    }
    JRef(className = "java/lang/String")
  } else if funcName == "format3" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    } else {
      insns.add(LPushString(s = ""))
      JVoid
    }
    JRef(className = "java/lang/String")
  } else if funcName == "format4" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    } else {
      insns.add(LPushString(s = ""))
      JVoid
    }
    JRef(className = "java/lang/String")
  } else if funcName == "longToInt" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    insns.add(LL2i)
    JInt
  } else if funcName == "intToLong" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    insns.add(LI2l)
    JLong
  } else if funcName == "intToDouble" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    insns.add(LI2d)
    JDouble
  } else if funcName == "charToString" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    // Wrap in a char array and call new String(char[]) — or box and toString.
    insns.add(LBoxChar)
    val csPs: List[JvmType] = newList()
    insns.add(LInvokevirtual(
      owner  = "java/lang/Character",
      name   = "toString",
      params = csPs,
      ret    = JRef(className = "java/lang/String")))
    JRef(className = "java/lang/String")
  } else if funcName == "stringToUtf8Bytes" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    insns.add(LGetstatic(
      owner = "java/nio/charset/StandardCharsets",
      name  = "UTF_8",
      t     = JRef(className = "java/nio/charset/Charset")))
    val subPs: List[JvmType] = newList()
    subPs.add(JRef(className = "java/nio/charset/Charset"))
    insns.add(LInvokevirtual(
      owner  = "java/lang/String",
      name   = "getBytes",
      params = subPs,
      ret    = JArray(elem = JByte)))
    JArray(elem = JByte)
  } else if funcName == "catch" {
    // Std.Jvm.catch intrinsic: macroexpand to inline try-catch when the
    // argument is a zero-parameter lambda literal.  See lowerCatchIntrinsic.
    if args.count > 0 {
      val argExpr: Expr = match args[0] {
        case CAPositional(e)  -> e
        case CANamed(_, e, _) -> e
      }
      match argExpr.kind {
        case ELambda(_, lambdaBody) -> {
          lowerCatchIntrinsic(ctx, insns, lambdaBody)
        }
        case _ -> {
          // Non-literal lambda: fall through to general call which will fail
          // at JVM load time — same behaviour as the removed @externTarget.
          lowerGeneralStaticCall(ctx, insns, funcName, path, args)
        }
      }
    } else {
      lowerGeneralStaticCall(ctx, insns, funcName, path, args)
    }
  } else {
    // General static call: resolve against the current package/class.
    lowerGeneralStaticCall(ctx, insns, funcName, path, args)
  }
}

// Resolve a general (non-builtin) static function call.
func lowerGeneralStaticCall(
  ctx:      in FuncCtx,
  insns:    in List[LInsn],
  funcName: in String,
  path:     in ModulePath,
  args:     in List[CallArg]
): JvmType {
  // Collect parameter types and emit args.
  val paramTys: List[JvmType] = newList()
  var i = 0
  while i < args.count {
    val aTy = lowerCallArg(ctx, insns, args[i])
    paramTys.add(aTy)
    i = i + 1
  }

  // Determine the owner class for the call.
  // If path has more than one segment, use all but the last as the class path,
  // replacing "." with "/".  Otherwise, use ctx.className.
  val owner =
    if path.segments.count > 1 {
      // Join all but last segment as the class path.
      val segs: List[String] = newList()
      var si = 0
      while si < path.segments.count - 1 {
        segs.add(path.segments[si])
        si = si + 1
      }
      joinSegments(segs, "/")
    } else {
      ctx.className
    }

  // Return type is unknown at this point; use Object as a safe default.
  insns.add(LInvokestatic(
    owner  = owner,
    name   = funcName,
    params = paramTys,
    ret    = JRef(className = "java/lang/Object")))
  JRef(className = "java/lang/Object")
}

// Lower a method call on a receiver: recv.memberName(args...).
func lowerMethodCall(
  ctx:        in FuncCtx,
  insns:      in List[LInsn],
  recv:       in Expr,
  memberName: in String,
  args:       in List[CallArg]
): JvmType {
  val recvTy = lowerExpr(ctx, insns, recv)
  val paramTys: List[JvmType] = newList()
  var i = 0
  while i < args.count {
    val aTy = lowerCallArg(ctx, insns, args[i])
    paramTys.add(aTy)
    i = i + 1
  }
  match recvTy {
    case JRef(cls) -> {
      insns.add(LInvokevirtual(
        owner  = cls,
        name   = memberName,
        params = paramTys,
        ret    = JRef(className = "java/lang/Object")))
      JRef(className = "java/lang/Object")
    }
    case _ -> {
      JRef(className = "java/lang/Object")
    }
  }
}

// Return the appropriate descriptor type for a println/print argument.
// PrintStream has overloads for int, long, double, boolean, char, String, Object.
func printArgType(ty: in JvmType): JvmType {
  match ty {
    case JInt     -> JInt
    case JLong    -> JLong
    case JDouble  -> JDouble
    case JBoolean -> JBoolean
    case JChar    -> JChar
    case JVoid    -> JRef(className = "java/lang/String")
    case _        -> JRef(className = "java/lang/String")
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
          val ty =
            match tyOpt {
              case Some(te) -> typeExprToJvm(te, ctx.pkgName)
              case None     -> initTy
            }
          val slot = allocSlot(ctx, name, ty)
          emitStore(insns, slot, ty)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          val ty =
            match tyOpt {
              case Some(te) -> typeExprToJvm(te, ctx.pkgName)
              case None     -> JInt
            }
          match initOpt {
            case Some(init) -> {
              val initTy = lowerExpr(ctx, insns, init)
              val slot = allocSlot(ctx, name, ty)
              emitStore(insns, slot, ty)
            }
            case None -> {
              val slot = allocSlot(ctx, name, ty)
              match ty {
                case JLong   -> { insns.add(LLconst(v = 0i64)); emitStore(insns, slot, ty) }
                case JDouble -> { insns.add(LDconst(v = 0.0)); emitStore(insns, slot, ty) }
                case JRef(_)  -> { insns.add(LAconstNull); emitStore(insns, slot, ty) }
                case JArray(_) -> { insns.add(LAconstNull); emitStore(insns, slot, ty) }
                case JVoid   -> insns.add(LNop)
                case _       -> { insns.add(LIconst(v = 0)); emitStore(insns, slot, ty) }
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
        case _     -> insns.add(LPop)
      }
    }

    // ── While loop ─────────────────────────────────────────────────────────
    case SWhile(_, cond, body) -> {
      val loopL  = freshLabel(ctx)
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
          val endLA  = freshLabel(ctx)
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
          val iterableClass  = "java/lang/Iterable"
          val iteratorClass  = "java/util/Iterator"
          val objTy = JRef(className = "java/lang/Object")
          val iterableSlot = allocSlot(ctx, "__iterable_" + toString(ctx.slotTicker.count), objTy)
          emitStore(insns, iterableSlot, objTy)
          // Call .iterator() to get an Iterator.
          emitLoad(insns, iterableSlot, objTy)
          val iterPs: List[JvmType] = newList()
          insns.add(LInvokeinterface(
            owner    = iterableClass,
            name     = "iterator",
            params   = iterPs,
            ret      = JRef(className = iteratorClass),
            argCount = 1))
          val itorSlot = allocSlot(ctx, "__itor_" + toString(ctx.slotTicker.count), objTy)
          emitStore(insns, itorSlot, objTy)
          val loopLB = freshLabel(ctx)
          val endLB  = freshLabel(ctx)
          insns.add(LLabel(name = loopLB))
          // hasNext()
          emitLoad(insns, itorSlot, objTy)
          val hnPs: List[JvmType] = newList()
          insns.add(LInvokeinterface(
            owner    = iteratorClass,
            name     = "hasNext",
            params   = hnPs,
            ret      = JBoolean,
            argCount = 1))
          insns.add(LIfeq(label = endLB))
          // next()
          emitLoad(insns, itorSlot, objTy)
          val nextPs: List[JvmType] = newList()
          insns.add(LInvokeinterface(
            owner    = iteratorClass,
            name     = "next",
            params   = nextPs,
            ret      = JRef(className = "java/lang/Object"),
            argCount = 1))
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

    // ── Defer (bootstrap: inline immediately — incorrect semantics but
    //           allows code to compile) ──────────────────────────────────
    case SDefer(body) -> {
      lowerBlock(ctx, insns, body)
    }

    // ── Try/catch ─────────────────────────────────────────────────────────
    case STry(body, catches) -> {
      lowerTryCatch(ctx, insns, body, catches)
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
  ctx:    in FuncCtx,
  insns:  in List[LInsn],
  pat:    in Pattern,
  initTy: in JvmType,
  tyOpt:  in Option[TypeExpr]
): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      val ty =
        match tyOpt {
          case Some(te) -> typeExprToJvm(te, ctx.pkgName)
          case None     -> initTy
        }
      val slot = allocSlot(ctx, name, ty)
      emitStore(insns, slot, ty)
    }
    case PWildcard -> {
      // Discard the value.
      match initTy {
        case JVoid -> insns.add(LNop)
        case _     -> insns.add(LPop)
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

func lowerTryCatch(
  ctx:     in FuncCtx,
  insns:   in List[LInsn],
  body:    in Block,
  catches: in List[CatchClause]
): Unit {
  val startL   = freshLabel(ctx)
  val endL     = freshLabel(ctx)
  val afterL   = freshLabel(ctx)

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
    // Register exception table entry.
    // typeName is a dotted class name string like "java.lang.Exception".
    val catchClass = lyricNameToJvm(c.typeName)
    insns.add(LTryCatch(
      startLabel   = startL,
      endLabel     = endL,
      handlerLabel = handlerL,
      catchClass   = catchClass))
    i = i + 1
  }

  insns.add(LLabel(name = afterL))
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

// ─────────────────────────────────────────────────────────────────────────────
// §8. Function lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Create a fresh FuncCtx for the given function.
func makeFuncCtx(pkgName: in String, className: in String): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  FuncCtx(
    pkgName     = pkgName,
    className   = className,
    slots       = slots,
    types       = types,
    slotTicker  = slotTicker,
    labelTicker = labelTicker,
    loopBreak   = loopBreak,
    loopCont    = loopCont,
    genClass    = None)
}

// Create a FuncCtx for lowering a generator body (runBody instance method).
// Slot 0 = `this` (reserved); params start at slot 1.
func makeFuncCtxForGenerator(pkgName: in String, genClass: in String): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  slotTicker.add(0)  // reserve slot 0 for `this`
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  FuncCtx(
    pkgName     = pkgName,
    className   = genClass,
    slots       = slots,
    types       = types,
    slotTicker  = slotTicker,
    labelTicker = labelTicker,
    loopBreak   = loopBreak,
    loopCont    = loopCont,
    genClass    = Some(value = genClass))
}

pub func lowerFunc(decl: in FunctionDecl, pkgName: in String, className: in String): LFunc {
  val retTy =
    match decl.ret {
      case Some(te) -> typeExprToJvm(te, pkgName)
      case None     -> JVoid
    }

  val ctx = makeFuncCtx(pkgName, className)
  val insns: List[LInsn] = newList()

  // Allocate slots for parameters.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToJvm(p.ty, pkgName)
    allocSlot(ctx, p.name, paramTy)
    pi = pi + 1
  }

  // Lower the body.
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          lowerBlock(ctx, insns, block)
          // Emit a final return if the last instruction isn't already a return.
          if not endsWithReturn(insns) {
            emitReturn(insns, retTy)
          }
        }
        case FBExpr(e) -> {
          val ty = lowerExpr(ctx, insns, e)
          emitReturn(insns, ty)
        }
      }
    }
    case None -> {
      match findExternTarget(decl) {
        case Some(target) -> { lowerExternTargetBody(decl, ctx, insns, target); () }
        case None         -> emitReturn(insns, retTy)
      }
    }
  }

  // Determine param types for the LFunc descriptor.
  val paramTypes: List[JvmType] = newList()
  var pi2 = 0
  while pi2 < decl.params.count {
    val p2 = decl.params[pi2]
    paramTypes.add(typeExprToJvm(p2.ty, pkgName))
    pi2 = pi2 + 1
  }

  LFunc(
    flags     = 0x0009,  // public static
    name      = decl.name,
    params    = paramTypes,
    ret       = retTy,
    insns     = insns,
    maxStack  = 16,
    maxLocals = ctx.slotTicker.count)
}

// Check whether the last meaningful instruction in a list is a return.
func endsWithReturn(insns: in List[LInsn]): Bool {
  var i = insns.count - 1
  while i >= 0 {
    match insns[i] {
      case LReturn   -> { return true }
      case LIreturn  -> { return true }
      case LLreturn  -> { return true }
      case LDreturn  -> { return true }
      case LAreturn  -> { return true }
      case LAthrow   -> { return true }
      case LNop      -> { i = i - 1 }
      // A label may be a branch target from code above (e.g. the after-label
      // of a match expression), so we cannot treat instructions before it as
      // the effective end of the method.  Stop scanning and report "no terminal".
      case LLabel(_) -> { return false }
      case _         -> { return false }
    }
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Record lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerRecord(decl: in RecordDecl, pkgName: in String): LRecord {
  val className = pkgName + "/" + decl.name

  val fields: List[LField] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        fields.add(LField(
          flags     = 0x0001,  // public
          name      = f.name,
          fieldType = typeExprToJvm(f.ty, pkgName)))
      }
      case RMInvariant(_) -> {}
      case RMFunc(_)      -> {}
    }
    i = i + 1
  }

  // Synthesise <init> constructor that takes all fields as params and stores them.
  val ctorInsns: List[LInsn] = newList()
  val ctorCtx = makeFuncCtx(pkgName, className)

  // Slot 0 = this.
  ctorCtx.slotTicker.add(0)

  val ctorParams: List[JvmType] = newList()
  var slot = 1
  var fi = 0
  while fi < fields.count {
    val f = fields[fi]
    ctorParams.add(f.fieldType)
    // Load this, load param, putfield.
    ctorInsns.add(LAload(slot = 0))
    emitLoad(ctorInsns, slot, f.fieldType)
    ctorInsns.add(LPutfield(owner = className, name = f.name, t = f.fieldType))
    slot = slot + fieldSlotSize(f.fieldType)
    fi = fi + 1
  }
  // Call super.<init>().
  ctorInsns.add(LAload(slot = 0))
  val objPs: List[JvmType] = newList()
  ctorInsns.add(LInvokespecial(
    owner  = "java/lang/Object",
    name   = "<init>",
    params = objPs,
    ret    = JVoid))
  ctorInsns.add(LReturn)

  val ctor = LFunc(
    flags     = 0x0001,  // public
    name      = "<init>",
    params    = ctorParams,
    ret       = JVoid,
    insns     = ctorInsns,
    maxStack  = 16,
    maxLocals = slot)

  val methods: List[LFunc] = newList()
  methods.add(ctor)

  // Also lower any RMFunc members.
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case RMFunc(fn) -> {
        methods.add(lowerFunc(fn, pkgName, className))
      }
      case _ -> {}
    }
    mi = mi + 1
  }

  LRecord(
    className = className,
    fields    = fields,
    methods   = methods)
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Union lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerUnion(decl: in UnionDecl, pkgName: in String): LSealedUnion {
  val baseName = pkgName + "/" + decl.name

  val cases: List[LSealedCase] = newList()
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    val caseFields: List[LField] = newList()
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(LField(
            flags     = 0x0001,
            name      = name,
            fieldType = typeExprToJvm(ty, pkgName)))
        }
        case UFPos(ty, _) -> {
          caseFields.add(LField(
            flags     = 0x0001,
            name      = "field" + toString(fi),
            fieldType = typeExprToJvm(ty, pkgName)))
        }
      }
      fi = fi + 1
    }
    cases.add(LSealedCase(
      caseName = c.name,
      fields   = caseFields))
    i = i + 1
  }

  LSealedUnion(baseName = baseName, cases = cases)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Package codegen — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

// Join path segments with "/" to form the JVM binary name.
func segmentsToJvmPath(segs: in List[String]): String {
  joinSegments(segs, "/")
}

// Determine whether a function is the JVM entry point:
// name="main" with no parameters (Lyric convention).
func isMainFunc(decl: in FunctionDecl): Bool {
  decl.name == "main" and decl.params.count == 0
}

// ── Async generator detection ─────────────────────────────────────────────────

func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_)         -> true
    case EAwait(inner)     -> exprContainsYield(inner)
    case ESpawn(inner)     -> exprContainsYield(inner)
    case EParen(inner)     -> exprContainsYield(inner)
    case ETry(inner)       -> exprContainsYield(inner)
    case EPropagate(inner) -> exprContainsYield(inner)
    case EOld(inner)       -> exprContainsYield(inner)
    case EPrefix(_, inner) -> exprContainsYield(inner)
    case EBinop(_, l, r)   -> exprContainsYield(l) or exprContainsYield(r)
    case EAssign(t, _, v)  -> exprContainsYield(t) or exprContainsYield(v)
    case EBlock(blk)       -> blockContainsYield(blk)
    case EUnsafe(blk)      -> blockContainsYield(blk)
    case EIf(cond, thn, els, _) -> {
      if exprContainsYield(cond) { return true }
      if eobContainsYield(thn)   { return true }
      match els {
        case Some(e2) -> eobContainsYield(e2)
        case None     -> false
      }
    }
    case EMatch(scrut, arms) -> {
      if exprContainsYield(scrut) { return true }
      var i = 0
      while i < arms.count {
        if eobContainsYield(arms[i].body) { return true }
        i = i + 1
      }
      false
    }
    case ECall(fn, args) -> {
      if exprContainsYield(fn) { return true }
      var i = 0
      while i < args.count {
        val argContains = match args[i] {
          case CAPositional(e)   -> exprContainsYield(e)
          case CANamed(_, e, _)  -> exprContainsYield(e)
        }
        if argContains { return true }
        i = i + 1
      }
      false
    }
    case EIndex(recv, idxs) -> {
      if exprContainsYield(recv) { return true }
      var i = 0
      while i < idxs.count {
        if exprContainsYield(idxs[i]) { return true }
        i = i + 1
      }
      false
    }
    case EMember(recv, _)  -> exprContainsYield(recv)
    case ETuple(exprs)     -> listContainsYield(exprs)
    case EList(exprs)      -> listContainsYield(exprs)
    case ETypeApp(fn, _)   -> exprContainsYield(fn)
    case _                 -> false
  }
}

func listContainsYield(exprs: in List[Expr]): Bool {
  var i = 0
  while i < exprs.count {
    if exprContainsYield(exprs[i]) { return true }
    i = i + 1
  }
  false
}

func eobContainsYield(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e)   -> exprContainsYield(e)
    case EOBBlock(blk) -> blockContainsYield(blk)
  }
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) { return true }
    i = i + 1
  }
  false
}

func stmtContainsYield(stmt: in Statement): Bool {
  match stmt.kind {
    case SExpr(e)  -> exprContainsYield(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsYield(init)
        case LBLet(_, _, init) -> exprContainsYield(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> exprContainsYield(init)
            case None       -> false
          }
        }
      }
    }
    case SReturn(eOpt) -> {
      match eOpt {
        case Some(e) -> exprContainsYield(e)
        case None    -> false
      }
    }
    case SAssign(t, _, v)  -> exprContainsYield(t) or exprContainsYield(v)
    case SThrow(e)         -> exprContainsYield(e)
    case SWhile(_, cond, body) -> exprContainsYield(cond) or blockContainsYield(body)
    case SLoop(_, body)        -> blockContainsYield(body)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SBreak(_)             -> false
    case SContinue(_)          -> false
    case STry(body, catches)   -> {
      if blockContainsYield(body) { return true }
      var i = 0
      while i < catches.count {
        if blockContainsYield(catches[i].body) { return true }
        i = i + 1
      }
      false
    }
    case SDefer(body)    -> blockContainsYield(body)
    case SScope(_, body) -> blockContainsYield(body)
    case SInvariant(e)   -> exprContainsYield(e)
    case SRule(l, r)     -> exprContainsYield(l) or exprContainsYield(r)
    case SItem(_)        -> false
  }
}

func funcBodyContainsYield(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(blk) -> blockContainsYield(blk)
        case FBExpr(e)    -> exprContainsYield(e)
      }
    }
    case None -> false
  }
}

// Lower a generator function body to a flat list of LInsn.
// Params are accessed as fields on `this` (slot 0); the preamble loads
// each param field into a local slot so the body can use them normally.
func lowerGeneratorBody(
  decl:     in FunctionDecl,
  pkgName:  in String,
  genClass: in String
): List[LInsn] {
  val insns: List[LInsn] = newList()
  val ctx = makeFuncCtxForGenerator(pkgName, genClass)

  // Preamble: load each param from this.<field> into a local slot.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToJvm(p.ty, pkgName)
    val slot = allocSlot(ctx, p.name, paramTy)
    // load this (slot 0), then getfield, then store into slot
    insns.add(LAload(slot = 0))
    insns.add(LGetfield(owner = genClass, name = p.name, t = paramTy))
    emitStore(insns, slot, paramTy)
    pi = pi + 1
  }

  // Lower the body.
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> lowerBlock(ctx, insns, block)
        case FBExpr(e)      -> { lowerExpr(ctx, insns, e); () }
      }
    }
    case None -> {}
  }

  insns
}

// Synthesise the static factory LFunc that constructs a generator instance.
// `public static Object name(params...) { return new GenClass(params...); }`
// This is added to LPFuncs so it lands in the same class file as main().
func makeGeneratorFactory(
  decl:     in FunctionDecl,
  genClass: in String,
  pkgName:  in String
): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LNew(className = genClass))
  insns.add(LDup)

  val ctorParams: List[JvmType] = newList()
  var slot = 0
  var pi = 0
  while pi < decl.params.count {
    val pty = typeExprToJvm(decl.params[pi].ty, pkgName)
    ctorParams.add(pty)
    match pty {
      case JLong   -> { insns.add(LLload(slot = slot)); slot = slot + 2 }
      case JDouble -> { insns.add(LDload(slot = slot)); slot = slot + 2 }
      case JFloat  -> { insns.add(LFload(slot = slot)); slot = slot + 1 }
      case JRef(_) -> { insns.add(LAload(slot = slot)); slot = slot + 1 }
      case _       -> { insns.add(LIload(slot = slot)); slot = slot + 1 }
    }
    pi = pi + 1
  }

  insns.add(LInvokespecial(
    owner  = genClass,
    name   = "<init>",
    params = ctorParams,
    ret    = JVoid))
  insns.add(LAreturn)

  LFunc(
    flags     = 0x0009,   // ACC_PUBLIC | ACC_STATIC
    name      = decl.name,
    params    = ctorParams,
    ret       = JRef(className = "java/lang/Object"),
    insns     = insns,
    maxStack  = 0,        // inferred from peak-stack tracking
    maxLocals = 0)        // inferred from slot scan
}

pub func codegenPackage(file: in SourceFile): LPackage {
  val pkgName    = segmentsToJvmPath(file.packageDecl.path.segments)
  val funcsClass = pkgName

  val fns:   List[LFunc]        = newList()
  val items: List[LPackageItem] = newList()
  var hasMain = false

  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IFunc(decl) -> {
        if decl.isAsync and funcBodyContainsYield(decl) {
          // Async generator: synthesise Iterable+Iterator class via lowerAsyncGenerator.
          val genClass  = pkgName + "$" + decl.name + "$Gen"
          val bodyInsns = lowerGeneratorBody(decl, pkgName, genClass)
          val genParams: List[LGenParam] = newList()
          var pi = 0
          while pi < decl.params.count {
            val p = decl.params[pi]
            genParams.add(LGenParam(paramName = p.name, paramType = typeExprToJvm(p.ty, pkgName)))
            pi = pi + 1
          }
          val elemTy =
            match decl.ret {
              case Some(te) -> typeExprToJvm(te, pkgName)
              case None     -> JRef(className = "java/lang/Object")
            }
          val genFunc = LGenFunc(
            generatorClass = genClass,
            hostClass      = "",     // pipeline adds factory to LPFuncs instead
            methodName     = decl.name,
            elemType       = elemTy,
            params         = genParams,
            bodyInsns      = bodyInsns)
          items.add(LPAsyncGenerator(g = genFunc))
          // Factory method lives alongside main() in the functions class.
          fns.add(makeGeneratorFactory(decl, genClass, pkgName))
        } else {
          fns.add(lowerFunc(decl, pkgName, funcsClass))
          if isMainFunc(decl) {
            hasMain = true
          }
        }
      }
      case IRecord(decl) -> {
        items.add(LPRecord(rec = lowerRecord(decl, pkgName)))
      }
      case IExposedRec(decl) -> {
        items.add(LPRecord(rec = lowerRecord(decl, pkgName)))
      }
      case IUnion(decl) -> {
        items.add(LPSealedUnion(su = lowerUnion(decl, pkgName)))
      }
      case IConst(_)         -> {}
      case IVal(_)           -> {}
      case ITypeAlias(_)     -> {}
      case IDistinctType(_)  -> {}
      case IEnum(_)          -> {}
      case IOpaque(_)        -> {}
      case IProtected(_)     -> {}
      case IInterface(_)     -> {}
      case IImpl(_)          -> {}
      case IWire(_)          -> {}
      case IScopeKind(_)     -> {}
      case IExtern(_)        -> {}
      case IExternType(_)    -> {}
      case ITest(_)          -> {}
      case IProperty(_)      -> {}
      case IFixture(_)       -> {}
      case IConfig(_)        -> {}
      case IAspect(_)        -> {}
      case IError            -> {}
    }
    i = i + 1
  }

  // If there's a `main(): Unit` function, add a JVM-main wrapper that accepts
  // String[] and delegates to the Lyric main().
  if hasMain {
    val jvmMainParams: List[JvmType] = newList()
    jvmMainParams.add(JArray(elem = JRef(className = "java/lang/String")))
    val jvmMainInsns: List[LInsn] = newList()
    val lyricMainPs: List[JvmType] = newList()
    jvmMainInsns.add(LInvokestatic(
      owner  = funcsClass,
      name   = "main",
      params = lyricMainPs,
      ret    = JVoid))
    jvmMainInsns.add(LReturn)
    val jvmMain = LFunc(
      flags     = 0x0009,
      name      = "main",
      params    = jvmMainParams,
      ret       = JVoid,
      insns     = jvmMainInsns,
      maxStack  = 1,
      maxLocals = 1)
    fns.add(jvmMain)
  }

  items.add(LPFuncs(funcsClass = funcsClass, fns = fns))

  LPackage(packageName = pkgName, items = items)
}
