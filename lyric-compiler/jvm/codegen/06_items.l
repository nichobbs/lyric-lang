//! jvm/codegen/06_items.l — Jvm.Codegen: function/record/union lowering and package entry.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! lowerFunc/lowerRecord/lowerUnion, makeFuncCtx helpers, async-generator
//! synthesis, IImpl pre-pass helpers, and the codegenPackage entry point.
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

// A module-level `val NAME = init` lowered once, up front (#2853).  The init is
// lowered with the shared `<clinit>` ctx so the field's JVM type is the *exact*
// type the value carries (`lowered`, then coerced to `field`).  Both the
// `getstatic` descriptor (`moduleVals`) and the emitted field (`LStaticVal`)
// read from the same `field` type here, so they can never disagree.
record LoweredModuleVal {
  name: String
  field: JvmType
  insns: List[LInsn]
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Function lowering.
// ─────────────────────────────────────────────────────────────────────────────
// Create a fresh FuncCtx for the given function.
func makeFuncCtx(
  pkgName: in String,
  className: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  retTy: in JvmType,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  val deferStack: List[Block] = newList()
  val loopDeferDepth: List[Int] = newList()
  val deferRanSlots: List[Int] = newList()
  FuncCtx(
    pkgName = pkgName,
    className = className,
    slots = slots,
    types = types,
    slotTicker = slotTicker,
    labelTicker = labelTicker,
    loopBreak = loopBreak,
    loopCont = loopCont,
    genClass = None,
    funcSigs = funcSigs,
    caseFields = caseFields,
    ctors = ctors,
    externTypes = externTypes,
    autoFfi = autoFfi,
    retTy = retTy,
    deferStack = deferStack,
    loopDeferDepth = loopDeferDepth,
    deferRanSlots = deferRanSlots,
    selfClass = None,
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    captureCellNames = newList(),
    varGenericArgs = newMap()
  )
}

// Create a FuncCtx for lowering a generator body (runBody instance method).
// Slot 0 = `this` (reserved); params start at slot 1.
func makeFuncCtxForGenerator(
  pkgName: in String,
  genClass: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  slotTicker.add(0)  // reserve slot 0 for `this`
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  val deferStack: List[Block] = newList()
  val loopDeferDepth: List[Int] = newList()
  val deferRanSlots: List[Int] = newList()
  FuncCtx(
    pkgName = pkgName,
    className = genClass,
    slots = slots,
    types = types,
    slotTicker = slotTicker,
    labelTicker = labelTicker,
    loopBreak = loopBreak,
    loopCont = loopCont,
    genClass = Some(value = genClass),
    funcSigs = funcSigs,
    caseFields = caseFields,
    ctors = ctors,
    externTypes = externTypes,
    autoFfi = autoFfi,
    retTy = JVoid,
    deferStack = deferStack,
    loopDeferDepth = loopDeferDepth,
    deferRanSlots = deferRanSlots,
    selfClass = None,
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    captureCellNames = newList(),
    varGenericArgs = newMap()
  )
}

// Create a FuncCtx for a protected-type entry / helper instance method.
// Slot 0 is reserved for `this`; `selfClass = Some(className)` so bare field
// references resolve to `getfield`/`putfield` on the receiver.
func makeFuncCtxInstance(
  pkgName: in String,
  className: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  retTy: in JvmType,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  slotTicker.add(0)  // reserve slot 0 for `this`
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  val deferStack: List[Block] = newList()
  val loopDeferDepth: List[Int] = newList()
  val deferRanSlots: List[Int] = newList()
  FuncCtx(
    pkgName = pkgName,
    className = className,
    slots = slots,
    types = types,
    slotTicker = slotTicker,
    labelTicker = labelTicker,
    loopBreak = loopBreak,
    loopCont = loopCont,
    genClass = None,
    funcSigs = funcSigs,
    caseFields = caseFields,
    ctors = ctors,
    externTypes = externTypes,
    autoFfi = autoFfi,
    retTy = retTy,
    deferStack = deferStack,
    loopDeferDepth = loopDeferDepth,
    deferRanSlots = deferRanSlots,
    selfClass = Some(value = className),
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    captureCellNames = newList(),
    varGenericArgs = newMap()
  )
}

// Emit a return, boxing a primitive `byte[]` (`JArray(JByte)`) into a
// `java.lang.Object[]` of boxed `java.lang.Byte` when the declared return
// type is the erased Lyric slice representation (`JArray(JRef Object)`).
// This is the return-side counterpart of `emitFfiCoerce`'s
// `[Ljava/lang/Object; -> [B` arg coercion: it lets a `_kernel_jvm` host
// declare `slice[Byte]` while internally producing a JDK `byte[]` (e.g. a
// `MessageDigest.digest` result), so the value crossing the function
// boundary actually matches the method's `[Ljava/lang/Object;` descriptor.
func emitReturnArrayCoerced(ctx: in FuncCtx, insns: in List[LInsn], tailTy: in JvmType, retTy: in JvmType): Unit {
  if isByteArrayToObjectArray(tailTy, retTy) {
    emitBoxByteArray(ctx, insns)
  } else {
    // Numeric / reference coercion so the tail value matches the declared
    // return descriptor (e.g. a plain `1.5` Double tail in a `: Float`
    // function narrows with d2f before `freturn`).
    coerceArgTo(insns, tailTy, retTy)
  }
  emitReturn(insns, retTy)
}

// True when `fromTy` is a primitive `byte[]` and `toTy` is the erased Lyric
// slice representation `java.lang.Object[]` (`JArray(JRef ...)`).
func isByteArrayToObjectArray(fromTy: in JvmType, toTy: in JvmType): Bool {
  match fromTy {
    case JArray(fe) -> {
      match fe {
        case JByte -> {
          match toTy {
            case JArray(te) -> {
              match te {
                case JRef(_) -> true
                case _ -> false
              }
            }
            case _ -> false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

// Replace a primitive `byte[]` on top of the operand stack with a freshly
// built `java.lang.Object[]` of boxed `java.lang.Byte` (the erased Lyric
// `slice[Byte]` representation).  The inverse of `emitFfiCoerce`'s
// `[Ljava/lang/Object; -> [B` arg coercion.  Generated bytecode mirrors the
// element-copy loop documented there.
func emitBoxByteArray(ctx: in FuncCtx, insns: in List[LInsn]): Unit {
  val srcSlot = allocSlot(ctx, "__box_arr_src_" + freshLabel(ctx), JArray(elem = JByte))
  val dstSlot = allocSlot(ctx, "__box_arr_dst_" + freshLabel(ctx), JArray(elem = JRef(className = "java/lang/Object")))
  val idxSlot = allocSlot(ctx, "__box_arr_idx_" + freshLabel(ctx), JInt)
  val lenSlot = allocSlot(ctx, "__box_arr_len_" + freshLabel(ctx), JInt)
  val loopL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  // `LAstoreAs` carries the array descriptor so the StackMapTable types the
  // slot as `[B` / `[Ljava/lang/Object;` rather than the plain-Object default
  // — `baload` / `aastore` on an Object-typed local is a VerifyError.
  insns.add(LAstoreAs(slot = srcSlot, className = "[B"))
  insns.add(LAload(slot = srcSlot))
  insns.add(LArraylength)
  insns.add(LAnewarray(className = "java/lang/Byte"))
  insns.add(LAstoreAs(slot = dstSlot, className = "[Ljava/lang/Object;"))
  // Hoist arraylength out of the loop condition — avoids re-fetching the
  // array header on every iteration (#2752).
  insns.add(LAload(slot = srcSlot))
  insns.add(LArraylength)
  insns.add(LIstore(slot = lenSlot))
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = idxSlot))
  insns.add(LLabel(name = loopL))
  insns.add(LIload(slot = idxSlot))
  insns.add(LIload(slot = lenSlot))
  insns.add(LIfIcmpge(label = endL))
  insns.add(LAload(slot = dstSlot))
  insns.add(LIload(slot = idxSlot))
  insns.add(LAload(slot = srcSlot))
  insns.add(LIload(slot = idxSlot))
  insns.add(LBaload)
  val voPs: List[JvmType] = newList()
  voPs.add(JByte)
  insns.add(
    LInvokestatic(owner = "java/lang/Byte", name = "valueOf", params = voPs, ret = JRef(className = "java/lang/Byte"))
  )
  insns.add(LAastore)
  insns.add(LIinc(slot = idxSlot, delta = 1))
  insns.add(LGoto(label = loopL))
  insns.add(LLabel(name = endL))
  insns.add(LAload(slot = dstSlot))
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. `out` / `inout` parameter prologue + descriptor (#1763).
// ─────────────────────────────────────────────────────────────────────────────
// True when any of `params` declares an `out`/`inout` mode.
func anyHolderParam(params: in List[Param]): Bool {
  var i = 0
  while i < params.count {
    if isHolderMode(params[i].mode) {
      return true
    }
    i = i + 1
  }
  false
}

// Build the JVM descriptor parameter types for a function/method, honouring
// `out`/`inout` modes: a holder parameter of element type T is declared as the
// single-element array type `JArray(T)` (the caller passes the holder array),
// while `in` parameters keep their value type.  `toJvm` maps a parameter's
// TypeExpr to its element JvmType (caller supplies the erased or non-erased
// mapper).  Index-aligned with `params`.
pub func holderAwareParamTypes(
  params: in List[Param],
  pkgName: in String,
  erase: in Bool,
  typeParams: in List[String],
  externTypes: in Map[String, String],
): List[JvmType] {
  val acc: List[JvmType] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    val elemTy = if erase {
      typeExprToJvmErased(p.ty, pkgName, typeParams)
    } else {
      typeExprToJvmExtern(p.ty, pkgName, externTypes)
    }
    if isHolderMode(p.mode) {
      acc.add(holderArrayType(elemTy))
    } else {
      acc.add(elemTy)
    }
    i = i + 1
  }
  acc
}

// Allocate JVM local slots for a static (free) function's parameters, set up
// `out`/`inout` holder bindings, and emit the entry-prologue unwrap for each
// holder parameter (#1763).  Parameter slots are allocated first, in
// declaration order, so they line up with the JVM calling convention; then a
// fresh value slot is allocated for each holder parameter and the holder array's
// element 0 is unwrapped into it.  The parameter name resolves to the value slot
// (a plain local), so reads need no array deref; `emitStoreLocalWriteThrough`
// mirrors writes back to the holder.  `collectModes`, when non-null, receives
// the declared modes index-aligned with the descriptor.
pub func setupStaticParamSlotsAndHolders(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  params: in List[Param],
  pkgName: in String,
  externTypes: in Map[String, String],
): Unit {
  // Pass 1: allocate the ABI slot for every parameter, in order.  A holder
  // parameter's ABI slot holds the incoming array; it is bound under a hidden
  // name so the visible parameter name can later map to the unwrapped value
  // slot.
  val holderIdx: List[Int] = newList()
  val holderSlots: List[Int] = newList()
  val holderElems: List[JvmType] = newList()
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    val elemTy = typeExprToJvmExtern(p.ty, pkgName, externTypes)
    if isHolderMode(p.mode) {
      val hs = allocSlot(ctx, "__holder$" + p.name, holderArrayType(elemTy))
      holderIdx.add(pi)
      holderSlots.add(hs)
      holderElems.add(elemTy)
    } else {
      allocSlot(ctx, p.name, elemTy)
    }
    pi = pi + 1
  }
  // Pass 2: unwrap each holder into a fresh value slot bound to the parameter
  // name, and record the holder binding so assignments write through.  The
  // unwrap instructions are appended to `insns` (the body list, still empty at
  // this point) so they run first.
  var hi = 0
  while hi < holderIdx.count {
    val name = params[holderIdx[hi]].name
    val elemTy = holderElems[hi]
    val hs = holderSlots[hi]
    val valueSlot = allocSlot(ctx, name, elemTy)
    ctx.holderArraySlot.add(valueSlot, hs)
    ctx.holderElemType.add(valueSlot, elemTy)
    insns.add(LAload(slot = hs))
    insns.add(LIconst(v = 0))
    emitHolderElemLoad(insns, elemTy)
    emitStore(insns, valueSlot, elemTy)
    hi = hi + 1
  }
}

// Allocate JVM local slots for an instance method's parameters (slot 0 = `this`
// is already reserved), set up `out`/`inout` holder bindings, and emit the
// entry-prologue unwrap for each holder parameter (#1763).  Identical in structure
// to `setupStaticParamSlotsAndHolders` but uses `typeExprToJvmErased` with the
// caller-supplied `typeParams` list so generic record methods erase type variables
// to `Object`, matching the descriptor emitted for the method.  For non-generic
// methods pass `newList()` for `typeParams`; the result is the same as
// `typeExprToJvm` (no-op erase with an empty list).
pub func setupInstanceParamSlotsAndHolders(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  params: in List[Param],
  pkgName: in String,
  typeParams: in List[String],
): Unit {
  val holderIdx: List[Int] = newList()
  val holderSlots: List[Int] = newList()
  val holderElems: List[JvmType] = newList()
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    val elemTy = typeExprToJvmErased(p.ty, pkgName, typeParams)
    if isHolderMode(p.mode) {
      val hs = allocSlot(ctx, "__holder$" + p.name, holderArrayType(elemTy))
      holderIdx.add(pi)
      holderSlots.add(hs)
      holderElems.add(elemTy)
    } else {
      allocSlot(ctx, p.name, elemTy)
    }
    pi = pi + 1
  }
  var hi = 0
  while hi < holderIdx.count {
    val name = params[holderIdx[hi]].name
    val elemTy = holderElems[hi]
    val hs = holderSlots[hi]
    val valueSlot = allocSlot(ctx, name, elemTy)
    ctx.holderArraySlot.add(valueSlot, hs)
    ctx.holderElemType.add(valueSlot, elemTy)
    insns.add(LAload(slot = hs))
    insns.add(LIconst(v = 0))
    emitHolderElemLoad(insns, elemTy)
    emitStore(insns, valueSlot, elemTy)
    hi = hi + 1
  }
}

// Collect names referenced inside any lambda in a block statement.
func collectInLambdaNamesBlockStmt(s: in Statement, acc: in List[String]): Unit {
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
    case SExpr(e) -> collectInLambdaNamesExpr(e, acc)
    case SThrow(e) -> collectInLambdaNamesExpr(e, acc)
    case SWhile(_, cond, body) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesBlockBody(body, acc)
    }
    case SLoop(_, body) -> collectInLambdaNamesBlockBody(body, acc)
    case SFor(_, _, iter, body) -> {
      collectInLambdaNamesExpr(iter, acc)
      collectInLambdaNamesBlockBody(body, acc)
    }
    case STry(body, catches, finally_) -> {
      collectInLambdaNamesBlockBody(body, acc)
      var ci = 0
      while ci < catches.count {
        collectInLambdaNamesBlockBody(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> collectInLambdaNamesBlockBody(fb, acc)
        case None -> ()
      }
    }
    case SDefer(body) -> collectInLambdaNamesBlockBody(body, acc)
    case SScope(_, body) -> collectInLambdaNamesBlockBody(body, acc)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> collectInLambdaNamesExpr(e, acc)
        case None -> ()
      }
    }
    case _ -> ()
  }
}

func collectInLambdaNamesBlockBody(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectInLambdaNamesBlockStmt(b.statements[i], acc)
    i = i + 1
  }
}

// Compute the pre-pass set of `var` names referenced inside lambdas
// in the function body.  These must be hoisted to heap cells for by-ref capture.
func computeHoistedVarNamesJvm(decl: in FunctionDecl, mutableVars: in Map[String, Bool]): List[String] {
  val inLambdaNames: List[String] = newList()
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(blk) -> collectInLambdaNamesBlockBody(blk, inLambdaNames)
        case FBExpr(e) -> collectInLambdaNamesExpr(e, inLambdaNames)
      }
    }
    case None -> ()
  }
  // Keep only the names that are `var` declarations in this function.
  val hoisted: List[String] = newList()
  var i = 0
  while i < inLambdaNames.count {
    val nm = inLambdaNames[i]
    if mutableVars.containsKey(nm) and not nameInList(hoisted, nm) {
      hoisted.add(nm)
    }
    i = i + 1
  }
  hoisted
}

// Collect all `var` declarations in a function body.
func collectMutableVarsExpr(e: in Expr, acc: in Map[String, Bool]): Unit {
  match e.kind {
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      match thenBranch {
        case EOBExpr(ex) -> collectMutableVarsExpr(ex, acc)
        case EOBBlock(blk) -> collectMutableVarsBlock(blk, acc)
      }
      match elseBranch {
        case Some(eb) -> {
          match eb {
            case EOBExpr(ex) -> collectMutableVarsExpr(ex, acc)
            case EOBBlock(blk) -> collectMutableVarsBlock(blk, acc)
          }
        }
        case None -> ()
      }
    }
    case EMatch(scr, arms) -> {
      var ai = 0
      while ai < arms.count {
        match arms[ai].body {
          case EOBExpr(ex) -> collectMutableVarsExpr(ex, acc)
          case EOBBlock(blk) -> collectMutableVarsBlock(blk, acc)
        }
        ai = ai + 1
      }
    }
    case EBlock(blk) -> {
      collectMutableVarsBlock(blk, acc)
    }
    case EUnsafe(blk) -> {
      collectMutableVarsBlock(blk, acc)
    }
    case _ -> ()
  }
}

func collectMutableVarsBlock(b: in Block, acc: in Map[String, Bool]): Unit {
  var i = 0
  while i < b.statements.count {
    match b.statements[i].kind {
      case SLocal(binding) -> {
        match binding {
          case LBVar(name, _, _) -> {
            if not acc.containsKey(name) {
              acc.add(name, true)
            }
          }
          case LBVal(_, _, init) -> {
            collectMutableVarsExpr(init, acc)
          }
          case LBLet(_, _, init) -> {
            collectMutableVarsExpr(init, acc)
          }
          case _ -> ()
        }
      }
      case SExpr(e) -> collectMutableVarsExpr(e, acc)
      case SWhile(_, _, body) -> collectMutableVarsBlock(body, acc)
      case SLoop(_, body) -> collectMutableVarsBlock(body, acc)
      case SFor(_, _, _, body) -> collectMutableVarsBlock(body, acc)
      case STry(body, catches, finally_) -> {
        collectMutableVarsBlock(body, acc)
        var ci = 0
        while ci < catches.count {
          collectMutableVarsBlock(catches[ci].body, acc)
          ci = ci + 1
        }
        match finally_ {
          case Some(fb) -> collectMutableVarsBlock(fb, acc)
          case None -> ()
        }
      }
      case SDefer(body) -> collectMutableVarsBlock(body, acc)
      case SScope(_, body) -> collectMutableVarsBlock(body, acc)
      case _ -> ()
    }
    i = i + 1
  }
}

pub func lowerFunc(
  decl: in FunctionDecl,
  pkgName: in String,
  className: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LFunc {
  val retTy = match decl.ret { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }

  val ctx = makeFuncCtx(
    pkgName,
    className,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    retTy,
    moduleVals,
    opaqueTypes,
    closureAcc
  )

  // Hoisting pre-pass: detect `var` bindings referenced inside lambdas.
  // These must be hoisted to heap cells for by-ref capture (epic #1877 Stage 2).
  val mutableVars: Map[String, Bool] = newMap()
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(blk) -> collectMutableVarsBlock(blk, mutableVars)
        case FBExpr(_) -> ()
      }
    }
    case None -> ()
  }
  val hoistedVars = computeHoistedVarNamesJvm(decl, mutableVars)
  var hvi = 0
  while hvi < hoistedVars.count {
    ctx.hoistedVarNames.add(hoistedVars[hvi])
    hvi = hvi + 1
  }

  val insns: List[LInsn] = newList()

  // Allocate slots for parameters and set up any `out`/`inout` holder bindings;
  // the holder unwrap-prologue (if any) is emitted into `insns` first (#1763).
  setupStaticParamSlotsAndHolders(ctx, insns, decl.params, pkgName, externTypes)

  // Lower the body. @externTarget annotation takes priority over any syntactic
  // body form — a conventional `= ()` stub on an extern declaration must route
  // to lowerExternTargetBody, not the unit-literal path (which leaves the
  // operand stack empty and causes a VerifyError on the typed return).
  // Mirrors the MSIL hasExternTargetMsil guard in the MSIL emitter.
  match findExternTarget(decl) {
    case Some(target) -> {
      lowerExternTargetBody(decl, ctx, insns, target);
      ()
    }
    case None -> {
      match decl.body {
        case Some(body) -> {
          match body {
            case FBBlock(block) -> {
              match retTy {
                case JVoid -> {
                  // Void function: every statement (including a trailing
                  // expression) is lowered in statement position and its value
                  // discarded; a bare `return` closes the method.
                  lowerBlock(ctx, insns, block)
                }
                case _ -> {
                  // Non-void function: the block's trailing expression IS the
                  // return value, so lower it in expression position (leaving its
                  // value on the stack) rather than popping it.  Using statement-
                  // mode `lowerBlock` here popped the tail, leaving the stack empty
                  // for the synthesised `ireturn` (VerifyError: operand stack
                  // underflow).
                  val tailTy = lowerBlockExpr(ctx, insns, block)
                  // `try { … } finally { … }` in tail position falls back to
                  // statement-mode lowering inside `lowerBlockExpr` and reports
                  // `JVoid` (value discarded by the fallback).  Emitting a typed
                  // `ireturn`/`areturn` next would underflow the operand stack
                  // (VerifyError) — so a tail value of `JVoid` requires the
                  // value-less `return` instead (#1683).
                  //
                  // `blockTerminates(block)` covers the case where the tail is an
                  // `if`/`else` (or `match`) whose arms all `return`: the lowering
                  // leaves the unreachable join label as the last instruction, so
                  // `endsWithReturn` cannot see the termination and would otherwise
                  // append a stray void `return` (#2870).
                  if not endsWithReturn(insns) and not blockTerminates(block) {
                    match tailTy {
                      case JVoid -> emitReturn(insns, JVoid)
                      case _ -> emitReturnArrayCoerced(ctx, insns, tailTy, retTy)
                    }
                  }
                }
              }
              // For the void path the inner `lowerBlock` did not leave a value on
              // the stack; close the method with `return` if it didn't already end
              // in one.  The non-void path returned above.
              if retTy == JVoid and not endsWithReturn(insns) and not blockTerminates(block) {
                emitReturn(insns, retTy)
              }
            }
            case FBExpr(e) -> {
              val ty = lowerExpr(ctx, insns, e)
              emitReturnArrayCoerced(ctx, insns, ty, retTy)
            }
          }
        }
        case None -> emitReturn(insns, retTy)
      }
    }
  }

  // Determine param types for the LFunc descriptor.  An `out`/`inout`
  // parameter is declared as a single-element holder array (#1763).
  val noTypeParams: List[String] = newList()
  val paramTypes = holderAwareParamTypes(decl.params, pkgName, false, noTypeParams, externTypes)

  // Synthesised @derive names like "Point.equals" carry a "TypeName." prefix
  // that JVMS §4.2.2 forbids in unqualified method names.  Strip everything up
  // to and including the last dot so the classfile method name is just the
  // short member name ("equals").  The call site in lowerMethodCall uses the
  // plain Lyric memberName as the invokestatic target — both sides must agree.
  var jvmFuncName = decl.name
  match lastIndexOf(decl.name, ".") {
    case Some(dotIdx) -> {
      jvmFuncName = decl.name.substring(dotIdx + 1, decl.name.length - dotIdx - 1)
    }
    case None -> ()
  }

  LFunc(
    flags = 0x0009,
    name = jvmFuncName,
    params = paramTypes,
    ret = retTy,
    insns = insns,
    maxStack = 16,
    maxLocals = ctx.slotTicker.count
  )
}

// Check whether the last meaningful instruction in a list is a return.
func endsWithReturn(insns: in List[LInsn]): Bool {
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
      case LDreturn -> {
        return true
      }
      case LAreturn -> {
        return true
      }
      case LAthrow -> {
        return true
      }
      case LNop -> {
        i = i - 1
      }
      // `LTryCatch` is a zero-width meta-instruction (an exception-table entry)
      // emitted after a defer/try region's rethrowing handler; skip past it to
      // find the real terminal instruction (the handler's `athrow`).
      case LTryCatch(_, _, _, _) -> {
        i = i - 1
      }
      // A label may be a branch target from code above (e.g. the after-label
      // of a match expression), so we cannot treat instructions before it as
      // the effective end of the method.  Stop scanning and report "no terminal".
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

// AST-level terminator analysis (mirrors the MSIL backend's intent: a body that
// unconditionally transfers control on every path must NOT have an implicit
// trailing `return` appended after it).  `endsWithReturn` inspects the emitted
// instruction stream and stops at a label, so it cannot see that an `if`/`else`
// (or `match`) whose arms all `return` is terminating — the lowering leaves the
// (unreachable) join label as the last instruction.  Appending a void `return`
// there produces a stray, wrong-typed return that fails JVM verification (#2870).
// These predicates close that gap by reasoning over the source AST instead.
// True when executing `block` always transfers control away (every path ends in
// `return` / `throw`), so the fall-off point after it is unreachable.
pub func blockTerminates(block: in Block): Bool {
  val n = block.statements.count
  if n == 0 {
    return false
  }
  stmtTerminates(block.statements[n - 1])
}

// True when executing `stmt` always transfers control away on every path.
func stmtTerminates(stmt: in Statement): Bool {
  match stmt.kind {
    case SReturn(_) -> true
    case SThrow(_) -> true
    case SBreak(_) -> true
    case SContinue(_) -> true
    case SExpr(e) -> exprTerminates(e)
    case _ -> false
  }
}

// True when evaluating `e` always transfers control away on every path.  Covers
// the `if`/`else` and `match` expression forms whose every arm terminates; an
// `if` with no `else` is NOT terminating (the false path falls through).
func exprTerminates(e: in Expr): Bool {
  match e.kind {
    case EBlock(block) -> blockTerminates(block)
    case EIf(_, thenBranch, elseBranchOpt, _) -> {
      match elseBranchOpt {
        case None -> false
        case Some(elseBranch) -> exprOrBlockTerminates(thenBranch) and exprOrBlockTerminates(elseBranch)
      }
    }
    case EMatch(_, arms) -> {
      if arms.count == 0 {
        return false
      }
      var i = 0
      while i < arms.count {
        if not exprOrBlockTerminates(arms[i].body) {
          return false
        }
        i = i + 1
      }
      true
    }
    case _ -> false
  }
}

// True when the `then`/`else`/match-arm body always transfers control away.
func exprOrBlockTerminates(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> exprTerminates(e)
    case EOBBlock(block) -> blockTerminates(block)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Record lowering.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerRecord(
  decl: in RecordDecl,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LRecord {
  val className = pkgName + "/" + decl.name
  // Generic type params erase to `Object` (docs/44 M-1 / Q-J001) so a `T`-typed
  // field on a generic record (e.g. `Box[T] { value: T }`) is declared `Object`.
  val tps = genericParamNames(decl.generics)

  val fields: List[LField] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        fields.add(
          LField(
            flags = 0x0001,
            // public
            name = f.name,
            fieldType = typeExprToJvmErasedExtern(f.ty, pkgName, tps, externTypes)
          )
        )
      }
      case RMInvariant(_) -> {
      }
      case RMFunc(_) -> {
      }
    }
    i = i + 1
  }

  // The record's `<init>(field…)V` constructor is synthesised from the field
  // list by `Jvm.Lowering.lowerRecord` (LRecord → ClassFile); it is NOT added
  // here, otherwise the class would carry two identical `<init>` methods
  // (ClassFormatError "Duplicate method <init>" at load).
  val methods: List[LFunc] = newList()

  // Lower any RMFunc members as true non-static instance methods (slot 0 =
  // `this`, flags 0x0001).  A record method call `rec.m(args)` lowers to
  // `invokevirtual <recordClass>.m` at the call site (J3 `<class>#<method>`
  // registry), so emitting them static (as a top-level `func`) makes the JVM
  // reject the call ("Expecting non-static method") (#2865).  `lowerRecordMethod`
  // sets `selfClass` so bare field references resolve through `this`, and erases
  // the record's generic type params to `Object` in the descriptor (docs/44 J4).
  // A body-less RMFunc signature is skipped (records carry no abstract methods).
  // Lambdas inside a record method still register their synthesised closure
  // inner class into the package-shared accumulator (#2864) via the threaded
  // `closureAcc`.
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case RMFunc(fn) -> {
        match fn.body {
          case Some(b) -> {
            methods.add(
              lowerRecordMethod(
                className,
                fn,
                b,
                pkgName,
                tps,
                funcSigs,
                caseFields,
                ctors,
                externTypes,
                autoFfi,
                moduleVals,
                opaqueTypes,
                closureAcc
              )
            )
          }
          case None -> ()
        }
      }
      case _ -> {
      }
    }
    mi = mi + 1
  }

  LRecord(className = className, fields = fields, methods = methods, implementsIfaces = newList())
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Union lowering.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerUnion(decl: in UnionDecl, pkgName: in String, externTypes: in Map[String, String]): LSealedUnion {
  val baseName = pkgName + "/" + decl.name
  // Generic type params erase to `Object` (no reified generics on the JVM —
  // docs/44 M-1 / Q-J001), so a `T`-typed payload field is declared `Object`.
  val tps = genericParamNames(decl.generics)

  val cases: List[LSealedCase] = newList()
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    val caseFields: List[LField] = newList()
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(
            LField(flags = 0x0001, name = name, fieldType = typeExprToJvmErasedExtern(ty, pkgName, tps, externTypes))
          )
        }
        case UFPos(ty, _) -> {
          caseFields.add(
            LField(
              flags = 0x0001,
              name = "field" + toString(fi),
              fieldType = typeExprToJvmErasedExtern(ty, pkgName, tps, externTypes)
            )
          )
        }
      }
      fi = fi + 1
    }
    cases.add(LSealedCase(caseName = c.name, fields = caseFields))
    i = i + 1
  }

  LSealedUnion(baseName = baseName, cases = cases)
}

// ─────────────────────────────────────────────────────────────────────────────
// §10b. Protected-type and wire-block lowering (J3 M-3).
// ─────────────────────────────────────────────────────────────────────────────
// Build an instance method (slot 0 = `this`) for a protected-type entry/helper.
// `selfClass` is set so bare field references resolve to `getfield`/`putfield`
// on the receiver.  Parameters start at slot 1; the body is lowered with normal
// return semantics (an entry's early `return e` emits the typed return opcode).
// Shared body-lowering tail for non-static instance methods (protected-type
// entries and record `RMFunc` methods).  Emits `body` into `insns` given the
// already-configured `ctx` and `retTy`, appending a trailing `return` only
// when the block does not already terminate via `endsWithReturn` /
// `blockTerminates` (#2870, #2874).  Extracted to prevent the two call-sites
// (`lowerProtectedMethod`, `lowerRecordMethod`) from drifting.
func lowerInstanceMethodBody(ctx: in FuncCtx, insns: in List[LInsn], body: in FunctionBody, retTy: in JvmType): Unit {
  match body {
    case FBBlock(block) -> {
      match retTy {
        case JVoid -> {
          lowerBlock(ctx, insns, block)
          if not endsWithReturn(insns) and not blockTerminates(block) {
            emitReturn(insns, JVoid)
          }
        }
        case _ -> {
          val tailTy = lowerBlockExpr(ctx, insns, block)
          if not endsWithReturn(insns) and not blockTerminates(block) {
            match tailTy {
              case JVoid -> emitReturn(insns, JVoid)
              case _ -> {
                coerceArgTo(insns, tailTy, retTy)
                emitReturn(insns, retTy)
              }
            }
          }
        }
      }
    }
    case FBExpr(e) -> {
      val ty = lowerExpr(ctx, insns, e)
      coerceArgTo(insns, ty, retTy)
      emitReturn(insns, retTy)
    }
  }
}

func lowerProtectedMethod(
  className: in String,
  flags: in Int,
  name: in String,
  params: in List[Param],
  retOpt: in Option[TypeExpr],
  body: in FunctionBody,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LFunc {
  val retTy = match retOpt { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }
  // Lambdas inside a protected-type entry/helper register their synthesised
  // closure inner class into the package-shared accumulator (#2864), so an
  // `ELambda` here emits `<pkg>$Lambda$<n>` into the package output and works
  // end-to-end — exactly as in a top-level `func` body.
  val ctxSelf = makeFuncCtxInstance(
    pkgName,
    className,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    retTy,
    moduleVals,
    opaqueTypes,
    closureAcc
  )
  val insns: List[LInsn] = newList()
  val noTps: List[String] = newList()
  val paramTypes = holderAwareParamTypes(params, pkgName, true, noTps, externTypes)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, params, pkgName, noTps)
  lowerInstanceMethodBody(ctxSelf, insns, body, retTy)
  LFunc(flags = flags, name = name, params = paramTypes, ret = retTy, insns = insns, maxStack = 0, maxLocals = 0)
}

func stripLeadingSelfParam(params: in List[Param]): List[Param] {
  val res: List[Param] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    val isSelf = i == 0 and p.name == "self"
    if not isSelf {
      res.add(p)
    }
    i = i + 1
  }
  res
}

// Build a record instance method (`RMFunc`) as a true non-static instance method
// (slot 0 = `this`, flags 0x0001).  A record method call `rec.m(args)` lowers to
// `invokevirtual <recordClass>.m` at the call site (`lowerMethodCall`, J3
// `<class>#<method>` registry), so the method must be an instance method or the
// JVM rejects the call ("Expecting non-static method") (#2865).  `selfClass` is
// set (via `makeFuncCtxInstance`) so bare field references inside the body
// resolve through `this` (`getfield`/`putfield`), mirroring protected-type
// entries and `impl` methods.  Generic type params (`typeParams`) erase to
// `Object` in param/return descriptors so the emitted method byte-matches the
// registered `<class>#<method>` sig, applying the J4 erased-generics
// boxing/checkcast that `coerceArgTo` already performs on the tail value.
func lowerRecordMethod(
  className: in String,
  fn: in FunctionDecl,
  body: in FunctionBody,
  pkgName: in String,
  typeParams: in List[String],
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LFunc {
  val retTy = match fn.ret { case Some(te) -> typeExprToJvmErased(te, pkgName, typeParams); case None -> JVoid }
  val ctxSelf = makeFuncCtxInstance(
    pkgName,
    className,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    retTy,
    moduleVals,
    opaqueTypes,
    closureAcc
  )
  val insns: List[LInsn] = newList()
  val noExts: Map[String, String] = newMap()
  val filteredParams = stripLeadingSelfParam(fn.params)
  val paramTypes = holderAwareParamTypes(filteredParams, pkgName, true, typeParams, noExts)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, filteredParams, pkgName, typeParams)
  lowerInstanceMethodBody(ctxSelf, insns, body, retTy)
  LFunc(flags = 0x0001, name = fn.name, params = paramTypes, ret = retTy, insns = insns, maxStack = 0, maxLocals = 0)
}

// Build an `impl T for X` interface method as a true non-static instance method
// (slot 0 = `this`, flags 0x0001) so the JVM class for X actually implements T.
// Call sites that dispatch through the registered `<targetClass>#<method>` sig
// emit `invokevirtual targetClass.method`; bare sibling calls inside the body
// (`m()` or `self.m()`) both reach here via `selfClass = Some(targetClass)`.
func lowerImplMethod(
  targetClass: in String,
  fn: in FunctionDecl,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LFunc {
  val body = match fn.body {
    case Some(b) -> b
    case None -> panic("lowerImplMethod: impl method has no body — interface-only declaration reached codegen")
  }
  val retTy = match fn.ret { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }
  val ctxSelf = makeFuncCtxInstance(
    pkgName,
    targetClass,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    retTy,
    moduleVals,
    opaqueTypes,
    closureAcc
  )
  val insns: List[LInsn] = newList()
  val noTpsImpl: List[String] = newList()
  val paramTypes = holderAwareParamTypes(fn.params, pkgName, true, noTpsImpl, externTypes)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, fn.params, pkgName, noTpsImpl)
  lowerInstanceMethodBody(ctxSelf, insns, body, retTy)
  LFunc(flags = 0x0001, name = fn.name, params = paramTypes, ret = retTy, insns = insns, maxStack = 0, maxLocals = 0)
}

// Build a protected-type class as a record-shaped `LPRecord`: data fields plus
// the entry / helper methods as instance methods.  This mirrors the MSIL
// backend (`lowerProtectedMsil`), which also emits protected types as records;
// real ReentrantLock-based mutual exclusion is a documented cross-target gap
// (MSIL "Phase R6", JVM `lowerProtected` Path-A) tracked in #855 / #1833.  The
// record shape is required so the field-args constructor matches how protected
// types are constructed (`TokenBucket(field = …, …)`), unlike the no-arg
// `lowerProtected` Path-A constructor.
func buildProtected(
  decl: in ProtectedTypeDecl,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LPackageItem {
  val className = pkgName + "/" + decl.name
  val fields: List[LField] = newList()
  val methods: List[LFunc] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _) -> fields.add(LField(flags = 0x0001, name = name, fieldType = typeExprToJvmExtern(ty, pkgName, externTypes)))
          case PFLet(name, ty, _, _) -> fields.add(LField(flags = 0x0001, name = name, fieldType = typeExprToJvmExtern(ty, pkgName, externTypes)))
          case PFImmutable(f) -> fields.add(LField(flags = 0x0001, name = f.name, fieldType = typeExprToJvmExtern(f.ty, pkgName, externTypes)))
        }
      }
      case PMEntry(ed) -> {
        methods.add(
          lowerProtectedMethod(
            className,
            0x0001,
            ed.name,
            ed.params,
            ed.ret,
            ed.body,
            pkgName,
            funcSigs,
            caseFields,
            ctors,
            externTypes,
            autoFfi,
            moduleVals,
            opaqueTypes,
            closureAcc
          )
        )
      }
      case PMFunc(fn) -> {
        match fn.body {
          case Some(b) -> {
            methods.add(
              lowerProtectedMethod(
                className,
                0x0001,
                fn.name,
                fn.params,
                fn.ret,
                b,
                pkgName,
                funcSigs,
                caseFields,
                ctors,
                externTypes,
                autoFfi,
                moduleVals,
                opaqueTypes,
                closureAcc
              )
            )
          }
          case None -> ()
        }
      }
      case PMInvariant(_) -> ()
    }
    mi = mi + 1
  }
  LPRecord(rec = LRecord(className = className, fields = fields, methods = methods, implementsIfaces = newList()))
}

// ─────────────────────────────────────────────────────────────────────────────
// §10c. Wire topological sort (JVM) — mirrors MSIL `wireTopoSortMsil`.
// ─────────────────────────────────────────────────────────────────────────────
// Result of wire topological sort.
union WireTopoResult {
  case WTRSorted(members: List[WireMember])
  case WTRCycle(path: List[String])
}

// Extract the set of wire member names that an expression directly references.
func wireExprDepsJvm(e: in Expr, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if knownNames.containsKey(name) {
          acc.add(name)
        }
      }
    }
    case ECall(fn, args) -> {
      wireExprDepsJvm(fn, knownNames, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(expr) -> wireExprDepsJvm(expr, knownNames, acc)
          case CANamed(_, value, _) -> wireExprDepsJvm(value, knownNames, acc)
        }
        ai = ai + 1
      }
    }
    case EMember(receiver, _) -> wireExprDepsJvm(receiver, knownNames, acc)
    case EBlock(block) -> wireBlockDepsJvm(block, knownNames, acc)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      wireExprDepsJvm(cond, knownNames, acc)
      wireExprOrBlockDepsJvm(thenBranch, knownNames, acc)
      match elseBranch {
        case Some(eb) -> wireExprOrBlockDepsJvm(eb, knownNames, acc)
        case None -> ()
      }
    }
    case EParen(inner) -> wireExprDepsJvm(inner, knownNames, acc)
    case EBinop(_, lhs, rhs) -> {
      wireExprDepsJvm(lhs, knownNames, acc)
      wireExprDepsJvm(rhs, knownNames, acc)
    }
    case EPrefix(_, operand) -> wireExprDepsJvm(operand, knownNames, acc)
    case _ -> ()
  }
}

func wireExprOrBlockDepsJvm(eob: in ExprOrBlock, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match eob {
    case EOBExpr(expr) -> wireExprDepsJvm(expr, knownNames, acc)
    case EOBBlock(block) -> wireBlockDepsJvm(block, knownNames, acc)
  }
}

func wireBlockDepsJvm(block: in Block, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  var si = 0
  while si < block.statements.count {
    wireStmtDepsJvm(block.statements[si], knownNames, acc)
    si = si + 1
  }
}

func wireStmtDepsJvm(s: in Statement, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match s.kind {
    case SExpr(expr) -> wireExprDepsJvm(expr, knownNames, acc)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> wireExprDepsJvm(init, knownNames, acc)
        case LBLet(_, _, init) -> wireExprDepsJvm(init, knownNames, acc)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> wireExprDepsJvm(init, knownNames, acc); case None -> () }
      }
    }
    case SAssign(target, _, value) -> {
      wireExprDepsJvm(target, knownNames, acc)
      wireExprDepsJvm(value, knownNames, acc)
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> wireExprDepsJvm(e, knownNames, acc); case None -> () }
    case _ -> ()
  }
}

// Extract the init expression from a WireMember (None for members with no init).
func wireMemberInitJvm(m: in WireMember): Option[Expr] {
  match m {
    case WMSingleton(_, _, init, _) -> Some(value = init)
    case WMLocal(_, _, init, _) -> Some(value = init)
    case WMScoped(_, _, _, init, _) -> Some(value = init)
    case WMBind(_, provider, _) -> Some(value = provider)
    case WMProvided(_, _, _) -> None
    case WMExpose(_, _) -> None
  }
}

// Name of a WireMember, or "" for unnamed members.
func wireMemberNameJvm(m: in WireMember): String {
  match m {
    case WMSingleton(name, _, _, _) -> name
    case WMLocal(name, _, _, _) -> name
    case WMScoped(_, name, _, _, _) -> name
    case WMBind(iface, _, _) -> match iface.kind { case TRef(path) -> lastSegment(path); case _ -> "__bind" }
    case WMProvided(name, _, _) -> name
    case WMExpose(name, _) -> name
  }
}

// Topologically sort wire members using Kahn's BFS algorithm.  Returns
// WTRSorted with members in dependency order, or WTRCycle when a cycle exists.
// WMExpose members share names with the WMSingleton/WMLocal they expose and
// have no init expression, so they are excluded from the graph and appended
// after sorting to avoid duplicate-key crashes and false cycle detection.
func wireTopoSortJvm(members: in List[WireMember]): WireTopoResult {
  val sortable: List[WireMember] = newList()
  val exposeMembers: List[WireMember] = newList()
  var sep = 0
  while sep < members.count {
    match members[sep] {
      case WMExpose(_, _) -> exposeMembers.add(members[sep])
      case _ -> sortable.add(members[sep])
    }
    sep = sep + 1
  }

  val nameToIdx: Map[String, Int] = newMap()
  val knownNames: Map[String, Bool] = newMap()
  var i = 0
  while i < sortable.count {
    val n = wireMemberNameJvm(sortable[i])
    if n.length > 0 and not nameToIdx.containsKey(n) {
      nameToIdx.add(n, i)
      knownNames.add(n, true)
    }
    i = i + 1
  }

  val depsOf: Map[String, List[String]] = newMap()
  var j = 0
  while j < sortable.count {
    val n = wireMemberNameJvm(sortable[j])
    val initDeps: List[String] = newList()
    match wireMemberInitJvm(sortable[j]) {
      case Some(e) -> {
        val raw: List[String] = newList()
        wireExprDepsJvm(e, knownNames, raw)
        var di = 0
        while di < raw.count {
          if raw[di] != n {
            initDeps.add(raw[di])
          }
          di = di + 1
        }
      }
      case None -> ()
    }
    if not depsOf.containsKey(n) {
      depsOf.add(n, initDeps)
    }
    j = j + 1
  }

  val inDegree: Map[String, Int] = newMap()
  var k = 0
  while k < sortable.count {
    val n = wireMemberNameJvm(sortable[k])
    if not inDegree.containsKey(n) {
      inDegree.add(n, 0)
    }
    k = k + 1
  }
  var m2 = 0
  while m2 < sortable.count {
    match wireMemberInitJvm(sortable[m2]) {
      case None -> ()
      case Some(_) -> {
        val n = wireMemberNameJvm(sortable[m2])
        match mapGet(depsOf, n) {
          case Some(dList) -> {
            val seen: Map[String, Bool] = newMap()
            var di = 0
            while di < dList.count {
              val dep = dList[di]
              if not seen.containsKey(dep) {
                seen.add(dep, true)
                match mapGet(inDegree, n) {
                  case Some(cur) -> {
                    inDegree.remove(n)
                    inDegree.add(n, cur + 1)
                  }
                  case None -> inDegree.add(n, 1)
                }
              }
              di = di + 1
            }
          }
          case None -> ()
        }
      }
    }
    m2 = m2 + 1
  }

  val queue: List[String] = newList()
  var qi = 0
  while qi < sortable.count {
    val n = wireMemberNameJvm(sortable[qi])
    match mapGet(inDegree, n) {
      case Some(deg) -> {
        if deg == 0 {
          queue.add(n)
        }
      }
      case None -> queue.add(n)
    }
    qi = qi + 1
  }

  val sortedNames: List[String] = newList()
  var head = 0
  while head < queue.count {
    val current = queue[head]
    sortedNames.add(current)
    var ri = 0
    while ri < sortable.count {
      val rn = wireMemberNameJvm(sortable[ri])
      match mapGet(depsOf, rn) {
        case Some(dList) -> {
          var found = false
          var dj = 0
          while dj < dList.count {
            if dList[dj] == current {
              found = true
            }
            dj = dj + 1
          }
          if found {
            match mapGet(inDegree, rn) {
              case Some(deg) -> {
                val newDeg = deg - 1
                inDegree.remove(rn)
                inDegree.add(rn, newDeg)
                if newDeg == 0 {
                  queue.add(rn)
                }
              }
              case None -> ()
            }
          }
        }
        case None -> ()
      }
      ri = ri + 1
    }
    head = head + 1
  }

  if sortedNames.count < sortable.count {
    val sortedSet: Map[String, Bool] = newMap()
    var si = 0
    while si < sortedNames.count {
      sortedSet.add(sortedNames[si], true)
      si = si + 1
    }
    val cyclePath: List[String] = newList()
    var ci = 0
    while ci < sortable.count {
      val cn = wireMemberNameJvm(sortable[ci])
      if not sortedSet.containsKey(cn) {
        cyclePath.add(cn)
      }
      ci = ci + 1
    }
    return WTRCycle(path = cyclePath)
  }

  val sorted: List[WireMember] = newList()
  var sni = 0
  while sni < sortedNames.count {
    val sn = sortedNames[sni]
    match mapGet(nameToIdx, sn) {
      case Some(idx) -> sorted.add(sortable[idx])
      case None -> ()
    }
    sni = sni + 1
  }
  var ei = 0
  while ei < exposeMembers.count {
    sorted.add(exposeMembers[ei])
    ei = ei + 1
  }
  WTRSorted(members = sorted)
}

// Build a wire-block DI factory class.  Each `singleton` / `local` binding's
// initialiser is lowered to instructions that push the constructed value (no
// return); `lowerWire` emits a private static field per binding, a `bootstrap()`
// that runs every binding initialiser then `putstatic`s it, and a public static
// accessor for each `expose`d binding.  A binding initialiser may reference an
// earlier binding by name — the shared `wireCtx` resolves such a reference to a
// `getstatic` on the wire class so the dependency graph wires up in order.
// Also handles WMProvided (@provided params become bootstrap() arguments stored
// to private static fields) and WMBind (registers interface → provider mapping).
func buildWire(
  decl: in WireDecl,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): LWire {
  val className = pkgName + "/" + decl.name
  val bindings: List[LWireBinding] = newList()
  val exposes: List[String] = newList()
  val providedParams: List[LWireParam] = newList()
  // Track binding name → static-field type so a later binding referencing an
  // earlier one resolves to `getstatic <wire>.<name>`.
  val bindingTypes: Map[String, JvmType] = newMap()

  // Topologically sort members so init-expression dependencies always refer to
  // fields that have already been stored (mirrors `wireTopoSortMsil` in the MSIL
  // backend).  A cycle produces W0001.
  val sortedMembers: List[WireMember] = match wireTopoSortJvm(decl.members) {
    case WTRSorted(sm) -> sm
    case WTRCycle(path) -> {
      val cycleStr = if path.count > 0 { path[0] } else { "<unknown>" }
      panic("W0001: wire '" + decl.name + "' has a dependency cycle involving: " + cycleStr)
    }
  }

  // Pre-pass: collect @provided members so their types are in bindingTypes before
  // the main loop processes bindings that may reference them.
  var ppi = 0
  while ppi < sortedMembers.count {
    match sortedMembers[ppi] {
      case WMProvided(pname, pty, _) -> {
        val bty = typeExprToJvm(pty, pkgName)
        providedParams.add(LWireParam(name = pname, valType = bty))
        // Register in bindingTypes so later init expressions that reference `pname`
        // resolve to `getstatic <wire>.<pname>` (the field that bootstrap() stores to).
        if not bindingTypes.containsKey(pname) {
          bindingTypes.add(pname, bty)
        }
      }
      case _ -> ()
    }
    ppi = ppi + 1
  }

  var mi = 0
  while mi < sortedMembers.count {
    match sortedMembers[mi] {
      case WMProvided(_, _, _) -> {
        // Already captured into providedParams in the pre-pass.  No binding insns
        // needed — lowerWire stores the bootstrap param to the field directly.
      }
      case WMSingleton(name, ty, init, _) -> {
        val bty = typeExprToJvm(ty, pkgName)
        val initInsns: List[LInsn] = newList()
        lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          opaqueTypes,
          closureAcc,
          initInsns,
          init,
          bty
        )
        bindings.add(LWireBinding(name = name, valType = bty, insns = initInsns))
        if not bindingTypes.containsKey(name) {
          bindingTypes.add(name, bty)
        }
      }
      case WMLocal(name, tyOpt, init, _) -> {
        val bty = match tyOpt { case Some(t) -> typeExprToJvm(t, pkgName); case None -> JRef(className = "java/lang/Object") }
        val initInsns: List[LInsn] = newList()
        lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          opaqueTypes,
          closureAcc,
          initInsns,
          init,
          bty
        )
        bindings.add(LWireBinding(name = name, valType = bty, insns = initInsns))
        if not bindingTypes.containsKey(name) {
          bindingTypes.add(name, bty)
        }
      }
      case WMBind(iface, provider, _) -> {
        // WMBind registers the provider expression as the resolution of the interface.
        // The binding is stored under the interface's simple name as a static field.
        val ifaceName = match iface.kind { case TRef(path) -> lastSegment(path); case _ -> "__bind" }
        val bty = typeExprToJvm(iface, pkgName)
        val initInsns: List[LInsn] = newList()
        lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          opaqueTypes,
          closureAcc,
          initInsns,
          provider,
          bty
        )
        bindings.add(LWireBinding(name = ifaceName, valType = bty, insns = initInsns))
        if not bindingTypes.containsKey(ifaceName) {
          bindingTypes.add(ifaceName, bty)
        }
      }
      case WMExpose(name, _) -> exposes.add(name)
      case WMScoped(_, _, _, _, _) -> {
        // ThreadLocal-backed scoping deferred to #2972; not lowered until then.
      }
    }
    mi = mi + 1
  }
  LWire(className = className, providedParams = providedParams, bindings = bindings, exposes = exposes)
}

// Lower a wire-binding initialiser so it pushes the constructed value (no return
// instruction).  Binding cross-references resolve to `getstatic` on the wire
// class via `bindingTypes`; everything else lowers through the normal expression
// path.
func lowerWireBindingInit(
  className: in String,
  bindingTypes: in Map[String, JvmType],
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  insns: in List[LInsn],
  init: in Expr,
  expectedTy: in JvmType,
): Unit {
  // A bare reference to an already-declared binding resolves to a `getstatic`
  // on the wire class; everything else lowers through the normal expression
  // path.
  var refName = ""
  match init.kind {
    case EPath(path) -> {
      refName = lastSegment(path)
    }
    case _ -> ()
  }
  if refName != "" and bindingTypes.containsKey(refName) {
    val fty = match mapGet(bindingTypes, refName) { case Some(t) -> t; case None -> JRef(className = "java/lang/Object") }
    insns.add(LGetstatic(owner = className, name = refName, t = fty))
  } else {
    // A lambda in a wire-binding initialiser registers its synthesised closure
    // inner class into the package-shared accumulator (#2864), so it emits
    // `<pkg>$Lambda$<n>` into the package output and works end-to-end.
    val ctx = makeFuncCtx(
      pkgName,
      className,
      funcSigs,
      caseFields,
      ctors,
      externTypes,
      autoFfi,
      expectedTy,
      moduleVals,
      opaqueTypes,
      closureAcc
    )
    val ty = lowerExpr(ctx, insns, init)
    coerceArgTo(insns, ty, expectedTy)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Package codegen — main entry point.
// ─────────────────────────────────────────────────────────────────────────────
// Join path segments with "/" to form the JVM binary name.
func segmentsToJvmPath(segs: in List[String]): String {
  joinSegments(segs, "/")
}

// Determine whether a function is the JVM entry point:
// name="main" with no parameters, or with a single `slice[String]`
// argv parameter (both Lyric entry-point conventions, #3303).
func isMainFunc(decl: in FunctionDecl): Bool {
  if decl.name != "main" {
    return false
  }
  if decl.params.count == 0 {
    return true
  }
  decl.params.count == 1 and mainParamIsStringSlice(decl.params[0].ty)
}

// True when a `main` parameter is `slice[String]` (the argv shape).
func mainParamIsStringSlice(te: in TypeExpr): Bool {
  match te.kind {
    case TSlice(elem) -> {
      match elem.kind {
        case TRef(path) -> path.segments.count == 1 and path.segments[0] == "String"
        case _ -> false
      }
    }
    case TParen(inner) -> mainParamIsStringSlice(inner)
    case _ -> false
  }
}

// ── Async generator detection ─────────────────────────────────────────────────
func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_) -> true
    case EAwait(inner) -> exprContainsYield(inner)
    case ESpawn(inner) -> exprContainsYield(inner)
    case EParen(inner) -> exprContainsYield(inner)
    case ETry(inner) -> exprContainsYield(inner)
    case EPropagate(inner) -> exprContainsYield(inner)
    case EOld(inner) -> exprContainsYield(inner)
    case EPrefix(_, inner) -> exprContainsYield(inner)
    case EBinop(_, l, r) -> exprContainsYield(l) or exprContainsYield(r)
    case EAssign(t, _, v) -> exprContainsYield(t) or exprContainsYield(v)
    case EBlock(blk) -> blockContainsYield(blk)
    case EUnsafe(blk) -> blockContainsYield(blk)
    case EIf(cond, thn, els, _) -> {
      if exprContainsYield(cond) {
        return true
      }
      if eobContainsYield(thn) {
        return true
      }
      match els {
        case Some(e2) -> eobContainsYield(e2)
        case None -> false
      }
    }
    case EMatch(scrut, arms) -> {
      if exprContainsYield(scrut) {
        return true
      }
      var i = 0
      while i < arms.count {
        if eobContainsYield(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ECall(fn, args) -> {
      if exprContainsYield(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        val argContains = match args[i] {
          case CAPositional(e) -> exprContainsYield(e)
          case CANamed(_, e, _) -> exprContainsYield(e)
        }
        if argContains {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(recv, idxs) -> {
      if exprContainsYield(recv) {
        return true
      }
      var i = 0
      while i < idxs.count {
        if exprContainsYield(idxs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EMember(recv, _) -> exprContainsYield(recv)
    case ETuple(exprs) -> listContainsYield(exprs)
    case EList(exprs) -> listContainsYield(exprs)
    case ETypeApp(fn, _) -> exprContainsYield(fn)
    case _ -> false
  }
}

func listContainsYield(exprs: in List[Expr]): Bool {
  var i = 0
  while i < exprs.count {
    if exprContainsYield(exprs[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func eobContainsYield(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> exprContainsYield(e)
    case EOBBlock(blk) -> blockContainsYield(blk)
  }
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContainsYield(stmt: in Statement): Bool {
  match stmt.kind {
    case SExpr(e) -> exprContainsYield(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsYield(init)
        case LBLet(_, _, init) -> exprContainsYield(init)
        case LBVar(_, _, initOpt) -> {
          match initOpt {
            case Some(init) -> exprContainsYield(init)
            case None -> false
          }
        }
      }
    }
    case SReturn(eOpt) -> {
      match eOpt {
        case Some(e) -> exprContainsYield(e)
        case None -> false
      }
    }
    case SAssign(t, _, v) -> exprContainsYield(t) or exprContainsYield(v)
    case SThrow(e) -> exprContainsYield(e)
    case SWhile(_, cond, body) -> exprContainsYield(cond) or blockContainsYield(body)
    case SLoop(_, body) -> blockContainsYield(body)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SBreak(_) -> false
    case SContinue(_) -> false
    case STry(body, catches, finally_) -> {
      if blockContainsYield(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockContainsYield(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContainsYield(fb)
      }
    }
    case SDefer(body) -> blockContainsYield(body)
    case SScope(_, body) -> blockContainsYield(body)
    case SInvariant(e) -> exprContainsYield(e)
    case SRule(l, r) -> exprContainsYield(l) or exprContainsYield(r)
    case SItem(_) -> false
  }
}

func funcBodyContainsYield(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(blk) -> blockContainsYield(blk)
        case FBExpr(e) -> exprContainsYield(e)
      }
    }
    case None -> false
  }
}

// Lower a generator function body to a flat list of LInsn.
// Params are accessed as fields on `this` (slot 0); the preamble loads
// each param field into a local slot so the body can use them normally.
func lowerGeneratorBody(
  decl: in FunctionDecl,
  pkgName: in String,
  genClass: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
): List[LInsn] {
  val insns: List[LInsn] = newList()
  // #2856: thread the real `moduleVals` / `opaqueTypes` maps into the generator
  // ctx so a generator body that reads a module-`val` (bare `getstatic`) or an
  // opaque-type field resolves it, instead of silently lowering to `null`.
  val ctx = makeFuncCtxForGenerator(
    pkgName,
    genClass,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    moduleVals,
    opaqueTypes,
    closureAcc
  )

  // `out`/`inout` parameters on an async generator are not supported on the
  // JVM target (the holder array is captured into a generator field, and the
  // write-back point is undefined across suspension) — reject rather than
  // silently pass by value (#1763).
  var _gpi = 0
  while _gpi < decl.params.count {
    if isHolderMode(decl.params[_gpi].mode) {
      panic(
        "Jvm.Codegen: `out`/`inout` parameter '" + decl.params[_gpi].name + "' on async generator " + genClass +
          " is not supported on the JVM target (#1763); use a return value instead."
      )
    }
    _gpi = _gpi + 1
  }
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
        case FBExpr(e) -> {
          lowerExpr(ctx, insns, e);
          ()
        }
      }
    }
    case None -> {
    }
  }

  insns
}

// Synthesise the static factory LFunc that constructs a generator instance.
// `public static Object name(params...) { return new GenClass(params...); }`
// This is added to LPFuncs so it lands in the same class file as main().
func makeGeneratorFactory(decl: in FunctionDecl, genClass: in String, pkgName: in String): LFunc {
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
      case JLong -> {
        insns.add(LLload(slot = slot))
        slot = slot + 2
      }
      case JDouble -> {
        insns.add(LDload(slot = slot))
        slot = slot + 2
      }
      case JFloat -> {
        insns.add(LFload(slot = slot))
        slot = slot + 1
      }
      case JRef(_) -> {
        insns.add(LAload(slot = slot))
        slot = slot + 1
      }
      // JBoolean, JByte, JChar, JShort are all JVM category-1 int types;
      // iload/istore works for all of them.
      case _ -> {
        insns.add(LIload(slot = slot))
        slot = slot + 1
      }
    }
    pi = pi + 1
  }

  insns.add(LInvokespecial(owner = genClass, name = "<init>", params = ctorParams, ret = JVoid))
  insns.add(LAreturn)

  LFunc(
    flags = 0x0009,
    // ACC_PUBLIC | ACC_STATIC
    name = decl.name,
    params = ctorParams,
    ret = JRef(className = "java/lang/Object"),
    insns = insns,
    maxStack = 0,
    // inferred from peak-stack tracking
    maxLocals = 0
  )        // inferred from slot scan
}

// ── IImpl pre-pass helpers ────────────────────────────────────────────────────
record ImplEntry {
  targetClass: String
  ifaceClass: String
  methods: List[LFunc]
}

// Convert a single-segment or multi-segment TypeExpr to a JVM binary class name.
// Used to resolve `impl Y for X` target from the AST.
//
// The non-TRef fallback used to return `pkgName + "/$unknown"` — not a
// valid JVM binary name and unreferenceable by the class loader.
// `panic` here surfaces the gap at codegen time with a clear message
// instead of letting an `interfaces` array reference a nonexistent
// class and tripping `ClassNotFoundException: pkg/$unknown` at JVM
// load time.  All `impl` targets are `TRef(path)` in practice today
// (concrete record names); a non-TRef case is a parser/AST shape
// not seen yet and we want to know about it loudly.
func typeExprToJvmClass(te: in TypeExpr, pkgName: in String): String {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        pkgName + "/" + path.segments[0]
      } else {
        segmentsToJvmPath(path.segments)
      }
    }
    case _ -> panic("Jvm.Codegen: `impl Y for X` target is not a TRef (path) — got an " + "unsupported TypeExpr shape; refusing to emit an unbindable JVM " + "class name.  Add a TypeExpr arm to typeExprToJvmClass if a new " + "impl-target shape is intended.")
  }
}

// Convert a ConstraintRef to a JVM binary class name.
// Used to resolve `impl Y for X` interface from the AST.
func constraintRefToJvmClass(cr: in ConstraintRef, pkgName: in String): String {
  if cr.head.segments.count == 1 {
    pkgName + "/" + cr.head.segments[0]
  } else {
    segmentsToJvmPath(cr.head.segments)
  }
}

// Collect a file's `extern type Alias = "java.fq.Name"` declarations into an
// alias → dotted-Java-FQN map (first-wins).  Used to resolve extern aliases in
// parameter/return descriptors so they don't fall back to `<pkg>/<Alias>`.
pub func collectExternTypesFromFile(file: in SourceFile): Map[String, String] {
  val externTypes: Map[String, String] = newMap()
  var eti = 0
  while eti < file.items.count {
    match file.items[eti].kind {
      case IExternType(decl) -> {
        if not externTypes.containsKey(decl.name) {
          externTypes.add(decl.name, decl.clrName)
        }
      }
      case _ -> ()
    }
    eti = eti + 1
  }
  externTypes
}

// Collect every top-level `func` item's JVM call signature from `file` into
// `into` (keyed by bare function name; first declaration of a given name
// wins).  Owner is the file's package host class.  Used to build the
// cross-package call registry so any package's call sites can resolve a
// callee's owner + descriptor.  See JvmFuncSig.
pub func collectFileSigs(file: in SourceFile, into: in Map[String, JvmFuncSig]): Unit {
  val emptySeed: Map[String, String] = newMap()
  collectFileSigsSeeded(file, into, emptySeed)
}

// Union of a file's own `extern type` declarations and `seed` (the extern
// types of the packages it imports).  Own declarations win on alias collision.
pub func mergeExternSeed(own: in Map[String, String], seed: in Map[String, String]): Map[String, String] {
  val merged: Map[String, String] = newMap()
  for k in mapKeys(seed) {
    match mapGet(seed, k) {
      case Some(v) -> merged.add(k, v)
      case None -> ()
    }
  }
  for k2 in mapKeys(own) {
    match mapGet(own, k2) {
      case Some(v2) -> {
        merged.remove(k2)
        merged.add(k2, v2)
      }
      case None -> ()
    }
  }
  merged
}

// As `collectFileSigs`, but resolving extern-type aliases against the file's
// own declarations UNION `externSeed` — the extern types of the packages the
// file imports (own declarations win).  A public signature written against an
// imported extern type (e.g. `Std.Time.now(): Instant`, where `Instant` is an
// `extern type` in `Std.TimeHost`) must resolve to the real JVM class in both
// the registered sig and the emitted descriptor, or the method links against a
// nonexistent `<pkg>/<Alias>` class at runtime.
pub func collectFileSigsSeeded(
  file: in SourceFile, into: in Map[String, JvmFuncSig], externSeed: in Map[String, String]
): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  // Resolve `extern type` parameter/return descriptors to the real JVM class
  // (e.g. `JBAOS` -> `java/io/ByteArrayOutputStream`), not `<pkg>/<Alias>`
  // (#3334).  The emitted method descriptor in `lowerFunc` resolves the same
  // way, so the registered sig and the method stay in lockstep.
  val externTypes = mergeExternSeed(collectExternTypesFromFile(file), externSeed)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        // An `out`/`inout` parameter is declared as a holder array in the JVM
        // descriptor (#1763), so the registry records the array type and the
        // declared mode; call sites read the modes to wrap holder arguments.
        // A generic function's own type parameters erase to Object in the
        // registered sig — the previous empty list let `T` fall to the
        // in-package class guess, so an unmonomorphized call's descriptor
        // referenced the phantom `Std/Core/T` (NoClassDefFoundError at
        // link time; hit by `unwrapOr` in parse_tests).
        val sigTps = genericParamNames(decl.generics)
        val params = holderAwareParamTypes(decl.params, owner, false, sigTps, externTypes)
        val paramNames: List[String] = newList()
        val paramDefaults: List[Option[Expr]] = newList()
        val paramModes: List[ParamMode] = newList()
        var pi = 0
        while pi < decl.params.count {
          paramNames.add(decl.params[pi].name)
          paramDefaults.add(decl.params[pi].dflt)
          paramModes.add(decl.params[pi].mode)
          pi = pi + 1
        }
        // An async generator's *factory* returns the synthesised generator
        // object (an Iterable), not its declared element type — so the call
        // site must store/use a reference, not `decl.ret` (e.g. the `Int`
        // element type).  Record Object for it; everything else uses the
        // declared return.
        val ret = if decl.isAsync and funcBodyContainsYield(decl) {
          JRef(className = "java/lang/Object")
        } else {
          match decl.ret {
            case Some(te) -> typeExprToJvmErasedExtern(te, owner, sigTps, externTypes)
            case None -> JVoid
          }
        }
        val sig = JvmFuncSig(
          owner = owner,
          params = params,
          ret = ret,
          paramNames = paramNames,
          paramDefaults = paramDefaults,
          paramModes = paramModes,
          isIface = false,
          retGenericArgs = returnTypeGenericArgs(decl.ret)
        )
        // Qualified key (`Std/Testing/assertEqualInt`) is unique across the
        // bundle, so two packages exporting the same short name (e.g.
        // `fromString` in `Std.Json` and `Std.Yaml`) no longer collide
        // silently — call sites with a qualified path resolve via this key
        // (#1680).
        val qkey = owner + "/" + decl.name
        if not into.containsKey(qkey) {
          into.add(qkey, sig)
        }
        // Bare key kept for unqualified intra-package calls (first-wins on
        // collision, matching pre-1680 behaviour for compatibility).
        if not into.containsKey(decl.name) {
          into.add(decl.name, sig)
        }
        // Arity-suffixed keys so same-name OVERLOADS in one package resolve
        // to the right descriptor: with name-only keys, first-wins collision
        // made a 3-arg call link against the 2-arg overload's descriptor —
        // VerifyError at class load (`Std.String.substring`'s two overloads,
        // hit by lyric-storage's `basenameOf`).  Call sites try the exact
        // arity first and fall back to the name key (which also covers calls
        // that rely on parameter defaults).
        val akey = qkey + "@" + toString(decl.params.count)
        if not into.containsKey(akey) {
          into.add(akey, sig)
        }
        val bkey = decl.name + "@" + toString(decl.params.count)
        if not into.containsKey(bkey) {
          into.add(bkey, sig)
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: register each protected entry / helper method under the
        // instance-method key `<class>#<method>` so `c.increment()` resolves to
        // the real descriptor (e.g. `()V`) instead of the `()Object` guess.
        val protClass = owner + "/" + decl.name
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMEntry(ed) -> {
              registerInstanceSig(into, protClass, ed.name, ed.params, ed.ret, owner)
            }
            case PMFunc(fn) -> {
              registerInstanceSig(into, protClass, fn.name, fn.params, fn.ret, owner)
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      case IRecord(decl) -> {
        // Register record instance methods (`RMFunc`) under `<class>#<method>`
        // too, so a method call on a record receiver resolves precisely (same
        // `()Object`-guess gap as protected entries).
        val recClass = owner + "/" + decl.name
        // Generic type params erase to `Object` so the registered descriptor
        // matches what `lowerRecordMethod` emits (#2865).
        val recTps = genericParamNames(decl.generics)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              registerInstanceSigErased(into, recClass, fn.name, fn.params, fn.ret, owner, recTps)
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      case IImpl(decl) -> {
        // Register each impl method under `<targetClass>#<methodName>` so that
        // call sites (`lowerMethodCall` J3 M-3 path) emit a precisely-typed
        // `invokevirtual` rather than the `()Object` guess (#1722).
        val tgtClass = typeExprToJvmClass(decl.target, owner)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> {
              registerInstanceSig(into, tgtClass, fn.name, fn.params, fn.ret, owner)
            }
            case IMplAssoc(_) -> ()
          }
          mi = mi + 1
        }
      }
      case IInterface(decl) -> {
        // Register each interface member under `<ifaceClass>#<method>` with
        // `isIface = true` so a call on an interface-typed receiver emits
        // `invokeinterface` — the `()Object`-guess `invokevirtual` against an
        // interface owner fails class-load verification (#3687).  Params and
        // return mirror the abstract-method emission (`IInterface` arm of
        // `codegenPackageWithSigs`) exactly so the descriptors stay in lockstep.
        val ifClass = owner + "/" + decl.name
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              registerIfaceSig(into, ifClass, sig.name, sig.params, sig.ret, owner, externTypes)
            }
            case IMFunc(fn) -> {
              registerIfaceSig(into, ifClass, fn.name, fn.params, fn.ret, owner, externTypes)
            }
            case IMAssoc(_) -> ()
          }
          mi = mi + 1
        }
      }
      case IOpaque(decl) -> {
        // Erased-Object receiver fallback (#3044): register each opaque field
        // under the `field:<name>` key (owner class + declared type) so a
        // member read on a statically-Object receiver — e.g. the match
        // binding on `tryInto()`'s `Ok` payload — can checkcast to the owner
        // and read through its `$<name>()` accessor.  First-wins on
        // cross-type field-name collisions, mirroring the MSIL
        // `fieldTokensByName` package-level reverse lookup.
        if decl.hasBody {
          val opqCls = owner + "/" + decl.name
          var mi = 0
          while mi < decl.members.count {
            match decl.members[mi] {
              case OMField(f) -> {
                val fkey = "field:" + f.name
                if not into.containsKey(fkey) {
                  val fPs: List[JvmType] = newList()
                  into.add(
                    fkey,
                    JvmFuncSig(
                      owner = opqCls,
                      params = fPs,
                      ret = typeExprToJvm(f.ty, owner),
                      paramNames = newList(),
                      paramDefaults = newList(),
                      paramModes = newList(),
                      isIface = false,
                      retGenericArgs = returnTypeGenericArgs(Some(f.ty))
                    )
                  )
                }
              }
              case OMInvariant(_) -> ()
            }
            mi = mi + 1
          }
        }
      }
      case IWire(decl) -> {
        // J3 M-3: register the wire's static factory methods under the
        // `<wireShortName>.<method>` key so `AppWire.bootstrap()` /
        // `AppWire.svc()` resolve to `invokestatic <wireClass>.<method>` with the
        // real descriptor.  `bootstrap()V` runs the bindings; each exposed
        // binding gets a `()T` accessor returning its declared type.
        val wireClass = owner + "/" + decl.name
        val noPs: List[Param] = newList()
        // bootstrap()V
        registerStaticWireSig(into, decl.name, wireClass, "bootstrap", newList(), JVoid)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case WMSingleton(bname, bty, _, _) -> {
              if wireExposes(decl, bname) {
                registerStaticWireSig(into, decl.name, wireClass, bname, newList(), typeExprToJvm(bty, owner))
              }
            }
            case WMLocal(bname, btyOpt, _, _) -> {
              if wireExposes(decl, bname) {
                val rt = match btyOpt { case Some(t) -> typeExprToJvm(t, owner); case None -> JRef(className = "java/lang/Object") }
                registerStaticWireSig(into, decl.name, wireClass, bname, newList(), rt)
              }
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Register an instance method's signature under the `<class>#<method>` key used
// by `lowerMethodCall` to emit a precisely-typed `invokevirtual` for in-package
// receivers (records / protected types) instead of the `()Object` guess.
func registerInstanceSig(
  into: in Map[String, JvmFuncSig],
  className: in String,
  methodName: in String,
  params: in List[Param],
  retOpt: in Option[TypeExpr],
  owner: in String,
): Unit {
  // Non-generic receiver: no type params to erase.
  registerInstanceSigErased(into, className, methodName, params, retOpt, owner, newList())
}

// As `registerInstanceSig`, but a param/return whose type names one of
// `typeParams` erases to `java/lang/Object` (JVM has no reified generics —
// docs/44 M-1 / Q-J001).  Used for generic record instance methods so the
// registered descriptor matches the emitted method (`lowerRecordMethod` erases
// the same params), keeping the `invokevirtual` call site precise.
func registerInstanceSigErased(
  into: in Map[String, JvmFuncSig],
  className: in String,
  methodName: in String,
  params: in List[Param],
  retOpt: in Option[TypeExpr],
  owner: in String,
  typeParams: in List[String],
): Unit {
  val filteredParams = stripLeadingSelfParam(params)
  // Use holderAwareParamTypes so out/inout params register as JArray(elemTy) in the
  // descriptor, matching the emitted method and the call-site wrapping (#1763).
  val noExts: Map[String, String] = newMap()
  val ps = holderAwareParamTypes(filteredParams, owner, true, typeParams, noExts)
  val ret = match retOpt { case Some(te) -> typeExprToJvmErased(te, owner, typeParams); case None -> JVoid }
  val paramNames: List[String] = newList()
  val paramDefs: List[Option[Expr]] = newList()
  val modes: List[ParamMode] = newList()
  var pi = 0
  while pi < filteredParams.count {
    paramNames.add(filteredParams[pi].name)
    paramDefs.add(filteredParams[pi].dflt)
    modes.add(filteredParams[pi].mode)
    pi = pi + 1
  }
  val key = className + "#" + methodName
  if not into.containsKey(key) {
    into.add(
      key,
      JvmFuncSig(
        owner = className,
        params = ps,
        ret = ret,
        paramNames = paramNames,
        paramDefaults = paramDefs,
        paramModes = modes,
        isIface = false,
        retGenericArgs = returnTypeGenericArgs(retOpt)
      )
    )
  }
}

// Register one interface member under `<ifaceClass>#<method>` with
// `isIface = true` (#3687).  Params and return mirror the abstract-method
// emission in the `IInterface` arm of `codegenPackageWithSigs` exactly —
// `holderAwareParamTypes(erase = true, no type params)` and a bare
// `typeExprToJvm` return — so the registered descriptor and the emitted
// interface method stay in lockstep.
func registerIfaceSig(
  into: in Map[String, JvmFuncSig],
  ifClass: in String,
  methodName: in String,
  params: in List[Param],
  retOpt: in Option[TypeExpr],
  owner: in String,
  externTypes: in Map[String, String],
): Unit {
  val noTps: List[String] = newList()
  val ps = holderAwareParamTypes(params, owner, true, noTps, externTypes)
  val ret = match retOpt { case Some(te) -> typeExprToJvmExtern(te, owner, externTypes); case None -> JVoid }
  val pNames: List[String] = newList()
  val pDefs: List[Option[Expr]] = newList()
  val pModes: List[ParamMode] = newList()
  var pi = 0
  while pi < params.count {
    pNames.add(params[pi].name)
    pDefs.add(params[pi].dflt)
    pModes.add(params[pi].mode)
    pi = pi + 1
  }
  val key = ifClass + "#" + methodName
  if not into.containsKey(key) {
    into.add(
      key,
      JvmFuncSig(
        owner = ifClass,
        params = ps,
        ret = ret,
        paramNames = pNames,
        paramDefaults = pDefs,
        paramModes = pModes,
        isIface = true,
        retGenericArgs = returnTypeGenericArgs(retOpt)
      )
    )
  }
}

// Register a wire's static factory method under the `<wireShortName>.<method>`
// key consulted by `lowerMethodCall` for `AppWire.bootstrap()` / accessor calls.
func registerStaticWireSig(
  into: in Map[String, JvmFuncSig],
  wireShortName: in String,
  wireClass: in String,
  methodName: in String,
  params: in List[JvmType],
  ret: in JvmType,
): Unit {
  val key = wireShortName + "." + methodName
  if not into.containsKey(key) {
    into.add(
      key,
      JvmFuncSig(
        owner = wireClass,
        params = params,
        ret = ret,
        paramNames = newList(),
        paramDefaults = newList(),
        paramModes = newList(),
        isIface = false,
        retGenericArgs = newList()
      )
    )
  }
}

// True when `name` is listed in a `wire` block's `expose` members.
func wireExposes(decl: in WireDecl, name: in String): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case WMExpose(en, _) -> {
        if en == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// Collect every `union` case class's field list from `file` into `into`,
// keyed by the case class JVM name (e.g. "Pkg/Union$Case").  Mirrors the
// case-class field generation in lowerUnion so the binding-site field names
// and types agree.  See JvmCaseField.
pub func collectFileCases(file: in SourceFile, into: in Map[String, List[JvmCaseField]]): Unit {
  val noExternCfc: Map[String, String] = newMap()
  collectFileCasesExtern(file, into, noExternCfc)
}

// As `collectFileCases`, but resolving field types through the file's
// extern-type table (own declarations + imported seed) so a field typed by
// an imported extern type registers the real JVM class.
pub func collectFileCasesExtern(
  file: in SourceFile,
  into: in Map[String, List[JvmCaseField]],
  externTypes: in Map[String, String],
): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IUnion(decl) -> {
        // A generic union's case fields (`Some(value: T)`, `Ok(value: T)`)
        // erase their type-param payloads to `Object` so the binding-site field
        // types match the `Ljava/lang/Object;` fields the class actually emits.
        val tps = genericParamNames(decl.generics)
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          val caseClass = owner + "/" + decl.name + "$" + c.name
          if not into.containsKey(caseClass) {
            val flds: List[JvmCaseField] = newList()
            var fi = 0
            while fi < c.fields.count {
              match c.fields[fi] {
                case UFNamed(name, ty, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvmErasedExtern(ty, owner, tps, externTypes), paramIdx = typeParamIndexOf(ty, tps)))
                case UFPos(ty, _) -> flds.add(JvmCaseField(name = "field" + toString(fi), ty = typeExprToJvmErasedExtern(ty, owner, tps, externTypes), paramIdx = typeParamIndexOf(ty, tps)))
              }
              fi = fi + 1
            }
            into.add(caseClass, flds)
          }
          ci = ci + 1
        }
      }
      case IRecord(decl) -> {
        val recClass = owner + "/" + decl.name
        val tps = genericParamNames(decl.generics)
        if not into.containsKey(recClass) {
          val flds: List[JvmCaseField] = newList()
          var mi = 0
          while mi < decl.members.count {
            match decl.members[mi] {
              case RMField(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvmErasedExtern(f.ty, owner, tps, externTypes), paramIdx = -1))
              case _ -> {
              }
            }
            mi = mi + 1
          }
          into.add(recClass, flds)
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: a protected type lowers to a record-shaped class (field-args
        // ctor + instance methods), so register its data fields here too —
        // otherwise `TokenBucket(...)` construction and bare field reads inside
        // entries can't resolve the field descriptors.
        val protClass = owner + "/" + decl.name
        if not into.containsKey(protClass) {
          val flds: List[JvmCaseField] = newList()
          var mi = 0
          while mi < decl.members.count {
            match decl.members[mi] {
              case PMField(pf) -> {
                match pf {
                  case PFVar(name, ty, _, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvmExtern(ty, owner, externTypes), paramIdx = -1))
                  case PFLet(name, ty, _, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvmExtern(ty, owner, externTypes), paramIdx = -1))
                  case PFImmutable(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvmExtern(f.ty, owner, externTypes), paramIdx = -1))
                }
              }
              case _ -> ()
            }
            mi = mi + 1
          }
          into.add(protClass, flds)
        }
      }
      case IOpaque(decl) -> {
        // J3 M-3: an opaque type's field-args ctor lets `Counter(value = …)`
        // construct it; register its logical fields (the `$`-mangling is applied
        // only at accessor-emit time) so construction arg-ordering resolves.
        if decl.hasBody {
          val opqClass = owner + "/" + decl.name
          if not into.containsKey(opqClass) {
            val flds: List[JvmCaseField] = newList()
            var mi = 0
            while mi < decl.members.count {
              match decl.members[mi] {
                case OMField(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvm(f.ty, owner), paramIdx = -1))
                case OMInvariant(_) -> ()
              }
              mi = mi + 1
            }
            into.add(opqClass, flds)
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Collect every constructible nominal type (record + union case) from `file`
// into `into`, keyed by its short name.  Mirrors `collectFileCases` (which is
// keyed by JVM class name); this map drives construction-call lowering, which
// resolves a head name like `Point` / `Circle` to the class to `new`.
// Register this file's NON-GENERIC declared type names (unions, records,
// protected and opaque types) as dotted class FQNs (`YamlValue` ->
// `Std.Yaml.YamlValue`), in the same value format as the extern-type maps.
// `externSeedForFile` unions these into the seed of every IMPORTING file, so
// a descriptor written against an imported Lyric type (a record field
// `node: YamlValue` in Std.JsonHost) resolves to the declaring package's
// real class instead of the in-package guess (`Std/JsonHost/YamlValue` —
// NoClassDefFoundError at first use).  Generic declarations are skipped: a
// bare reference to one erases to Object, and seeding e.g. `Option` would
// re-type every erased generic field.
pub func collectFileDeclaredTypeFqns(file: in SourceFile, into: in Map[String, String]): Unit {
  val pkgDotted = dottedPathOfSegments(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IUnion(decl) -> {
        match decl.generics {
          case None -> {
            if not into.containsKey(decl.name) {
              into.add(decl.name, pkgDotted + "." + decl.name)
            }
          }
          case Some(_) -> ()
        }
      }
      case IRecord(decl) -> {
        match decl.generics {
          case None -> {
            if not into.containsKey(decl.name) {
              into.add(decl.name, pkgDotted + "." + decl.name)
            }
          }
          case Some(_) -> ()
        }
      }
      case IProtected(decl) -> {
        match decl.generics {
          case None -> {
            if not into.containsKey(decl.name) {
              into.add(decl.name, pkgDotted + "." + decl.name)
            }
          }
          case Some(_) -> ()
        }
      }
      case IOpaque(decl) -> {
        match decl.generics {
          case None -> {
            if decl.hasBody and not into.containsKey(decl.name) {
              into.add(decl.name, pkgDotted + "." + decl.name)
            }
          }
          case Some(_) -> ()
        }
      }
      case IInterface(decl) -> {
        // Interfaces are emitted as real JVM interfaces; a consumer's
        // interface-typed binding (`bucket: StorageBucket` in a test module)
        // otherwise carries the in-package guess.
        match decl.generics {
          case None -> {
            if not into.containsKey(decl.name) {
              into.add(decl.name, pkgDotted + "." + decl.name)
            }
          }
          case Some(_) -> ()
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func dottedPathOfSegments(segments: in List[String]): String {
  var out2 = ""
  var i = 0
  while i < segments.count {
    if i > 0 {
      out2 = out2 + "."
    }
    out2 = out2 + segments[i]
    i = i + 1
  }
  out2
}

pub func collectFileCtors(file: in SourceFile, into: in Map[String, String]): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        addCtorKeys(into, owner, decl.name, owner + "/" + decl.name)
      }
      case IUnion(decl) -> {
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          addCtorKeys(into, owner, c.name, owner + "/" + decl.name + "$" + c.name)
          ci = ci + 1
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: protected types are constructed like records (`TokenBucket(…)`).
        addCtorKeys(into, owner, decl.name, owner + "/" + decl.name)
      }
      case IOpaque(decl) -> {
        // J3 M-3: opaque types are constructed like records (`Counter(value=…)`).
        if decl.hasBody {
          addCtorKeys(into, owner, decl.name, owner + "/" + decl.name)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Register a constructable type under both its bare name (bundle-global,
// first wins — the legacy single-package shape) and a package-scoped key
// (`<owner>::<name>`).  `ctorClassFor` tries the scoped key first, so a
// package's OWN case wins over a same-named case another bundled package
// registered earlier (`InvalidDocument` exists in both `Std.Xml`'s
// XmlError and `Std.Yaml`'s YamlError — the bare first-wins entry gave
// Yaml's code Xml's class: NoClassDefFoundError at runtime).
func addCtorKeys(into: in Map[String, String], owner: in String, name: in String, cls: in String): Unit {
  if not into.containsKey(name) {
    into.add(name, cls)
  }
  val scopedKey = owner + "::" + name
  if not into.containsKey(scopedKey) {
    into.add(scopedKey, cls)
  }
}

// Collect every module-level `val NAME [: T] = expr` binding from `file` into
// `into`, keyed by `NAME` with its JVM field type.  Drives bare-name reads of
// module-level vals (lowered to `getstatic <hostClass>.<name>`).  Only the
// simple `PBinding` form participates; destructuring module-level vals emit no
// host field and so are not registered (m-2).
pub func collectFileVals(file: in SourceFile, owner: in String, into: in Map[String, JvmType]): Unit {
  val noExtern: Map[String, String] = newMap()
  collectFileValsExtern(file, owner, into, noExtern)
}

// As `collectFileVals`, but resolving a module val's declared type through the
// file's extern-type table so `val rdr: JBufferedReader = …` carries the real
// JVM class (`java/io/BufferedReader`) instead of the in-package
// `<pkg>/JBufferedReader` guess (NoClassDefFoundError at <clinit>).
pub func collectFileValsExtern(
  file: in SourceFile,
  owner: in String,
  into: in Map[String, JvmType],
  externTypes: in Map[String, String],
): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(name, _) -> {
            if not into.containsKey(name) {
              val vty = match decl.ty {
                case Some(te) -> typeExprToJvmExtern(te, owner, externTypes)
                case None -> inferValType(decl.init, owner)
              }
              into.add(name, vty)
            }
          }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Collect every `opaque type` declaration's JVM class name into `into` (value
// is always `true`).  Drives accessor-routed field reads on opaque receivers.
pub func collectFileOpaque(file: in SourceFile, owner: in String, into: in Map[String, Bool]): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IOpaque(decl) -> {
        if decl.hasBody {
          val cls = owner + "/" + decl.name
          if not into.containsKey(cls) {
            into.add(cls, true)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// True when the annotation list carries `@<headName>` (first path segment
// match).  Mirrors the MSIL backend's `hasAnnotationMsil`.
pub func hasAnnotationJvm(anns: in List[Annotation], headName: in String): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count > 0 and segs[0] == headName {
      return true
    }
    i = i + 1
  }
  false
}

// Collect every `@projectable` opaque type's JVM class name into `into`
// (value always `true`).  Run over the user file plus every bundled file
// BEFORE any per-package codegen so nested-projectable detection is
// declaration-order- and package-order-independent — the JVM counterpart of
// the MSIL `prescanProjectableFqns` (#3044).
pub func collectFileProjectables(file: in SourceFile, into: in Map[String, Bool]): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IOpaque(decl) -> {
        if decl.hasBody and hasAnnotationJvm(decl.annotations, "projectable") {
          val cls = owner + "/" + decl.name
          if not into.containsKey(cls) {
            into.add(cls, true)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Per-field projection metadata for one `@projectable` opaque declaration:
// @hidden / @projectionBoundary flags plus the nested view class when the
// field's type is itself a non-boundary projectable (per `allProjFqns`).
func buildProjFieldInfos(
  decl: in OpaqueTypeDecl, owner: in String, allProjFqns: in Map[String, Bool]
): List[LProjFieldInfo] {
  val infos: List[LProjFieldInfo] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case OMField(f) -> {
        val hidden = hasAnnotationJvm(f.annotations, "hidden")
        val boundary = hasAnnotationJvm(f.annotations, "projectionBoundary")
        val srcTy = typeExprToJvm(f.ty, owner)
        val nested: Option[String] = if boundary {
          None
        } else {
          match srcTy {
            case JRef(c) -> {
              if allProjFqns.containsKey(c) {
                Some(value = c + "View")
              } else {
                None
              }
            }
            case _ -> None
          }
        }
        infos.add(
          LProjFieldInfo(name = f.name, fieldType = srcTy, hidden = hidden, boundary = boundary, nestedViewClass = nested)
        )
      }
      case OMInvariant(_) -> ()
    }
    mi = mi + 1
  }
  infos
}

// tryInto() eligibility: every field visible (no @hidden) and no visible
// field is a non-boundary nested projectable (those would need monadic
// bind).  Mirrors the MSIL `canEmitTryInto` (minus the Result-token gate —
// the JVM links `Std.Core.Result` lazily at first invocation).
func projCanTryInto(infos: in List[LProjFieldInfo]): Bool {
  var i = 0
  while i < infos.count {
    if infos[i].hidden {
      return false
    }
    match infos[i].nestedViewClass {
      case Some(_) -> return false
      case None -> ()
    }
    i = i + 1
  }
  true
}

// Register a file's `@projectable` artifacts into the shared registries so
// call sites and field reads resolve across the whole compilation (#3044):
//   • caseFields[`<Pkg>/<Name>View`] — the view's visible fields with
//     view-substituted types (drives `uv.<field>` getfield emission);
//   • funcSigs[`<Pkg>/<Name>#toView`] — `()L<Pkg>/<Name>View;`;
//   • funcSigs[`<Pkg>/<Name>View#tryInto`] — `()LStd/Core/Result;`
//     (only when eligible, matching the emitted class).
// Must run AFTER `allProjFqns` is fully populated for every file in the
// compilation.
pub func registerProjectableViews(
  file: in SourceFile,
  allProjFqns: in Map[String, Bool],
  caseFields: in Map[String, List[JvmCaseField]],
  funcSigs: in Map[String, JvmFuncSig],
): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IOpaque(decl) -> {
        if decl.hasBody and hasAnnotationJvm(decl.annotations, "projectable") {
          val cls = owner + "/" + decl.name
          val viewCls = cls + "View"
          val infos = buildProjFieldInfos(decl, owner, allProjFqns)
          if not caseFields.containsKey(viewCls) {
            val vflds: List[JvmCaseField] = newList()
            var fi = 0
            while fi < infos.count {
              if not infos[fi].hidden {
                vflds.add(JvmCaseField(name = infos[fi].name, ty = projViewFieldType(infos[fi]), paramIdx = -1))
              }
              fi = fi + 1
            }
            caseFields.add(viewCls, vflds)
          }
          val tvKey = cls + "#toView"
          if not funcSigs.containsKey(tvKey) {
            val tvPs: List[JvmType] = newList()
            funcSigs.add(
              tvKey,
              JvmFuncSig(
                owner = cls,
                params = tvPs,
                ret = JRef(className = viewCls),
                paramNames = newList(),
                paramDefaults = newList(),
                paramModes = newList(),
                isIface = false,
                retGenericArgs = newList()
              )
            )
          }
          if projCanTryInto(infos) {
            val tiKey = viewCls + "#tryInto"
            if not funcSigs.containsKey(tiKey) {
              val tiPs: List[JvmType] = newList()
              funcSigs.add(
                tiKey,
                JvmFuncSig(
                  owner = viewCls,
                  params = tiPs,
                  ret = JRef(className = "Std/Core/Result"),
                  paramNames = newList(),
                  paramDefaults = newList(),
                  paramModes = newList(),
                  isIface = false,
                  retGenericArgs = newList()
                )
              )
            }
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Best-effort static type of a module-level `val` initialiser without a
// declared annotation: literals map to their JVM type; everything else falls
// back to a `java/lang/Object` reference.  The field type only needs to be the
// JVM *kind* (the codegen coerces the init value to it); annotated vals (the
// common case) bypass this.
func inferValType(e: in Expr, owner: in String): JvmType {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(_, suffix, _) -> match suffix { case I64 -> JLong; case U64 -> JLong; case _ -> JInt }
        case LFloat(_, suffix, _) -> match suffix { case F32 -> JFloat; case _ -> JDouble }
        case LBool(_) -> JBoolean
        case LString(_) -> JRef(className = "java/lang/String")
        case LChar(_) -> JChar
        case _ -> JRef(className = "java/lang/Object")
      }
    }
    case _ -> JRef(className = "java/lang/Object")
  }
}

// Pre-lower every module-level `val NAME = init` (PBinding form) once, against
// the shared `<clinit>` ctx, and **overwrite** `moduleVals[NAME]` with the real
// field type the value carries (#2853).  `collectFileVals`'s `inferValType`
// guess disagrees with the emitted field in two cases — an F32 float literal
// (`D` vs `F`) and any non-literal init (`Object` vs the concrete type) — which
// made the bare-reference `getstatic <owner>.<name>:<desc>` mismatch the
// declared field and fail class load with `NoSuchFieldError`.  Lowering here,
// before any function body or the `<clinit>` itself, means the `getstatic`
// descriptor and the `LStaticVal` field are derived from the identical `field`
// type.  The lowered insns are cached so the `<clinit>` emission reuses them
// rather than lowering a second time (slot numbering stays consistent).
func prelowerModuleVals(
  file: in SourceFile,
  pkgName: in String,
  valInitCtx: in FuncCtx,
  moduleVals: in Map[String, JvmType],
): List[LoweredModuleVal] {
  val lowered: List[LoweredModuleVal] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(name, _) -> {
            val initInsns: List[LInsn] = newList()
            val valTy = lowerExpr(valInitCtx, initInsns, decl.init)
            // Resolve the declared type through the extern-type table so a
            // module val of extern type (`val rdr: JBufferedReader = …`)
            // carries the real JVM class, not the in-package guess
            // (NoClassDefFoundError at <clinit>).
            val fieldTy = match decl.ty {
              case Some(te) -> typeExprToJvmExtern(te, pkgName, valInitCtx.externTypes)
              case None -> valTy
            }
            coerceArgTo(initInsns, valTy, fieldTy)
            // Overwrite the `collectFileVals`/`inferValType` guess with the real
            // field type so bare reads emit the matching `getstatic` descriptor.
            if moduleVals.containsKey(name) {
              moduleVals.remove(name)
            }
            moduleVals.add(name, fieldTy)
            lowered.add(LoweredModuleVal(name = name, field = fieldTy, insns = initInsns))
          }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  lowered
}

// Look up the pre-lowered module val for `name` (#2853).  Returns the cached
// field type + init insns so the `<clinit>` emission reuses the single lowering.
func findLoweredModuleVal(cache: in List[LoweredModuleVal], name: in String): Option[LoweredModuleVal] {
  var i = 0
  while i < cache.count {
    if cache[i].name == name {
      return Some(value = cache[i])
    }
    i = i + 1
  }
  None
}

// Backward-compatible single-package entry: the registry carries only this
// file's own functions (enough to resolve intra-package calls — including
// void-returning ones the legacy guess mis-resolved).
pub func codegenPackage(file: in SourceFile): LPackage {
  val sigs: Map[String, JvmFuncSig] = newMap()
  collectFileSigs(file, sigs)
  val cases: Map[String, List[JvmCaseField]] = newMap()
  collectFileCases(file, cases)
  val ctors: Map[String, String] = newMap()
  collectFileCtors(file, ctors)
  // #3044: @projectable pre-scan + view/toView/tryInto registration (single-
  // file entry, so the scan covers only this file's own projectables).
  val allProjFqns: Map[String, Bool] = newMap()
  collectFileProjectables(file, allProjFqns)
  registerProjectableViews(file, allProjFqns, cases, sigs)
  val autoFfi = buildAutoFfiCtx()
  codegenPackageWithSigs(file, sigs, cases, ctors, autoFfi, allProjFqns)
}

// Codegen a package against a pre-built call registry `funcSigs` spanning the
// whole compilation (this file's funcs plus every imported / stdlib package's).
// The multi-package bridge builds one global registry from all files and hands
// the same map to each package, so cross-package calls resolve owner + descriptor.
pub func codegenPackageWithSigs(
  file: in SourceFile,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  allProjFqns: in Map[String, Bool],
): LPackage {
  val emptySeed: Map[String, String] = newMap()
  codegenPackageWithSigsSeeded(file, funcSigs, caseFields, ctors, autoFfi, allProjFqns, emptySeed)
}

// As `codegenPackageWithSigs`, but resolving extern-type aliases against the
// file's own declarations UNION `externSeed` (imported packages' extern
// types; own declarations win) — see `collectFileSigsSeeded`.
pub func codegenPackageWithSigsSeeded(
  file: in SourceFile,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  // #3044: complete set of @projectable opaque JVM class names across the
  // whole compilation (pre-scanned via `collectFileProjectables`), so the
  // nested-view substitution and tryInto() eligibility are declaration-order-
  // independent — the JVM counterpart of the MSIL `allProjFqns`.
  allProjFqns: in Map[String, Bool],
  externSeed: in Map[String, String],
): LPackage {
  val pkgName = segmentsToJvmPath(file.packageDecl.path.segments)
  val funcsClass = pkgName

  // Collect extern-type declarations: alias → Java FQN.
  val externTypes = mergeExternSeed(collectExternTypesFromFile(file), externSeed)

  // m-2: collect the module-level `val NAME` declarations up front (name → JVM
  // type) so a bare reference to one resolves to `getstatic <hostClass>.<name>`
  // in every function of this package.
  val moduleVals: Map[String, JvmType] = newMap()
  collectFileValsExtern(file, pkgName, moduleVals, externTypes)
  // J3 M-3: collect opaque-type class names so field reads on opaque receivers
  // route through the `$<name>()` accessor methods instead of a direct getfield.
  val opaqueTypes: Map[String, Bool] = newMap()
  collectFileOpaque(file, pkgName, opaqueTypes)

  val fns: List[LFunc] = newList()
  val items: List[LPackageItem] = newList()
  // m-2: module-level `val NAME = expr` declarations, accumulated into the host
  // class's `<clinit>` as `public static final` fields.  All inits share one
  // FuncCtx (`valInitCtx`) so their local-slot numbering stays disjoint when the
  // initialisers are concatenated into a single `<clinit>` body.
  val staticVals: List[LStaticVal] = newList()
  // J2b closures (#2665): the package-shared closure accumulator,
  // threaded through every top-level `func` / module-`val` / `impl` / `interface`
  // FuncCtx so that an `ELambda` anywhere on those paths registers its synthesised
  // inner class here.  Drained into `LPClosureClass` items after the item loop.
  val closureAcc: List[LClosure] = newList()
  val valInitCtx = makeFuncCtx(
    pkgName,
    funcsClass,
    funcSigs,
    caseFields,
    ctors,
    externTypes,
    autoFfi,
    JVoid,
    moduleVals,
    opaqueTypes,
    closureAcc
  )
  // #2853: lower every module-level `val` once, now, and overwrite `moduleVals`
  // with the real field type before any function (or the `<clinit>` itself) is
  // lowered — so a bare reference's `getstatic` descriptor matches the emitted
  // field.  The IVal item loop below reuses these cached insns / types.
  val loweredVals = prelowerModuleVals(file, pkgName, valInitCtx, moduleVals)
  var hasMain = false
  // Captured return type of the Lyric `main(): T` so the JVM wrapper can
  // emit a correctly-typed invokestatic.  `JVoid` until / unless a main is
  // observed.  An `Int` return is routed to `java.lang.System.exit(int)`
  // so the value becomes the process exit code (#3303); other category-1
  // returns are popped.
  var mainRet: JvmType = JVoid
  // True when the Lyric main takes the `argv: slice[String]` parameter —
  // the wrapper then forwards its incoming `String[]` (covariantly
  // assignable to the erased `Object[]` slice representation, #3303).
  var mainHasArgs = false

  // ── IImpl pre-pass ──────────────────────────────────────────────────────────
  // Collect all IImpl blocks before the main item loop so that when IRecord
  // is processed, its ClassFile can include the correct `implements` list.
  val implEntries: List[ImplEntry] = newList()
  var pi = 0
  while pi < file.items.count {
    match file.items[pi].kind {
      case IImpl(decl) -> {
        val targetClass = typeExprToJvmClass(decl.target, pkgName)
        val ifaceClass = constraintRefToJvmClass(decl.iface, pkgName)
        val implFuncs: List[LFunc] = newList()
        var mi2 = 0
        while mi2 < decl.members.count {
          match decl.members[mi2] {
            case IMplFunc(fn) -> {
              // Emit each impl method as a true instance method on the target
              // class (#1722).  `lowerImplMethod` uses `makeFuncCtxInstance` so
              // `selfClass = Some(targetClass)` — bare `m()` and `self.m()` calls
              // inside the body dispatch as `invokevirtual`.  `out`/`inout` params
              // are fully supported via `setupInstanceParamSlotsAndHolders` and
              // `lowerVirtualCallWithHolders` at the call site (#1763).
              implFuncs.add(
                lowerImplMethod(
                  targetClass,
                  fn,
                  pkgName,
                  funcSigs,
                  caseFields,
                  ctors,
                  externTypes,
                  autoFfi,
                  moduleVals,
                  opaqueTypes,
                  closureAcc
                )
              )
            }
            case IMplAssoc(_) -> {
            }
          }
          mi2 = mi2 + 1
        }
        implEntries.add(ImplEntry(targetClass = targetClass, ifaceClass = ifaceClass, methods = implFuncs))
      }
      case _ -> {
      }
    }
    pi = pi + 1
  }

  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IFunc(decl) -> {
        if decl.isAsync and funcBodyContainsYield(decl) {
          // Async generator: synthesise Iterable+Iterator class via lowerAsyncGenerator.
          val genClass = pkgName + "$" + decl.name + "$Gen"
          val bodyInsns = lowerGeneratorBody(
            decl,
            pkgName,
            genClass,
            funcSigs,
            caseFields,
            ctors,
            externTypes,
            autoFfi,
            moduleVals,
            opaqueTypes,
            closureAcc
          )
          val genParams: List[LGenParam] = newList()
          var pi = 0
          while pi < decl.params.count {
            val p = decl.params[pi]
            genParams.add(LGenParam(paramName = p.name, paramType = typeExprToJvm(p.ty, pkgName)))
            pi = pi + 1
          }
          val elemTy = match decl.ret {
            case Some(te) -> typeExprToJvm(te, pkgName)
            case None -> JRef(className = "java/lang/Object")
          }
          val genFunc = LGenFunc(
            generatorClass = genClass,
            hostClass = "",
            // pipeline adds factory to LPFuncs instead
            methodName = decl.name,
            elemType = elemTy,
            params = genParams,
            bodyInsns = bodyInsns
          )
          items.add(LPAsyncGenerator(g = genFunc))
          // Factory method lives alongside main() in the functions class.
          fns.add(makeGeneratorFactory(decl, genClass, pkgName))
        } else {
          fns.add(
            lowerFunc(
              decl,
              pkgName,
              funcsClass,
              funcSigs,
              caseFields,
              ctors,
              externTypes,
              autoFfi,
              moduleVals,
              opaqueTypes,
              closureAcc
            )
          )
          if isMainFunc(decl) {
            hasMain = true
            mainHasArgs = decl.params.count == 1
            // Resolve the Lyric main's declared return type so the JVM
            // wrapper can call it with the matching descriptor.
            mainRet = match decl.ret { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }
          }
        }
      }
      case IRecord(decl) -> {
        // Look up any IImpl entries for this type and inject interfaces + methods.
        val className = pkgName + "/" + decl.name
        val ifaces: List[String] = newList()
        val implFuncs: List[LFunc] = newList()
        var ei = 0
        while ei < implEntries.count {
          if implEntries[ei].targetClass == className {
            ifaces.add(implEntries[ei].ifaceClass)
            val ms = implEntries[ei].methods
            var mi3 = 0
            while mi3 < ms.count {
              implFuncs.add(ms[mi3])
              mi3 = mi3 + 1
            }
          }
          ei = ei + 1
        }
        val baseRec = lowerRecord(
          decl,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          opaqueTypes,
          closureAcc
        )
        val mergedMethods: List[LFunc] = newList()
        for fn in baseRec.methods.toArray() {
          mergedMethods.add(fn)
        }
        for fn in implFuncs.toArray() {
          mergedMethods.add(fn)
        }
        items.add(
          LPRecord(
            rec = LRecord(
              className = baseRec.className,
              fields = baseRec.fields,
              methods = mergedMethods,
              implementsIfaces = ifaces
            )
          )
        )
      }
      case IExposedRec(decl) -> {
        // Same impl-injection logic as `IRecord` (#900): `impl Trait
        // for ExposedRec { … }` blocks targeting an exposed-record
        // type must inject `implements` clauses + method bodies into
        // the emitted ClassFile, otherwise the record carries the
        // declared interface only in source-level AST and the JVM
        // verifier rejects dispatch through `Trait`-typed slots.
        val className = pkgName + "/" + decl.name
        val ifaces: List[String] = newList()
        val implFuncs: List[LFunc] = newList()
        var ei = 0
        while ei < implEntries.count {
          if implEntries[ei].targetClass == className {
            ifaces.add(implEntries[ei].ifaceClass)
            val ms = implEntries[ei].methods
            var mi3 = 0
            while mi3 < ms.count {
              implFuncs.add(ms[mi3])
              mi3 = mi3 + 1
            }
          }
          ei = ei + 1
        }
        val baseRec = lowerRecord(
          decl,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          opaqueTypes,
          closureAcc
        )
        val mergedMethods: List[LFunc] = newList()
        for fn in baseRec.methods.toArray() {
          mergedMethods.add(fn)
        }
        for fn in implFuncs.toArray() {
          mergedMethods.add(fn)
        }
        items.add(
          LPRecord(
            rec = LRecord(
              className = baseRec.className,
              fields = baseRec.fields,
              methods = mergedMethods,
              implementsIfaces = ifaces
            )
          )
        )
      }
      case IUnion(decl) -> {
        items.add(LPSealedUnion(su = lowerUnion(decl, pkgName, externTypes)))
      }
      case IConst(_) -> {
      }
      case IVal(decl) -> {
        // m-2: module-level `val NAME = expr` → `public static final` field
        // initialised in the host class's `<clinit>` (parity with the MSIL
        // `.cctor` static-field path).  Only the simple `val NAME = …` binding
        // form participates; destructuring patterns at module scope are not
        // emitted (no MSIL counterpart either).
        match decl.pattern.kind {
          case PBinding(name, _) -> {
            // #2853: reuse the single pre-lowering (cached in `loweredVals`) so
            // the emitted field type is identical to the one `moduleVals`
            // carries for bare-reference `getstatic`.  The cache is always
            // populated for the PBinding form (same scan as here).
            match findLoweredModuleVal(loweredVals, name) {
              case Some(lv) -> staticVals.add(LStaticVal(name = name, valType = lv.field, initInsns = lv.insns))
              case None -> ()
            }
          }
          case _ -> ()
        }
      }
      case ITypeAlias(_) -> {
      }
      case IDistinctType(decl) -> {
        val inner = typeExprToJvm(decl.underlying, pkgName)
        items.add(LPDistinctType(dt = LDistinctType(wrapperClass = pkgName + "/" + decl.name, underlyingType = inner)))
      }
      case IEnum(decl) -> {
        val className2 = pkgName + "/" + decl.name
        val variants: List[String] = newList()
        var ci = 0
        while ci < decl.cases.count {
          variants.add(decl.cases[ci].name)
          ci = ci + 1
        }
        items.add(LPEnum(en = LEnumType(className = className2, variants = variants)))
      }
      case IOpaque(decl) -> {
        // J3 M-3: emit the opaque-type wrapper class plus its Java-interop
        // facade via the existing `Jvm.Lowering.lowerOpaqueType` /
        // `lowerOpaqueFacade` (driven from `LPOpaqueType`).  A body-less opaque
        // declaration (`opaque type X` with no `{ … }`) has no fields to wrap,
        // so it contributes no class — matching the MSIL `hasBody` guard.
        // A `@projectable` opaque (#3044) instead drives `lowerProjectableType`
        // (via `LPProjectable`), which additionally emits the `<Name>View`
        // twin, `toView()`, and — when eligible — `tryInto()`, mirroring the
        // MSIL `lowerMOpaque` projectable path (PR #3015).
        if decl.hasBody {
          if hasAnnotationJvm(decl.annotations, "projectable") {
            val pInfos = buildProjFieldInfos(decl, pkgName, allProjFqns)
            items.add(
              LPProjectable(
                pt = LProjectableType(
                  opaqueClassName = pkgName + "/" + decl.name,
                  viewClassName = pkgName + "/" + decl.name + "View",
                  fields = pInfos,
                  emitTryInto = projCanTryInto(pInfos)
                )
              )
            )
          } else {
            val oFields: List[LOpaqueField] = newList()
            var ofi = 0
            while ofi < decl.members.count {
              match decl.members[ofi] {
                case OMField(f) -> oFields.add(LOpaqueField(name = f.name, fieldType = typeExprToJvm(f.ty, pkgName)))
                case OMInvariant(_) -> ()
              }
              ofi = ofi + 1
            }
            items.add(LPOpaqueType(ot = LOpaqueType(className = pkgName + "/" + decl.name, fields = oFields)))
          }
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: emit a record-shaped class via `buildProtected` (an
        // `LPRecord`).  Field members become private data fields; each `entry`
        // / helper `func` becomes an instance method whose bare field
        // references resolve through `selfClass` (slot 0 = `this`).  Real
        // ReentrantLock guarding is a documented cross-target gap — MSIL also
        // emits protected types as plain records.
        items.add(
          buildProtected(
            decl,
            pkgName,
            funcSigs,
            caseFields,
            ctors,
            externTypes,
            autoFfi,
            moduleVals,
            opaqueTypes,
            closureAcc
          )
        )
      }
      case IInterface(decl) -> {
        // Emit a JVM interface ClassFile: one abstract method per IMSig member.
        val ifClassName = pkgName + "/" + decl.name
        val abstractMethods: List[MethodInfo] = newList()
        val concreteFuncs: List[LFunc] = newList()
        val emptyAttrs: List[Attribute] = newList()
        var imi = 0
        while imi < decl.members.count {
          match decl.members[imi] {
            case IMSig(sig) -> {
              val noTpsIface: List[String] = newList()
              val params = holderAwareParamTypes(sig.params, pkgName, true, noTpsIface, externTypes)
              val ret = match sig.ret { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }
              val desc = buildDescriptor(params, ret)
              abstractMethods.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, sig.name, desc, emptyAttrs))
            }
            case IMFunc(fn) -> {
              concreteFuncs.add(
                lowerFunc(
                  fn,
                  pkgName,
                  ifClassName,
                  funcSigs,
                  caseFields,
                  ctors,
                  externTypes,
                  autoFfi,
                  moduleVals,
                  opaqueTypes,
                  closureAcc
                )
              )
            }
            case IMAssoc(_) -> {
            }
          }
          imi = imi + 1
        }
        items.add(
          LPInterface(
            iface = LInterface(className = ifClassName, abstractMethods = abstractMethods, concreteFuncs = concreteFuncs)
          )
        )
      }
      case IImpl(_) -> {
      }   // handled by pre-pass above
      case IWire(decl) -> {
        // J3 M-3: emit a final DI factory class via the existing
        // `Jvm.Lowering.lowerWire` (driven from `LPWire`): one private static
        // field per binding, a private ctor, a `bootstrap()V` that initialises
        // the bindings in declaration order, and a public static accessor per
        // exposed binding.
        items.add(
          LPWire(
            w = buildWire(
              decl,
              pkgName,
              funcSigs,
              caseFields,
              ctors,
              externTypes,
              autoFfi,
              moduleVals,
              opaqueTypes,
              closureAcc
            )
          )
        )
      }
      case IScopeKind(_) -> {
      }
      case IExtern(_) -> {
      }
      case IExternType(_) -> {
      }
      case IExternFunc(decl) -> {
        // A C-ABI `extern func` (D-N-007) only exists on the native target;
        // reaching the JVM backend means the source is being compiled for
        // the wrong target — reject loudly instead of emitting a call to a
        // function that was silently dropped (#4630).
        panic(
          "extern func '" + decl.name +
            "' is only supported with --target native; on the JVM declare the binding via extern type auto-FFI in a _kernel_jvm/ package instead"
        )
      }
      case ITest(_) -> {
      }
      case IProperty(_) -> {
      }
      case IFixture(_) -> {
      }
      case IConfig(_) -> {
        // J3 M-3: `config { … }` blocks declare compile-time DI configuration
        // (D046 / D048).  They are resolved during config/wire resolution and
        // carry no standalone runtime representation — the MSIL backend emits
        // nothing for `IConfig` for the same reason, so this is intentional
        // parity, not a dropped body.  When the config-resolution phase lands a
        // JVM consumer it will read the resolved values directly rather than a
        // synthesised class.
      }
      case IAspect(_) -> {
      }
      case IError -> {
      }
    }
    i = i + 1
  }

  // If there's a `main(): T` function, add a JVM-main wrapper that accepts
  // String[] and delegates to the Lyric main().  The wrapper has to call the
  // Lyric main with its actual return descriptor (e.g. `()I` for `Int`,
  // `()V` for `Unit`) — otherwise the JVM raises NoSuchMethodError.  Any
  // non-void return value is dropped (POP/POP2) before returning; exposing
  // it as a process exit code is a follow-up via java.lang.System.exit.
  if hasMain {
    // Guard against Long/Double `main` returns: the wrapper would need
    // category-2 `POP2` to discard them, and the generator only emits
    // category-1 `LPop` today.  Emitting `LPop` against a 2-slot value
    // would leave the stack unbalanced and trigger a JVM `VerifyError`
    // at class load.  Refuse to compile rather than silently produce a
    // broken class file; the source program can wrap the value in an
    // `Int` return (the idiomatic exit-code shape) or `Unit`.
    // bridge.l::mainReturns2SlotType pre-validates literal Long/Double
    // return-type identifiers via J001 before reaching codegenPackage,
    // but only catches the bare name; a type alias such as
    // `type MyLong = Long` resolves to JLong here and trips these
    // panics rather than J001.  See follow-up to widen
    // mainReturns2SlotType to the resolved slot type.
    match mainRet {
      case JLong -> panic("Jvm.Codegen: `func main(): Long` is not supported on the JVM target — wrap the result in `Int` or `Unit`")
      case JDouble -> panic("Jvm.Codegen: `func main(): Double` is not supported on the JVM target — wrap the result in `Int` or `Unit`")
      case _ -> ()
    }
    val jvmMainParams: List[JvmType] = newList()
    jvmMainParams.add(JArray(elem = JRef(className = "java/lang/String")))
    val jvmMainInsns: List[LInsn] = newList()
    val lyricMainPs: List[JvmType] = newList()
    if mainHasArgs {
      // Forward the JVM `String[]` argv to the Lyric main's erased
      // `slice[String]` parameter (`Object[]`) — legal by JVM array
      // covariance, no copy needed (#3303).
      lyricMainPs.add(JArray(elem = JRef(className = "java/lang/Object")))
      jvmMainInsns.add(LAload(slot = 0))
    }
    jvmMainInsns.add(LInvokestatic(owner = funcsClass, name = "main", params = lyricMainPs, ret = mainRet))
    // An `Int` return becomes the process exit code via
    // `java.lang.System.exit(int)` (#3303) — branchless, so the wrapper
    // needs no StackMapTable.  The Long/Double 2-slot cases are rejected
    // above; every other non-void return is category-1 and popped.
    match mainRet {
      case JVoid -> ()
      case JInt -> {
        val exitPs: List[JvmType] = newList()
        exitPs.add(JInt)
        jvmMainInsns.add(LInvokestatic(owner = "java/lang/System", name = "exit", params = exitPs, ret = JVoid))
      }
      case _ -> jvmMainInsns.add(LPop)
    }
    jvmMainInsns.add(LReturn)
    val jvmMain = LFunc(
      flags = 0x0009,
      name = "main",
      params = jvmMainParams,
      ret = JVoid,
      insns = jvmMainInsns,
      maxStack = 2,
      maxLocals = 1
    )
    fns.add(jvmMain)
  }

  // `__lyricCount(Object)I` — the erased-receiver `.count`/`.length`
  // dispatch as a synthesised static helper.  Emitting the runtime-class
  // branches INLINE at the member-access site broke verification whenever
  // the access ran with values already stacked (`i < pairs.count` in a
  // while condition evaluates the dispatch with `i` on the stack, and the
  // StackMapTable declares an empty stack at every branch target).  A
  // static call is branch-free at the call site; the helper's own frames
  // start from an empty stack.  Every arm returns directly, so there is
  // no join.  Unconditionally emitted: ~40 bytes per package class.
  val lcInsns: List[LInsn] = newList()
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LInstanceof(className = "java/util/Collection"))
  lcInsns.add(LIfeq(label = "__lc_map"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LCheckcast(className = "java/util/Collection"))
  val lcColPs: List[JvmType] = newList()
  lcInsns.add(
    LInvokeinterface(owner = "java/util/Collection", name = "size", params = lcColPs, ret = JInt, argCount = 1)
  )
  lcInsns.add(LIreturn)
  lcInsns.add(LLabel(name = "__lc_map"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LInstanceof(className = "java/util/Map"))
  lcInsns.add(LIfeq(label = "__lc_str"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LCheckcast(className = "java/util/Map"))
  val lcMapPs: List[JvmType] = newList()
  lcInsns.add(LInvokeinterface(owner = "java/util/Map", name = "size", params = lcMapPs, ret = JInt, argCount = 1))
  lcInsns.add(LIreturn)
  lcInsns.add(LLabel(name = "__lc_str"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LInstanceof(className = "java/lang/String"))
  lcInsns.add(LIfeq(label = "__lc_arr"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LCheckcast(className = "java/lang/String"))
  val lcLenPs: List[JvmType] = newList()
  lcInsns.add(LInvokevirtual(owner = "java/lang/String", name = "length", params = lcLenPs, ret = JInt))
  lcInsns.add(LIreturn)
  // Last resort: a boxed slice (`Object[]`).  Anything else fails the
  // checkcast loudly rather than yielding a wrong value.
  lcInsns.add(LLabel(name = "__lc_arr"))
  lcInsns.add(LAload(slot = 0))
  lcInsns.add(LCheckcast(className = "[Ljava/lang/Object;"))
  lcInsns.add(LArraylength)
  lcInsns.add(LIreturn)
  val lcParams: List[JvmType] = newList()
  lcParams.add(JRef(className = "java/lang/Object"))
  fns.add(
    LFunc(
      flags = 0x0009,
      name = "__lyricCount",
      params = lcParams,
      ret = JInt,
      insns = lcInsns,
      maxStack = 2,
      maxLocals = 1
    )
  )

  // `__lyricUnwrapOr(Object, Object)Object` — Std.Core's generic
  // `unwrapOr(Option[T], T): T` as a synthesised helper.  Generic
  // functions are never emitted as JVM methods, and a call the
  // monomorphizer cannot specialise linked against a phantom
  // descriptor (see the `__lyricCount` note above for why the
  // branches must live in a helper, not inline at the call site).
  val uoInsns: List[LInsn] = newList()
  uoInsns.add(LAload(slot = 0))
  uoInsns.add(LInstanceof(className = "Std/Core/Option$Some"))
  uoInsns.add(LIfeq(label = "__uo_dflt"))
  uoInsns.add(LAload(slot = 0))
  uoInsns.add(LCheckcast(className = "Std/Core/Option$Some"))
  uoInsns.add(LGetfield(owner = "Std/Core/Option$Some", name = "value", t = JRef(className = "java/lang/Object")))
  uoInsns.add(LAreturn)
  uoInsns.add(LLabel(name = "__uo_dflt"))
  uoInsns.add(LAload(slot = 1))
  uoInsns.add(LAreturn)
  val uoParams: List[JvmType] = newList()
  uoParams.add(JRef(className = "java/lang/Object"))
  uoParams.add(JRef(className = "java/lang/Object"))
  fns.add(
    LFunc(
      flags = 0x0009,
      name = "__lyricUnwrapOr",
      params = uoParams,
      ret = JRef(className = "java/lang/Object"),
      insns = uoInsns,
      maxStack = 2,
      maxLocals = 2
    )
  )

  items.add(LPFuncs(funcsClass = funcsClass, fns = fns, staticVals = staticVals))

  // J2b closures (#2665): drain the accumulated lambda closures into package
  // items, and — if any lambda was emitted — add the one shared functional
  // interface `<pkg>/Lyric$Lambda` they all implement
  // (`invoke([Ljava/lang/Object;)Ljava/lang/Object;`).
  if closureAcc.count > 0 {
    val ifaceName = lambdaIfaceName(pkgName)
    val ifaceParams: List[JvmType] = newList()
    ifaceParams.add(JArray(elem = JRef(className = "java/lang/Object")))
    val ifaceDesc = buildDescriptor(ifaceParams, JRef(className = "java/lang/Object"))
    val ifaceAttrs: List[Attribute] = newList()
    val ifaceAbstract: List[MethodInfo] = newList()
    ifaceAbstract.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, lambdaIfaceMethod(), ifaceDesc, ifaceAttrs))
    val ifaceConcrete: List[LFunc] = newList()
    items.add(
      LPInterface(
        iface = LInterface(className = ifaceName, abstractMethods = ifaceAbstract, concreteFuncs = ifaceConcrete)
      )
    )
    var li = 0
    while li < closureAcc.count {
      items.add(LPClosureClass(c = closureAcc[li]))
      li = li + 1
    }
  }

  LPackage(packageName = pkgName, items = items)
}
