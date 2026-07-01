//! jvm/codegen/05_stmts.l — Jvm.Codegen: statement and block lowering.
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
          // Check if this is a hoisted var (by-ref capture in closures)
          match mapGet(ctx.hoistedCellSlot, name) {
            case Some(cellSlot) -> {
              // Assignment to hoisted var goes through cell[0]
              val cellElemTy = match mapGet(ctx.hoistedCellType, name) {
                case Some(t) -> t
                case None -> ty
              }
              val cellType = JArray(elem = cellElemTy)
              match op {
                case AssEq -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  lowerExpr(ctx, insns, value)
                  emitArrayStore(insns, cellElemTy)
                }
                case AssPlus -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  lowerExpr(ctx, insns, value)
                  match cellElemTy {
                    case JLong -> insns.add(LLadd)
                    case JDouble -> insns.add(LDadd)
                    case _ -> insns.add(LIadd)
                  }
                  val resultSlot = allocSlot(ctx, "__cell_result_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, resultSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, resultSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
                case AssMinus -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  lowerExpr(ctx, insns, value)
                  match cellElemTy {
                    case JLong -> insns.add(LLsub)
                    case JDouble -> insns.add(LDsub)
                    case _ -> insns.add(LIsub)
                  }
                  val resultSlot = allocSlot(ctx, "__cell_result_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, resultSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, resultSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
                case AssStar -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  lowerExpr(ctx, insns, value)
                  match cellElemTy {
                    case JLong -> insns.add(LLmul)
                    case JDouble -> insns.add(LDmul)
                    case _ -> insns.add(LImul)
                  }
                  val resultSlot = allocSlot(ctx, "__cell_result_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, resultSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, resultSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
                case AssSlash -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  lowerExpr(ctx, insns, value)
                  match cellElemTy {
                    case JLong -> insns.add(LLdiv)
                    case JDouble -> insns.add(LDdiv)
                    case JByte -> {
                      val rhsSlot = allocSlot(ctx, "__cell_rhs_" + freshLabel(ctx), JInt)
                      emitStore(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      emitLoad(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      insns.add(LIdiv)
                    }
                    case _ -> insns.add(LIdiv)
                  }
                  val resultSlot = allocSlot(ctx, "__cell_result_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, resultSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, resultSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
                case AssPercent -> {
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  lowerExpr(ctx, insns, value)
                  match cellElemTy {
                    case JLong -> insns.add(LLrem)
                    case JByte -> {
                      val rhsSlot = allocSlot(ctx, "__cell_rhs_" + freshLabel(ctx), JInt)
                      emitStore(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      emitLoad(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      insns.add(LIrem)
                    }
                    case _ -> insns.add(LIrem)
                  }
                  val resultSlot = allocSlot(ctx, "__cell_result_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, resultSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, resultSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
              }
              JVoid
            }
            case None -> {
              // Normal (non-hoisted) local var assignment
              match op {
                case AssEq -> {
                  lowerExpr(ctx, insns, value)
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
                case AssPlus -> {
                  emitLoad(insns, slot, ty)
                  lowerExpr(ctx, insns, value)
                  match ty {
                    case JLong -> insns.add(LLadd)
                    case JDouble -> insns.add(LDadd)
                    case _ -> insns.add(LIadd)
                  }
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
                case AssMinus -> {
                  emitLoad(insns, slot, ty)
                  lowerExpr(ctx, insns, value)
                  match ty {
                    case JLong -> insns.add(LLsub)
                    case JDouble -> insns.add(LDsub)
                    case _ -> insns.add(LIsub)
                  }
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
                case AssStar -> {
                  emitLoad(insns, slot, ty)
                  lowerExpr(ctx, insns, value)
                  match ty {
                    case JLong -> insns.add(LLmul)
                    case JDouble -> insns.add(LDmul)
                    case _ -> insns.add(LImul)
                  }
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
                case AssSlash -> {
                  emitLoad(insns, slot, ty)
                  lowerExpr(ctx, insns, value)
                  match ty {
                    case JLong -> insns.add(LLdiv)
                    case JDouble -> insns.add(LDdiv)
                    case JByte -> {
                      val rhsSlot = allocSlot(ctx, "__ass_rhs_" + freshLabel(ctx), JInt)
                      emitStore(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      emitLoad(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      insns.add(LIdiv)
                    }
                    case _ -> insns.add(LIdiv)
                  }
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
                case AssPercent -> {
                  emitLoad(insns, slot, ty)
                  lowerExpr(ctx, insns, value)
                  match ty {
                    case JLong -> insns.add(LLrem)
                    case JByte -> {
                      val rhsSlot = allocSlot(ctx, "__ass_rhs_" + freshLabel(ctx), JInt)
                      emitStore(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      emitLoad(insns, rhsSlot, JInt)
                      insns.add(LIconst(255))
                      insns.add(LIand)
                      insns.add(LIrem)
                    }
                    case _ -> insns.add(LIrem)
                  }
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                }
              }
              JVoid
            }
          }
        }
        case None -> {
          // Inside an instance method (protected-type entry / helper), a bare
          // name that is a field of the receiver is `this.<name>`: assign with
          // `aload_0; <rhs>; putfield` (compound ops read the field first).
          // Protected entries assign their fields by bare name (`tokens = …`),
          // so without this the store was silently dropped (J3 M-3).
          match selfFieldType(ctx, name) {
            case Some(fty) -> {
              val selfCls = match ctx.selfClass { case Some(c) -> c; case None -> "" }
              match op {
                case AssEq -> {
                  insns.add(LAload(slot = 0))
                  val vTy = lowerExpr(ctx, insns, value)
                  coerceArgTo(insns, vTy, fty)
                  insns.add(LPutfield(owner = selfCls, name = name, t = fty))
                }
                case _ -> {
                  insns.add(LAload(slot = 0))
                  insns.add(LDup)
                  insns.add(LGetfield(owner = selfCls, name = name, t = fty))
                  val vTy = lowerExpr(ctx, insns, value)
                  coerceArgTo(insns, vTy, fty)
                  emitCompoundArith(ctx, insns, op, fty)
                  insns.add(LPutfield(owner = selfCls, name = name, t = fty))
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
      }
    }
    case EMember(recv, fieldName) -> {
      // Record / opaque field assignment: `recv.field = e` → load receiver, eval
      // (and coerce) RHS, `putfield owner.field:desc`.  Compound ops
      // (`recv.field += e`) read the current field value, combine, and store.
      val recvTy = lowerExpr(ctx, insns, recv)
      match recvTy {
        case JRef(cls) -> {
          val fty = match recordFieldType(ctx, cls, fieldName) {
            case Some(t) -> t
            case None -> JRef(className = "java/lang/Object")
          }
          match op {
            case AssEq -> {
              val vTy = lowerExpr(ctx, insns, value)
              coerceArgTo(insns, vTy, fty)
              insns.add(LPutfield(owner = cls, name = fieldName, t = fty))
            }
            case _ -> {
              // Compound: stack has [recv]; dup it so one copy reads the field and
              // the other receives the putfield.  Sequence: dup; getfield; rhs;
              // <op>; putfield.
              insns.add(LDup)
              insns.add(LGetfield(owner = cls, name = fieldName, t = fty))
              val vTy = lowerExpr(ctx, insns, value)
              coerceArgTo(insns, vTy, fty)
              emitCompoundArith(ctx, insns, op, fty)
              insns.add(LPutfield(owner = cls, name = fieldName, t = fty))
            }
          }
          JVoid
        }
        case _ -> {
          // Receiver isn't a known reference type — nothing to store into.
          lowerExpr(ctx, insns, value)
          insns.add(LPop)
          JVoid
        }
      }
    }
    case EIndex(recv, indices) -> {
      // Slice / array / list element assignment: `arr[i] = e`.
      if indices.count == 0 {
        lowerExpr(ctx, insns, value)
        insns.add(LPop)
        return JVoid
      }
      val recvTy = lowerExpr(ctx, insns, recv)
      match recvTy {
        case JArray(elem) -> {
          match op {
            case AssEq -> {
              // [arr]; push index; (coerced) RHS; Xastore.
              lowerExpr(ctx, insns, indices[0])
              val vTy = lowerExpr(ctx, insns, value)
              coerceArgTo(insns, vTy, elem)
              emitArrayStore(insns, elem)
            }
            case _ -> {
              // Compound: spill arrayref + index to locals (no dup2 opcode), read
              // the current element, combine with the RHS, store back.
              val arrSlot = allocSlot(ctx, "__idxasn_arr_" + freshLabel(ctx), recvTy)
              emitStore(insns, arrSlot, recvTy)
              lowerExpr(ctx, insns, indices[0])
              val idxSlot = allocSlot(ctx, "__idxasn_i_" + freshLabel(ctx), JInt)
              emitStore(insns, idxSlot, JInt)
              emitLoad(insns, arrSlot, recvTy)
              emitLoad(insns, idxSlot, JInt)
              emitLoad(insns, arrSlot, recvTy)
              emitLoad(insns, idxSlot, JInt)
              emitArrayLoad(insns, elem)
              val vTy = lowerExpr(ctx, insns, value)
              coerceArgTo(insns, vTy, elem)
              emitCompoundArith(ctx, insns, op, elem)
              emitArrayStore(insns, elem)
            }
          }
          JVoid
        }
        case _ -> {
          // List-style element assignment via ArrayList.set(int, Object).  Values
          // are boxed to Object (the list-element representation).
          lowerExpr(ctx, insns, indices[0])
          val vTy = lowerExpr(ctx, insns, value)
          boxIfNeeded(insns, vTy)
          emitListSet(insns)
          JVoid
        }
      }
    }
    case _ -> {
      // Other assignment targets (deref, etc.) are not meaningful on the JVM.
      lowerExpr(ctx, insns, value)
      insns.add(LPop)
      JVoid
    }
  }
}

// Emit the element-store opcode for a JVM array of element type `elem`.  Stack:
// [arrayref, index, value] → [].
func emitArrayStore(insns: in List[LInsn], elem: in JvmType): Unit {
  match elem {
    case JByte -> insns.add(LBastore)
    case JBoolean -> insns.add(LBastore)
    case JChar -> insns.add(LCastore)
    case JShort -> insns.add(LSastore)
    case JInt -> insns.add(LIastore)
    case JLong -> insns.add(LLastore)
    case JFloat -> insns.add(LFastore)
    case JDouble -> insns.add(LDastore)
    case _ -> insns.add(LAastore)
  }
}

// Emit the newarray or anewarray opcode for an array of element type `elem`.
// Stack: [count] → [array].  For primitive arrays uses newarray; for reference
// arrays uses anewarray with the class name.
func emitNewarray(insns: in List[LInsn], elem: in JvmType): Unit {
  match elem {
    case JBoolean -> insns.add(LNewarray(typeCode = 4))  // T_BOOLEAN
    case JChar -> insns.add(LNewarray(typeCode = 5))     // T_CHAR
    case JFloat -> insns.add(LNewarray(typeCode = 6))    // T_FLOAT
    case JDouble -> insns.add(LNewarray(typeCode = 7))   // T_DOUBLE
    case JByte -> insns.add(LNewarray(typeCode = 8))     // T_BYTE
    case JShort -> insns.add(LNewarray(typeCode = 9))    // T_SHORT
    case JInt -> insns.add(LNewarray(typeCode = 10))     // T_INT
    case JLong -> insns.add(LNewarray(typeCode = 11))    // T_LONG
    case JRef(className) -> insns.add(LAnewarray(className = className))
    case JArray(_) -> panic("emitNewarray: multi-dimensional array allocation not supported")
    case JVoid -> panic("emitNewarray: cannot create array of void")
  }
}

// Emit the element-load opcode for a JVM array of element type `elem`.  Stack:
// [arrayref, index] → [value].  Used by compound index assignment.
func emitArrayLoad(insns: in List[LInsn], elem: in JvmType): Unit {
  match elem {
    case JByte -> insns.add(LBaload)
    case JBoolean -> insns.add(LBaload)
    case JChar -> insns.add(LCaload)
    case JShort -> insns.add(LSaload)
    case JInt -> insns.add(LIaload)
    case JLong -> insns.add(LLaload)
    case JFloat -> insns.add(LFaload)
    case JDouble -> insns.add(LDaload)
    case _ -> insns.add(LAaload)
  }
}

// Replace element at index in an ArrayList: stack [list, index, value] → [].
// `set(int, Object)` returns the previous element, which we discard.
func emitListSet(insns: in List[LInsn]): Unit {
  val setPs: List[JvmType] = newList()
  setPs.add(JInt)
  setPs.add(JRef(className = "java/lang/Object"))
  insns.add(
    LInvokevirtual(
      owner = "java/util/ArrayList",
      name = "set",
      params = setPs,
      ret = JRef(className = "java/lang/Object")
    )
  )
  insns.add(LPop)
}

// Combine the current target value (already on the stack) with the RHS using
// the compound-assignment operator, for primitive numeric target type `ty`.
func emitCompoundArith(ctx: in FuncCtx, insns: in List[LInsn], op: in AssignOp, ty: in JvmType): Unit {
  match op {
    case AssPlus -> match ty { case JLong -> insns.add(LLadd); case JFloat -> insns.add(LFadd); case JDouble -> insns.add(LDadd); case _ -> insns.add(LIadd) }
    case AssMinus -> match ty { case JLong -> insns.add(LLsub); case JFloat -> insns.add(LFsub); case JDouble -> insns.add(LDsub); case _ -> insns.add(LIsub) }
    case AssStar -> match ty { case JLong -> insns.add(LLmul); case JFloat -> insns.add(LFmul); case JDouble -> insns.add(LDmul); case _ -> insns.add(LImul) }
    case AssSlash -> match ty {
      case JLong -> insns.add(LLdiv)
      case JFloat -> insns.add(LFdiv)
      case JDouble -> insns.add(LDdiv)
      case JByte -> {
        val rhsSlot = allocSlot(ctx, "__comp_rhs_" + freshLabel(ctx), JInt)
        emitStore(insns, rhsSlot, JInt)
        insns.add(LIconst(255))
        insns.add(LIand)
        emitLoad(insns, rhsSlot, JInt)
        insns.add(LIconst(255))
        insns.add(LIand)
        insns.add(LIdiv)
      }
      case _ -> insns.add(LIdiv)
    }
    case AssPercent -> match ty {
      case JLong -> insns.add(LLrem)
      case JFloat -> insns.add(LFrem)
      case JDouble -> insns.add(LDrem)
      case JByte -> {
        val rhsSlot = allocSlot(ctx, "__comp_rhs_" + freshLabel(ctx), JInt)
        emitStore(insns, rhsSlot, JInt)
        insns.add(LIconst(255))
        insns.add(LIand)
        emitLoad(insns, rhsSlot, JInt)
        insns.add(LIconst(255))
        insns.add(LIand)
        insns.add(LIrem)
      }
      case _ -> insns.add(LIrem)
    }
    case AssEq -> ()
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
          coerceArgTo(insns, initTy, ty)
          val slot = allocSlot(ctx, name, ty)
          emitStore(insns, slot, ty)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          // Check if this var is hoisted (referenced inside a lambda).
          val isHoisted = nameInList(ctx.hoistedVarNames, name)
          match initOpt {
            case Some(init) -> {
              // An un-annotated `var x = e` takes its slot type from the
              // initialiser; an annotated `var x: T = e` coerces `e` to `T`.
              val initTy = lowerExpr(ctx, insns, init)
              val ty = match tyOpt { case Some(te) -> typeExprToJvm(te, ctx.pkgName); case None -> initTy }
              coerceArgTo(insns, initTy, ty)
              if isHoisted {
                // Allocate a heap cell (1-element typed array) for the var.
                // Stack on entry: [initValue (coerced)]
                // Strategy: save value to temp, create array, init element, store array to cell slot
                val cellType = JArray(elem = ty)
                val tempSlot = allocSlot(ctx, "__hoisted_tmp_" + freshLabel(ctx), ty)
                emitStore(insns, tempSlot, ty)
                // Create cell array
                insns.add(LIconst(v = 1))
                emitNewarray(insns, ty)
                val cellSlot = allocSlot(ctx, name, cellType)
                emitStore(insns, cellSlot, cellType)
                // Initialize cell[0] with the value
                emitLoad(insns, cellSlot, cellType)
                insns.add(LIconst(v = 0))
                emitLoad(insns, tempSlot, ty)
                emitArrayStore(insns, ty)
                ctx.hoistedCellSlot.add(name, cellSlot)
                ctx.hoistedCellType.add(name, ty)
              } else {
                // Normal by-value var: store to local slot
                val slot = allocSlot(ctx, name, ty)
                emitStore(insns, slot, ty)
              }
            }
            case None -> {
              // No initialiser: an annotation is required to know the slot type;
              // default to JInt only as a last resort (matches prior behaviour).
              val ty = match tyOpt { case Some(te) -> typeExprToJvm(te, ctx.pkgName); case None -> JInt }
              if isHoisted {
                // Create an empty cell for the hoisted var
                val cellType = JArray(elem = ty)
                insns.add(LIconst(v = 1))
                emitNewarray(insns, ty)
                val cellSlot = allocSlot(ctx, name, cellType)
                emitStore(insns, cellSlot, cellType)
                // Initialize the cell with a default value
                emitLoad(insns, cellSlot, cellType)
                insns.add(LIconst(v = 0))
                match ty {
                  case JLong -> {
                    insns.add(LLconst(v = 0i64))
                    emitArrayStore(insns, ty)
                  }
                  case JFloat -> {
                    insns.add(LFconst(v = 0.0))
                    emitArrayStore(insns, ty)
                  }
                  case JDouble -> {
                    insns.add(LDconst(v = 0.0))
                    emitArrayStore(insns, ty)
                  }
                  case JRef(_) -> {
                    insns.add(LAconstNull)
                    emitArrayStore(insns, ty)
                  }
                  case JArray(_) -> {
                    insns.add(LAconstNull)
                    emitArrayStore(insns, ty)
                  }
                  case JVoid -> insns.add(LNop)
                  case _ -> {
                    insns.add(LIconst(v = 0))
                    emitArrayStore(insns, ty)
                  }
                }
                ctx.hoistedCellSlot.add(name, cellSlot)
                ctx.hoistedCellType.add(name, ty)
              } else {
                // Normal by-value var
                val slot = allocSlot(ctx, name, ty)
                match ty {
                  case JLong -> {
                    insns.add(LLconst(v = 0i64))
                    emitStore(insns, slot, ty)
                  }
                  case JFloat -> {
                    insns.add(LFconst(v = 0.0))
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
    }

    // ── Return ─────────────────────────────────────────────────────────────
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          val ty = lowerExpr(ctx, insns, e)
          // Coerce to the declared return type so the value matches the method
          // descriptor (e.g. a plain Double literal in a `: Float` function
          // narrows with d2f).  Skip for void / generator contexts where the
          // declared return type isn't threaded.
          val rt = match ctx.retTy { case JVoid -> ty; case t -> { coerceArgTo(insns, ty, t); t } }
          // A `return` exits the function, so every still-pending `defer` block
          // (the whole stack) must run first.  Stash the already-coerced value
          // in a temp so the deferred blocks run on an empty operand stack, then
          // reload and return (#1833, mirrors MSIL #1477's epilogue routing).
          if ctx.deferStack.count > 0 {
            val rtmp = allocSlot(ctx, "__defer_ret_" + freshLabel(ctx), rt)
            emitStore(insns, rtmp, rt)
            replayDefers(ctx, insns, 0)
            emitLoad(insns, rtmp, rt)
          }
          emitReturn(insns, rt)
        }
        case None -> {
          replayDefers(ctx, insns, 0)
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
      ctx.loopDeferDepth.add(ctx.deferStack.count)
      lowerBlock(ctx, insns, body)
      ctx.loopDeferDepth.removeAt(ctx.loopDeferDepth.count - 1)
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
          val arrSlot = allocSlot(ctx, "__arr_" + freshLabel(ctx), iterTy)
          emitStore(insns, arrSlot, iterTy)
          val iSlot = allocSlot(ctx, "__for_i_" + freshLabel(ctx), JInt)
          insns.add(LIconst(v = 0))
          emitStore(insns, iSlot, JInt)
          val lenSlot = allocSlot(ctx, "__for_len_" + freshLabel(ctx), JInt)
          emitLoad(insns, arrSlot, iterTy)
          insns.add(LArraylength)
          emitStore(insns, lenSlot, JInt)
          val loopLA = freshLabel(ctx)
          val contLA = freshLabel(ctx)
          val endLA = freshLabel(ctx)
          insns.add(LLabel(name = loopLA))
          emitLoad(insns, iSlot, JInt)
          emitLoad(insns, lenSlot, JInt)
          insns.add(LIfIcmpge(label = endLA))
          emitLoad(insns, arrSlot, iterTy)
          emitLoad(insns, iSlot, JInt)
          emitArrayLoad(insns, elemArr)
          val elemSlotA = allocSlot(ctx, "__for_elem_" + freshLabel(ctx), elemArr)
          emitStore(insns, elemSlotA, elemArr)
          lowerPatternBind(ctx, insns, pat, elemSlotA, elemArr)
          // #2854: `continue` targets the index-increment point (`contLA`), not
          // the loop top, so the loop variable still advances; `break` targets
          // `endLA`.  `loopDeferDepth` captures the entry depth so a body `defer`
          // replays on both before the jump.
          ctx.loopBreak.add(endLA)
          ctx.loopCont.add(contLA)
          ctx.loopDeferDepth.add(ctx.deferStack.count)
          lowerBlock(ctx, insns, body)
          ctx.loopDeferDepth.removeAt(ctx.loopDeferDepth.count - 1)
          ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
          ctx.loopCont.removeAt(ctx.loopCont.count - 1)
          insns.add(LLabel(name = contLA))
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
          val iterableSlot = allocSlot(ctx, "__iterable_" + freshLabel(ctx), objTy)
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
          val itorSlot = allocSlot(ctx, "__itor_" + freshLabel(ctx), objTy)
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
          val elemSlotB = allocSlot(ctx, "__for_elem_" + freshLabel(ctx), elemTyB)
          emitStore(insns, elemSlotB, elemTyB)
          lowerPatternBind(ctx, insns, pat, elemSlotB, elemTyB)
          // #2854: `continue` targets the loop top (`loopLB`, which re-checks
          // hasNext()); `break` targets `endLB`.  `loopDeferDepth` captures the
          // entry depth so a body `defer` replays on both before the jump.
          ctx.loopBreak.add(endLB)
          ctx.loopCont.add(loopLB)
          ctx.loopDeferDepth.add(ctx.deferStack.count)
          lowerBlock(ctx, insns, body)
          ctx.loopDeferDepth.removeAt(ctx.loopDeferDepth.count - 1)
          ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
          ctx.loopCont.removeAt(ctx.loopCont.count - 1)
          insns.add(LGoto(label = loopLB))
          insns.add(LLabel(name = endLB))
        }
      }
    }

    // ── Loop (unconditional) ───────────────────────────────────────────────
    case SLoop(_, body) -> {
      val loopL3 = freshLabel(ctx)
      val afterL3 = freshLabel(ctx)
      insns.add(LLabel(name = loopL3))
      // #2854: register this loop's own break/continue targets (an unconditional
      // `loop` exits only via `break`/`return`) and the defer depth at entry, so
      // a `defer` declared in the body replays on `break`/`continue` and the jump
      // lands on *this* loop rather than an enclosing one.
      ctx.loopBreak.add(afterL3)
      ctx.loopCont.add(loopL3)
      ctx.loopDeferDepth.add(ctx.deferStack.count)
      lowerBlock(ctx, insns, body)
      ctx.loopDeferDepth.removeAt(ctx.loopDeferDepth.count - 1)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      insns.add(LGoto(label = loopL3))
      insns.add(LLabel(name = afterL3))
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
        // Replay any `defer` declared inside the loop body before exiting.
        if ctx.loopDeferDepth.count > 0 {
          replayDefers(ctx, insns, ctx.loopDeferDepth[ctx.loopDeferDepth.count - 1])
        }
        insns.add(LGoto(label = ctx.loopBreak[ctx.loopBreak.count - 1]))
      } else {
        insns.add(LNop)
      }
    }

    case SContinue(_) -> {
      if ctx.loopCont.count > 0 {
        // Replay any `defer` declared inside the loop body before continuing.
        if ctx.loopDeferDepth.count > 0 {
          replayDefers(ctx, insns, ctx.loopDeferDepth[ctx.loopDeferDepth.count - 1])
        }
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
    // `defer { D }` runs D on every scope exit (fall-off, return, break/continue,
    // exception unwind).  Lowered by `lowerBlockStmtsFrom`, which wraps the
    // statements after the defer in a protected region whose catch-all runs the
    // deferred block then rethrows, replays it inline on the normal fall-off,
    // and pushes it onto `ctx.deferStack` so early transfers replay it (#1833,
    // mirrors MSIL #1477).  Every block routes through `lowerBlockStmtsFrom`, so
    // a bare `SDefer` never reaches `lowerStmt`.
    case SDefer(_) -> {
      panic(
        "Jvm.Codegen: SDefer reached lowerStmt directly — defers must be lowered through lowerBlockStmtsFrom (unreachable)"
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
      coerceArgTo(insns, initTy, ty)
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
      val tmpSlot = allocSlot(ctx, "__tmp_" + freshLabel(ctx), initTy)
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
        match catchBodyTy {
          case JVoid -> {
            // The catch body produced nothing (statement mode) but the try
            // body produced a value — emitting a store here would pop a
            // value that isn't on the stack and produce a VerifyError.
            // Abort codegen with a source-located diagnostic so the user
            // sees a pointed compile error rather than an untyped crash
            // with no line number (#3193, supersedes the bare panic from
            // #2690).  The Jvm.Bridge `Bug` catch re-emits this message
            // under `error[J002]`; the `error[J004]` code and `line:col`
            // prefix below name the offending catch arm precisely.  Code
            // is threaded through the panic message because the codegen
            // tree returns `JvmType`, not a diagnostic-collecting Result.
            val pos = c.span.startPos
            panic(
              "error[J004]: " + pos.line.toString() + ":" + pos.column.toString() +
                ": try-catch used as an expression, but this catch arm yields Unit while the " +
                "try body yields a value; the JVM backend cannot route an absent value through " +
                "the result slot. Give the catch arm a trailing value of the try body's type, or " +
                "annotate the try-catch result type explicitly (type-checker gap #2042)."
            )
          }
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
      val tmpName = "__finally_ex_" + freshLabel(ctx)
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
  lowerBlockStmtsFrom(ctx, insns, block.statements, 0)
}

// True when the last meaningful instruction unconditionally transfers control
// (return / throw / goto), so the fall-through point is unreachable.  Used to
// suppress the normal-path `defer` replay (and its StackMapTable frames) after
// an early `return` / `break` / `continue` already replayed and transferred.
func lastInsnIsTerminator(insns: in List[LInsn]): Bool {
  var i = insns.count - 1
  while i >= 0 {
    match insns[i] {
      case LReturn -> {
        return true
      }
      case LIreturn -> {
        return true
      }
      case LLreturn -> {
        return true
      }
      case LFreturn -> {
        return true
      }
      case LDreturn -> {
        return true
      }
      case LAreturn -> {
        return true
      }
      case LAthrow -> {
        return true
      }
      case LGoto(_) -> {
        return true
      }
      case LNop -> {
        i = i - 1
      }
      // `LTryCatch` is a zero-width meta-instruction (an exception-table entry);
      // it carries no control flow, so skip past it to the real tail.
      case LTryCatch(_, _, _, _) -> {
        i = i - 1
      }
      case LLabel(_) -> {
        return false
      }
      case _ -> {
        return false
      }
    }
  }
  false
}

// Replay the `defer` blocks pending at indices [downTo, deferStack.count) in
// reverse (innermost-defined runs first), WITHOUT popping them.  Control is
// transferring away (return / break / continue), so the stack entries stay in
// place for any enclosing block's own fall-off / exception handling.
// Before emitting each inline replay body, stores 1 to the parallel
// `deferRanSlots[i]` flag so the catch-all handler for that region (which
// covers the replay site) can detect the early-transfer case and skip
// re-running the block — preventing double execution (#2855).
func replayDefers(ctx: in FuncCtx, insns: in List[LInsn], downTo: in Int): Unit {
  var i = ctx.deferStack.count - 1
  while i >= downTo {
    if i < ctx.deferRanSlots.count {
      val ranSlot = ctx.deferRanSlots[i]
      insns.add(LIconst(v = 1))
      insns.add(LIstore(slot = ranSlot))
    }
    lowerBlock(ctx, insns, ctx.deferStack[i])
    i = i - 1
  }
}

// Lower `stmts[start..]`, honouring any `defer { … }` in that range.  The first
// `defer` splits the suffix: statements after it run inside a protected region
// whose catch-all handler runs the deferred block then rethrows (exception
// path), and whose normal fall-off re-runs the deferred block once (fall-off
// path).  Early `return` / `break` / `continue` inside the region replay the
// pending defers before transferring (see `replayDefers`).  Mirrors MSIL #1477.
func lowerBlockStmtsFrom(ctx: in FuncCtx, insns: in List[LInsn], stmts: in List[Statement], start: in Int): Unit {
  val n = stmts.count
  // Locate the first `defer` at or after `start`.
  var deferIdx = -1
  var di = start
  while di < n {
    if deferIdx < 0 {
      match stmts[di].kind {
        case SDefer(_) -> {
          deferIdx = di
        }
        case _ -> ()
      }
    }
    di = di + 1
  }
  if start >= n {
    ()
  } else if deferIdx < 0 {
    var i = start
    while i < n {
      lowerStmt(ctx, insns, stmts[i])
      i = i + 1
    }
  } else {
    lowerDeferRegion(ctx, insns, stmts, start, deferIdx)
  }
}

// Lower the statements before `deferIdx` normally, then the suffix after it
// inside the protected region described in `lowerBlockStmtsFrom`.
func lowerDeferRegion(
  ctx: in FuncCtx, insns: in List[LInsn], stmts: in List[Statement], start: in Int, deferIdx: in Int
): Unit {
  // Statements before the defer run normally.
  var k = start
  while k < deferIdx {
    lowerStmt(ctx, insns, stmts[k])
    k = k + 1
  }
  val deferBody = match stmts[deferIdx].kind {
    case SDefer(b) -> b
    case _ -> panic("Jvm.Codegen: lowerDeferRegion: deferIdx does not point at an SDefer (unreachable)")
  }
  val startL = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  val normalReplayL = freshLabel(ctx)
  val handlerL = freshLabel(ctx)
  // Allocate the "already-replayed" flag (#2855): a JVM int local initialised
  // to 0 here, set to 1 by `replayDefers` before each inline early-transfer
  // replay.  The catch-all handler below checks this flag and skips the defer
  // body when it is 1, so a throw from the inline replay does not re-run the
  // block a second time.
  val ranSlot = allocSlot(ctx, "__defer_ran_" + freshLabel(ctx), JInt)
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = ranSlot))
  insns.add(LLabel(name = startL))
  // Make the deferred block visible to `return` / `break` / `continue` inside
  // the protected region so they replay it before transferring control.
  ctx.deferStack.add(deferBody)
  ctx.deferRanSlots.add(ranSlot)
  val savedDepth = ctx.deferStack.count - 1
  lowerBlockStmtsFrom(ctx, insns, stmts, deferIdx + 1)
  // Drop this defer from the pending set before the normal-path replay (the
  // inline copy below covers fall-off; replays past here must not re-run it).
  ctx.deferStack.removeAt(savedDepth)
  ctx.deferRanSlots.removeAt(savedDepth)
  // Snapshot whether the suffix already transferred control BEFORE emitting the
  // normalReplayL label (a label resets `lastInsnIsTerminator`, so the check
  // must run against the suffix's true tail).
  val suffixTerminated = lastInsnIsTerminator(insns)
  // Close the protected region BEFORE the inline normal-path replay so a throw
  // from the deferred block during replay is NOT caught by the catch-all (which
  // would re-run the block — double execution, diverging from try/finally).
  insns.add(LLabel(name = normalReplayL))
  // Normal fall-off: run the deferred block once and jump over the handler.
  // When an early transfer already terminated the region, the fall-off is
  // unreachable — skip both the inline replay and the jump so no dead code (and
  // no stray StackMapTable frame) lands before the handler.
  if not suffixTerminated {
    lowerBlock(ctx, insns, deferBody)
    insns.add(LGoto(label = afterL))
  }
  // Exception path: catch any throwable.  Skip the deferred block when the
  // "already-replayed" flag is set (meaning an early-transfer replay threw and
  // unwound here), then rethrow so the block never runs twice (#2855).
  insns.add(LLabel(name = handlerL))
  val exTy = JRef(className = "java/lang/Throwable")
  val tmpName = "__defer_ex_" + freshLabel(ctx)
  val tmpSlot = allocSlot(ctx, tmpName, exTy)
  // Store via `LAstoreAs` so the slot's StackMapTable type is `Throwable`, not
  // the bare `Object` a plain `astore` registers — otherwise the rethrow's
  // `athrow` fails verification when the deferred block itself does not diverge.
  insns.add(LAstoreAs(slot = tmpSlot, className = "java/lang/Throwable"))
  val skipDeferL = freshLabel(ctx)
  insns.add(LIload(slot = ranSlot))
  insns.add(LIfne(label = skipDeferL))
  lowerBlock(ctx, insns, deferBody)
  insns.add(LLabel(name = skipDeferL))
  emitLoad(insns, tmpSlot, exTy)
  insns.add(LAthrow)
  // Catch-all entry covers [startL, normalReplayL) (the region body + suffix
  // only); endLabel = normalReplayL excludes the inline normal-path replay so a
  // throw during replay rethrows directly rather than re-running the block.
  insns.add(LTryCatch(startLabel = startL, endLabel = normalReplayL, handlerLabel = handlerL, catchClass = ""))
  insns.add(LLabel(name = afterL))
}

// True when `block` declares a `defer` directly among its statements.
pub func blockHasDefer(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    match block.statements[i].kind {
      case SDefer(_) -> {
        return true
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// Value-producing counterpart of `lowerBlockStmtsFrom`: lower
// `block.statements[start..]` leaving the trailing value on the stack while
// honouring a `defer`.  Statements after the first defer run inside a protected
// region; on normal completion the trailing value is stashed in a temp, the
// deferred block runs, and the value is reloaded (so the block still yields it).
// Early `return` / `break` / `continue` replay the pending defers via
// `replayDefers`; an exception runs the deferred block via the catch-all and
// rethrows.  Mirrors MSIL `lowerStmtsExprFromMsil` (#1833 / #1477).
pub func lowerBlockExprWithDefer(ctx: in FuncCtx, insns: in List[LInsn], block: in Block, start: in Int): JvmType {
  val stmts = block.statements
  val n = stmts.count
  // Locate the first defer at/after `start`.
  var deferIdx = -1
  var di = start
  while di < n {
    if deferIdx < 0 {
      match stmts[di].kind {
        case SDefer(_) -> {
          deferIdx = di
        }
        case _ -> ()
      }
    }
    di = di + 1
  }
  if deferIdx < 0 {
    // No defer left: plain trailing-value lowering of stmts[start..].
    return lowerStmtsTrailingValue(ctx, insns, stmts, start)
  }
  // Statements before the defer run normally.
  var k = start
  while k < deferIdx {
    lowerStmt(ctx, insns, stmts[k])
    k = k + 1
  }
  val deferBody = match stmts[deferIdx].kind {
    case SDefer(b) -> b
    case _ -> panic("Jvm.Codegen: lowerBlockExprWithDefer: deferIdx does not point at an SDefer (unreachable)")
  }
  val startL = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  val normalReplayL = freshLabel(ctx)
  val handlerL = freshLabel(ctx)
  // Allocate the "already-replayed" flag (#2855): see `lowerDeferRegion` for
  // the full rationale.  `replayDefers` sets this to 1 before any inline early-
  // transfer replay; the catch-all handler skips the body when the flag is set.
  val ranSlot = allocSlot(ctx, "__defer_ran_" + freshLabel(ctx), JInt)
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = ranSlot))
  insns.add(LLabel(name = startL))
  ctx.deferStack.add(deferBody)
  ctx.deferRanSlots.add(ranSlot)
  val savedDepth = ctx.deferStack.count - 1
  // Recurse for the value-producing suffix (may contain further defers).
  val valTy = lowerBlockExprWithDefer(ctx, insns, block, deferIdx + 1)
  ctx.deferStack.removeAt(savedDepth)
  ctx.deferRanSlots.removeAt(savedDepth)
  // Snapshot whether the suffix already transferred control BEFORE emitting the
  // normalReplayL label (a label resets `lastInsnIsTerminator`, so the check
  // must run against the suffix's true tail).
  val suffixTerminated = lastInsnIsTerminator(insns)
  // Close the protected region BEFORE the inline normal-path replay so a throw
  // from the deferred block during replay is NOT caught by the catch-all (which
  // would re-run the block — double execution, diverging from try/finally).
  insns.add(LLabel(name = normalReplayL))
  // Normal completion path: when the suffix did not unconditionally transfer
  // control (an early `return` / `break` / `continue` already replayed the
  // deferred block via `replayDefers`), stash the trailing value, run the
  // deferred block, reload, and jump over the handler.  When the suffix DID
  // terminate, the fall-off is unreachable — emit nothing here so no dead code
  // / stray frame lands before the handler.
  if not suffixTerminated {
    var valSlot = -1
    match valTy {
      case JVoid -> ()
      case _ -> {
        valSlot = allocSlot(ctx, "__defer_val_" + freshLabel(ctx), valTy)
        emitStore(insns, valSlot, valTy)
      }
    }
    lowerBlock(ctx, insns, deferBody)
    match valTy {
      case JVoid -> ()
      case _ -> emitLoad(insns, valSlot, valTy)
    }
    insns.add(LGoto(label = afterL))
  }
  // Exception path: skip the defer body when already replayed by an early
  // transfer, then rethrow (#2855).
  insns.add(LLabel(name = handlerL))
  val exTy = JRef(className = "java/lang/Throwable")
  val tmpSlot = allocSlot(ctx, "__defer_ex_" + toString(ctx.labelTicker.count), exTy)
  // Store via `LAstoreAs` so the slot's StackMapTable type is `Throwable`, not
  // the bare `Object` a plain `astore` registers — otherwise the rethrow's
  // `athrow` fails verification when the deferred block itself does not diverge.
  insns.add(LAstoreAs(slot = tmpSlot, className = "java/lang/Throwable"))
  val skipDeferExprL = freshLabel(ctx)
  insns.add(LIload(slot = ranSlot))
  insns.add(LIfne(label = skipDeferExprL))
  lowerBlock(ctx, insns, deferBody)
  insns.add(LLabel(name = skipDeferExprL))
  emitLoad(insns, tmpSlot, exTy)
  insns.add(LAthrow)
  // Catch-all covers [startL, normalReplayL) (region body + suffix only);
  // endLabel = normalReplayL excludes the inline normal-path replay so a throw
  // during replay rethrows directly rather than re-running the block.
  insns.add(LTryCatch(startLabel = startL, endLabel = normalReplayL, handlerLabel = handlerL, catchClass = ""))
  // Only land the join label when the normal path actually reaches it; when the
  // suffix terminated (e.g. trailing `return`), nothing branches to `afterL`,
  // so emitting it would leave a non-terminator tail and make the caller append
  // a spurious (wrong-typed) return after the region.
  if not suffixTerminated {
    insns.add(LLabel(name = afterL))
  }
  valTy
}

// Lower `stmts[start..]` leaving the trailing value on the stack (no defer in
// range).  The last statement's value becomes the block value; non-tail
// statements are lowered in statement position.
func lowerStmtsTrailingValue(ctx: in FuncCtx, insns: in List[LInsn], stmts: in List[Statement], start: in Int): JvmType {
  val n = stmts.count
  if start >= n {
    return JVoid
  }
  var i = start
  while i < n - 1 {
    lowerStmt(ctx, insns, stmts[i])
    i = i + 1
  }
  val last = stmts[n - 1]
  match last.kind {
    case SExpr(e) -> lowerExpr(ctx, insns, e)
    case STry(body, catches, finally_) -> {
      match finally_ {
        case None -> lowerTryCatchExpr(ctx, insns, body, catches)
        case Some(_) -> {
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
