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
// True when `e` is a bare `default()` call.  A generic `default()` lowers to
// `aconst_null` (the erased model); binding it to a PRIMITIVE-annotated local
// must not go through the null (checkcast+unbox NPEs at runtime — hit by
// `var v: Long = default()` in Std.Json.tryGetLong) — the declared type's
// zero value is pushed instead.
func isDefaultCall(e: in Expr): Bool {
  match e.kind {
    case ECall(fn, args) -> {
      if args.count == 0 {
        match fn.kind {
          case EPath(p) -> lastSegment(p) == "default"
          case _ -> false
        }
      } else {
        false
      }
    }
    case _ -> false
  }
}

// Push the zero value of primitive `ty`; returns false for non-primitives
// (caller lowers the expression normally).
func pushPrimitiveZero(insns: in List[LInsn], ty: in JvmType): Bool {
  match ty {
    case JLong -> {
      insns.add(LLconst(v = 0i64))
      true
    }
    case JDouble -> {
      insns.add(LDconst(v = 0.0))
      true
    }
    case JFloat -> {
      insns.add(LFconst(v = 0.0))
      true
    }
    case JInt -> {
      insns.add(LIconst(v = 0))
      true
    }
    case JBoolean -> {
      insns.add(LIconst(v = 0))
      true
    }
    case JByte -> {
      insns.add(LIconst(v = 0))
      true
    }
    case JShort -> {
      insns.add(LIconst(v = 0))
      true
    }
    case JChar -> {
      insns.add(LIconst(v = 0))
      true
    }
    case _ -> false
  }
}

// Push the JVM zero/default value for `ty`, covering every `JvmType` variant
// (unlike `pushPrimitiveZero` above, which only covers primitives and signals
// failure for the rest via its `Bool` result): a reference or array type
// pushes `aconst_null`.  Used by `emitNeverTailReturn` below.
func pushDefaultValueJvm(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JLong -> insns.add(LLconst(v = 0i64))
    case JDouble -> insns.add(LDconst(v = 0.0))
    case JFloat -> insns.add(LFconst(v = 0.0))
    case JBoolean -> insns.add(LIconst(v = 0))
    case JByte -> insns.add(LIconst(v = 0))
    case JShort -> insns.add(LIconst(v = 0))
    case JChar -> insns.add(LIconst(v = 0))
    case JInt -> insns.add(LIconst(v = 0))
    case JRef(_) -> insns.add(LAconstNull)
    case JArray(_) -> insns.add(LAconstNull)
    case JVoid -> ()
  }
}

// A block's tail expression can lower to the erased `JVoid` — `Never` erases
// to `JVoid` exactly like `Unit` (`Jvm.Codegen.typeExprToJvm`) — even though
// the ENCLOSING function's declared return type is non-void.  Type-checking
// only accepts a `Unit`-shaped tail value inside a differently-typed function
// when the tail expression's REAL type is `Never`: a genuine `Unit` value
// never unifies with a non-Unit declared return type, but `Never` unifies
// with anything.  So reaching this helper (from `lowerFunc` /
// `lowerInstanceMethodBody` in `06_items.l`) is proof the tail expression
// diverges — e.g. a bare tail-position call to a user-defined (or
// `@externTarget`-bound) function declared `: Never`, which erases to a
// `JVoid`-returning call and leaves nothing on the operand stack.
//
// Emitting a bare `return` there does not match the method's descriptor and
// fails class-load verification ("Method expects a return value", #5378).
// Push `retTy`'s zero/default value and return it instead: this is dead code
// whenever the `Never` contract holds, and mirrors how `panic(...)` in the
// same tail position already terminates cleanly via a real `athrow` — a
// `panic(...)` tail never reaches this helper because `endsWithReturn`
// recognizes its `athrow` as a terminator before the caller gets here.
pub func emitNeverTailReturn(insns: in List[LInsn], retTy: in JvmType): Unit {
  pushDefaultValueJvm(insns, retTy)
  emitReturn(insns, retTy)
}

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
              val cellElemTy = match mapGet(ctx.hoistedCellType, name) { case Some(t) -> t; case None -> ty }
              val cellType = JArray(elem = cellElemTy)
              match op {
                case AssEq -> {
                  // Evaluate and coerce the RHS BEFORE pushing the cell array
                  // and index: the ctx-aware coercion's primitive-array boxing
                  // loop (`[B` assigned into a hoisted `slice[Byte]` var,
                  // #5609 item 2) requires an empty operand stack under the
                  // value, and the cell/index loads are pure so the reorder
                  // is unobservable.  The coercion itself is the same as call
                  // arguments / local bindings: the value's static type may
                  // not match the cell's element type (an erased-Object match
                  // payload assigned into a primitive-typed var, and vice
                  // versa).
                  val cvTy = lowerExpr(ctx, insns, value)
                  coerceValueTo(ctx, insns, cvTy, cellElemTy)
                  val hvSlot = allocSlot(ctx, "__cellv_" + freshLabel(ctx), cellElemTy)
                  emitStore(insns, hvSlot, cellElemTy)
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitLoad(insns, hvSlot, cellElemTy)
                  emitArrayStore(insns, cellElemTy)
                }
                case _ -> {
                  // Compound assignment through the hoisted cell: read cell[0],
                  // combine via the shared `emitCompoundCombineJvm` (Float/String
                  // opcode selection, erased-RHS coercion), stash the result, and
                  // write it back to cell[0].
                  emitLoad(insns, cellSlot, cellType)
                  insns.add(LIconst(v = 0))
                  emitArrayLoad(insns, cellElemTy)
                  val cvTy = lowerExpr(ctx, insns, value)
                  emitCompoundCombineJvm(ctx, insns, op, cellElemTy, cvTy)
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
                  val vTy = lowerExpr(ctx, insns, value)
                  // The value's static type may not match the slot's declared
                  // type: an erased-Object match payload (`case Some(n) ->
                  // contentLength = n` on Option[Long]) assigned into a
                  // primitive-typed var left an Object on the stack for an
                  // lstore — VerifyError (lyric-storage's listEntryForKey).
                  // Same coercion discipline as call arguments; the ctx-aware
                  // form also boxes a primitive array assigned into a
                  // `slice[T]`-typed var (#5572).
                  coerceValueTo(ctx, insns, vTy, ty)
                  emitStoreLocalWriteThrough(ctx, insns, slot, ty)
                  // Re-binding a `var handle = spawn f()` handle to a new spawn
                  // (`handle = spawn g()`) must refresh the slot's spawn-result
                  // type so a later `await handle` unboxes to g's return type, not
                  // f's stale entry (#5205).  Mirrors the `SLocal` wiring; a no-op
                  // for a non-spawn RHS or a spawn outside any `scope { }`.
                  recordSpawnResultType(ctx, name, value)
                }
                case _ -> {
                  // Compound assignment: read-combine-store through the shared
                  // `emitCompoundCombineJvm` (Float/String opcode selection,
                  // erased-RHS coercion — see the helper's doc).
                  emitLoad(insns, slot, ty)
                  val cvTy = lowerExpr(ctx, insns, value)
                  emitCompoundCombineJvm(ctx, insns, op, ty, cvTy)
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
              // The RHS is lowered against an EMPTY operand stack in both arms
              // — `this` (slot 0, stable) is pushed only AFTER the RHS, and for
              // a compound op the current field value is read into a temp
              // first.  This is the implicit-self (`impl` method / protected-
              // type entry) sibling of the `EMember` path's #5936 fix: a bare
              // self-field reassign whose RHS reads the same field inline
              // (`buf = buf.slice(0, n)` inside an `impl` method) lowers to an
              // internal conditional branch (the inlined bounds check), and
              // evaluating it with `this` still live broke the "operand stack
              // empty at every branch target" StackMapTable invariant →
              // `VerifyError: Inconsistent stackmap frames` (#6168).
              match op {
                case AssEq -> {
                  val vTy = lowerExpr(ctx, insns, value)
                  val vSlot = allocSlot(ctx, "__sfassign_v_" + freshLabel(ctx), vTy)
                  emitStore(insns, vSlot, vTy)
                  insns.add(LAload(slot = 0))
                  emitLoad(insns, vSlot, vTy)
                  // Receiver-aware coercion: a `[B` flowing into a
                  // `slice[Byte]`-typed receiver field needs the boxing loop,
                  // which requires an empty stack under the reloaded value —
                  // guaranteed now that both operands come from slots
                  // (#5609 item 2).
                  coerceValueToUnderReceiver(ctx, insns, JRef(className = selfCls), vTy, fty)
                  insns.add(LPutfield(owner = selfCls, name = name, t = fty))
                }
                case _ -> {
                  insns.add(LAload(slot = 0))
                  insns.add(LGetfield(owner = selfCls, name = name, t = fty))
                  val curSlot = allocSlot(ctx, "__sfassign_cur_" + freshLabel(ctx), fty)
                  emitStore(insns, curSlot, fty)
                  val vTy = lowerExpr(ctx, insns, value)
                  val vSlot = allocSlot(ctx, "__sfassign_v_" + freshLabel(ctx), vTy)
                  emitStore(insns, vSlot, vTy)
                  emitLoad(insns, curSlot, fty)
                  emitLoad(insns, vSlot, vTy)
                  emitCompoundCombineJvm(ctx, insns, op, fty, vTy)
                  val combSlot = allocSlot(ctx, "__sfassign_comb_" + freshLabel(ctx), fty)
                  emitStore(insns, combSlot, fty)
                  insns.add(LAload(slot = 0))
                  emitLoad(insns, combSlot, fty)
                  insns.add(LPutfield(owner = selfCls, name = name, t = fty))
                }
              }
              JVoid
            }
            case None -> {
              // No local slot and no receiver field of this name: dropping the
              // store here silently miscompiles the program (the J3 M-3 and
              // EResult-target bugs were both this shape) — fail loudly.
              panic("Jvm.Codegen: assignment target '" + name + "' resolves to no local, parameter, or receiver field")
            }
          }
        }
      }
    }
    case EResult -> {
      // `result` is a contextual keyword: a local or parameter named "result"
      // parses as EResult even in assignment-target position, so `result = …`
      // fell through to the unsupported-target fallback below and the store
      // was silently discarded (the stdlib's own `buildArgString` assigns to
      // a `result` local, which broke every ProcessCapture argument
      // round-trip on JVM).  Rebuild the equivalent named-path target and
      // re-lower through the local-variable path.
      val segs: List[String] = newList()
      segs.add("result")
      val pathTarget = Expr(kind = EPath(path = ModulePath(segments = segs, span = target.span)), span = target.span)
      lowerAssignExpr(ctx, insns, pathTarget, op, value)
    }
    case EMember(recv, fieldName) -> {
      // Record / opaque field assignment: `recv.field = e` → load receiver, eval
      // (and coerce) RHS, `putfield owner.field:desc`.  Compound ops
      // (`recv.field += e`) read the current field value, combine, and store.
      //
      // The receiver — and, for compound ops, the current field value — is
      // spilled to a temp slot and RELOADED after the RHS is lowered, rather
      // than left live on the operand stack across it.  `assembleCodeWithFrames`
      // documents (and its StackMapTable generator hard-codes) that the operand
      // stack is EMPTY at every branch target; an RHS that reads the same
      // field being assigned inline (`h.buf = h.buf.slice(n, h.buf.length)`)
      // lowers to bytecode with an internal conditional branch (the inlined
      // `.slice()`/`.concat()` bounds check), and evaluating it with `recv`
      // still live on the stack broke that invariant — `VerifyError:
      // Inconsistent stackmap frames at branch target` (#5936).
      val recvTy = lowerExpr(ctx, insns, recv)
      val recvSlot = allocSlot(ctx, "__fassign_recv_" + freshLabel(ctx), recvTy)
      emitStore(insns, recvSlot, recvTy)
      match recvTy {
        case JRef(cls) -> {
          val fty = match recordFieldType(ctx, cls, fieldName) {
            case Some(t) -> t
            case None -> JRef(className = "java/lang/Object")
          }
          match op {
            case AssEq -> {
              val vTy = lowerExpr(ctx, insns, value)
              val vSlot = allocSlot(ctx, "__fassign_v_" + freshLabel(ctx), vTy)
              emitStore(insns, vSlot, vTy)
              emitLoad(insns, recvSlot, recvTy)
              emitLoad(insns, vSlot, vTy)
              // Receiver-aware coercion (#5609 item 2): the boxing loop for
              // a `[B` → `slice[Byte]` field needs an empty operand stack,
              // which reloading from slots (instead of keeping values live
              // across the RHS) already guarantees.
              coerceValueToUnderReceiver(ctx, insns, recvTy, vTy, fty)
              insns.add(LPutfield(owner = cls, name = fieldName, t = fty))
            }
            case _ -> {
              // Compound: read the current field value into a slot too, so
              // the RHS is lowered against an empty operand stack exactly
              // like the AssEq case above, then reload [current, rhs] for
              // the combine and [recv, combined] for the store.
              emitLoad(insns, recvSlot, recvTy)
              insns.add(LGetfield(owner = cls, name = fieldName, t = fty))
              val curSlot = allocSlot(ctx, "__fassign_cur_" + freshLabel(ctx), fty)
              emitStore(insns, curSlot, fty)
              val vTy = lowerExpr(ctx, insns, value)
              val vSlot = allocSlot(ctx, "__fassign_v_" + freshLabel(ctx), vTy)
              emitStore(insns, vSlot, vTy)
              emitLoad(insns, curSlot, fty)
              emitLoad(insns, vSlot, vTy)
              emitCompoundCombineJvm(ctx, insns, op, fty, vTy)
              val combSlot = allocSlot(ctx, "__fassign_comb_" + freshLabel(ctx), fty)
              emitStore(insns, combSlot, fty)
              emitLoad(insns, recvSlot, recvTy)
              emitLoad(insns, combSlot, fty)
              insns.add(LPutfield(owner = cls, name = fieldName, t = fty))
            }
          }
          JVoid
        }
        case _ -> {
          // A field store into a non-reference receiver is a front-end or
          // lowering bug; dropping the store would silently miscompile.
          panic("Jvm.Codegen: field assignment '" + fieldName + "' on a non-reference receiver")
        }
      }
    }
    case EIndex(recv, indices) -> {
      // Slice / array / list / map element assignment: `arr[i] = e`, `m[k] = e`.
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
              emitCompoundCombineJvm(ctx, insns, op, elem, vTy)
              emitArrayStore(insns, elem)
            }
          }
          JVoid
        }
        case JRef(c0) -> {
          if c0 == "java/util/HashMap" {
            // `m[k] = e` / `m[k] += e` — key and value are both boxed to
            // Object (the Map[K, V] erased representation, #1707/m-5).
            match op {
              case AssEq -> {
                val kTy = lowerExpr(ctx, insns, indices[0])
                boxIfNeeded(insns, kTy)
                val vTy = lowerExpr(ctx, insns, value)
                boxIfNeeded(insns, vTy)
                emitMapPut(insns)
              }
              case _ -> {
                // Compound: stash map + boxed key + RHS to locals, then load
                // [map, key] TWICE (mirroring the JArray compound-assign
                // below) so the pair survives under the fetched/combined
                // value all the way to the final `put` — no reordering needed.
                val mapSlot = allocSlot(ctx, "__idxasn_map_" + freshLabel(ctx), recvTy)
                emitStore(insns, mapSlot, recvTy)
                val kTy = lowerExpr(ctx, insns, indices[0])
                boxIfNeeded(insns, kTy)
                val keySlot = allocSlot(ctx, "__idxasn_k_" + freshLabel(ctx), JRef(className = "java/lang/Object"))
                emitStore(insns, keySlot, JRef(className = "java/lang/Object"))
                val vTy = lowerExpr(ctx, insns, value)
                val rhsSlot = allocSlot(ctx, "__idxasn_rhs_" + freshLabel(ctx), vTy)
                emitStore(insns, rhsSlot, vTy)
                emitLoad(insns, mapSlot, recvTy)
                emitLoad(insns, keySlot, JRef(className = "java/lang/Object"))
                emitLoad(insns, mapSlot, recvTy)
                emitLoad(insns, keySlot, JRef(className = "java/lang/Object"))
                emitMapGet(insns)
                emitUnboxObjectTo(insns, vTy)
                emitLoad(insns, rhsSlot, vTy)
                emitCompoundCombineJvm(ctx, insns, op, vTy, vTy)
                boxIfNeeded(insns, vTy)
                emitMapPut(insns)
              }
            }
          } else {
            match op {
              case AssEq -> {
                // List-style element assignment via ArrayList.set(int, Object).
                // Values are boxed to Object (the list-element representation).
                lowerExpr(ctx, insns, indices[0])
                val vTy = lowerExpr(ctx, insns, value)
                boxIfNeeded(insns, vTy)
                emitListSet(insns)
              }
              case _ -> {
                // Compound: stash list + index + RHS to locals, then load
                // [list, idx] TWICE (mirroring the JArray compound-assign
                // above) so the pair survives under the fetched/combined
                // value all the way to the final `set` — no reordering needed.
                val listSlot = allocSlot(ctx, "__idxasn_list_" + freshLabel(ctx), recvTy)
                emitStore(insns, listSlot, recvTy)
                lowerExpr(ctx, insns, indices[0])
                val idxSlot = allocSlot(ctx, "__idxasn_i_" + freshLabel(ctx), JInt)
                emitStore(insns, idxSlot, JInt)
                val vTy = lowerExpr(ctx, insns, value)
                val rhsSlot = allocSlot(ctx, "__idxasn_rhs_" + freshLabel(ctx), vTy)
                emitStore(insns, rhsSlot, vTy)
                emitLoad(insns, listSlot, recvTy)
                emitLoad(insns, idxSlot, JInt)
                emitLoad(insns, listSlot, recvTy)
                emitLoad(insns, idxSlot, JInt)
                emitListGet(insns)
                emitUnboxObjectTo(insns, vTy)
                emitLoad(insns, rhsSlot, vTy)
                emitCompoundCombineJvm(ctx, insns, op, vTy, vTy)
                boxIfNeeded(insns, vTy)
                emitListSet(insns)
              }
            }
          }
          JVoid
        }
        case _ -> {
          // A well-typed `recv[i] = ...` / `recv[i] op= ...` target always
          // lowers `recv` to `JArray` or `JRef` (array, List, Map, or String);
          // any other JVM type here means the front-end accepted an
          // uncodegen-able index target.  Panic rather than silently apply
          // List-style AssEq-only codegen, which would drop the operator on
          // a compound assignment (the same class of bug this file's other
          // fallback below already guards against).
          panic("Jvm.Codegen: EIndex assignment target with non-container receiver type")
        }
      }
    }
    case _ -> {
      // Any other target shape reaching codegen is a front-end or lowering
      // bug; evaluating the RHS and dropping the store would silently
      // miscompile the program (the EResult-target bug was this shape).
      panic("Jvm.Codegen: unsupported assignment-target expression shape")
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
    // An array-typed ELEMENT (a hoisted heap cell for a lambda-captured
    // `var acc: slice[T]`, #5609 item 2) is a single-dimension `anewarray`
    // whose CONSTANT_Class is the element's array descriptor
    // (`[Ljava/lang/Object;`) — JVMS §6.5 anewarray accepts array classes.
    case JArray(inner) -> insns.add(LAnewarray(className = "[" + typeDescriptor(inner)))
    case JVoid -> panic("emitNewarray: cannot create array of void")
  }
}

// Emit the element-load opcode for a JVM array of element type `elem`.  Stack:
// [arrayref, index] → [value].  Used by compound index assignment.
func emitArrayLoad(insns: in List[LInsn], elem: in JvmType): Unit {
  match elem {
    case JByte -> {
      // `baload` sign-extends; mask to the canonical unsigned form (see
      // maskByteUnsigned in 04_calls.l).
      insns.add(LBaload)
      maskByteUnsigned(insns)
    }
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

// Read element at index from an ArrayList: stack [list, index] → [element].
func emitListGet(insns: in List[LInsn]): Unit {
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
}

// Read the value for a (boxed) key from a HashMap: stack [map, key] → [value].
// `get` yields `null` for an absent key, matching Java Map semantics.
func emitMapGet(insns: in List[LInsn]): Unit {
  val getPs: List[JvmType] = newList()
  getPs.add(JRef(className = "java/lang/Object"))
  insns.add(
    LInvokevirtual(
      owner = "java/util/HashMap",
      name = "get",
      params = getPs,
      ret = JRef(className = "java/lang/Object")
    )
  )
}

// Associate a (boxed) key with a (boxed) value in a HashMap:
// stack [map, key, value] → []. `put` returns the previous value, discarded.
func emitMapPut(insns: in List[LInsn]): Unit {
  val putPs: List[JvmType] = newList()
  putPs.add(JRef(className = "java/lang/Object"))
  putPs.add(JRef(className = "java/lang/Object"))
  insns.add(
    LInvokevirtual(
      owner = "java/util/HashMap",
      name = "put",
      params = putPs,
      ret = JRef(className = "java/lang/Object")
    )
  )
  insns.add(LPop)
}

// Combine a compound assignment's current target value and raw RHS — stacked
// [target(targetTy), rhs(vTy)] — into the new target value, leaving it on the
// stack.  The single implementation every compound-assignment path (local var,
// hoisted cell, receiver field, array/list/map element) routes through: the
// local and cell paths previously selected opcodes ad hoc and fell to `iadd`
// for `Float` and `String` targets (VerifyError at class load), and no
// compound path coerced its RHS, so an erased-`Object` match payload
// (`case Some(n) -> total += n`) reached the arithmetic opcode still boxed.
// `String` supports `+=` only, mirroring what plain `s = s + x` lowers to
// (rhs stringified, StringBuilder concat); any other reference or array
// target has no combinable representation and panics rather than silently
// emitting integer opcodes.
func emitCompoundCombineJvm(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  op: in AssignOp,
  targetTy: in JvmType,
  vTy: in JvmType,
): Unit {
  match targetTy {
    case JRef(cls) -> {
      if cls == "java/lang/String" {
        match op {
          case AssPlus -> {
            // Stack on entry: [target String, rhs value (vTy)].  Spill the raw
            // rhs to a typed slot BEFORE stringifying it: coerceToStringForConcat
            // can emit a branch (Double `.0` normalization, emitNormalizeDoubleString),
            // which is unverifiable while the target String still sits beneath
            // the rhs on the stack — that produced a JVM VerifyError
            // ("inconsistent stackmap frames at branch target") for `s += 3.5`
            // once the type checker began accepting it (#5657).  Draining the
            // stack to locals first lets the (possibly branching) stringification
            // run with nothing underneath, then we build via StringBuilder — the
            // same shape the BAdd String path emits.
            val rawSlot = allocSlot(ctx, "__compcat_rawrhs_" + freshLabel(ctx), vTy)
            emitStore(insns, rawSlot, vTy)
            val lSlot = allocSlot(ctx, "__compcat_lhs_" + freshLabel(ctx), JRef(className = "java/lang/String"))
            emitStore(insns, lSlot, JRef(className = "java/lang/String"))
            emitLoad(insns, rawSlot, vTy)
            coerceToStringForConcat(ctx, insns, vTy)
            val rSlot = allocSlot(ctx, "__compcat_rhs_" + freshLabel(ctx), JRef(className = "java/lang/String"))
            emitStore(insns, rSlot, JRef(className = "java/lang/String"))
            insns.add(LNew(className = "java/lang/StringBuilder"))
            insns.add(LDup)
            val sbPs: List[JvmType] = newList()
            insns.add(LInvokespecial(owner = "java/lang/StringBuilder", name = "<init>", params = sbPs, ret = JVoid))
            val apPs: List[JvmType] = newList()
            apPs.add(JRef(className = "java/lang/String"))
            emitLoad(insns, lSlot, JRef(className = "java/lang/String"))
            insns.add(
              LInvokevirtual(
                owner = "java/lang/StringBuilder",
                name = "append",
                params = apPs,
                ret = JRef(className = "java/lang/StringBuilder")
              )
            )
            emitLoad(insns, rSlot, JRef(className = "java/lang/String"))
            insns.add(
              LInvokevirtual(
                owner = "java/lang/StringBuilder",
                name = "append",
                params = apPs,
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
          }
          case _ -> panic("Jvm.Codegen: compound assignment on a String target supports `+=` only")
        }
      } else {
        panic(
          "Jvm.Codegen: compound assignment on a reference-typed target ('" + cls +
            "') — only String `+=` combines on a reference; a numeric target erased to Object needs an explicit type annotation"
        )
      }
    }
    case JArray(_) -> panic("Jvm.Codegen: compound assignment on an array-typed target has no combinable lowering")
    case JVoid -> panic("Jvm.Codegen: compound assignment on a Unit-typed target (front-end should have rejected this)")
    case _ -> {
      // Numeric/char/bool primitive target: coerce the RHS to the target's
      // stack width first (unboxes an erased `Object` payload, widens an int
      // literal against a Long/Double/Float target) so the arithmetic opcode
      // sees two like-typed operands.
      coerceArgTo(insns, vTy, targetTy)
      emitCompoundArith(ctx, insns, op, targetTy)
    }
  }
}

// Combine the current target value (already on the stack) with the RHS using
// the compound-assignment operator, for primitive numeric target type `ty`.
func emitCompoundArith(ctx: in FuncCtx, insns: in List[LInsn], op: in AssignOp, ty: in JvmType): Unit {
  // A JByte result re-masks to the canonical unsigned 0..255 form (unsigned
  // wrap, matching MSIL `conv.u1` — `b *= 2` on 200 is 144, not 400; see
  // maskByteUnsigned in 04_calls.l).  The JByte div/rem arms below mask their
  // OPERANDS instead (unsigned division needs unsigned inputs, and their
  // results are then already in range).
  match op {
    case AssPlus -> match ty { case JLong -> insns.add(LLadd); case JFloat -> insns.add(LFadd); case JDouble -> insns.add(LDadd); case JByte -> { insns.add(LIadd); maskByteUnsigned(insns) }; case _ -> insns.add(LIadd) }
    case AssMinus -> match ty { case JLong -> insns.add(LLsub); case JFloat -> insns.add(LFsub); case JDouble -> insns.add(LDsub); case JByte -> { insns.add(LIsub); maskByteUnsigned(insns) }; case _ -> insns.add(LIsub) }
    case AssStar -> match ty { case JLong -> insns.add(LLmul); case JFloat -> insns.add(LFmul); case JDouble -> insns.add(LDmul); case JByte -> { insns.add(LImul); maskByteUnsigned(insns) }; case _ -> insns.add(LImul) }
    case AssSlash -> match ty { case JLong -> insns.add(LLdiv); case JFloat -> insns.add(LFdiv); case JDouble -> insns.add(LDdiv); case JByte -> { val rhsSlot = allocSlot(ctx, "__comp_rhs_" + freshLabel(ctx), JInt); emitStore(insns, rhsSlot, JInt); insns.add(LIconst(255)); insns.add(LIand); emitLoad(insns, rhsSlot, JInt); insns.add(LIconst(255)); insns.add(LIand); insns.add(LIdiv) }; case _ -> insns.add(LIdiv) }
    case AssPercent -> match ty { case JLong -> insns.add(LLrem); case JFloat -> insns.add(LFrem); case JDouble -> insns.add(LDrem); case JByte -> { val rhsSlot = allocSlot(ctx, "__comp_rhs_" + freshLabel(ctx), JInt); emitStore(insns, rhsSlot, JInt); insns.add(LIconst(255)); insns.add(LIand); emitLoad(insns, rhsSlot, JInt); insns.add(LIconst(255)); insns.add(LIand); insns.add(LIrem) }; case _ -> insns.add(LIrem) }
    case AssEq -> ()
  }
}

// Emit a counted `for` loop for a range-driven `for <pat> in lo ..< hi` (half-
// open, `inclusive = false`) or `lo ..= hi` (closed, `inclusive = true`).
// Mirrors the MSIL `emitCountingForMsil` path: evaluate `lo` into a counter slot
// and `hi` once into a bound slot, then loop `while i < hi` (half-open) / `i <= hi`
// (closed).  The pattern is bound from the counter each iteration; `continue`
// targets the increment point so the counter still advances, `break` targets the
// exit.  Int and Long counters are both supported (Long compares via `lcmp`).
func emitCountingForJvm(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  pat: in Pattern,
  lo: in Expr,
  hi: in Expr,
  inclusive: in Bool,
  body: in Block,
): Unit {
  val loTy = lowerExpr(ctx, insns, lo)
  val iSlot = allocSlot(ctx, "__for_i_" + freshLabel(ctx), loTy)
  emitStore(insns, iSlot, loTy)
  val hiTy = lowerExpr(ctx, insns, hi)
  val hiSlot = allocSlot(ctx, "__for_hi_" + freshLabel(ctx), hiTy)
  emitStore(insns, hiSlot, hiTy)
  // Defensive invariant: `lo` and `hi` share a type (the type checker unifies a
  // range's bounds).  The comparison-opcode dispatch and increment below are
  // driven by `loTy` alone; a Long/int-like mismatch would emit `lcmp` against a
  // single-slot operand (or vice versa) — a class-load `VerifyError` rather than
  // a diagnostic.  Fail loud at compile time if a future front-end change ever
  // breaks the invariant.
  val boundsSameWidth = match loTy {
    case JLong -> match hiTy { case JLong -> true; case _ -> false }
    case _ -> match hiTy { case JLong -> false; case _ -> true }
  }
  if not boundsSameWidth {
    panic(
      "Jvm.Codegen: range `for` bounds have mismatched JVM types (lo is Long xor hi is Long) — the type checker should have unified them"
    )
  }

  val loopL = freshLabel(ctx)
  val contL = freshLabel(ctx)
  val endL = freshLabel(ctx)

  insns.add(LLabel(name = loopL))
  // Exit test: leave the loop once the counter is no longer in range.  For a
  // half-open range exit when `i >= hi`; for a closed range exit when `i > hi`.
  emitLoad(insns, iSlot, loTy)
  emitLoad(insns, hiSlot, hiTy)
  match loTy {
    case JLong -> {
      insns.add(LLcmp)
      if inclusive {
        insns.add(LIfgt(label = endL))
      } else {
        insns.add(LIfge(label = endL))
      }
    }
    case _ -> {
      if inclusive {
        insns.add(LIfIcmpgt(label = endL))
      } else {
        insns.add(LIfIcmpge(label = endL))
      }
    }
  }
  // The loop variable is a per-loop lexical binding (#5191 follow-up): a
  // `for i in …` shadowing a still-live outer `i` must get a fresh slot, and
  // the outer name→slot mapping must be restored when the loop ends — pattern
  // binds bypass `lowerBlock`'s bracket (which only covers the body block).
  val loopScope = enterBlockScope(ctx)
  lowerPatternBind(ctx, insns, pat, iSlot, loTy, newList())

  ctx.loopBreak.add(endL)
  ctx.loopCont.add(contL)
  ctx.loopDeferDepth.add(ctx.deferStack.count)
  lowerBlock(ctx, insns, body)
  ctx.loopDeferDepth.removeAt(ctx.loopDeferDepth.count - 1)
  ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
  ctx.loopCont.removeAt(ctx.loopCont.count - 1)
  exitBlockScope(ctx, loopScope)

  insns.add(LLabel(name = contL))
  emitLoad(insns, iSlot, loTy)
  match loTy {
    case JLong -> {
      insns.add(LLconst(v = 1i64))
      insns.add(LLadd)
    }
    case _ -> {
      insns.add(LIconst(v = 1))
      insns.add(LIadd)
    }
  }
  emitStore(insns, iSlot, loTy)
  insns.add(LGoto(label = loopL))
  insns.add(LLabel(name = endL))
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
          // A simple `val r = <expr>` records `r`'s generic args so a later
          // `match r` unboxes an erased payload (#4938).  An explicit
          // `slice[Elem]`/`List[Elem]` annotation overrides them with the
          // declared element type, so an indexed element read narrows
          // (docs/59 §4.3 #5439 class).
          match pat.kind {
            case PBinding(nm, _) -> {
              recordVarGenericArgs(ctx, nm, init)
              recordSpawnResultType(ctx, nm, init)
              match tyOpt {
                case Some(te) -> recordDeclaredElemType(ctx, nm, te, newList())
                case None -> ()
              }
            }
            case _ -> ()
          }
        }
        case LBLet(name, tyOpt, init) -> {
          val annTy = match tyOpt { case Some(te) -> typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes); case None -> JVoid }
          if isDefaultCall(init) and pushPrimitiveZero(insns, annTy) {
            val slot0 = allocSlot(ctx, name, annTy)
            emitStore(insns, slot0, annTy)
          } else {
            val initTy = lowerExpr(ctx, insns, init)
            val ty = match tyOpt { case Some(_) -> annTy; case None -> initTy }
            // `coerceValueTo` boxes a primitive array into an annotated
            // `slice[T]` local's erased slot type (#5572).
            coerceValueTo(ctx, insns, initTy, ty)
            val slot = allocSlot(ctx, name, ty)
            emitStore(insns, slot, ty)
            recordVarGenericArgs(ctx, name, init)
            recordSpawnResultType(ctx, name, init)
            match tyOpt {
              case Some(te) -> recordDeclaredElemType(ctx, name, te, newList())
              case None -> ()
            }
          }
        }
        case LBVar(name, tyOpt, initOpt) -> {
          // Check if this var is hoisted (referenced inside a lambda).
          val isHoisted = nameInList(ctx.hoistedVarNames, name)
          match initOpt {
            case Some(init) -> {
              // An un-annotated `var x = e` takes its slot type from the
              // initialiser; an annotated `var x: T = e` coerces `e` to `T`.
              val annTy = match tyOpt { case Some(te) -> typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes); case None -> JVoid }
              var ty = annTy
              if isDefaultCall(init) and pushPrimitiveZero(insns, annTy) {
                ()
              } else {
                val initTy = lowerExpr(ctx, insns, init)
                ty = match tyOpt { case Some(_) -> annTy; case None -> initTy }
                // `coerceValueTo` boxes a primitive array into an annotated
                // `slice[T]` var's erased slot type (#5572).
                coerceValueTo(ctx, insns, initTy, ty)
              }
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
              // Record `name`'s generic args so a later `match name` unboxes an
              // erased payload (#4938).  The type checker fixes a `var`'s type
              // across reassignments, so recording at the initialiser is stable.
              // An explicit `slice[Elem]`/`List[Elem]` annotation overrides them
              // with the declared element type (docs/59 §4.3 #5439 class).
              recordVarGenericArgs(ctx, name, init)
              recordSpawnResultType(ctx, name, init)
              match tyOpt {
                case Some(te) -> recordDeclaredElemType(ctx, name, te, newList())
                case None -> ()
              }
            }
            case None -> {
              // No initialiser: an annotation is required to know the slot type;
              // default to JInt only as a last resort (matches prior behaviour).
              val ty = match tyOpt { case Some(te) -> typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes); case None -> JInt }
              match tyOpt {
                case Some(te2) -> recordDeclaredElemType(ctx, name, te2, newList())
                case None -> ()
              }
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
          // declared return type isn't threaded.  Routes through
          // `coerceValueTo` (not bare `coerceArgTo`) so an explicit
          // `return someIntArray` gets the same primitive-array boxing an
          // equivalent tail-expression return already got.
          val rt = match ctx.retTy { case JVoid -> ty; case t -> { coerceValueTo(ctx, insns, ty, t); t } }
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
        case JVoid -> {
          // The LNop is only a placeholder so a JVoid expression statement isn't
          // empty.  Skip it when the expression already TERMINATED (a `panic` →
          // athrow): a nop after a terminator is unreachable dead code that then
          // falls through into the following label — e.g. a `defer` catch-all
          // handler — creating an empty-stack fall-through edge that conflicts
          // with the handler's {Throwable} frame (VerifyError) (#4878).
          if not lastInsnIsTerminator(insns) {
            insns.add(LNop)
          }
        }
        case _ -> discardValue(insns, ty)
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
      match iter.kind {
        // A range-driven `for` (`for i in 0 ..< n`, `for i in a ..= b`) lowers to
        // a counted loop — mirrors the MSIL `emitCountingForMsil` path.  Bounded
        // ranges only: an open start (`..< b`) has nothing to count from and an
        // open end (`a ..`) is unbounded, so both are rejected (matching MSIL).
        case ERange(bound) -> {
          match bound {
            case RBClosed(lo, hi) -> emitCountingForJvm(ctx, insns, pat, lo, hi, true, body)
            case RBHalfOpen(lo, hi) -> emitCountingForJvm(ctx, insns, pat, lo, hi, false, body)
            case RBLowerOpen(_) -> {
              panic("Jvm.Codegen: an open-start range cannot drive a `for` loop — no lower bound to count from (#1478)")
            }
            case RBUpperOpen(_) -> {
              panic("Jvm.Codegen: an open-end range (`a ..`) cannot drive a `for` loop — it is unbounded (#1478)")
            }
          }
        }
        case _ -> {
          // Resolved BEFORE the iterable is lowered (mirrors `EIndex`'s
          // ordering): the loop element's recorded declared type — the same
          // `indexedElemTypeOverride` resolution `EIndex` applies (a declared
          // `slice[Elem]`/`List[Elem]` parameter/local, a call-derived binding
          // #4938, a direct call's declared return instantiation, or a record
          // FIELD receiver via the `elem:<class>#<field>` registry, #5444).
          // Without it the loop variable stays `Object`, so a typed use in
          // the body (an instance method, an auto-FFI overload pick)
          // mis-resolves — e.g. `for name in mapKeys(...)` fed
          // `HttpString.new(name)` the `ByteBuffer` ctor overload instead of
          // `String` (VerifyError at class load).
          val forElemOverride = indexedElemTypeOverride(ctx, iter)
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
              // A slice's erased `Object[]` element narrows to the recorded
              // declared element type, exactly as `EIndex`'s JArray arm does;
              // a precisely-typed array element keeps its own type.
              val elemTyA = match elemArr {
                case JRef(cA) -> {
                  if cA == "java/lang/Object" {
                    applyIndexedElemOverride(insns, forElemOverride)
                  } else {
                    elemArr
                  }
                }
                case _ -> elemArr
              }
              val elemSlotA = allocSlot(ctx, "__for_elem_" + freshLabel(ctx), elemTyA)
              emitStore(insns, elemSlotA, elemTyA)
              // Loop-variable bind is a per-loop lexical scope — see
              // `emitCountingForJvm` (#5191 follow-up).
              val forScopeA = enterBlockScope(ctx)
              lowerPatternBind(ctx, insns, pat, elemSlotA, elemTyA, newList())
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
              exitBlockScope(ctx, forScopeA)
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
              // Narrow the erased `next()` element to the iterable's recorded
              // declared element type when known (see `forElemOverride` above).
              val elemTyB = applyIndexedElemOverride(insns, forElemOverride)
              val elemSlotB = allocSlot(ctx, "__for_elem_" + freshLabel(ctx), elemTyB)
              emitStore(insns, elemSlotB, elemTyB)
              // Loop-variable bind is a per-loop lexical scope — see
              // `emitCountingForJvm` (#5191 follow-up).
              val forScopeB = enterBlockScope(ctx)
              lowerPatternBind(ctx, insns, pat, elemSlotB, elemTyB, newList())
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
              exitBlockScope(ctx, forScopeB)
              insns.add(LGoto(label = loopLB))
              insns.add(LLabel(name = endLB))
            }
          }
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
    // Structured concurrency (D119 S4 / D120): open a virtual-thread
    // `ExecutorService`, make it visible to `spawn` inside the body, and close
    // it on every exit path (fall-off, return, break/continue, exception) via a
    // synthesized `defer` — the `close()` blocks until every submitted task
    // terminates, giving §7.4's no-task-leak join.
    case SScope(_, body) -> {
      lowerScopeStmt(ctx, insns, body, stmt.span)
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
      val ty = match tyOpt { case Some(te) -> typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes); case None -> initTy }
      // `coerceValueTo` boxes a primitive array into an annotated `slice[T]`
      // val's erased slot type (#5572).
      coerceValueTo(ctx, insns, initTy, ty)
      val slot = allocSlot(ctx, name, ty)
      emitStore(insns, slot, ty)
    }
    case PWildcard -> {
      // Discard the value (pop2 for category-2 long/double).
      match initTy {
        case JVoid -> insns.add(LNop)
        case _ -> discardValue(insns, initTy)
      }
    }
    case _ -> {
      // Complex pattern: store to a temp slot then bind.
      val tmpSlot = allocSlot(ctx, "__tmp_" + freshLabel(ctx), initTy)
      emitStore(insns, tmpSlot, initTy)
      lowerPatternBind(ctx, insns, pat, tmpSlot, initTy, newList())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Try/catch lowering.
// ─────────────────────────────────────────────────────────────────────────────
// A catch arm pre-lowered into its own instruction buffer (#5850).  The
// #5805 fix tracked the expression join type as a first-value-wins mutable
// accumulator updated WHILE arm bytecode was being emitted, which made the
// outcome depend on catch-clause order: a Unit-typed, non-terminating arm
// processed before the value-producing arm silently skipped its result-slot
// store and jumped to the join — where the shared epilogue loads a slot
// that edge never wrote (VerifyError, or stale-slot garbage).  Swapping the
// clause order turned the same program into a J004 compile error.  Buffering
// each arm first lets the join type be computed from the try body plus ALL
// arms, and every Unit edge be validated, before a single store/goto
// decision is emitted.
record LoweredCatchArm {
  insns: List[LInsn]
  bodyTy: JvmType
  terminated: Bool
  handlerLabel: String
}

// Pass 1 of try/catch-expression lowering: lower every catch arm (handler
// label, exception binding, body — bracketed as its own lexical scope,
// #5522) into a private buffer, recording the arm's produced type and
// whether its tail unconditionally transfers control.
func lowerCatchArmsBuffered(ctx: in FuncCtx, catches: in List[CatchClause]): List[LoweredCatchArm] {
  val arms: List[LoweredCatchArm] = newList()
  var i = 0
  while i < catches.count {
    val c = catches[i]
    val buf: List[LInsn] = newList()
    val handlerL = freshLabel(ctx)
    buf.add(LLabel(name = handlerL))
    val handlerScope = enterBlockScope(ctx)
    val exTy = JRef(className = "java/lang/Throwable")
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlot(ctx, bname, exTy)
        emitStore(buf, exSlot, exTy)
      }
      case None -> buf.add(LPop)
    }
    val catchBodyTy = lowerBlockExpr(ctx, buf, c.body)
    exitBlockScope(ctx, handlerScope)
    val terminated = lastInsnIsTerminator(buf)
    arms.add(LoweredCatchArm(insns = buf, bodyTy = catchBodyTy, terminated = terminated, handlerLabel = handlerL))
    i = i + 1
  }
  arms
}

func appendLInsns(dst: in List[LInsn], src: in List[LInsn]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

func firstValueArmIndex(arms: in List[LoweredCatchArm]): Int {
  var i = 0
  while i < arms.count {
    match arms[i].bodyTy {
      case JVoid -> ()
      case _ -> return i
    }
    i = i + 1
  }
  -1
}

// The try-catch expression's effective join type: the try body's own type
// when it produces one, else the first value-producing arm's type — computed
// from the COMPLETE set of pre-lowered arms, never accumulated in emission
// order (#5850).
func effectiveCatchJoinTy(resultTy: in JvmType, arms: in List[LoweredCatchArm]): JvmType {
  match resultTy {
    case JVoid -> {
      val idx = firstValueArmIndex(arms)
      if idx >= 0 {
        arms[idx].bodyTy
      } else {
        JVoid
      }
    }
    case _ -> resultTy
  }
}

// Order-independent J004 validation (#5850): when the join type demands a
// value, EVERY edge that can fall through to the join must produce one —
// the try body's own fall-through included, not just catch arms.  Emitting
// a store on a valueless edge would pop a value that isn't on the stack;
// skipping it leaves the join loading an unwritten slot.  Neither is
// recoverable at this layer (the codegen tree returns `JvmType`, not a
// diagnostic-collecting Result), so abort with a source-located,
// `error[J004]`-prefixed message — `Jvm.Bridge`'s `startsWith("error[J0")`
// passthrough re-emits it verbatim rather than wrapping it under
// `error[J002]` (#3193, #3310, #3311).  Mixed Unit/value arms in expression
// position are reachable pending type-checker gap #2042.
func validateCatchJoinEdges(
  ctx: in FuncCtx,
  formName: in String,
  resultTy: in JvmType,
  tryTerminated: in Bool,
  arms: in List[LoweredCatchArm],
  catches: in List[CatchClause],
): Unit {
  val joinTy = effectiveCatchJoinTy(resultTy, arms)
  match joinTy {
    case JVoid -> ()
    case _ -> {
      val dottedPkgName = ctx.pkgName.replace("/", ".")
      val tryYieldsUnit = match resultTy { case JVoid -> true; case _ -> false }
      if tryYieldsUnit and not tryTerminated {
        val vIdx = firstValueArmIndex(arms)
        val pos = catches[vIdx].span.startPos
        panic(
          "error[J004]: " + dottedPkgName + ":" + pos.line.toString() + ":" + pos.column.toString() + ": " + formName +
            " used as an expression, but the try body falls through yielding " +
            "Unit while this catch arm yields a value; the JVM backend cannot route an absent " +
            "value through the result slot. Give the try body a trailing value of the catch " +
            "arm's type, or annotate the try-catch result type explicitly (type-checker gap #2042)."
        )
      }
      var i = 0
      while i < arms.count {
        val unitArm = match arms[i].bodyTy { case JVoid -> true; case _ -> false }
        if unitArm and not arms[i].terminated {
          val pos = catches[i].span.startPos
          panic(
            "error[J004]: " + dottedPkgName + ":" + pos.line.toString() + ":" + pos.column.toString() + ": " + formName +
              " used as an expression, but this catch arm yields Unit while " +
              "another arm or the try body yields a value; the JVM backend cannot route an " +
              "absent value through the result slot. Give the catch arm a trailing value of " +
              "the join type, or annotate the try-catch result type explicitly (type-checker " +
              "gap #2042)."
          )
        }
        i = i + 1
      }
    }
  }
}

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
  // #5805/#5850: the expression's effective join type is the try body's own
  // type when it produces one, else the first value-producing catch arm's —
  // computed by `effectiveCatchJoinTy` over the COMPLETE set of pre-lowered
  // arms (never accumulated in emission order, which made J004 vs a
  // silent-miscompile depend on catch-clause order), then every
  // fall-through-to-join Unit edge is rejected up front by
  // `validateCatchJoinEdges`.  A terminated edge (trailing `panic(...)` →
  // athrow, `return`) never reaches the join: skip its result store AND its
  // fall-through `goto` (dead code after `athrow` breaks verification) —
  // the `readTextOrPanic` shape.
  val tryTerminated = lastInsnIsTerminator(insns)
  val arms = lowerCatchArmsBuffered(ctx, catches)
  val joinTy = effectiveCatchJoinTy(resultTy, arms)
  validateCatchJoinEdges(ctx, "try-catch", resultTy, tryTerminated, arms, catches)
  match joinTy {
    case JVoid -> ()
    case _ -> {
      rslot = allocSlot(ctx, rslotName, joinTy)
    }
  }
  match resultTy {
    case JVoid -> ()
    case _ -> emitStore(insns, rslot, resultTy)
  }
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = endL))

  var i = 0
  while i < arms.count {
    val a = arms[i]
    val c = catches[i]
    appendLInsns(insns, a.insns)
    if not a.terminated {
      // Store with THIS arm's own produced kind so an arm whose actual
      // type differs from the join type (documented type-checker gap
      // #2042) emits the matching `istore`/`astore` variant and the JVM
      // verifier doesn't reject a mismatched store (#1681).
      match a.bodyTy {
        case JVoid -> ()
        case _ -> emitStore(insns, rslot, a.bodyTy)
      }
      insns.add(LGoto(label = afterL))
    }
    val catchClass = if c.typeName == "Bug" { "java/lang/Throwable" } else { lyricNameToJvm(c.typeName) }
    insns.add(LTryCatch(startLabel = startL, endLabel = endL, handlerLabel = a.handlerLabel, catchClass = catchClass))
    i = i + 1
  }

  insns.add(LLabel(name = afterL))
  match joinTy {
    case JVoid -> ()
    case _ -> {
      if rslot >= 0 {
        emitResultLoad(insns, rslot, joinTy)
      }
    }
  }
  joinTy
}

// Try/catch/**finally** in *expression* position (#2043): the try body's (or
// a matching catch arm's) trailing value must survive the finally block, so
// the value-join machinery of `lowerTryCatchExpr` is combined with the
// catch-all-handler + duplicated-finally strategy of `lowerTryCatch`'s
// statement-mode finally lowering.  `lowerBlockExprInner` previously fell
// back to statement-mode lowering for this shape (value discarded, #1683
// follow-up comment) whenever a finally block was present — which did not
// merely leave the shape unhandled, it silently replaced the try's real
// result with `retTy`'s zero/default value instead of failing loudly: a
// genuine miscompile (a `func f(): Int { try { 42 } finally { cleanup() } }`
// returned 0), not just an unhandled/uncommon shape.
//
// Strategy: lower the try body (and any catch arms) exactly like
// `lowerTryCatchExpr`, storing the produced value in a result slot.  On the
// normal-completion path (`afterL`), run the finally block for its side
// effects (its own trailing value, if any, is discarded — a `finally` block
// is a Unit-typed cleanup block, mirroring `lowerTryCatch`), THEN reload the
// stashed result.  A catch-all handler covering the try body and every catch
// arm ([startL, finallyExL)) runs the finally block on the exceptional path
// too, before rethrowing — the finally must run on every exit, matching
// `lowerTryCatch`'s statement-mode contract.
func lowerTryCatchFinallyExpr(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  body: in Block,
  catches: in List[CatchClause],
  fb: in Block,
): JvmType {
  val startL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  val afterL = freshLabel(ctx)
  val rslotName = "__tryf_r_" + afterL
  var rslot = -1

  insns.add(LLabel(name = startL))
  val resultTy = lowerBlockExpr(ctx, insns, body)
  // Same structure as `lowerTryCatchExpr` above (#5805/#5850): pre-lower
  // every catch arm into its own buffer, compute the effective join type
  // from the try body plus ALL arms (never in emission order), and reject
  // every fall-through-to-join Unit edge up front.
  val tryTerminated = lastInsnIsTerminator(insns)
  val arms = lowerCatchArmsBuffered(ctx, catches)
  val joinTy = effectiveCatchJoinTy(resultTy, arms)
  validateCatchJoinEdges(ctx, "try-catch-finally", resultTy, tryTerminated, arms, catches)
  match joinTy {
    case JVoid -> ()
    case _ -> {
      rslot = allocSlot(ctx, rslotName, joinTy)
    }
  }
  match resultTy {
    case JVoid -> ()
    case _ -> emitStore(insns, rslot, resultTy)
  }
  insns.add(LGoto(label = afterL))
  insns.add(LLabel(name = endL))

  var i = 0
  while i < arms.count {
    val a = arms[i]
    val c = catches[i]
    appendLInsns(insns, a.insns)
    if not a.terminated {
      // Store with THIS arm's own produced kind (#1681) — see the matching
      // comment in `lowerTryCatchExpr` above.
      match a.bodyTy {
        case JVoid -> ()
        case _ -> emitStore(insns, rslot, a.bodyTy)
      }
      insns.add(LGoto(label = afterL))
    }
    val catchClass = if c.typeName == "Bug" { "java/lang/Throwable" } else { lyricNameToJvm(c.typeName) }
    insns.add(LTryCatch(startLabel = startL, endLabel = endL, handlerLabel = a.handlerLabel, catchClass = catchClass))
    i = i + 1
  }

  // Catch-all: runs the finally block then rethrows, covering the try body
  // and every catch arm ([startL, finallyExL)); self-excludes the handler.
  val finallyExL = freshLabel(ctx)
  insns.add(LLabel(name = finallyExL))
  val exTy2 = JRef(className = "java/lang/Throwable")
  val tmpName = "__tryf_ex_" + finallyExL
  val tmpSlot = allocSlot(ctx, tmpName, exTy2)
  emitStore(insns, tmpSlot, exTy2)
  lowerBlock(ctx, insns, fb)
  emitLoad(insns, tmpSlot, exTy2)
  insns.add(LAthrow)
  insns.add(LTryCatch(startLabel = startL, endLabel = finallyExL, handlerLabel = finallyExL, catchClass = ""))

  // Normal path: run the finally block for its side effects, then reload the
  // stashed try/catch result.
  insns.add(LLabel(name = afterL))
  lowerBlock(ctx, insns, fb)
  match joinTy {
    case JVoid -> ()
    case _ -> {
      if rslot >= 0 {
        emitResultLoad(insns, rslot, joinTy)
      }
    }
  }
  joinTy
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
    // Bracket bind + handler body as its own lexical scope (#5522) — see the
    // matching comment in `lowerTryCatchExpr` above.
    val handlerScope = enterBlockScope(ctx)
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
    exitBlockScope(ctx, handlerScope)
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
  // A Lyric `{ … }` block is a lexical scope: snapshot the block-local binding
  // maps on entry and restore them on exit so a nested `val`/`var` (including
  // one that shadows an enclosing binding of the same name) does not leak past
  // the block or clobber the enclosing binding's slot (general shadowing, #5191).
  val blockScope = enterBlockScope(ctx)
  lowerBlockStmtsFrom(ctx, insns, block.statements, 0)
  exitBlockScope(ctx, blockScope)
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
  // A trailing `defer` (nothing follows it in the block — the common case, and
  // every defer past the first in a run of consecutive defers) has an EMPTY
  // protected region: emitting a catch-all for it yields an illegal `[X, X)`
  // exception-table range that fails class verification ("Illegal exception table
  // range").  Nothing after the defer can throw, so run the deferred block inline
  // on fall-off with no handler (#4878).
  if deferIdx + 1 >= stmts.count {
    lowerBlock(ctx, insns, deferBody)
    return
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
  // A `scope { }` body's synthesized close-defer must NOT run `close()` on the
  // exception path (#5569 item 3): `close()` blocks until every submitted task
  // terminates, so a Throwable escaping the body with an unfinished spawned
  // task parked the rethrow behind an unbounded wait — the error became a
  // silent hang in `ThreadPerTaskExecutor.close`.  First-failure semantics
  // (D119 §7.4) want the opposite: cancel outstanding children and propagate.
  // `shutdownNow()` interrupts running tasks and returns without waiting, so
  // the rethrow below surfaces the original Throwable immediately.  User
  // `defer` blocks are unaffected — this substitution applies only to the
  // compiler-synthesized close intrinsic.
  match scopeCloseDeferExecName(deferBody) {
    case Some(execName) -> emitAbortExecutor(ctx, insns, execName)
    case None -> lowerBlock(ctx, insns, deferBody)
  }
  insns.add(LLabel(name = skipDeferL))
  emitLoad(insns, tmpSlot, exTy)
  insns.add(LAthrow)
  // Catch-all entry covers [startL, normalReplayL) (the region body + suffix
  // only); endLabel = normalReplayL excludes the inline normal-path replay so a
  // throw during replay rethrows directly rather than re-running the block.
  insns.add(LTryCatch(startLabel = startL, endLabel = normalReplayL, handlerLabel = handlerL, catchClass = ""))
  // Emit the join label only when it is reachable.  The single `goto afterL` (the
  // normal-path replay above) is itself guarded by `not suffixTerminated`, so when
  // the suffix already transferred control (e.g. a `scope { … return … }` at a
  // function's tail) `afterL` has no incoming edge.  Emitting it there leaves a
  // dead label at the method's end, and the StackMapTable generator then records a
  // frame at the code-end offset — "StackMapTable error: bad offset" at load time.
  if not suffixTerminated {
    insns.add(LLabel(name = afterL))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Structured concurrency: `scope { }` lowering (D119 S4 / D120).
// ─────────────────────────────────────────────────────────────────────────────
// The internal name of the intrinsic that `makeCloseDeferStmt` synthesizes and
// `lowerCall` (04_calls.l) intercepts to emit `ExecutorService.close()`.  A
// leading `__lyric_` marks it as compiler-synthesized; it is never user-nameable
// (`__` is reserved) so no real function can collide with it.
pub func jvmCloseExecutorIntrinsic(): String {
  "__lyric_jvm_close_executor"
}

// Open a virtual-thread `ExecutorService` for a `scope { }` block, lower the body
// with the executor visible to `spawn` (via `ctx.scopeExecSlots`), and close the
// executor on every exit path.  The close is routed through a synthesized
// `defer { <close intrinsic>(<exec local>) }` prepended to the body so the
// existing defer machinery (fall-off, early return/break/continue replay, and
// the exception catch-all) drives it — exactly D120's "try/finally so it closes
// on all exit paths (mirroring defer)".
func lowerScopeStmt(ctx: in FuncCtx, insns: in List[LInsn], body: in Block, span: in Span): Unit {
  val execTy = JRef(className = "java/util/concurrent/ExecutorService")
  val execName = "__lyric_exec_" + freshLabel(ctx)
  val execSlot = allocSlot(ctx, execName, execTy)
  val noParams: List[JvmType] = newList()
  insns.add(
    LInvokestatic(
      owner = "java/util/concurrent/Executors",
      name = "newVirtualThreadPerTaskExecutor",
      params = noParams,
      ret = execTy
    )
  )
  emitStore(insns, execSlot, execTy)
  ctx.scopeExecSlots.add(execSlot)
  // Prepend the synthesized close-defer, then lower the augmented statement list
  // through the normal defer-aware path.
  val augmented: List[Statement] = newList()
  augmented.add(makeCloseDeferStmt(execName, span))
  var i = 0
  while i < body.statements.count {
    augmented.add(body.statements[i])
    i = i + 1
  }
  // A `scope { … }` body is a lexical scope, so bracket its lowering with
  // `enterBlockScope`/`exitBlockScope` the way `lowerBlock` does (#5204) — a
  // `val`/`var` declared directly in the scope body that shadows a still-live
  // enclosing binding must get a fresh slot and be dropped on scope exit, not
  // clobber the enclosing binding (the general shadowing bug this PR fixes
  // everywhere else).  The executor slot is allocated BEFORE the bracket so it
  // lives in the enclosing scope: the synthesized close-defer (which resolves
  // `execName`) and `scopeExecSlots` both see it throughout the body.
  val bodyScope = enterBlockScope(ctx)
  lowerBlockStmtsFrom(ctx, insns, augmented, 0)
  exitBlockScope(ctx, bodyScope)
  ctx.scopeExecSlots.removeAt(ctx.scopeExecSlots.count - 1)
}

// Record the logical result type of a `val/let/var t = spawn f(…)` binding whose
// slot holds a `Future` (a spawn lowered inside a `scope { }`), so a later
// `await t` unboxes the joined `Object` back to `f`'s return type.  A no-op for a
// non-spawn init, a bare (no-scope) spawn whose binding already holds the value,
// a `Unit`-returning spawn (nothing to unbox), or an unresolvable spawn call.
pub func recordSpawnResultType(ctx: in FuncCtx, name: in String, init: in Expr): Unit {
  if ctx.scopeExecSlots.count > 0 {
    match init.kind {
      // Unwrap a parenthesised initialiser `val t = (spawn f(x))` so the spawn is
      // still recognised (#5194), mirroring `spawnInnerResultType` /
      // `awaitLogicalType`, which already peel `EParen`.
      case EParen(inner) -> recordSpawnResultType(ctx, name, inner)
      case ESpawn(spawnInner) -> {
        match spawnInnerResultType(ctx, spawnInner) {
          case Some(t) -> putSpawnResultType(ctx, name, t)
          case None -> ()
        }
      }
      case _ -> ()
    }
  }
}

// Record a spawn binding's result type keyed by its JVM local SLOT, not its name
// (#5191).  `await` resolves a name to its current slot (`lookupSlot`) and looks
// the type up by that slot, so the unbox/checkcast coercion always matches the
// binding actually occupying the slot.  A name-keyed map instead let a nested
// `if`/`match` shadow's entry corrupt an outer, still-live binding's coercion at
// compile time regardless of which branch runs.  With block-scoped slot
// allocation (D-progress-603), a nested shadow of a still-live enclosing binding
// now gets a FRESH slot rather than aliasing the enclosing one, so slot-keying
// and the scope machinery agree — the general shadowing bug (`val t = 7; if c {
// val t = 99 }; t` once yielded `99`, now correctly yields `7`) is fixed on both
// backends, not a residual limitation.  `Unit` results are skipped (nothing to
// unbox); `Map.add` (= `Dictionary.Add`) throws on a duplicate key, so an existing
// entry for the slot is removed first (mirrors the `containsKey`+`remove` guard
// `recordVarGenericArgs` uses, #5185).  `t` is a clean parameter so the `JvmType`
// match is emitter-safe (see `isVoidJvmType`).
func putSpawnResultType(ctx: in FuncCtx, name: in String, t: in JvmType): Unit {
  if not isVoidJvmType(t) {
    match lookupSlot(ctx, name) {
      case Some(slot) -> {
        val key = spawnSlotKey(slot)
        if ctx.spawnResultTypes.containsKey(key) {
          ctx.spawnResultTypes.remove(key)
        }
        ctx.spawnResultTypes.add(key, t)
      }
      case None -> ()
    }
  }
}

// The `spawnResultTypes` map key for a JVM local slot (#5191).  A `slot:` prefix
// keeps these entries visually distinct from other string keys.
pub func spawnSlotKey(slot: in Int): String {
  "slot:" + toString(slot)
}

// When `deferBody` is a `scope { }`'s synthesized close-defer — exactly one
// statement, a call to the reserved close intrinsic with the executor local as
// its single positional argument (see `makeCloseDeferStmt`) — return the
// executor local's name.  `None` for every user-written defer.  The reserved
// `__lyric_` prefix guarantees no user function can produce this shape.
func scopeCloseDeferExecName(deferBody: in Block): Option[String] {
  if deferBody.statements.count != 1 {
    return None
  }
  match deferBody.statements[0].kind {
    case SExpr(e) -> {
      match e.kind {
        case ECall(fn, args) -> {
          match fn.kind {
            case EPath(p) -> {
              if p.segments.count == 1 and lastSegment(p) == jvmCloseExecutorIntrinsic() and args.count == 1 {
                val argExpr = match args[0] { case CAPositional(a) -> a; case CANamed(_, a, _) -> a }
                match argExpr.kind {
                  case EPath(ap) -> Some(value = lastSegment(ap))
                  case _ -> None
                }
              } else {
                None
              }
            }
            case _ -> None
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

// Emit `<execLocal>.shutdownNow()` (result discarded) — the exception-path
// counterpart of `lowerCloseExecutorIntrinsic`'s `close()`: interrupt every
// running spawned task and return WITHOUT waiting for them, so the pending
// rethrow propagates the scope body's Throwable immediately (#5569 item 3).
func emitAbortExecutor(ctx: in FuncCtx, insns: in List[LInsn], execName: in String): Unit {
  val execTy = JRef(className = "java/util/concurrent/ExecutorService")
  match lookupSlot(ctx, execName) {
    case Some(s) -> {
      emitLoad(insns, s, execTy)
      val noParams: List[JvmType] = newList()
      insns.add(
        LInvokeinterface(
          owner = "java/util/concurrent/ExecutorService",
          name = "shutdownNow",
          params = noParams,
          ret = JRef(className = "java/util/List"),
          argCount = 1
        )
      )
      insns.add(LPop)
    }
    case None -> panic("Jvm.Codegen: scope abort references unknown executor local '" + execName + "' (unreachable)")
  }
}

// Synthesize `defer { <jvmCloseExecutorIntrinsic>(<execName>) }` as an AST
// `Statement`, using `span` for every synthetic node so diagnostics (should any
// escape) point at the originating `scope`.
func makeCloseDeferStmt(execName: in String, span: in Span): Statement {
  val calleeSegs: List[String] = newList()
  calleeSegs.add(jvmCloseExecutorIntrinsic())
  val callee = Expr(kind = EPath(path = ModulePath(segments = calleeSegs, span = span)), span = span)
  val argSegs: List[String] = newList()
  argSegs.add(execName)
  val argExpr = Expr(kind = EPath(path = ModulePath(segments = argSegs, span = span)), span = span)
  val callArgs: List[CallArg] = newList()
  callArgs.add(CAPositional(expr = argExpr))
  val callExpr = Expr(kind = ECall(fn = callee, args = callArgs), span = span)
  val exprStmt = Statement(kind = SExpr(expr = callExpr), span = span)
  val deferStmts: List[Statement] = newList()
  deferStmts.add(exprStmt)
  val deferBlock = Block(statements = deferStmts, span = span)
  Statement(kind = SDefer(body = deferBlock), span = span)
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
  // A trailing `defer` (last statement of the value block — the block then yields
  // `Unit`) has an EMPTY protected region; emitting a catch-all for it produces an
  // illegal `[X, X)` exception-table range (ClassFormatError), exactly as in
  // `lowerDeferRegion`.  Nothing follows the defer, so run its block inline with no
  // handler and yield `JVoid` (#4878, #4885).
  if deferIdx + 1 >= n {
    lowerBlock(ctx, insns, deferBody)
    return JVoid
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
  // Stash the trailing value into a temp BEFORE closing the protected region so
  // the region-end (`normalReplayL`) frame sees an empty operand stack.  Leaving
  // the value on the stack across the LTryCatch `end_pc` label made the emitted
  // StackMapTable frame there (empty) disagree with the actual `{value}` stack —
  // a VerifyError ("Current frame's stack size doesn't match stackmap") on every
  // value-position `defer`.  The `emitStore` cannot throw, so lowering it inside
  // the region does not change exception semantics; the deferred-block replay
  // stays after `normalReplayL`, preserving the #2855 double-execution guard (#4878).
  var valSlot = -1
  if not suffixTerminated {
    match valTy {
      case JVoid -> ()
      case _ -> {
        valSlot = allocSlot(ctx, "__defer_val_" + freshLabel(ctx), valTy)
        emitStore(insns, valSlot, valTy)
      }
    }
  }
  insns.add(LLabel(name = normalReplayL))
  // Normal completion path: when the suffix did not unconditionally transfer
  // control (an early `return` / `break` / `continue` already replayed the
  // deferred block via `replayDefers`), run the deferred block and jump over the
  // handler.  The stashed value is reloaded AFTER `afterL` (below), not here, so
  // the `goto` reaches `afterL` with an empty operand stack: `afterL`'s only
  // live predecessor is this `goto` (the handler path diverges via `athrow`), and
  // the frame emitter derives a label's stack from its linear predecessor — an
  // `athrow`-terminated empty one — so a value carried across the `goto` would
  // disagree with the emitted empty frame (#4878).  When the suffix DID
  // terminate, the fall-off is unreachable — emit nothing so no dead code / stray
  // frame lands before the handler.
  if not suffixTerminated {
    lowerBlock(ctx, insns, deferBody)
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
    // Reload the stashed trailing value here — past the `afterL` join — so the
    // block still yields it to the caller while the `goto` above reaches
    // `afterL` with an empty stack (see the normal-path comment / #4878).
    match valTy {
      case JVoid -> ()
      case _ -> emitLoad(insns, valSlot, valTy)
    }
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
