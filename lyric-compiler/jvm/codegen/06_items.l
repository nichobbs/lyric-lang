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
import Lyric.BareFuncRef as BareFuncRef
import Lyric.ModeChecker
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
  // #6393: see `FuncCtx.aliasTargets`.
  aliasTargets: in Map[String, TypeExpr],
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
    configFieldTypes = configFieldTypes,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    usesLyricCount = usesLyricCount,
    importsStdString = importsStdString,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    varGenericArgs = newMap(),
    funcValRetTypes = newMap(),
    wireClassName = "",
    wireBindingTypes = newMap(),
    scopeExecSlots = newList(),
    spawnResultTypes = newMap(),
    scopeBase = 0,
    scopeUndo = newList(),
    ctorExpectStack = newList(),
    ctorExpectClassStack = newList(),
    aliasTargets = aliasTargets,
    unsignedVars = newMap(),
    unsignedUndo = newList(),
    varGenericArgsUndo = newList()
  )
}

// Derive a wire-binding-init `FuncCtx` from a freshly-made one (#5013): every
// field is carried through unchanged except `wireClassName`/`wireBindingTypes`,
// so a bare-name reference anywhere inside the binding's init expression tree
// (not just as the whole top-level init) can resolve to `getstatic` on the
// wire class instead of falling through to the module-val / null fallback.
func withWireBinding(ctx: in FuncCtx, wireClassName: in String, wireBindingTypes: in Map[String, JvmType]): FuncCtx {
  FuncCtx(
    pkgName = ctx.pkgName,
    className = ctx.className,
    slots = ctx.slots,
    types = ctx.types,
    slotTicker = ctx.slotTicker,
    labelTicker = ctx.labelTicker,
    loopBreak = ctx.loopBreak,
    loopCont = ctx.loopCont,
    genClass = ctx.genClass,
    funcSigs = ctx.funcSigs,
    caseFields = ctx.caseFields,
    ctors = ctx.ctors,
    externTypes = ctx.externTypes,
    autoFfi = ctx.autoFfi,
    retTy = ctx.retTy,
    deferStack = ctx.deferStack,
    loopDeferDepth = ctx.loopDeferDepth,
    deferRanSlots = ctx.deferRanSlots,
    selfClass = ctx.selfClass,
    moduleVals = ctx.moduleVals,
    configFieldTypes = ctx.configFieldTypes,
    opaqueTypes = ctx.opaqueTypes,
    closureAcc = ctx.closureAcc,
    usesLyricCount = ctx.usesLyricCount,
    importsStdString = ctx.importsStdString,
    holderArraySlot = ctx.holderArraySlot,
    holderElemType = ctx.holderElemType,
    hoistedVarNames = ctx.hoistedVarNames,
    hoistedCellSlot = ctx.hoistedCellSlot,
    hoistedCellType = ctx.hoistedCellType,
    varGenericArgs = ctx.varGenericArgs,
    funcValRetTypes = ctx.funcValRetTypes,
    wireClassName = wireClassName,
    wireBindingTypes = wireBindingTypes,
    scopeExecSlots = ctx.scopeExecSlots,
    spawnResultTypes = ctx.spawnResultTypes,
    scopeBase = ctx.scopeBase,
    scopeUndo = ctx.scopeUndo,
    ctorExpectStack = ctx.ctorExpectStack,
    ctorExpectClassStack = ctx.ctorExpectClassStack,
    aliasTargets = ctx.aliasTargets,
    unsignedVars = ctx.unsignedVars,
    unsignedUndo = ctx.unsignedUndo,
    varGenericArgsUndo = ctx.varGenericArgsUndo
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
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
    configFieldTypes = configFieldTypes,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    usesLyricCount = usesLyricCount,
    importsStdString = importsStdString,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    varGenericArgs = newMap(),
    funcValRetTypes = newMap(),
    wireClassName = "",
    wireBindingTypes = newMap(),
    scopeExecSlots = newList(),
    spawnResultTypes = newMap(),
    scopeBase = 0,
    scopeUndo = newList(),
    ctorExpectStack = newList(),
    ctorExpectClassStack = newList(),
    // #6393: a generator body has no reachable file-scoped alias table at
    // this call site — out of scope for now (see `FuncCtx.aliasTargets`).
    aliasTargets = newMap(),
    unsignedVars = newMap(),
    unsignedUndo = newList(),
    varGenericArgsUndo = newList()
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
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
    configFieldTypes = configFieldTypes,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    usesLyricCount = usesLyricCount,
    importsStdString = importsStdString,
    holderArraySlot = newMap(),
    holderElemType = newMap(),
    hoistedVarNames = newList(),
    hoistedCellSlot = newMap(),
    hoistedCellType = newMap(),
    varGenericArgs = newMap(),
    funcValRetTypes = newMap(),
    wireClassName = "",
    wireBindingTypes = newMap(),
    scopeExecSlots = newList(),
    spawnResultTypes = newMap(),
    scopeBase = 0,
    scopeUndo = newList(),
    ctorExpectStack = newList(),
    ctorExpectClassStack = newList(),
    // #6393: an instance-method body (protected-type entry / record method /
    // impl method) has no reachable file-scoped alias table at this call
    // site — out of scope for now (see `FuncCtx.aliasTargets`).
    aliasTargets = newMap(),
    unsignedVars = newMap(),
    unsignedUndo = newList(),
    varGenericArgsUndo = newList()
  )
}

// Emit a return, boxing a primitive array (`JArray(primitiveElem)`) into a
// `java.lang.Object[]` of the matching boxed wrapper type when the declared
// return type is the erased Lyric slice representation (`JArray(JRef
// Object)`).  This is the return-side counterpart of `emitFfiCoerce`'s
// generalized `[Ljava/lang/Object; -> primitive[]` arg coercion: it lets a
// `_kernel_jvm` host declare `slice[T]` while internally producing a raw JDK
// primitive array (e.g. a `MessageDigest.digest` `byte[]`, or an `int[]` /
// `double[]` / etc. from any other JDK API), so the value crossing the
// function boundary actually matches the method's `[Ljava/lang/Object;`
// descriptor.
func emitReturnArrayCoerced(ctx: in FuncCtx, insns: in List[LInsn], tailTy: in JvmType, retTy: in JvmType): Unit {
  coerceValueTo(ctx, insns, tailTy, retTy)
  emitReturn(insns, retTy)
}

// Ctx-aware value coercion for binding sites: the coercion half of
// `emitReturnArrayCoerced`, split out so the explicit `return` statement path
// (`SReturn` in `05_stmts.l`) applies the same primitive-array boxing this
// function does for an implicit tail-expression return, instead of skipping
// it: only the tail-position path applied this coercion, so `return
// someIntArray` on a `slice[Int]` function crashed at runtime while an
// equivalent tail expression worked.  Constructor arguments and annotated
// local bindings route through here too (#5572): a raw JDK primitive array
// (`s.getBytes()` → `[B`) flowing into a declared `slice[T]` field or local
// (`[Ljava/lang/Object;`) previously kept its primitive representation while
// the slot/field descriptor claimed the erased shape — a VerifyError at class
// load (plain form: "Bad type on operand stack" at the ctor invokespecial;
// inside a try/catch: "Stack map does not match the one at exception
// handler").  NOTE: `emitBoxPrimitiveArray` emits a back-branching loop, and
// the StackMapTable generator assumes an empty operand stack at branch
// targets — call this only where the value being coerced is the only thing
// on the operand stack (statement-position bindings, or the
// args-stashed-to-locals constructor/call patterns).
func coerceValueTo(ctx: in FuncCtx, insns: in List[LInsn], tailTy: in JvmType, retTy: in JvmType): Unit {
  if isPrimitiveArrayToObjectArray(tailTy, retTy) {
    match tailTy {
      case JArray(elemTy) -> emitBoxPrimitiveArray(ctx, insns, elemTy)
      case _ -> ()
    }
  } else {
    // Numeric / reference coercion so the tail value matches the declared
    // return descriptor (e.g. a plain `1.5` Double tail in a `: Float`
    // function narrows with d2f before `freturn`).
    coerceArgTo(insns, tailTy, retTy)
  }
}

// As `coerceValueTo`, but for `putfield` shapes where a receiver is already
// on the operand stack beneath the value.  `emitBoxPrimitiveArray`
// back-branches and the StackMapTable generator types every branch-target
// frame with an EMPTY operand stack, so the stacked receiver must be
// spilled to a local around the boxing loop and restored after (#5609
// item 2 — a `[B` assigned into a `slice[Byte]`-typed field either kept
// its primitive representation (putfield VerifyError "Bad type on operand
// stack") or, boxed in place, tripped the empty-stack frame invariant).
// The single-instruction coercions keep the direct `coerceArgTo` path.
func coerceValueToUnderReceiver(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  recvTy: in JvmType,
  vTy: in JvmType,
  fty: in JvmType,
): Unit {
  if isPrimitiveArrayToObjectArray(vTy, fty) {
    val vSlot = allocSlot(ctx, "__pfv_" + freshLabel(ctx), vTy)
    emitStore(insns, vSlot, vTy)
    val rSlot = allocSlot(ctx, "__pfr_" + freshLabel(ctx), recvTy)
    emitStore(insns, rSlot, recvTy)
    emitLoad(insns, vSlot, vTy)
    coerceValueTo(ctx, insns, vTy, fty)
    val bSlot = allocSlot(ctx, "__pfb_" + freshLabel(ctx), fty)
    emitStore(insns, bSlot, fty)
    emitLoad(insns, rSlot, recvTy)
    emitLoad(insns, bSlot, fty)
  } else {
    coerceArgTo(insns, vTy, fty)
  }
}

// True when `fromTy` is a JVM primitive array (`boolean[]`/`char[]`/
// `float[]`/`double[]`/`byte[]`/`short[]`/`int[]`/`long[]`) and `toTy` is the
// erased Lyric slice representation `java.lang.Object[]` (`JArray(JRef
// ...)`).
func isPrimitiveArrayToObjectArray(fromTy: in JvmType, toTy: in JvmType): Bool {
  match fromTy {
    case JArray(fe) -> {
      if isJvmPrimitiveElemType(fe) {
        match toTy {
          case JArray(te) -> {
            match te {
              case JRef(_) -> true
              case _ -> false
            }
          }
          case _ -> false
        }
      } else {
        false
      }
    }
    case _ -> false
  }
}

// Replace a primitive array on top of the operand stack with a freshly built
// `java.lang.Object[]` of the boxed wrapper type matching `elemTy` (the
// erased Lyric `slice[T]` representation).  The inverse of `emitFfiCoerce`'s
// generalized `[Ljava/lang/Object; -> primitive[]` arg coercion.  Generated
// bytecode mirrors the element-copy loop documented there.
func emitBoxPrimitiveArray(ctx: in FuncCtx, insns: in List[LInsn], elemTy: in JvmType): Unit {
  val srcSlot = allocSlot(ctx, "__box_arr_src_" + freshLabel(ctx), JArray(elem = elemTy))
  val dstSlot = allocSlot(ctx, "__box_arr_dst_" + freshLabel(ctx), JArray(elem = JRef(className = "java/lang/Object")))
  val idxSlot = allocSlot(ctx, "__box_arr_idx_" + freshLabel(ctx), JInt)
  val lenSlot = allocSlot(ctx, "__box_arr_len_" + freshLabel(ctx), JInt)
  val loopL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  // `LAstoreAs` carries the array descriptor so the StackMapTable types the
  // slot as the primitive array / `[Ljava/lang/Object;` rather than the
  // plain-Object default — a primitive `Txaload` / `aastore` on an
  // Object-typed local is a VerifyError.
  insns.add(LAstoreAs(slot = srcSlot, className = jvmTypeToDescStr(JArray(elem = elemTy))))
  insns.add(LAload(slot = srcSlot))
  insns.add(LArraylength)
  // The destination is `Object[]` populated with boxed wrapper instances —
  // `new <Wrapper>[len]`, NOT `newarray <primitive>` (that would allocate
  // another primitive array, the wrong direction for this function).
  insns.add(LAnewarray(className = wrapperClassNameFor(elemTy)))
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
  insns.add(primitiveArrayLoadInsn(elemTy))
  boxIfNeeded(insns, elemTy)
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
    // Resolve through `externTypes` on both arms (an earlier fix covered the
    // return-type side of this gap but left params on the `erase` arm calling
    // the plain `typeExprToJvmErased`, silently ignoring the `externTypes`
    // argument this function already takes — an extern-typed impl-method
    // param resolved to the in-package `<pkg>/<Name>` guess instead of the
    // real JVM class).
    val elemTy = if erase {
      typeExprToJvmErasedExtern(p.ty, pkgName, typeParams, externTypes)
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

// #6393: rebuild `params` with each param's declared type resolved through a
// function-type alias (`h: in Handler` -> `h: in (Int) -> Int`) — see
// `Lyric.BareFuncRef.resolveFuncTypeAliasOrSelf`.  A no-op copy for every
// param whose type is not (through an alias chain) function-shaped.
func resolveParamsFuncAlias(aliasTargets: in Map[String, TypeExpr], params: in List[Param]): List[Param] {
  val resolved: List[Param] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    resolved.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, p.ty),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  resolved
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
// to `setupStaticParamSlotsAndHolders` but uses `typeExprToJvmErasedExtern` with
// the caller-supplied `typeParams` list so generic record methods erase type
// variables to `Object`, matching the descriptor emitted for the method.  For
// non-generic methods pass `newList()` for `typeParams`.  Resolves through
// `externTypes` so a parameter typed with an imported extern type OR another
// package's record/interface (seeded as a dotted FQN by
// `collectFileDeclaredTypeFqns`) registers its slot under the real JVM class —
// the plain `typeExprToJvmErased` this used before fell to the declaring file's
// in-package `<pkg>/<Name>` guess, so `req.body` on a `Web.Request`-typed impl
// param panicked with "receiver of type 'Web/JvmServerSmoke/Request' has no
// known field or member" in a bundled multi-package compile (#5610); the slot
// type and the `holderAwareParamTypes` descriptor now stay in lockstep.
pub func setupInstanceParamSlotsAndHolders(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  params: in List[Param],
  pkgName: in String,
  typeParams: in List[String],
  externTypes: in Map[String, String],
): Unit {
  val holderIdx: List[Int] = newList()
  val holderSlots: List[Int] = newList()
  val holderElems: List[JvmType] = newList()
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    val elemTy = typeExprToJvmErasedExtern(p.ty, pkgName, typeParams, externTypes)
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
  // Record each parameter's declared slice/List element type so an indexed
  // element read narrows to its concrete class (docs/59 §4.3 #5439 class);
  // the receiver type's own generic params are filtered — they erase to Object.
  var rdi = 0
  while rdi < params.count {
    recordDeclaredElemType(ctx, params[rdi].name, params[rdi].ty, typeParams)
    // #5956: see `lowerFunc`'s matching call — an instance method's own
    // generic-instantiation-typed parameter needs the same registration.
    // #6660: `typeParams` (this method's own generic-parameter names) is
    // threaded through so `recordParamGenericArgs` can bail on an arg that
    // names an unresolved type parameter instead of guessing a phantom class.
    recordParamGenericArgs(ctx, params[rdi].name, params[rdi].ty, typeParams)
    // #6748: a `UInt`/`ULong`-typed parameter needs unsigned-aware
    // comparison/division/stringification inside the method body.
    recordUnsignedVarTy(ctx, params[rdi].name, params[rdi].ty)
    rdi = rdi + 1
  }
}

// Compute the pre-pass set of `var` names referenced inside lambdas
// in the function body.  These must be hoisted to heap cells for by-ref capture.
func computeHoistedVarNamesJvm(decl: in FunctionDecl, mutableVars: in Map[String, Bool]): List[String] {
  val inLambdaNames: List[String] = newList()
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(blk) -> collectInLambdaNamesBlock(blk, inLambdaNames)
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

// Collect all `var` declarations in a function body.  Mirrors the
// `collectInLambdaNamesExpr` traversal in `02_exprs.l` (same set of
// sub-expression-carrying `ExprKind` arms) so a `var` declared inside a
// block that appears in call-argument, operand, or other nested-expression
// position is not missed (#4264).  `ELambda` is deliberately NOT recursed
// into: a `var` declared inside a lambda's own body belongs to that
// lambda's own scope and is analyzed separately when the lambda is lowered.
func collectMutableVarsExpr(e: in Expr, acc: in Map[String, Bool]): Unit {
  match e.kind {
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      collectMutableVarsExpr(cond, acc)
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
      collectMutableVarsExpr(scr, acc)
      var ai = 0
      while ai < arms.count {
        match arms[ai].guard {
          case Some(guardExpr) -> collectMutableVarsExpr(guardExpr, acc)
          case None -> ()
        }
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
    case ECall(fn, args) -> {
      collectMutableVarsExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex) -> collectMutableVarsExpr(ex, acc)
          case CANamed(_, ex, _) -> collectMutableVarsExpr(ex, acc)
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectMutableVarsExpr(lhs, acc)
      collectMutableVarsExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> collectMutableVarsExpr(operand, acc)
    case EParen(inner) -> collectMutableVarsExpr(inner, acc)
    case EMember(recv, _) -> collectMutableVarsExpr(recv, acc)
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectMutableVarsExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectMutableVarsExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectMutableVarsExpr(recv, acc)
      var ii = 0
      while ii < indices.count {
        collectMutableVarsExpr(indices[ii], acc)
        ii = ii + 1
      }
    }
    case EAwait(inner) -> collectMutableVarsExpr(inner, acc)
    case EYield(inner) -> collectMutableVarsExpr(inner, acc)
    case ESpawn(inner) -> collectMutableVarsExpr(inner, acc)
    case ETry(inner) -> collectMutableVarsExpr(inner, acc)
    case EPropagate(inner) -> collectMutableVarsExpr(inner, acc)
    case EAssign(target, _, v) -> {
      collectMutableVarsExpr(target, acc)
      collectMutableVarsExpr(v, acc)
    }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> collectMutableVarsExpr(ex, acc)
          case _ -> ()
        }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> collectMutableVarsExpr(fn, acc)
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
  // #6393: same-file `alias X = ...` table — see `Lyric.BareFuncRef`'s
  // module doc §2 and `codegenPackageWithSigsSeeded`'s `aliasTargets`.
  // #6413 audit: kept for the stdlib-bundled-file gap, D-progress-752.
  aliasTargets: in Map[String, TypeExpr],
): LFunc {
  val resolvedRet = match decl.ret {
    case Some(te) -> Some(value = BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, te))
    case None -> None
  }
  val retTy = match resolvedRet { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }
  val resolvedParams = resolveParamsFuncAlias(aliasTargets, decl.params)

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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString,
    aliasTargets
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
  // `resolvedParams` (not `decl.params`) so a function-type alias param
  // (`h: in Handler`) allocates its slot as `Object`, exactly like the
  // literal `(Int) -> Int` annotation already does (#6393).
  setupStaticParamSlotsAndHolders(ctx, insns, resolvedParams, pkgName, externTypes)
  // Record each parameter's declared slice/List element type so an indexed
  // element read narrows to its concrete class (docs/59 §4.3 #5439 class);
  // the function's own type parameters are filtered — they erase to Object.
  val fnElemTps = genericParamNames(decl.generics)
  var rdi = 0
  while rdi < resolvedParams.count {
    recordDeclaredElemType(ctx, resolvedParams[rdi].name, resolvedParams[rdi].ty, fnElemTps)
    // #5956: a `Result[Age, String]`-typed (or any other generic-instantiation-
    // typed) parameter's own annotation seeds `varGenericArgs` so `match
    // <param> { … }` on it unboxes the payload — see `recordParamGenericArgs`.
    // #6660: `fnElemTps` (this function's own generic-parameter names,
    // already computed above for `recordDeclaredElemType`) is threaded
    // through so an arg naming an unresolved type param (e.g. `Result[T,
    // String]` on `func foo[T](...)`) bails instead of registering a
    // phantom `<pkgName>/T` class.
    recordParamGenericArgs(ctx, resolvedParams[rdi].name, resolvedParams[rdi].ty, fnElemTps)
    // #6748: see `setupInstanceParamSlotsAndHolders`'s matching call.
    recordUnsignedVarTy(ctx, resolvedParams[rdi].name, resolvedParams[rdi].ty)
    rdi = rdi + 1
  }

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
                  // #6735: seed the enum-hint expect-stack from this
                  // function's own declared return type before lowering
                  // the implicit tail-return expression, exactly like
                  // `SReturn` already does (05_stmts.l) — an implicit
                  // bare-case tail return (`func mk(): T.Level { Debug }`)
                  // is otherwise resolved with no expectation hint at all,
                  // falling through to the current-package/bare tiers and
                  // risking the same wrong-same-name-case resolution the
                  // #6728 CrossHintA/CrossHintB fix closed for the
                  // call-argument and pattern-match positions.
                  pushCtorExpect(ctx, retTy)
                  val tailTy = lowerBlockExpr(ctx, insns, block)
                  popCtorExpect(ctx)
                  // `try { … } finally { … }` in tail position now correctly
                  // propagates the try/catch result through the finally block
                  // via `lowerTryCatchFinallyExpr` (#2043; previously fell back
                  // to statement-mode lowering and silently discarded the
                  // value, returning `retTy`'s zero/default instead of the
                  // real result — a genuine miscompile, not just an unhandled
                  // shape).  A bare tail-position call to a `: Never`-declared
                  // function still reports `JVoid`, since `Never` erases to
                  // `JVoid` just like `Unit` (#5378): nothing is left on the
                  // operand stack there, so `emitNeverTailReturn` pushes
                  // `retTy`'s zero/default value before returning instead of
                  // emitting a value-less `return` that fails class-load
                  // verification ("Method expects a return value") against
                  // this non-void method's descriptor.
                  //
                  // `blockTerminates(block)` covers the case where the tail is an
                  // `if`/`else` (or `match`) whose arms all `return`: the lowering
                  // leaves the unreachable join label as the last instruction, so
                  // `endsWithReturn` cannot see the termination and would otherwise
                  // append a stray void `return` (#2870).
                  if not endsWithReturn(insns) and not blockTerminates(block) {
                    match tailTy {
                      case JVoid -> emitNeverTailReturn(insns, retTy)
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
              // #6735: same enum-hint seeding as the FBBlock tail-return
              // path above, for the `func f(): T = <expr>` body form.
              pushCtorExpect(ctx, retTy)
              val ty = lowerExpr(ctx, insns, e)
              popCtorExpect(ctx)
              // A `func f(): T = <Never-typed call>` body reports `JVoid`
              // (`Never` erases to `JVoid` same as `Unit`, #5378/#5651) with
              // nothing left on the operand stack; `emitReturnArrayCoerced`
              // has no `JVoid`->primitive-`toTy` coercion and would emit a
              // value-less `return` against this non-void method's real
              // descriptor otherwise ("Operand stack underflow").
              match ty {
                case JVoid -> emitNeverTailReturn(insns, retTy)
                case _ -> emitReturnArrayCoerced(ctx, insns, ty, retTy)
              }
            }
          }
        }
        case None -> emitReturn(insns, retTy)
      }
    }
  }

  // Determine param types for the LFunc descriptor.  An `out`/`inout`
  // parameter is declared as a single-element holder array (#1763).
  // `resolvedParams` so the emitted descriptor matches the registered
  // `JvmFuncSig.params` in `collectFileSigsSeeded` exactly (#6393).
  val noTypeParams: List[String] = newList()
  val paramTypes = holderAwareParamTypes(resolvedParams, pkgName, false, noTypeParams, externTypes)

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
    // A `scope { body }` transfers control away exactly when its body does — e.g.
    // a `scope` whose only exit is a `return` inside it (the `loadParallel`
    // shape).  Without this, a trailing `scope { … return … }` in a non-void
    // function looks non-terminating and the epilogue appends a stray void
    // `return`, which fails verification in a value-returning method.
    case SScope(_, body) -> blockTerminates(body)
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
// True when `anns` carries `@derive(<marker>)` (e.g. `@derive(Equals)`).
// Mirrors `Msil.Codegen.hasDeriveMarkerMsil` — kept as a separate JVM copy
// per the established per-backend-helper convention (no cross-package
// `Msil.Codegen` import from `Jvm.Codegen`).
func hasDeriveMarkerJvm(anns: in List[Annotation], marker: in String): Bool {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "derive" and a.args.count > 0 {
      val nm = match a.args[0] {
        case ABare(n, _) -> n
        case ALiteral(v, _) -> match v { case AVIdent(n, _) -> n; case _ -> "" }
        case AAName(_, _, _) -> ""
      }
      if nm == marker {
        return true
      }
    }
    i = i + 1
  }
  false
}

// Append `equals(Object): boolean` / `hashCode(): int` overrides to `methods`
// when `anns` carries `@derive(Equals)` / `@derive(Hash)` on a record, so BCL
// `HashMap`/`HashSet` key lookup (which dispatches these virtually) is
// structural rather than identity-based, matching the MSIL
// `appendDeriveOverridesMsil` behaviour for `Dictionary`/`HashSet` (#1480 on
// MSIL; docs/44 m-key / #4982 Finding 1 on JVM).  Delegates to the shared
// `Jvm.Lowering.buildDeriveEqualsFunc`/`buildDeriveHashCodeFunc` builders.
func appendDeriveOverridesJvm(
  methods: in List[LFunc],
  className: in String,
  fields: in List[LField],
  anns: in List[Annotation],
): Unit {
  if hasDeriveMarkerJvm(anns, "Equals") {
    methods.add(buildDeriveEqualsFunc(className, fields))
  }
  if hasDeriveMarkerJvm(anns, "Hash") {
    methods.add(buildDeriveHashCodeFunc(className, fields))
  }
}

pub func lowerRecord(
  decl: in RecordDecl,
  pkgName: in String,
  funcSigs: in Map[String, JvmFuncSig],
  caseFields: in Map[String, List[JvmCaseField]],
  ctors: in Map[String, String],
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  moduleVals: in Map[String, JvmType],
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
  // #6393: same-file `alias X = ...` table — see `Lyric.BareFuncRef`'s
  // module doc §2.  A function-type-aliased field (`record Holder { h:
  // Handler }`) must erase its FIELD DESCRIPTOR to `Object` exactly like a
  // literal `(Int) -> Int` field already does, not to the nonexistent
  // in-package class `<pkgName>/Handler` (`NoClassDefFoundError` at link
  // time).
  aliasTargets: in Map[String, TypeExpr],
  // #6596: field NAMES the whole-build write-safety audit found written
  // through a shape V0015 doesn't resolve — see `Msil.Codegen.lowerRecordMsil`'s
  // matching comment and `Lyric.ModeChecker.computeFieldLockSafetyForBuild`'s
  // doc comment for the full rationale.  Empty when the caller never ran the
  // audit, so an un-audited caller locks every non-`var` field exactly as
  // before this fix.
  unsafeFieldLockNames: in Map[String, Bool],
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
        // A non-`var` field (`FieldDecl.isMutable == false`) additionally gets
        // ACC_FINAL (0x0010, issue #1815 part 2a): the JVM verifier then
        // rejects any `putfield` outside this class's own `<init>`,
        // backstopping the mode checker's V0015 diagnostic at the bytecode
        // level.  See the MSIL twin (`Msil.Codegen.lowerRecordMsil`'s
        // `RMField` arm) for the full safety rationale (D-progress-706
        // part 2b widened V0015 + added `var` to every genuinely-mutated
        // `inout`-threaded field first).  #6596: a field the whole-build
        // write-safety audit could not vouch for (a write shape V0015 can't
        // resolve) is also left unlocked, rather than risk emitting a
        // `putfield` the JVM verifier rejects with `IllegalAccessError`.
        val skipLock = f.isMutable or unsafeFieldLockNames.containsKey(f.name)
        val recordFieldFlags = if skipLock { 0x0001 } else { 0x0001 + 0x0010 }
        // public [+ final]
        fields.add(
          LField(
            flags = recordFieldFlags,
            name = f.name,
            fieldType = typeExprToJvmErasedExtern(
              BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, f.ty),
              pkgName,
              tps,
              externTypes
            )
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
                configFieldTypes,
                opaqueTypes,
                closureAcc,
                usesLyricCount,
                importsStdString
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
pub func lowerUnion(
  decl: in UnionDecl,
  pkgName: in String,
  externTypes: in Map[String, String],
  aliasTargets: in Map[String, TypeExpr],
): LSealedUnion {
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
      // Alias-typed function fields must resolve to the underlying
      // TFunction before erasure, exactly like record fields (#6406) —
      // otherwise the descriptor embeds the nonexistent alias class.
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(
            LField(
              flags = 0x0001,
              name = name,
              fieldType = typeExprToJvmErasedExtern(
                BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, ty),
                pkgName,
                tps,
                externTypes
              )
            )
          )
        }
        case UFPos(ty, _) -> {
          caseFields.add(
            LField(
              flags = 0x0001,
              name = "field" + toString(fi),
              fieldType = typeExprToJvmErasedExtern(
                BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, ty),
                pkgName,
                tps,
                externTypes
              )
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
          // Same `Never`-tail gap as `lowerFunc` (#5378): a bare tail-position
          // call to a `: Never`-declared method/function reports `JVoid`
          // (Never erases to JVoid, same as Unit), leaving nothing on the
          // operand stack.  `emitNeverTailReturn` pushes `retTy`'s
          // zero/default value before returning instead of a value-less
          // `return` that fails class-load verification.
          if not endsWithReturn(insns) and not blockTerminates(block) {
            match tailTy {
              case JVoid -> emitNeverTailReturn(insns, retTy)
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
      // Same `Never`-tail gap as `lowerFunc`'s `FBExpr` arm (#5378/#5651):
      // `coerceArgTo` has no `JVoid`->primitive-`toTy` handling, so a bare
      // `: Never`-declared call here (erased to `JVoid`, nothing left on the
      // operand stack) would fail class-load verification.
      match ty {
        case JVoid -> emitNeverTailReturn(insns, retTy)
        case _ -> {
          coerceArgTo(insns, ty, retTy)
          emitReturn(insns, retTy)
        }
      }
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
): LFunc {
  val retTy = match retOpt { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }
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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString
  )
  val insns: List[LInsn] = newList()
  val noTps: List[String] = newList()
  // An explicit `self: in <ProtectedType>` receiver param (D037 spelling)
  // maps to the implicit `this` at slot 0 — it must not consume a real JVM
  // parameter slot or appear in the method descriptor, mirroring
  // `lowerRecordMethod` / `lowerImplMethod` above.  Without this strip, the
  // registered call-site descriptor (`registerInstanceSigErased`, which
  // already strips) diverges from the emitted method's descriptor, and the
  // JVM rejects the call with `NoSuchMethodError` (#6407).
  val realParams = stripLeadingSelfParam(params)
  val paramTypes = holderAwareParamTypes(realParams, pkgName, true, noTps, externTypes)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, realParams, pkgName, noTps, externTypes)
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
): LFunc {
  // Extern/import-resolving on ret + params (#5610): the registered
  // `<class>#<method>` sig (`registerInstanceSigErased`, #5051) resolves
  // through the declaring file's `externTypes`, so the EMITTED descriptor must
  // too or an extern-typed / imported-record-typed param diverges from the
  // registration and the call site's `invokevirtual` targets a descriptor the
  // class never carries.
  val retTy = match fn.ret {
    case Some(te) -> typeExprToJvmErasedExtern(te, pkgName, typeParams, externTypes)
    case None -> JVoid
  }
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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString
  )
  val insns: List[LInsn] = newList()
  val filteredParams = stripLeadingSelfParam(fn.params)
  val paramTypes = holderAwareParamTypes(filteredParams, pkgName, true, typeParams, externTypes)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, filteredParams, pkgName, typeParams, externTypes)
  // #6426: a non-receiver `Self`-typed parameter (`other: in Self`) refers to
  // THIS record's own type — narrow it with a real `checkcast` so field/method
  // access through it resolves instead of hitting the erased-`Object`
  // fallback.
  emitSelfParamChecksJvm(ctxSelf, insns, filteredParams, className)
  lowerInstanceMethodBody(ctxSelf, insns, body, retTy)
  LFunc(flags = 0x0001, name = fn.name, params = paramTypes, ret = retTy, insns = insns, maxStack = 0, maxLocals = 0)
}

// Unwrap parens to see whether a param's declared type is (or wraps) the
// bare `Self` type expression — mirrors MSIL's `isSelfTypeExprMsil`
// (`msil/codegen.l`).  Used by `emitSelfParamChecksJvm` to find every
// non-receiver `Self`-typed parameter of an impl/record method.
func isSelfTypeExprJvm(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TParen(inner) -> isSelfTypeExprJvm(inner)
    case _ -> false
  }
}

// JVM analog of MSIL's `registerParamsMsil` Self-narrowing (D-progress-753,
// #6421) — but where MSIL's fix is bookkeeping-only (the CLR JIT never
// verifies CIL type-safety at load time, so recording a concrete
// `MClass(selfTypeName)` as a parameter's internal static type is sound with
// no bytecode change), the JVM's classfile verifier IS a mandatory load-time
// gate: a `getfield`/`invokevirtual`/`putfield` against a local whose REAL
// slot descriptor is `Ljava/lang/Object;` (the signature stays erased to
// match the interface slot) fails `VerifyError` unless the local is narrowed
// by a real `checkcast` first (#6426).
//
// For each parameter in `params` whose declared type is (or paren-wraps)
// bare `Self`, this emits ONE entry-prologue `aload <slot>; checkcast
// <selfTypeName>; astore <slot>` (via `emitStore`, which emits `LAstoreAs`
// for a `JRef` — the SAME instruction the if/match/try result-local and
// pattern-bind cast sites already use so the StackMapTable frames the slot
// with its real class rather than `Object`, #3307) — REUSING the parameter's
// existing slot number so an `inout`-mode param's holder write-through
// bookkeeping (`ctx.holderArraySlot`/`ctx.holderElemType`, keyed by slot
// number) stays valid — then retypes `ctx.types[p.name]` to the concrete
// `JRef(selfTypeName)` so every later read of the parameter (field access,
// method-call receiver, byref reassignment) resolves through the existing
// type-directed lookups instead of ever falling into the erased-`Object`
// fallback (`02_exprs.l`'s `error[J007]` refusal).  Must run AFTER
// `setupInstanceParamSlotsAndHolders` has already allocated the parameter's
// slot (and, for a holder param, already appended its unwrap-into-value-slot
// instructions to `insns` — the cast instructions appended here run
// immediately after, re-narrowing that same already-unwrapped slot).
//
// Sound because `checkImplConformance` (D-progress-751/#6417) only accepts a
// `Self`-typed argument at this parameter position when it resolves to
// EXACTLY this impl/record's own target type, so the `checkcast` can never
// throw for a checker-accepted program. The emitted METHOD DESCRIPTOR is
// untouched — still erased `Ljava/lang/Object;`, still matching the
// interface slot; only the slot's post-prologue verifier type (and this
// function's own `ctx.types` bookkeeping) changes, mirroring MSIL's
// "signature untouched, internal bookkeeping only" property even though the
// JVM side additionally needs real bytecode. `selfTypeName` is the enclosing
// impl/record method's own concrete target class (`<pkg>/<Name>`, matching
// `ctx.caseFields`'/`ctx.ctors`' key format) — always non-empty at both call
// sites (`lowerImplMethod`, `lowerRecordMethod`).
func emitSelfParamChecksJvm(
  ctx: in FuncCtx, insns: in List[LInsn], params: in List[Param], selfTypeName: in String
): Unit {
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    if isSelfTypeExprJvm(p.ty) {
      match lookupSlot(ctx, p.name) {
        case Some(slot) -> {
          insns.add(LAload(slot = slot))
          insns.add(LCheckcast(className = selfTypeName))
          emitStore(insns, slot, JRef(className = selfTypeName))
          ctx.types.remove(p.name)
          ctx.types.add(p.name, JRef(className = selfTypeName))
        }
        case None -> {
        }
      }
    }
    pi = pi + 1
  }
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
): LFunc {
  val body = match fn.body {
    case Some(b) -> b
    case None -> panic(
      "lowerImplMethod: impl method has no body — interface-only declaration reached codegen"
    )
  }
  // extern-resolving: an `impl <ExternInterface> for X` method returning an
  // extern-typed value (e.g. `Bool` from a JDK interface method, or another
  // extern type) must match the real JVM descriptor, not the in-package
  // `<pkg>/<Name>` guess plain `typeExprToJvm` would produce.
  val retTy = match fn.ret { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }
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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString
  )
  val insns: List[LInsn] = newList()
  val noTpsImpl: List[String] = newList()
  // An explicit `self: in <Target>` receiver (D037) must not become a real
  // JVM parameter: slot 0 is already `this` (the body's `self` lowers via
  // `ESelf` → aload_0), and the registration side
  // (`registerInstanceSigErased`) strips it — an unstripped emission here
  // disagreed with every registered descriptor (#5607).
  val implRealParams = stripLeadingSelfParam(fn.params)
  val paramTypes = holderAwareParamTypes(implRealParams, pkgName, true, noTpsImpl, externTypes)
  setupInstanceParamSlotsAndHolders(ctxSelf, insns, implRealParams, pkgName, noTpsImpl, externTypes)
  // #6426: a non-receiver `Self`-typed parameter (`other: in Self`) is
  // guaranteed by the type checker (D-progress-751/#6417) to be exactly
  // `targetClass` — narrow it with a real `checkcast` so field/method access
  // through it resolves instead of hitting the erased-`Object` fallback
  // (`error[J007]`).
  emitSelfParamChecksJvm(ctxSelf, insns, implRealParams, targetClass)
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
): LPackageItem {
  val className = pkgName + "/" + decl.name
  val fields: List[LField] = newList()
  val methods: List[LFunc] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _, _, _) -> fields.add(
            LField(
              flags = 0x0001,
              name = name,
              fieldType = typeExprToJvmExtern(ty, pkgName, externTypes)
            )
          )
          case PFLet(name, ty, _, _, _, _) -> fields.add(
            LField(
              flags = 0x0001,
              name = name,
              fieldType = typeExprToJvmExtern(ty, pkgName, externTypes)
            )
          )
          case PFImmutable(f) -> fields.add(
            LField(
              flags = 0x0001,
              name = f.name,
              fieldType = typeExprToJvmExtern(f.ty, pkgName, externTypes)
            )
          )
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
            configFieldTypes,
            opaqueTypes,
            closureAcc,
            usesLyricCount,
            importsStdString
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
                configFieldTypes,
                opaqueTypes,
                closureAcc,
                usesLyricCount,
                importsStdString
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
      // A call head that names a List-typed wire member (knownNames value
      // false) is really the element TYPE's constructor — the common
      // `contributes[Route] home = Route(path = "/")` shape, where the
      // synthesised collection shares the type's name.  Counting it as a
      // dependency manufactures a false entry→collection→entry cycle
      // (spurious W0001).  Mirrors wireExprDepsMsil.
      val skipFn = match fn.kind {
        case EPath(p) -> {
          if p.segments.count == 1 {
            match mapGet(knownNames, p.segments[0]) {
              case Some(callable) -> not callable
              case None -> false
            }
          } else {
            false
          }
        }
        case _ -> false
      }
      if not skipFn {
        wireExprDepsJvm(fn, knownNames, acc)
      }
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
    case EList(exprs) -> {
      var li = 0
      while li < exprs.count {
        wireExprDepsJvm(exprs[li], knownNames, acc)
        li = li + 1
      }
    }
    case ETuple(exprs) -> {
      var ti = 0
      while ti < exprs.count {
        wireExprDepsJvm(exprs[ti], knownNames, acc)
        ti = ti + 1
      }
    }
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
        case LBVar(_, _, initOpt) -> match initOpt {
          case Some(init) -> wireExprDepsJvm(init, knownNames, acc)
          case None -> ()
        }
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
    // docs/58 (D121) members are rewritten away by Lyric.WireExpand before
    // codegen; they carry no init at this stage.
    case _ -> None
  }
}

// True when the member's declared type is List[…] — i.e. it can hold a
// synthesised contributes collection and can never be a call head.
// Mirrors wireMemberIsListTypedMsil.
func wireMemberIsListTypedJvm(m: in WireMember): Bool {
  val tyOpt: Option[TypeExpr] = match m {
    case WMSingleton(_, ty, _, _) -> Some(value = ty)
    case WMLocal(_, ty, _, _) -> ty
    case WMScoped(_, _, ty, _, _) -> Some(value = ty)
    case _ -> None
  }
  match tyOpt {
    case Some(t) -> match t.kind { case TGenericApp(head, _) -> lastSegment(head) == "List"; case _ -> false }
    case None -> false
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
    case WMContributes(_, name, _, _, _, _) -> name
    case _ -> ""
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

  // knownNames value is false for List-typed members (synthesised
  // contributes collections): wireExprDepsJvm uses it to skip call-head
  // "references" to them (the element type's constructor).
  val nameToIdx: Map[String, Int] = newMap()
  val knownNames: Map[String, Bool] = newMap()
  var i = 0
  while i < sortable.count {
    val n = wireMemberNameJvm(sortable[i])
    if n.length > 0 and not nameToIdx.containsKey(n) {
      nameToIdx.add(n, i)
      knownNames.add(n, not wireMemberIsListTypedJvm(sortable[i]))
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
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
  // Iterate `decl.members` (declaration order), not the topo-sorted list: the
  // bootstrap-descriptor registration elsewhere scans declaration order, so
  // both passes share one source of truth for the param order (#5287).
  var ppi = 0
  while ppi < decl.members.count {
    match decl.members[ppi] {
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
        val tempSlots = lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          configFieldTypes,
          opaqueTypes,
          closureAcc,
          usesLyricCount,
          importsStdString,
          initInsns,
          init,
          bty
        )
        bindings.add(LWireBinding(name = name, valType = bty, insns = initInsns, tempSlots = tempSlots))
        if not bindingTypes.containsKey(name) {
          bindingTypes.add(name, bty)
        }
      }
      case WMLocal(name, tyOpt, init, _) -> {
        val bty = match tyOpt { case Some(t) -> typeExprToJvm(t, pkgName); case None -> JRef(className = "java/lang/Object") }
        val initInsns: List[LInsn] = newList()
        val tempSlots = lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          configFieldTypes,
          opaqueTypes,
          closureAcc,
          usesLyricCount,
          importsStdString,
          initInsns,
          init,
          bty
        )
        bindings.add(LWireBinding(name = name, valType = bty, insns = initInsns, tempSlots = tempSlots))
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
        val tempSlots = lowerWireBindingInit(
          className,
          bindingTypes,
          pkgName,
          funcSigs,
          caseFields,
          ctors,
          externTypes,
          autoFfi,
          moduleVals,
          configFieldTypes,
          opaqueTypes,
          closureAcc,
          usesLyricCount,
          importsStdString,
          initInsns,
          provider,
          bty
        )
        bindings.add(LWireBinding(name = ifaceName, valType = bty, insns = initInsns, tempSlots = tempSlots))
        if not bindingTypes.containsKey(ifaceName) {
          bindingTypes.add(ifaceName, bty)
        }
      }
      case WMExpose(name, _) -> exposes.add(name)
      case WMScoped(_, _, _, _, _) -> {
        // ThreadLocal-backed scoping deferred to #2972; not lowered until then.
      }
      case _ -> {
        // WMContributes / WMInclude / WMOverridable / WMConfigInst (docs/58,
        // D121) are rewritten into plain members by Lyric.WireExpand before
        // codegen.  Seeing one here means the expander did not run.
        panic(
          "Jvm.Codegen: wire '" + decl.name + "' still contains a docs/58 template member at codegen time; " +
            "Lyric.WireExpand.expandFile must run before lowering."
        )
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
  insns: in List[LInsn],
  init: in Expr,
  expectedTy: in JvmType,
): Int {
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
    0
  } else {
    // A lambda in a wire-binding initialiser registers its synthesised closure
    // inner class into the package-shared accumulator (#2864), so it emits
    // `<pkg>$Lambda$<n>` into the package output and works end-to-end.
    // #6393: a wire-binding init has no reachable file-scoped alias table at
    // this call site — out of scope for now (see `FuncCtx.aliasTargets`).
    val noAliasTargets: Map[String, TypeExpr] = newMap()
    val ctx0 = makeFuncCtx(
      pkgName,
      className,
      funcSigs,
      caseFields,
      ctors,
      externTypes,
      autoFfi,
      expectedTy,
      moduleVals,
      configFieldTypes,
      opaqueTypes,
      closureAcc,
      usesLyricCount,
      importsStdString,
      noAliasTargets
    )
    // #5013: an earlier binding referenced from a *nested* expression position
    // (e.g. `contents = widget` as a named constructor argument, not the bare
    // top-level init handled above) must also resolve to `getstatic` on the
    // wire class — otherwise it falls through to the module-val / null
    // fallback in `lowerExpr`'s `EPath` handling.
    val ctx = withWireBinding(ctx0, className, bindingTypes)
    val ty = lowerExpr(ctx, insns, init)
    coerceArgTo(insns, ty, expectedTy)
    ctx.slotTicker.count
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
  configFieldTypes: in Map[String, JvmType],
  opaqueTypes: in Map[String, Bool],
  closureAcc: in List[LClosure],
  usesLyricCount: in List[Bool],
  importsStdString: in Bool,
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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString
  )

  // `out`/`inout` parameters on an async generator are not supported on the
  // JVM target (the holder array is captured into a generator field, and the
  // write-back point is undefined across suspension) — reject rather than
  // silently pass by value (#1763).
  var gpi = 0
  while gpi < decl.params.count {
    if isHolderMode(decl.params[gpi].mode) {
      panic(
        "Jvm.Codegen: `out`/`inout` parameter '" + decl.params[gpi].name + "' on async generator " + genClass +
          " is not supported on the JVM target (#1763); use a return value instead."
      )
    }
    gpi = gpi + 1
  }
  // Preamble: load each param from this.<field> into a local slot.
  // Extern/import-resolving (#5610): must match the LGenParam field descriptor
  // and the factory ctor, which resolve the same way.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToJvmExtern(p.ty, pkgName, externTypes)
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
func makeGeneratorFactory(
  decl: in FunctionDecl,
  genClass: in String,
  pkgName: in String,
  externTypes: in Map[String, String],
): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LNew(className = genClass))
  insns.add(LDup)

  val ctorParams: List[JvmType] = newList()
  var slot = 0
  var pi = 0
  while pi < decl.params.count {
    // Extern/import-resolving (#5610): the generator ctor descriptor derives
    // from LGenParam, which resolves the same way — keep them in lockstep.
    val pty = typeExprToJvmExtern(decl.params[pi].ty, pkgName, externTypes)
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
    case _ -> panic(
      "Jvm.Codegen: `impl Y for X` target is not a TRef (path) — got an " +
        "unsupported TypeExpr shape; refusing to emit an unbindable JVM " +
        "class name.  Add a TypeExpr arm to typeExprToJvmClass if a new " +
        "impl-target shape is intended."
    )
  }
}

// Convert a ConstraintRef to a JVM binary class name.
// Used to resolve `impl Y for X` interface from the AST.  A single-segment
// name first checks `externTypes` (populated from the file's `extern type`
// declarations) so `impl JHandler for MyHandler` with
// `extern type JHandler = "io.undertow.server.HttpHandler"` resolves to the
// real JDK interface instead of a same-package `<pkg>/JHandler` guess — the
// same resolution `typeExprToJvmExtern` already applies to ordinary type
// positions (#3334).  Without this, the `implements` clause for an extern
// interface silently pointed at a nonexistent in-package class, so the JDK
// caller (e.g. Undertow's `Undertow.builder().setHandler(...)`) could never
// dispatch into the Lyric impl (confirmed via `javap`: emits `implements
// <pkg>/JRunnable` instead of `implements java/lang/Runnable`).
func constraintRefToJvmClass(cr: in ConstraintRef, pkgName: in String, externTypes: in Map[String, String]): String {
  if cr.head.segments.count == 1 {
    match mapGet(externTypes, cr.head.segments[0]) {
      case Some(javaFqn) -> javaFqn.replace(".", "/")
      case None -> pkgName + "/" + cr.head.segments[0]
    }
  } else {
    segmentsToJvmPath(cr.head.segments)
  }
}

// True iff `cr` (an `impl <cr> for …` interface reference) resolves through
// `externTypes` to a real JDK type — i.e. it is a single-segment name that
// was declared via `extern type` / `import extern`.  A multi-segment path is
// either a cross-package native Lyric interface or an explicit FQN written
// out in full; neither is validated against JDK metadata here.  Mirrors
// `implIfaceIsExternalClr` on the MSIL side (`msil/codegen.l`).
func implIfaceExternDottedFqn(cr: in ConstraintRef, externTypes: in Map[String, String]): Option[String] {
  if cr.head.segments.count == 1 {
    mapGet(externTypes, cr.head.segments[0])
  } else {
    None
  }
}

// Reject `impl <ExternType> for Record` at compile time when `<ExternType>`
// resolves to a JDK CLASS (concrete or abstract) rather than an interface
// (#5930).  Before this check, such a block silently emitted an `implements`
// clause against the class in the generated `.class` file — bytecode that is
// invalid per the JVM spec (only interfaces may appear in the `interfaces`
// table for an `implements` relationship) and throws
// `IncompatibleClassChangeError` at class-load time, e.g. `impl
// HttpsConfigurator for MyConfigurator` where `HttpsConfigurator` is the
// abstract JDK class `com.sun.net.httpserver.HttpsConfigurator`.
//
// Real subclassing of a concrete/abstract extern class (`super_class` +
// `invokespecial` to the chosen superclass constructor + override dispatch)
// is a genuine feature, not yet supported on the JVM target — tracked as a
// follow-up.  Silent-skips when the JDK reference index can't resolve the
// class at all (no `java.base.jmod` on disk, or a Maven/non-JDK type not on
// `LYRIC_FFI_JARS`): a build-time false positive from an unavailable
// classpath is worse than deferring the error to `TypeLoadException` at
// first use in that degraded environment, matching the established
// silent-skip convention for an unindexed FFI classpath (see F0024's
// "index empty" branch on the MSIL side).
func validateImplTargetIsInterfaceJvm(
  decl: in ImplDecl,
  pkgName: in String,
  externTypes: in Map[String, String],
  autoFfi: in AutoFfiCtx,
): Unit {
  match implIfaceExternDottedFqn(decl.iface, externTypes) {
    case None -> ()
    case Some(javaFqn) -> {
      match loadClass(autoFfi, javaFqn) {
        case None -> ()
        case Some(ci) -> {
          if not ci.isInterface {
            val targetName = typeExprToJvmClass(decl.target, pkgName).replace("/", ".")
            val pos = decl.span.startPos
            panic(
              "error[J006]: " + pos.line.toString() + ":" + pos.column.toString() + ": cannot `impl " + javaFqn + " for " +
                targetName +
                "`: '" +
                javaFqn +
                "' is a concrete or abstract JDK class, not an interface — only " +
                "interfaces can be implemented; subclassing external classes is not " +
                "yet supported on the JVM target"
            )
          }
        }
      }
    }
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

// True when `file` has `import Std.String` (or `import Std.String as X`) in
// scope — see `FuncCtx.importsStdString` / #6124.
func fileImportsStdString(file: in SourceFile): Bool {
  var ii = 0
  while ii < file.imports.count {
    if dottedPathOfSegments(file.imports[ii].path.segments) == "Std.String" {
      return true
    }
    ii = ii + 1
  }
  false
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

// The full type-resolution seed for `file`'s own signature/field/codegen
// passes: `externSeed` (the extern-type + declared-type maps of every
// package `file` imports) as the base, with `file`'s OWN declared record/
// union/protected/opaque/interface/enum types layered on top ONLY where one
// actually collides by simple name with something in `externSeed` (own
// declarations win such a collision), and `file`'s own `extern type` alias
// declarations on top of that.
//
// Every one of `typeExprToJvmExtern`'s callers used to build this seed as
// plain `mergeExternSeed(collectExternTypesFromFile(file), externSeed)` —
// which only merges the file's own `extern type` ALIASES over the seed, not
// its own plain type DECLARATIONS.  A file that both imports a package and
// declares its OWN type of the identical simple name (e.g. `Std.RegexSafe`
// importing `Std.Regex` while also declaring its own `RegexError` union)
// had its own declaration silently SHADOWED by the import's same-named
// type: every bare reference to its OWN `RegexError` — including in ITS OWN
// function signatures — resolved to the imported package's class instead,
// producing a cross-package type-descriptor mismatch (wrong owning class on
// the emitted method, `ClassCastException`/`NoSuchMethodError` at runtime,
// #5976).
//
// Only a COLLIDING own declaration is added — not every own-declared type
// unconditionally — because `ctx.externTypes` (the map this seed becomes)
// is ALSO read by `lowerMethodCall`'s auto-FFI receiver gate (docs/44 m-58):
// any key present there is treated as "this EPath receiver names a foreign
// JDK type", so injecting a NON-colliding own type (say `StoreError`, which
// no import shares) made `StoreError.UserNotFound(...)` — an ordinary
// same-package qualified union-case construction — misroute through
// `lowerAutoFfiStaticCall` and panic looking it up in the JDK, instead of
// falling through to the qualified-case-construction path a few lines
// below that already handles this exact shape.  Restricting the override to
// genuine collisions keeps every non-colliding own type entirely absent from
// `externTypes`, preserving that gate's existing behaviour for the
// overwhelming common case while still fixing the #5976 collision.
pub func ownAwareExternTypes(file: in SourceFile, externSeed: in Map[String, String]): Map[String, String] {
  val ownDeclared: Map[String, String] = newMap()
  collectFileDeclaredTypeFqns(file, ownDeclared)
  val collidingOwn: Map[String, String] = newMap()
  for k in mapKeys(ownDeclared) {
    if externSeed.containsKey(k) {
      match mapGet(ownDeclared, k) {
        case Some(v) -> collidingOwn.add(k, v)
        case None -> ()
      }
    }
  }
  mergeExternSeed(collectExternTypesFromFile(file), mergeExternSeed(collidingOwn, externSeed))
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
  val externTypes = ownAwareExternTypes(file, externSeed)
  // #6393: same-file `alias X = ...` table so a function-typed alias
  // annotation (`func adder(n: in Int): Handler`, `Handler = (Int) -> Int`)
  // registers its return/param types exactly like the literal
  // `(Int) -> Int` form already does, instead of the erasure below falling
  // to the "user type in the same package" guess (`JRef("<owner>/Handler")`
  // — a nonexistent class, `NoClassDefFoundError` at link time).  See
  // `Lyric.BareFuncRef`'s module doc §2.
  //
  // #6413 audit: for a user file this is now redundant with
  // `Lyric.TypeAliasResolve` (#6404), which already substituted the alias
  // reference before this file ever reached codegen. KEPT anyway: this
  // function is ALSO called on raw, un-resolved STDLIB source files
  // (`Jvm.Bridge`'s `collectFileSigsSeeded(stdlibFiles[ri], ...)` in the
  // bundled-JAR build), which are deliberately never run through the
  // pre-pass — see `Lyric.TypeAliasResolve`'s module doc and
  // `docs/03-decision-log.md` D-progress-752.
  val aliasTargets = BareFuncRef.collectFuncAliasTargets(file)
  // Same-file record names for `recordRetClassOf` (#6399): a bare pre-scan of
  // every `record` item declared in this file lets the return-type
  // computation below recover a LOCAL generic record's own raw class
  // (`Box[Int]` -> `Some("<owner>/Box")`) regardless of declaration order —
  // a function may be declared before the record it returns.
  val localRecordNames: Map[String, Bool] = newMap()
  var ri = 0
  while ri < file.items.count {
    match file.items[ri].kind {
      case IRecord(rd) -> localRecordNames.add(rd.name, true)
      // #6528: `IExposedRec` carries the identical `RecordDecl` shape as
      // `IRecord` — same pre-scan, so a same-file generic `exposed record`
      // returned by a function declared earlier in the file also resolves.
      case IExposedRec(rd) -> localRecordNames.add(rd.name, true)
      case _ -> ()
    }
    ri = ri + 1
  }
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
        // #6393: resolve each param's declared type through a function-type
        // alias before erasure — see the `aliasTargets` comment above.
        val resolvedParams = resolveParamsFuncAlias(aliasTargets, decl.params)
        val params = holderAwareParamTypes(resolvedParams, owner, false, sigTps, externTypes)
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
        // #6393: resolve the declared return type through a function-type
        // alias too, feeding `ret`/`sigClosureRetTy` below — see the
        // `aliasTargets` comment above.  `retGenericArgs`/`recordRetClass`
        // stay on the ORIGINAL `decl.ret`: neither ever matches a bare
        // `TRef` naming a function-type alias (no generic args, no known
        // record name), so resolving through the alias there would be a
        // no-op at best.
        val resolvedRet = match decl.ret {
          case Some(te) -> Some(value = BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, te))
          case None -> None
        }
        // An async generator's *factory* returns the synthesised generator
        // object (an Iterable), not its declared element type — so the call
        // site must store/use a reference, not `decl.ret` (e.g. the `Int`
        // element type).  Record Object for it; everything else uses the
        // declared return.
        val ret = if decl.isAsync and funcBodyContainsYield(decl) {
          JRef(className = "java/lang/Object")
        } else {
          match resolvedRet {
            case Some(te) -> typeExprToJvmErasedExtern(te, owner, sigTps, externTypes)
            case None -> JVoid
          }
        }
        // The async-generator arm above claims `ret` for the synthesised
        // generator object, not `decl.ret` itself — closureRetTy must come
        // from the SAME source `ret` was derived from, or a generator
        // factory declared `(...) -> R` would wrongly register R as its own
        // invoke-result type.
        // Explicitly annotated: an un-annotated if/else with a bare `None`
        // arm degrades to Option<object> under the self-hosted MSIL
        // emitter's context-free lowering (#4965 family) — caught by the
        // ilverify gate as a stack-type mismatch in this very function.
        val sigClosureRetTy: Option[JvmType] = if decl.isAsync and funcBodyContainsYield(decl) {
          None
        } else {
          closureRetTypeOf(resolvedRet, owner, sigTps, externTypes)
        }
        // Same generator exclusion as `sigClosureRetTy` above: the actual
        // runtime return is the synthesised generator object, not `decl.ret`,
        // so recovering a record class from `decl.ret` would be wrong there.
        val sigRecordRetClass: Option[String] = if decl.isAsync and funcBodyContainsYield(decl) {
          None
        } else {
          recordRetClassOf(decl.ret, owner, localRecordNames)
        }
        // #6754 (finding 1.2a): same async-generator exclusion as
        // `sigClosureRetTy`/`sigRecordRetClass` above — the synthesised
        // generator object is never `UInt`/`ULong`, only `resolvedRet` (the
        // ACTUAL declared return, alias-resolved) is.
        val sigRetIsUnsigned: Bool = if decl.isAsync and funcBodyContainsYield(decl) {
          false
        } else {
          match resolvedRet {
            case Some(te) -> isUnsignedTypeExpr(te)
            case None -> false
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
          retGenericArgs = eagerlyResolveGenericArgs(
            returnTypeGenericArgsFiltered(decl.ret, sigTps),
            owner,
            externTypes
          ),
          closureRetTy = sigClosureRetTy,
          recordRetClass = sigRecordRetClass,
          // A free function's return type is never `Self` (only legal on an
          // interface/impl/record method signature) — always false here.
          retIsSelf = false,
          retIsUnsigned = sigRetIsUnsigned
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
        // #6393: a "bareref:"-prefixed key marks `decl.name` as eligible to
        // be referenced bare as a first-class function value (`apply(double,
        // 21)`) — see `Lyric.BareFuncRef.isEligibleBareFuncRefTarget` and the
        // matching lookup at the `lowerExpr` EPath fallback
        // (`jvm/codegen/02_exprs.l`).  Reuses `sig` as-is: only its
        // `params.count` (the forwarding closure's arity) is read back.
        if BareFuncRef.isEligibleBareFuncRefTarget(decl) and not into.containsKey("bareref:" + decl.name) {
          into.add("bareref:" + decl.name, sig)
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: register each protected entry / helper method under the
        // instance-method key `<class>#<method>` so `c.increment()` resolves to
        // the real descriptor (e.g. `()V`) instead of the `()Object` guess.
        val protClass = owner + "/" + decl.name
        val protTps = genericParamNames(decl.generics)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMEntry(ed) -> {
              registerInstanceSig(into, protClass, ed.name, ed.params, ed.ret, owner, externTypes)
            }
            case PMFunc(fn) -> {
              registerInstanceSig(into, protClass, fn.name, fn.params, fn.ret, owner, externTypes)
            }
            case PMField(pf) -> {
              match pf {
                case PFVar(name, ty, _, _, _, _) -> registerFieldElemSig(into, protClass, name, ty, owner, protTps, externTypes)
                case PFLet(name, ty, _, _, _, _) -> registerFieldElemSig(into, protClass, name, ty, owner, protTps, externTypes)
                case PFImmutable(f) -> registerFieldElemSig(into, protClass, f.name, f.ty, owner, protTps, externTypes)
              }
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
              registerInstanceSigErased(into, recClass, fn.name, fn.params, fn.ret, owner, recTps, externTypes)
            }
            case RMField(f) -> {
              registerFieldElemSig(into, recClass, f.name, f.ty, owner, recTps, externTypes)
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      // #6526: `IExposedRec` carries the identical `RecordDecl` shape as
      // `IRecord` — same registration.  Missing this arm left every
      // `exposed record`'s instance methods/fields unregistered, so a
      // method call or compound-assignment on one resolved to the
      // `()Object` guess instead of the real descriptor.
      case IExposedRec(decl) -> {
        val recClass = owner + "/" + decl.name
        val recTps = genericParamNames(decl.generics)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              registerInstanceSigErased(into, recClass, fn.name, fn.params, fn.ret, owner, recTps, externTypes)
            }
            case RMField(f) -> {
              registerFieldElemSig(into, recClass, f.name, f.ty, owner, recTps, externTypes)
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      // Register the synthesised `toX` conversion method (#5956) under
      // `<wrapperClass>#toX` so `v.toInt()` on a distinct/range-subtype
      // receiver resolves through the ordinary `<class>#<method>` instance
      // dispatch (`lowerMethodCall`'s `ctx.funcSigs` lookup) instead of
      // falling through to the "no known method" fallback. `Jvm.Lowering`'s
      // `jvmDistinctConvName` picks the SAME name the emitted method carries
      // — no conversion method (and no registration) for a non-convertible
      // underlying type (`""`).
      case IDistinctType(decl) -> {
        val distClass = owner + "/" + decl.name
        val inner = typeExprToJvm(decl.underlying, owner)
        val convName = jvmDistinctConvName(inner)
        if convName.length > 0 {
          val noParams: List[Param] = newList()
          registerInstanceSigErased(
            into,
            distClass,
            convName,
            noParams,
            Some(value = decl.underlying),
            owner,
            newList(),
            externTypes
          )
        }
        // Static `from`/`tryFrom` construction API (#5956): registered under
        // the same `<TypeName>.<member>` dot-key `lowerMethodCall`'s existing
        // dot-named-static-call arm already dispatches through (the
        // `AppWire.bootstrap()` mechanism), so the call site needs no
        // special-casing of its own. `tryFrom`'s `retGenericArgs` —
        // pre-resolved via `eagerlyResolveGenericArgs`, exactly like a real
        // generic function's declared return (#4877) — lets
        // `scrutineeGenericArgs` recognise `Type.tryFrom(x)` as a
        // `Result[Type, String]` instantiation, so a `match`/`?`/`let`-bind
        // on it unboxes the erased `Ok`/`Err` payload back to the real
        // distinct-type class instead of leaving it `java.lang.Object` — the
        // JVM-erasure counterpart of `Lyric.Mono`'s front-end recognition of
        // this same call shape (#5841).
        val noParamNames: List[String] = newList()
        val noParamDefaults: List[Option[Expr]] = newList()
        val noParamModes: List[ParamMode] = newList()
        // #6664: register BOTH the bundle-global bare key (`<TypeName>.from`,
        // legacy first-wins shape, kept for a call site that never shadows)
        // AND a package-scoped key (`<owner>::<TypeName>.from`) — mirrors
        // `addCtorKeys`/`ctorClassFor`'s scoped-key-wins pattern that fixed
        // the identical same-simple-name collision for union cases (#5976).
        // Without the scoped key, two different packages each declaring
        // their own distinct/range-subtype named e.g. `Age` collide on the
        // bare `"Age.from"` key: whichever package's file this pre-scan
        // visits FIRST wins the bundle-wide registration, and every OTHER
        // package's `Age.from(...)`/`Age.tryFrom(...)` call site silently
        // resolves through the wrong package's class + range bounds
        // (`lowerMethodCall`'s `mapGet(ctx.funcSigs, ...)` has no way to
        // tell them apart from the bare key alone). `lowerMethodCall` now
        // consults the scoped key first via `ctx.pkgName`, so each
        // package's own call sites always resolve to their OWN type.
        val fromKey = decl.name + ".from"
        val fromParams: List[JvmType] = newList()
        fromParams.add(inner)
        val fromSig = JvmFuncSig(
          owner = distClass,
          params = fromParams,
          ret = JRef(className = distClass),
          paramNames = noParamNames,
          paramDefaults = noParamDefaults,
          paramModes = noParamModes,
          isIface = false,
          retGenericArgs = newList(),
          closureRetTy = None,
          recordRetClass = None,
          retIsSelf = false,
          // `Type.from(x)` is `ECall(EMember(…), …)` — never matches
          // `isUnsignedExpr`'s `ECall(EPath, …)`-only arm.
          retIsUnsigned = false
        )
        if not into.containsKey(fromKey) {
          into.add(fromKey, fromSig)
        }
        val fromScopedKey = owner + "::" + fromKey
        if not into.containsKey(fromScopedKey) {
          into.add(fromScopedKey, fromSig)
        }
        val tryFromKey = decl.name + ".tryFrom"
        val tryFromParams: List[JvmType] = newList()
        tryFromParams.add(inner)
        val selfSeg: List[String] = newList()
        selfSeg.add(decl.name)
        val selfTe = TypeExpr(kind = TRef(path = ModulePath(segments = selfSeg, span = decl.span)), span = decl.span)
        val stringSeg: List[String] = newList()
        stringSeg.add("String")
        val stringTe = TypeExpr(kind = TRef(path = ModulePath(segments = stringSeg, span = decl.span)), span = decl.span)
        val rawArgs: List[TypeExpr] = newList()
        rawArgs.add(selfTe)
        rawArgs.add(stringTe)
        val tryFromSig = JvmFuncSig(
          owner = distClass,
          params = tryFromParams,
          ret = JRef(className = "Std/Core/Result"),
          paramNames = noParamNames,
          paramDefaults = noParamDefaults,
          paramModes = noParamModes,
          isIface = false,
          retGenericArgs = eagerlyResolveGenericArgs(rawArgs, owner, externTypes),
          closureRetTy = None,
          recordRetClass = None,
          retIsSelf = false,
          // `Type.tryFrom(x)` is `ECall(EMember(…), …)` — same as `fromSig`.
          retIsUnsigned = false
        )
        if not into.containsKey(tryFromKey) {
          into.add(tryFromKey, tryFromSig)
        }
        val tryFromScopedKey = owner + "::" + tryFromKey
        if not into.containsKey(tryFromScopedKey) {
          into.add(tryFromScopedKey, tryFromSig)
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
              registerInstanceSig(into, tgtClass, fn.name, fn.params, fn.ret, owner, externTypes)
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
        // Generic type params, so retGenericArgs registration can guard against a
        // bare reference to the interface's OWN type parameter the same way
        // `recTps` guards `IRecord` above (#5050).
        val ifaceTps = genericParamNames(decl.generics)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              registerIfaceSig(into, ifClass, sig.name, sig.params, sig.ret, owner, externTypes, ifaceTps)
            }
            case IMFunc(fn) -> {
              registerIfaceSig(into, ifClass, fn.name, fn.params, fn.ret, owner, externTypes, ifaceTps)
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
          val opqTps = genericParamNames(decl.generics)
          var mi = 0
          while mi < decl.members.count {
            match decl.members[mi] {
              case OMField(f) -> {
                registerFieldElemSig(into, opqCls, f.name, f.ty, owner, opqTps, externTypes)
                val fkey = "field:" + f.name
                if not into.containsKey(fkey) {
                  val fPs: List[JvmType] = newList()
                  into.add(
                    fkey,
                    JvmFuncSig(
                      owner = opqCls,
                      params = fPs,
                      // Extern-alias + generic-erasure aware (same reason as the
                      // opaque-field arm of `collectFileCasesExtern`): the
                      // accessor's declared return otherwise names `<pkg>/<Alias>`.
                      ret = typeExprToJvmErasedExtern(f.ty, owner, opqTps, externTypes),
                      paramNames = newList(),
                      paramDefaults = newList(),
                      paramModes = newList(),
                      isIface = false,
                      retGenericArgs = eagerlyResolveGenericArgs(returnTypeGenericArgsFiltered(Some(f.ty), opqTps), owner, externTypes),
                      closureRetTy = None,
                      recordRetClass = None,
                      // An opaque field accessor's declared type is never `Self`.
                      retIsSelf = false,
                      // Field read is `EMember`, not `ECall` — out of scope
                      // for `isUnsignedExpr` (finding 1.2b, see its doc).
                      retIsUnsigned = false
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
        // bootstrap(...)V: the descriptor must include every `@provided`
        // parameter's type, in declaration order — `lowerWire` emits
        // `bootstrap` with exactly these params (#5013 follow-up).  A
        // registered zero-arg signature here made `<Wire>.bootstrap(args)`
        // resolve to the wrong (nonexistent) overload at call sites, so any
        // wire with a `@provided` member threw `NoSuchMethodError` at
        // runtime despite compiling cleanly.
        val bootstrapPs: List[JvmType] = newList()
        var ppi = 0
        while ppi < decl.members.count {
          match decl.members[ppi] {
            case WMProvided(_, pty, _) -> bootstrapPs.add(typeExprToJvm(pty, owner))
            case _ -> ()
          }
          ppi = ppi + 1
        }
        registerStaticWireSig(into, decl.name, wireClass, "bootstrap", bootstrapPs, JVoid)
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
      case IVal(decl) -> {
        // Register module-level `val`s in the cross-package registry so a
        // consumer package's bare reference emits `getstatic <owner>.<name>`
        // instead of the silent `aconst_null` fallback (docs/59 §4.4 — the
        // store side already panics since m-23, the load side was silent).
        // Registered under `val:`-prefixed keys (same idiom as the `field:`
        // opaque-field keys): the bare `val:<name>` key is import-aware — the
        // bridge's `importAwareRegistry` re-points `<owner>/<bare>` keys per
        // file — and `<owner>/val:<name>` is the qualified form.  Only vals
        // whose emitted static-field type is knowable WITHOUT lowering the
        // initialiser are registered (an explicit annotation, or a literal
        // init): for the rest, `prelowerModuleVals` derives the field type
        // from the lowered initialiser in the DECLARING package's context, so
        // a registry guess here would mis-descriptor the cross-package
        // `getstatic` (NoSuchFieldError at run time).  Unregistered vals fail
        // loud at the read site with a pointer to add an annotation.
        match decl.pattern.kind {
          case PBinding(vname, _) -> {
            match moduleValRegistryType(decl, owner, externTypes) {
              case Some(vty) -> {
                val vsig = JvmFuncSig(
                  owner = owner,
                  params = newList(),
                  ret = vty,
                  paramNames = newList(),
                  paramDefaults = newList(),
                  paramModes = newList(),
                  isIface = false,
                  retGenericArgs = newList(),
                  closureRetTy = None,
                  recordRetClass = None,
                  // A module-level `val`'s type is never `Self`.
                  retIsSelf = false,
                  // Keyed `val:`-prefixed, never a bare name — unreachable
                  // from `isUnsignedExpr`'s `ECall` arm, and a val read is
                  // `EMember` anyway, never `ECall`.
                  retIsUnsigned = false
                )
                val vqkey = owner + "/val:" + vname
                if not into.containsKey(vqkey) {
                  into.add(vqkey, vsig)
                }
                val vbkey = "val:" + vname
                if not into.containsKey(vbkey) {
                  into.add(vbkey, vsig)
                }
              }
              case None -> ()
            }
          }
          case _ -> ()
        }
      }
      case IEnum(decl) -> {
        // Enum-case value/pattern resolution (docs/59 §4.4): register each
        // variant under the type-scoped `enumty:<Enum>.<Case>` key and the bare
        // `enumcase:<Case>` key (plus its `<owner>/`-qualified form so the
        // bridge's import-aware overlay re-points the bare key per file), sig
        // owner = the declaring enum's JVM class.  Mirrors the MSIL
        // `registerEnumDeclMsil` ordinal registry; on the JVM a variant is the
        // `public static final` singleton field `lowerEnum` emits, read via
        // `getstatic` and pattern-tested by reference identity.
        val enumCls = owner + "/" + decl.name
        // Package-qualified key (`enumpkg:<dotted package>.<Case>`, e.g.
        // "enumpkg:Std.Http.GET"), alongside the type-scoped `enumty:<Enum>.<Case>`
        // key above: Lyric enum cases are conventionally referenced through
        // their declaring PACKAGE, not an explicit `<EnumType>.` segment
        // (`Std.Http.GET`, not `Std.Http.HttpMethod.GET`) — mirrors MSIL's
        // `registerEnumDeclMsil` `qn = pkgName + "." + cn` key (#5769, JVM
        // parity for MSIL's #5737 fix). `owner` is the JVM slash-path
        // (`Std/Http`); the source-level dotted package name is the same
        // segments joined with `.` instead.
        val dottedPkg = owner.replace("/", ".")
        var eci = 0
        while eci < decl.cases.count {
          val ecn = decl.cases[eci].name
          val esig = JvmFuncSig(
            owner = enumCls,
            params = newList(),
            ret = JRef(className = enumCls),
            paramNames = newList(),
            paramDefaults = newList(),
            paramModes = newList(),
            isIface = false,
            retGenericArgs = newList(),
            closureRetTy = None,
            recordRetClass = None,
            // An enum case value's type is never `Self`.
            retIsSelf = false,
            // Keyed `enum:`/`enumcase:`-prefixed, never a bare name, and a
            // nullary case reference is `EMember`, never `ECall`.
            retIsUnsigned = false
          )
          // #6683: each tier below gets its OWN key prefix (`enumty:` /
          // `enumfull:` / `enumpkg:`) so a type-scoped, package-scoped, or
          // (package, TYPE)-scoped key can never alias one another just
          // because `dottedPkg`/`decl.name` are ordinary user-controlled
          // identifiers whose concatenation happens to collide (e.g.
          // package `Std.Http` declaring `enum Status { case Ok }` — old
          // epkey "enum:Std.Http.Ok" — versus package `Std` declaring
          // `enum Http { case Ok }` — old efkey "enum:Std.Http.Ok" too).
          // Sharing one flat "enum:" namespace meant the `not containsKey`
          // guard on one tier could silently skip registering an unrelated
          // entry in a DIFFERENT tier that happened to produce the same
          // string, with no poison/ambiguity detection at all (the #6640
          // poison mechanism only fires on a same-KEY-same-tier conflict).
          val etkey = "enumty:" + decl.name + "." + ecn
          if not into.containsKey(etkey) {
            into.add(etkey, esig)
          }
          // #6640: the package-scoped key below is (package, case) only —
          // it omits the enum's own TYPE name — so two DIFFERENT enums
          // declared in the SAME package sharing a case name (e.g. `enum
          // Status { case Ok }` and `enum Health { case Ok }`) collide on
          // it, and the `not containsKey` guard silently kept whichever
          // enum registered first. Register the genuinely unambiguous
          // (package, TYPE, case)-scoped key first — always safe, since
          // `enumCls` bakes in the exact declaring class, so it can never
          // collide with another enum's entry — then guard the
          // (package, case)-only key: if it already names a DIFFERENT
          // enum, poison it (`enumVariantClassByPkg` refuses a poisoned
          // key) instead of leaving it pointed at whichever enum
          // registered first.
          val efkey = "enumfull:" + dottedPkg + "." + decl.name + "." + ecn
          if not into.containsKey(efkey) {
            into.add(efkey, esig)
          }
          val epkey = "enumpkg:" + dottedPkg + "." + ecn
          match mapGet(into, epkey) {
            case Some(existingSig) -> {
              if existingSig.owner != enumCls {
                val ambigKey = "enumpkgambig:" + dottedPkg + "." + ecn
                if not into.containsKey(ambigKey) {
                  into.add(ambigKey, esig)
                }
              }
            }
            case None -> into.add(epkey, esig)
          }
          val ebkey = "enumcase:" + ecn
          if not into.containsKey(ebkey) {
            into.add(ebkey, esig)
          }
          val eqkey = owner + "/enumcase:" + ecn
          if not into.containsKey(eqkey) {
            into.add(eqkey, esig)
          }
          eci = eci + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// The exact JVM static-field type a module-level `val` will be emitted with,
// when that is derivable without lowering the initialiser: the resolved
// explicit annotation, or a literal init's type (mirroring both the literal
// arm of `inferValType` and the width rule literal lowering applies).  `None`
// for an unannotated non-literal init — its field type only exists after
// `prelowerModuleVals` lowers the initialiser, so it cannot be promised to
// other packages.
func moduleValRegistryType(decl: in ValDecl, owner: in String, externTypes: in Map[String, String]): Option[JvmType] {
  match decl.ty {
    case Some(te) -> Some(value = typeExprToJvmExtern(te, owner, externTypes))
    case None -> {
      match decl.init.kind {
        case ELiteral(lit) -> {
          match lit {
            case LInt(v, suffix, _) -> {
              match suffix {
                case I64 -> Some(value = JLong)
                case U64 -> Some(value = JLong)
                case _ -> {
                  if v >= -2147483648i64 and v <= 2147483647i64 {
                    Some(value = JInt)
                  } else {
                    Some(value = JLong)
                  }
                }
              }
            }
            case LFloat(_, fsuffix, _) -> match fsuffix { case F32 -> Some(value = JFloat); case _ -> Some(value = JDouble) }
            case LBool(_) -> Some(value = JBoolean)
            case LString(_) -> Some(value = JRef(className = "java/lang/String"))
            case LTripleString(_) -> Some(value = JRef(className = "java/lang/String"))
            case LRawString(_) -> Some(value = JRef(className = "java/lang/String"))
            case LChar(_) -> Some(value = JChar)
            case LUnit -> None
          }
        }
        case _ -> None
      }
    }
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
  externTypes: in Map[String, String],
): Unit {
  // Non-generic receiver: no type params to erase.
  registerInstanceSigErased(into, className, methodName, params, retOpt, owner, newList(), externTypes)
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
  externTypes: in Map[String, String],
): Unit {
  val filteredParams = stripLeadingSelfParam(params)
  // Use holderAwareParamTypes so out/inout params register as JArray(elemTy) in the
  // descriptor, matching the emitted method and the call-site wrapping (#1763).
  // Resolves through the declaring file's own `externTypes` (#5051) — a bare
  // `noExts` here pre-resolved an extern-typed param/return/generic-arg
  // (`Option[Instant]`) to the in-package guess instead of the real class.
  val ps = holderAwareParamTypes(filteredParams, owner, true, typeParams, externTypes)
  val ret = match retOpt {
    case Some(te) -> typeExprToJvmErasedExtern(te, owner, typeParams, externTypes)
    case None -> JVoid
  }
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
  // Declared return is (or paren-wraps) bare `Self` — mirrors
  // `isSelfTypeExprJvm`'s param usage below, applied to the return slot
  // (#6431). `retOpt`/`retIsSelf` are computed from the RAW (unstripped)
  // signature, matching how `retGenericArgs`/`closureRetTy` are derived
  // above; a call site substitutes this against the receiver's own known
  // concrete class rather than the erased `ret` (which stays `Object`,
  // matching the interface slot's descriptor).
  val retIsSelf = match retOpt { case Some(te) -> isSelfTypeExprJvm(te); case None -> false }
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
        retGenericArgs = eagerlyResolveGenericArgs(returnTypeGenericArgsFiltered(retOpt, typeParams), owner, externTypes),
        closureRetTy = closureRetTypeOf(retOpt, owner, typeParams, externTypes),
        recordRetClass = None,
        retIsSelf = retIsSelf,
        // Keyed `<class>#<method>` — an instance-method call is
        // `ECall(EMember(…), …)`, never matches `isUnsignedExpr`'s
        // `ECall(EPath, …)`-only arm.
        retIsUnsigned = false
      )
    )
  }
}

// Register a record/protected/opaque field's DECLARED `slice[Elem]` /
// `List[Elem]` element type — or a `Map[K, V]` field's VALUE type `V`
// (#5451) — under the pseudo-key `elem:<class>#<field>` (#5444, following
// the `field:` / `enum:` / `enumcase:` funcSigs-key precedents).
// `indexedElemTypeOverride`'s `EMember` / bare-self-field arms consult it so
// an indexed element read through a FIELD receiver (`self.mws[self.idx]` —
// the lyric-web `MiddlewareChain` shape; `self.sessions[id]` — a
// `Map[String, SessionData]` field, the lyric-session shape) narrows the
// erased `Object` element back to its concrete class, exactly as the
// bare-name `varGenericArgs` path already does for parameters and locals.
// The element is resolved eagerly against the DECLARING file's own
// `owner`/`externTypes` (like `retGenericArgs`, #5050), so a cross-package
// consumer reading the field sees the real class, never its own in-package
// guess.  Only genuinely-narrowing elements are registered: the declaration's
// own generic params (erase to Object), `Object` itself, and nested
// slice/List/Map elements (`JArray` — `coerceArgTo` has no Object→array
// narrowing arm, mirroring `indexedElemTypeOverride`'s caution) are all
// skipped, so a registered entry's `ret` can be applied unconditionally at
// the read site.  Only `V` is ever recorded for a Map field — `K` is never
// consulted by an indexed VALUE read, and this registry holds a single
// `JvmFuncSig.ret`, not a `[K, V]` list.
func registerFieldElemSig(
  into: in Map[String, JvmFuncSig],
  className: in String,
  fieldName: in String,
  fty: in TypeExpr,
  owner: in String,
  typeParams: in List[String],
  externTypes: in Map[String, String],
): Unit {
  val elems: List[TypeExpr] = newList()
  match fty.kind {
    case TSlice(elem) -> elems.add(elem)
    case TGenericApp(head, args) -> {
      if head.segments.count == 1 and lastSegment(head) == "List" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> elems.add(inner)
          case TAValue(_) -> ()
        }
      } else if head.segments.count == 1 and lastSegment(head) == "Map" and args.count == 2 {
        match args[1] {
          case TAType(v) -> elems.add(v)
          case TAValue(_) -> ()
        }
      }
    }
    case TParen(inner) -> {
      registerFieldElemSig(into, className, fieldName, inner, owner, typeParams, externTypes)
      return
    }
    case _ -> ()
  }
  if elems.count != 1 {
    return
  }
  if typeParamIndexOf(elems[0], typeParams) >= 0 {
    return
  }
  val elemJvm = typeExprToJvmErasedExtern(elems[0], owner, typeParams, externTypes)
  val usable = match elemJvm {
    case JRef(cls) -> cls != "java/lang/Object"
    case JArray(_) -> false
    case JVoid -> false
    case _ -> true
  }
  if not usable {
    return
  }
  val key = "elem:" + className + "#" + fieldName
  if into.containsKey(key) {
    return
  }
  val noPs: List[JvmType] = newList()
  val noNames: List[String] = newList()
  val noDefs: List[Option[Expr]] = newList()
  val noModes: List[ParamMode] = newList()
  val noRga: List[TypeExpr] = newList()
  into.add(
    key,
    JvmFuncSig(
      owner = className,
      params = noPs,
      ret = elemJvm,
      paramNames = noNames,
      paramDefaults = noDefs,
      paramModes = noModes,
      isIface = false,
      retGenericArgs = noRga,
      closureRetTy = None,
      recordRetClass = None,
      // A field's declared element type is never `Self`.
      retIsSelf = false,
      // Keyed `elem:<class>#<field>`, consulted only by
      // `indexedElemTypeOverride`'s field-receiver arm — not the bare-name
      // `varGenericArgs` path `isUnsignedExpr`'s `EIndex` arm consults
      // (finding 1.2c is scoped to a bare-name receiver; see its doc).
      retIsUnsigned = false
    )
  )
}

// Register one interface member under `<ifaceClass>#<method>` with
// `isIface = true` (#3687).  Params and return mirror the abstract-method
// emission in the `IInterface` arm of `codegenPackageWithSigs` exactly —
// `holderAwareParamTypes(erase = true, the interface's own type params)` and
// an extern-aware return — so the registered descriptor and the emitted
// interface method stay in lockstep (#5054, #5534).
func registerIfaceSig(
  into: in Map[String, JvmFuncSig],
  ifClass: in String,
  methodName: in String,
  params: in List[Param],
  retOpt: in Option[TypeExpr],
  owner: in String,
  externTypes: in Map[String, String],
  typeParams: in List[String],
): Unit {
  // An explicit `self: in Self` receiver (the D037 spelling) is the
  // dispatch receiver, never a descriptor parameter — leaving it in made
  // every `invokeinterface` call site arity-mismatch (VerifyError
  // "Attempt to pop empty stack", #5607).  Same discipline as
  // `registerInstanceSigErased` and the MSIL `stripExplicitSelfParamMsil`.
  val realParams = stripLeadingSelfParam(params)
  val ps = holderAwareParamTypes(realParams, owner, true, typeParams, externTypes)
  val ret = match retOpt { case Some(te) -> typeExprToJvmExtern(te, owner, externTypes); case None -> JVoid }
  val pNames: List[String] = newList()
  val pDefs: List[Option[Expr]] = newList()
  val pModes: List[ParamMode] = newList()
  var pi = 0
  while pi < realParams.count {
    pNames.add(realParams[pi].name)
    pDefs.add(realParams[pi].dflt)
    pModes.add(realParams[pi].mode)
    pi = pi + 1
  }
  // Recorded for symmetry with `registerInstanceSigErased`, even though an
  // interface-typed receiver's call-site codegen never consults it (an
  // interface method's `Self` return stays erased — `sig.isIface = true`
  // gates the call site's checkcast substitution off, #6431).
  val retIsSelf = match retOpt { case Some(te) -> isSelfTypeExprJvm(te); case None -> false }
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
        // Resolved eagerly against the DECLARING file's own `owner`/`externTypes`
        // (#5050), same as `collectFileSigsSeeded`/`registerInstanceSigErased` —
        // filtered against the interface's OWN generic params first so a bare
        // `T` isn't mistaken for a resolved type (mirrors the `mapGet` guard).
        retGenericArgs = eagerlyResolveGenericArgs(returnTypeGenericArgsFiltered(retOpt, typeParams), owner, externTypes),
        closureRetTy = closureRetTypeOf(retOpt, owner, typeParams, externTypes),
        recordRetClass = None,
        retIsSelf = retIsSelf,
        // Keyed `<ifaceClass>#<method>` — interface method calls are
        // `ECall(EMember(…), …)`, same as `registerInstanceSigErased`.
        retIsUnsigned = false
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
        retGenericArgs = newList(),
        closureRetTy = None,
        recordRetClass = None,
        // A wire's static factory/accessor return is never `Self`.
        retIsSelf = false,
        // Keyed `<wireShortName>.<method>` — called `EMember`-form
        // (`AppWire.bootstrap()`), and `ret` here is already an erased
        // `JvmType` with no declared `TypeExpr` on hand to check.
        retIsUnsigned = false
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
  // #6393: same-file `alias X = ...` table so a function-type-aliased field
  // (`record Holder { h: Handler }`) registers its binding-site field type
  // as `Object` exactly like a literal `(Int) -> Int` field already does —
  // see `Lyric.BareFuncRef`'s module doc §2.  `f.ty`'s registered type here
  // must agree with the FIELD DESCRIPTOR `lowerRecord` actually emits, or a
  // field read (`holder.h`) recovers the wrong static type.
  val aliasTargets = BareFuncRef.collectFuncAliasTargets(file)
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
                case UFNamed(name, ty, _) -> flds.add(
                  JvmCaseField(
                    name = name,
                    ty = typeExprToJvmErasedExtern(
                      BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, ty),
                      owner,
                      tps,
                      externTypes
                    ),
                    paramIdx = typeParamIndexOf(ty, tps),
                    dflt = None
                  )
                )
                case UFPos(ty, _) -> flds.add(
                  JvmCaseField(
                    name = "field" + toString(fi),
                    ty = typeExprToJvmErasedExtern(
                      BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, ty),
                      owner,
                      tps,
                      externTypes
                    ),
                    paramIdx = typeParamIndexOf(ty, tps),
                    dflt = None
                  )
                )
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
              case RMField(f) -> flds.add(
                JvmCaseField(
                  name = f.name,
                  ty = typeExprToJvmErasedExtern(
                    BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, f.ty),
                    owner,
                    tps,
                    externTypes
                  ),
                  paramIdx = typeParamIndexOf(f.ty, tps),
                  dflt = f.dflt
                )
              )
              case _ -> {
              }
            }
            mi = mi + 1
          }
          into.add(recClass, flds)
        }
      }
      // #6526: `IExposedRec` carries the identical `RecordDecl` shape as
      // `IRecord` — same field-collection.  Missing this arm left
      // `recordFieldType` returning `None` for every `exposed record`
      // field, erasing reads/writes to `java.lang.Object` and panicking
      // on compound-assignment (`emitCompoundCombineJvm`'s erased-target
      // guard).
      case IExposedRec(decl) -> {
        val recClass = owner + "/" + decl.name
        val tps = genericParamNames(decl.generics)
        if not into.containsKey(recClass) {
          val flds: List[JvmCaseField] = newList()
          var mi = 0
          while mi < decl.members.count {
            match decl.members[mi] {
              case RMField(f) -> flds.add(
                JvmCaseField(
                  name = f.name,
                  ty = typeExprToJvmErasedExtern(
                    BareFuncRef.resolveFuncTypeAliasOrSelf(aliasTargets, f.ty),
                    owner,
                    tps,
                    externTypes
                  ),
                  paramIdx = typeParamIndexOf(f.ty, tps),
                  dflt = f.dflt
                )
              )
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
                  case PFVar(name, ty, init, _, _, _) -> flds.add(
                    JvmCaseField(
                      name = name,
                      ty = typeExprToJvmExtern(ty, owner, externTypes),
                      paramIdx = -1,
                      dflt = init
                    )
                  )
                  case PFLet(name, ty, init, _, _, _) -> flds.add(
                    JvmCaseField(
                      name = name,
                      ty = typeExprToJvmExtern(ty, owner, externTypes),
                      paramIdx = -1,
                      dflt = init
                    )
                  )
                  case PFImmutable(f) -> flds.add(
                    JvmCaseField(
                      name = f.name,
                      ty = typeExprToJvmExtern(f.ty, owner, externTypes),
                      paramIdx = -1,
                      dflt = f.dflt
                    )
                  )
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
                // Resolve through extern aliases + generic erasure like record
                // fields above: an opaque field typed by an imported extern
                // alias (`CompiledRegex { handle: RxHost.Regex }`) otherwise
                // registers as a nonexistent `<pkg>/<Alias>` class, and every
                // construction site checkcasts to it — NoClassDefFoundError at
                // first call (the Std.Regex-on-JVM failure shape).
                case OMField(f) -> flds.add(
                  JvmCaseField(
                    name = f.name,
                    ty = typeExprToJvmErasedExtern(f.ty, owner, genericParamNames(decl.generics), externTypes),
                    paramIdx = -1,
                    dflt = f.dflt
                  )
                )
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
      // #6526: `IExposedRec` carries the identical `RecordDecl` shape as
      // `IRecord` — same FQN registration.
      case IExposedRec(decl) -> {
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
      case IEnum(decl) -> {
        // Enums are emitted as real JVM classes (`lowerEnum`); without this a
        // consumer's enum-typed parameter / binding / field descriptor named
        // the in-package guess (`<consumerPkg>/HttpMethod`), which fails
        // linking with NoClassDefFoundError at first use (#5609 item 3 —
        // the variant-value registry (`enum:` keys) was already
        // cross-package, but the TYPE name itself never resolved).
        if not into.containsKey(decl.name) {
          into.add(decl.name, pkgDotted + "." + decl.name)
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
      // #6526: `IExposedRec` carries the identical `RecordDecl` shape as
      // `IRecord` — same ctor registration.  Missing this arm left every
      // `exposed record`'s constructor unregistered, so `Holder(value =
      // ...)` resolved to the bogus `()Object`-guess descriptor instead of
      // the real `<init>` — `NoSuchMethodError` at runtime.
      case IExposedRec(decl) -> {
        addCtorKeys(into, owner, decl.name, owner + "/" + decl.name)
      }
      case IUnion(decl) -> {
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          val caseCls = owner + "/" + decl.name + "$" + c.name
          addCtorKeys(into, owner, c.name, caseCls)
          // Also register the union-name-qualified key (`<Union>$<Case>`,
          // e.g. "YamlError$InvalidDocument") so `resolveCaseClassJvm` can
          // resolve an imported union's in-package-guessed static class to
          // its REAL declaring package's case class via a single `ctors`
          // lookup instead of a linear scan over every registered case class
          // (#4802) — same first-wins semantics as the bare/scoped keys above.
          addCtorKeys(into, owner, decl.name + "$" + c.name, caseCls)
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

// Register a constructable type under its bare name (bundle-global, first
// wins — the legacy single-package shape), a package-scoped key
// (`<owner>::<name>`), and a package-DOTTED-qualified key (`<dotted
// owner>.<name>`, e.g. "IfacePkg.Text").  `ctorClassFor` tries the scoped
// key first, so a package's OWN case wins over a same-named case another
// bundled package registered earlier (`InvalidDocument` exists in both
// `Std.Xml`'s XmlError and `Std.Yaml`'s YamlError — the bare first-wins
// entry gave Yaml's code Xml's class: NoClassDefFoundError at runtime).
// The dotted-qualified key lets a CALL SITE that spells out the declaring
// package (`IfacePkg.Text(value = ...)`, parsed as a flat multi-segment
// `EPath`) resolve to the real declaring class even when some OTHER
// bundled package registered the same bare case/record name first (#5455):
// `lowerGeneralStaticCall` looks up the full dotted path before falling
// back to the bare bundle-global entry.
func addCtorKeys(into: in Map[String, String], owner: in String, name: in String, cls: in String): Unit {
  if not into.containsKey(name) {
    into.add(name, cls)
  }
  val scopedKey = owner + "::" + name
  if not into.containsKey(scopedKey) {
    into.add(scopedKey, cls)
  }
  val dottedKey = owner.replace("/", ".") + "." + name
  if not into.containsKey(dottedKey) {
    into.add(dottedKey, cls)
  }
}

// ── Distinct/range-subtype static factories (#5956) ──────────────────────────
// JVM counterpart of `Msil.Codegen.foldRangeBound`/`mkDistinctTypeIR`: folds a
// distinct/range-subtype declaration's range clause into concrete bounds so
// the synthesised `from`/`tryFrom` factories (`Jvm.Lowering.lowerDistinctType`)
// can emit a real bounds check, and so `Jvm.Codegen.lowerMethodCall` can
// recognise a `TypeName.from(x)` / `TypeName.tryFrom(x)` call site.
record JvmRangeBoundVal {
  ok: Bool
  isFloat: Bool
  l: Long
  d: Double
}

func foldRangeBoundJvm(e: in Expr): JvmRangeBoundVal {
  val failVal = JvmRangeBoundVal(ok = false, isFloat = false, l = 0i64, d = 0.0)
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> JvmRangeBoundVal(ok = true, isFloat = false, l = v, d = 0.0)
        case LFloat(v, _, _) -> JvmRangeBoundVal(ok = true, isFloat = true, l = 0i64, d = v)
        case _ -> failVal
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          val inner = foldRangeBoundJvm(operand)
          if inner.ok {
            JvmRangeBoundVal(ok = true, isFloat = inner.isFloat, l = 0i64 - inner.l, d = 0.0 - inner.d)
          } else {
            failVal
          }
        }
        case _ -> failVal
      }
    }
    case _ -> failVal
  }
}

// `UInt`/`ULong` have no distinct JVM primitive (`typeExprToJvm` erases both
// to `JInt`/`JLong`, #6661), so `LDistinctType.isUnsigned` can't be derived
// from the erased `JvmType` alone — it's read off the SOURCE `TypeExpr`
// before erasure, at `mkJvmDistinctTypeIR`'s call site below.
func isUnsignedNumericBaseType(te: in TypeExpr): Bool {
  match te.kind {
    case TRef(path) -> {
      val seg = lastSegment(path)
      seg == "UInt" or seg == "ULong"
    }
    case _ -> false
  }
}

func mkJvmDistinctNoRange(wrapperClass: in String, inner: in JvmType, isUnsigned: in Bool): LDistinctType {
  LDistinctType(
    wrapperClass = wrapperClass,
    underlyingType = inner,
    hasRange = false,
    rangeIsFloat = false,
    minI = 0i64,
    maxI = 0i64,
    minF = 0.0,
    maxF = 0.0,
    upperExclusive = false,
    isUnsigned = isUnsigned
  )
}

func mkJvmDistinctRanged(
  wrapperClass: in String,
  inner: in JvmType,
  loE: in Expr,
  hiE: in Expr,
  upperExcl: in Bool,
  isUnsigned: in Bool,
): LDistinctType {
  val lo = foldRangeBoundJvm(loE)
  val hi = foldRangeBoundJvm(hiE)
  // #6661: `Float` (`JFloat`) is floating-point too — it was excluded here
  // (only `JDouble` counted), so a `Float`-backed range subtype folded its
  // bounds into the WRONG field pair (`minI`/`maxI`, always 0 for a
  // non-integer literal bound) and `Jvm.Lowering.emitJvmDistinctBoundsToFail`
  // then took the plain-int comparison branch against a 32-bit `float`
  // argument loaded via `fload` — a verifier type mismatch (unverifiable
  // bytecode), not merely a wrong bound.
  val isFloatInner = match inner { case JDouble -> true; case JFloat -> true; case _ -> false }
  if lo.ok and hi.ok {
    val loF = if lo.isFloat { lo.d } else { lo.l.toDouble() }
    val hiF = if hi.isFloat { hi.d } else { hi.l.toDouble() }
    LDistinctType(
      wrapperClass = wrapperClass,
      underlyingType = inner,
      hasRange = true,
      rangeIsFloat = isFloatInner,
      minI = lo.l,
      maxI = hi.l,
      minF = loF,
      maxF = hiF,
      upperExclusive = upperExcl,
      isUnsigned = isUnsigned
    )
  } else {
    mkJvmDistinctNoRange(wrapperClass, inner, isUnsigned)
  }
}

// Build the distinct-type IR item, folding any range clause to integer/float
// bounds for the synthesised `from`/`tryFrom` validation.  Mirrors
// `Msil.Codegen.mkDistinctTypeIR` exactly (same fold, same no-range fallback
// for an unrecognised `RangeBound` variant, #3116) — MSIL has no `isUnsigned`
// counterpart to thread since `UInt`/`ULong` have no MSIL representation at
// all yet (#6661).
pub func mkJvmDistinctTypeIR(
  wrapperClass: in String,
  inner: in JvmType,
  rangeClause: in Option[RangeBound],
  isUnsigned: in Bool,
): LDistinctType {
  match rangeClause {
    case Some(rb) -> {
      match rb {
        case RBClosed(loE, hiE) -> mkJvmDistinctRanged(wrapperClass, inner, loE, hiE, false, isUnsigned)
        case RBHalfOpen(loE, hiE) -> mkJvmDistinctRanged(wrapperClass, inner, loE, hiE, true, isUnsigned)
        case _ -> mkJvmDistinctNoRange(wrapperClass, inner, isUnsigned)
      }
    }
    case None -> mkJvmDistinctNoRange(wrapperClass, inner, isUnsigned)
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

// Collect every `config { … }` block's field types (docs/25-config-blocks.md,
// #3228) into `into`, keyed `"<BlockName>/<fieldName>"`.  Drives qualified
// reads (`Settings.port`) resolving to `getstatic <owner>/<BlockName>.<field>`
// — see `FuncCtx.configFieldTypes`.  By the time codegen sees the file,
// `Lyric.WireExpand` has already materialised every `config … from …`
// template instantiation and hoisted every wire-embedded config instance out
// to a top-level `IConfig` item with a concrete field list (docs/58 §12), so
// this pre-pass only needs to walk `file.items` once, exactly like
// `collectFileValsExtern` — no template/`from` resolution happens here.
// Config field types are restricted to Bool/Int/Long/Float/Double/String
// (G0009), so `typeExprToJvm` (no extern-type resolution needed) is enough.
pub func collectFileConfigFieldTypes(file: in SourceFile, owner: in String, into: in Map[String, JvmType]): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IConfig(decl) -> {
        var fi = 0
        while fi < decl.fields.count {
          val f = decl.fields[fi]
          val key = decl.name + "/" + f.name
          if not into.containsKey(key) {
            into.add(key, typeExprToJvm(f.ty, owner))
          }
          fi = fi + 1
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Derive the environment variable name for a config block field (D046,
// mirrors `Msil.Codegen.deriveConfigEnvVarName`):
// LYRIC_CONFIG_<PKG_UPPER>_<BLOCK_UPPER>_<FIELD_UPPER>
// Slashes in the JVM package path are replaced with underscores before
// uppercasing (the JVM `pkgName` is already slash-separated, e.g.
// "MyApp/Server", where MSIL's is dot-separated).
func deriveConfigEnvVarNameJvm(pkgName: in String, blockName: in String, fieldName: in String): String {
  val pkgUpper = pkgName.replace("/", "_").toUpper()
  val blockUpper = blockName.toUpper()
  val fieldUpper = fieldName.toUpper()
  "LYRIC_CONFIG_" + pkgUpper + "_" + blockUpper + "_" + fieldUpper
}

// Lower a config field's literal default expression into `insns`, pushing the
// value in `fieldTy`'s representation (no field store — the caller assembles
// the surrounding `putstatic`).  Mirrors `Msil.Codegen.emitConfigDefaultLiteralMsil`.
// Returns false for any non-literal shape; the type checker's G0010 guard
// rejects those before codegen, so a false return here is an ICE, not a
// diagnosable input.
func emitConfigDefaultLiteralJvm(fieldTy: in JvmType, lit: in Literal, neg: in Bool, insns: in List[LInsn]): Bool {
  match lit {
    case LInt(v0, _, _) -> {
      val v = if neg { 0i64 - v0 } else { v0 }
      match fieldTy {
        case JInt -> {
          insns.add(LIconst(v = longToInt(v)))
          true
        }
        case JLong -> {
          insns.add(LLconst(v = v))
          true
        }
        case JFloat -> {
          insns.add(LFconst(v = v.toDouble()))
          true
        }
        case JDouble -> {
          insns.add(LDconst(v = v.toDouble()))
          true
        }
        case _ -> false
      }
    }
    case LFloat(f0, _, _) -> {
      val fv = if neg { 0.0 - f0 } else { f0 }
      match fieldTy {
        case JFloat -> {
          insns.add(LFconst(v = fv))
          true
        }
        case JDouble -> {
          insns.add(LDconst(v = fv))
          true
        }
        case _ -> false
      }
    }
    case LBool(bv) -> {
      match fieldTy {
        case JBoolean -> {
          if neg {
            false
          } else {
            insns.add(LIconst(v = if bv { 1 } else { 0 }))
            true
          }
        }
        case _ -> false
      }
    }
    case LString(sv) -> {
      match fieldTy {
        case JRef(cls) -> {
          if cls == "java/lang/String" and not neg {
            insns.add(LPushString(s = sv))
            true
          } else {
            false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
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
                vflds.add(JvmCaseField(name = infos[fi].name, ty = projViewFieldType(infos[fi]), paramIdx = -1, dflt = None))
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
                retGenericArgs = newList(),
                closureRetTy = None,
                recordRetClass = None,
                // A synthesised `toView()` accessor's return is the view
                // class itself, never `Self`.
                retIsSelf = false,
                // Keyed `<class>#toView` — called `EMember`-form.
                retIsUnsigned = false
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
                  retGenericArgs = newList(),
                  closureRetTy = None,
                  recordRetClass = None,
                  // A synthesised `tryInto()` accessor's return is
                  // `Std.Core.Result`, never `Self`.
                  retIsSelf = false,
                  // Keyed `<class>#tryInto` — called `EMember`-form.
                  retIsUnsigned = false
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

// Build the per-package `__lyric_await` helper (D119 S4 / D120): a `public
// static Object __lyric_await(Future f)` that returns `f.get()`, catching
// `ExecutionException` and rethrowing its cause so a caller's `try { await … }
// catch <TaskError>` observes the task's real exception rather than the
// executor's wrapper.  Lives in its own method frame, so its exception region
// begins with a clean operand stack — the reason `await` calls it via
// `invokestatic` instead of inlining the try/catch (see `lowerFutureGet`).
//
// `InterruptedException` (the other checked exception `Future.get()` declares) is
// intentionally not caught: it cannot arise on today's baseline, which never
// interrupts a joining thread — the deferred JEP 505 sibling-cancel-on-first-fault
// follow-up (D120) is what would introduce interruption, and it will add the
// handler alongside the cancel wiring (tracked in #5192).
func makeAwaitHelperFunc(): LFunc {
  val futureTy = JRef(className = "java/util/concurrent/Future")
  val objTy = JRef(className = "java/lang/Object")
  val insns: List[LInsn] = newList()
  insns.add(LLabel(name = "aw_start"))
  insns.add(LAload(slot = 0))
  insns.add(
    LInvokeinterface(owner = "java/util/concurrent/Future", name = "get", params = newList(), ret = objTy, argCount = 1)
  )
  insns.add(LAreturn)
  insns.add(LLabel(name = "aw_end"))
  // Handler: the caught `ExecutionException` is on the stack; rethrow its cause.
  insns.add(LLabel(name = "aw_handler"))
  insns.add(
    LInvokevirtual(
      owner = "java/lang/Throwable",
      name = "getCause",
      params = newList(),
      ret = JRef(className = "java/lang/Throwable")
    )
  )
  insns.add(LAthrow)
  insns.add(
    LTryCatch(
      startLabel = "aw_start",
      endLabel = "aw_end",
      handlerLabel = "aw_handler",
      catchClass = "java/util/concurrent/ExecutionException"
    )
  )
  val ps: List[JvmType] = newList()
  ps.add(futureTy)
  LFunc(flags = 0x0009, name = awaitHelperName(), params = ps, ret = objTy, insns = insns, maxStack = 0, maxLocals = 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. Lambda-interface emission gate (#6113).
// ─────────────────────────────────────────────────────────────────────────────
// True when `ty` is, or (recursively) contains, a function type (`(A) -> B`).
// Syntax-only (no type-check info needed): used to decide, ahead of codegen,
// whether a package needs to emit its own `Lyric$Lambda` interface even when
// it lowers no lambda LITERAL of its own. A function whose parameter is
// itself a function type (e.g. `Std.Core.countWhere(xs, pred: (Int) ->
// Bool)`) still emits a `checkcast`/`invokeinterface` against the package's
// OWN `Lyric$Lambda` the moment that parameter is called (`lowerLambdaInvoke`
// in `04_calls.l`) — even though the closure literal that eventually flows in
// was created in a DIFFERENT (calling) package. The previous gate
// (`closureAcc.count > 0`, populated only when THIS package's own code
// lowers a lambda literal) missed every stdlib-style higher-order function
// that merely calls a caller-supplied predicate, so the interface class was
// never written to the JAR and the first call threw
// `NoClassDefFoundError: <Pkg>/Lyric$Lambda` at runtime — confirmed via
// `Std.Core.countWhere` (#6113): `core.l` declares zero lambda literals of
// its own, so `closureAcc` for that package's codegen pass was always empty.
func typeExprMentionsFunctionType(ty: in TypeExpr): Bool {
  match ty.kind {
    case TFunction(_, _) -> true
    case TGenericApp(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(inner) -> {
            if typeExprMentionsFunctionType(inner) {
              return true
            }
          }
          case TAValue(_) -> ()
        }
        i = i + 1
      }
      false
    }
    case TArray(_, element) -> typeExprMentionsFunctionType(element)
    case TSlice(element) -> typeExprMentionsFunctionType(element)
    case TTuple(types) -> {
      var i = 0
      while i < types.count {
        if typeExprMentionsFunctionType(types[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TNullable(inner) -> typeExprMentionsFunctionType(inner)
    case TParen(inner) -> typeExprMentionsFunctionType(inner)
    case _ -> false
  }
}

func paramsOrRetMentionFunctionType(params: in List[Param], ret: in Option[TypeExpr]): Bool {
  var i = 0
  while i < params.count {
    if typeExprMentionsFunctionType(params[i].ty) {
      return true
    }
    i = i + 1
  }
  match ret {
    case Some(t) -> typeExprMentionsFunctionType(t)
    case None -> false
  }
}

func recordDeclNeedsLambdaIface(decl: in RecordDecl): Bool {
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case RMField(f) -> {
        if typeExprMentionsFunctionType(f.ty) {
          return true
        }
      }
      case RMFunc(fn) -> {
        if paramsOrRetMentionFunctionType(fn.params, fn.ret) {
          return true
        }
      }
      case RMInvariant(_) -> ()
    }
    mi = mi + 1
  }
  false
}

func configFieldsNeedLambdaIface(fields: in List[ConfigField]): Bool {
  var i = 0
  while i < fields.count {
    if typeExprMentionsFunctionType(fields[i].ty) {
      return true
    }
    i = i + 1
  }
  false
}

// True when any function signature this package declares mentions a
// function type. A conservative (syntax-only) over-approximation: it does
// not verify the parameter is actually ever CALLED, only that it COULD be —
// so a package with an unused function-typed field emits one harmless,
// never-instantiated interface class rather than risk missing a real one.
//
// The `match item.kind` below is deliberately EXHAUSTIVE against every
// `ItemKind` case in `parser_ast.l` — no catch-all `case _`. Each excluded
// case carries a one-line justification so a future new `ItemKind` variant
// fails to compile here (forcing a conscious decision) rather than silently
// falling through a wildcard, which is exactly how #6349 and #6350 (missed
// `IUnion`, then missed `IImpl`/`IProtected`) slipped through twice.
func fileNeedsLambdaIface(file: in SourceFile): Bool {
  // A function-type alias makes any annotation a potential lambda carrier
  // WITHOUT literally mentioning a TFunction — the per-arm scans below see
  // only the unresolved TRef, so an alias-typed field/param would get an
  // iface-referencing descriptor with no iface emitted (#6406).
  // Over-approximate: any file declaring a function-type alias gets the
  // iface (an unused alias costs one small unused interface class).
  if BareFuncRef.hasFuncAliasTargets(file) {
    return true
  }
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IConst(decl) -> {
        if typeExprMentionsFunctionType(decl.ty) {
          return true
        }
      }
      case IVal(decl) -> {
        match decl.ty {
          case Some(ty) -> {
            if typeExprMentionsFunctionType(ty) {
              return true
            }
          }
          case None -> ()
        }
      }
      case IFunc(decl) -> {
        if paramsOrRetMentionFunctionType(decl.params, decl.ret) {
          return true
        }
      }
      // A type alias only renames an existing type — it declares no new
      // field or parameter of its own for this scan to see. Whatever USES
      // the alias is a different item, already covered by its own arm.
      case ITypeAlias(_) -> ()
      // Same reasoning as ITypeAlias: a distinct-type wrapper renames one
      // existing type without declaring a field or parameter.
      case IDistinctType(_) -> ()
      case IRecord(decl) -> {
        if recordDeclNeedsLambdaIface(decl) {
          return true
        }
      }
      // `IExposedRec` carries the identical `RecordDecl` shape as `IRecord`
      // (docs glossary: an exposed record is the flat, host-visible twin of
      // an opaque type) — same scan.
      case IExposedRec(decl) -> {
        if recordDeclNeedsLambdaIface(decl) {
          return true
        }
      }
      // #6349: a union case payload field can itself carry a function type
      // (e.g. `case OnClick(cb: (Int) -> Bool)`). A package that only ever
      // INVOKES such a payload-extracted closure — no lambda literal, no
      // function-typed func/record-field/interface-method signature
      // anywhere else in the file — still lowers that call to
      // `invokeinterface <Pkg>/Lyric$Lambda.invoke`, reproducing the exact
      // #6113 NoClassDefFoundError via the union-payload shape instead of
      // the higher-order-function shape.
      case IUnion(decl) -> {
        var ci = 0
        while ci < decl.cases.count {
          val uc = decl.cases[ci]
          var fi = 0
          while fi < uc.fields.count {
            val fieldTy = match uc.fields[fi] { case UFNamed(_, ty, _) -> ty; case UFPos(ty, _) -> ty }
            if typeExprMentionsFunctionType(fieldTy) {
              return true
            }
            fi = fi + 1
          }
          ci = ci + 1
        }
      }
      // Enum cases (`EnumCase`) are bare tags with no associated `TypeExpr`
      // at all — unlike union cases, which carry payload fields (see the
      // `IUnion` arm above). Nothing to scan.
      case IEnum(_) -> ()
      case IOpaque(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case OMField(field) -> {
              if typeExprMentionsFunctionType(field.ty) {
                return true
              }
            }
            case OMInvariant(_) -> ()
          }
          mi = mi + 1
        }
      }
      // #6350: a `ProtectedTypeDecl` member can carry a function type via a
      // field (`PMField` — `var`/`let`/immutable), an entry method
      // (`PMEntry`), or a plain method (`PMFunc`) — mirroring the
      // `IRecord`/`IInterface` arms.
      case IProtected(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMField(field) -> {
              val fieldTy = match field {
                case PFVar(_, ty, _, _, _, _) -> ty
                case PFLet(_, ty, _, _, _, _) -> ty
                case PFImmutable(fd) -> fd.ty
              }
              if typeExprMentionsFunctionType(fieldTy) {
                return true
              }
            }
            case PMEntry(entryDecl) -> {
              if paramsOrRetMentionFunctionType(entryDecl.params, entryDecl.ret) {
                return true
              }
            }
            case PMFunc(fn) -> {
              if paramsOrRetMentionFunctionType(fn.params, fn.ret) {
                return true
              }
            }
            case PMInvariant(_) -> ()
          }
          mi = mi + 1
        }
      }
      case IInterface(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              if paramsOrRetMentionFunctionType(sig.params, sig.ret) {
                return true
              }
            }
            case IMFunc(fn) -> {
              if paramsOrRetMentionFunctionType(fn.params, fn.ret) {
                return true
              }
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      // #6350: an `impl <Iface> for Type { ... }` block's own `IMplFunc`
      // members are the ONLY source of a method's signature when `<Iface>`
      // is an external/CLR interface (docs/51) — there is no corresponding
      // `IInterface` item in the same file for the `IInterface` arm above
      // to catch.
      case IImpl(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> {
              if paramsOrRetMentionFunctionType(fn.params, fn.ret) {
                return true
              }
            }
            case IMplAssoc(_) -> ()
          }
          mi = mi + 1
        }
      }
      // Wire declarations (docs/58) are expanded away by `Lyric.WireExpand`
      // before codegen runs, so an `IWire` item should not normally survive
      // to this scan — but the check is cheap and defensive in case an
      // unexpanded one ever reaches it (e.g. a future bridge path that
      // skips wire expansion).
      case IWire(decl) -> {
        if paramsOrRetMentionFunctionType(decl.params, None) {
          return true
        }
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case WMProvided(_, ty, _) -> {
              if typeExprMentionsFunctionType(ty) {
                return true
              }
            }
            case WMSingleton(_, ty, _, _) -> {
              if typeExprMentionsFunctionType(ty) {
                return true
              }
            }
            case WMScoped(_, _, ty, _, _) -> {
              if typeExprMentionsFunctionType(ty) {
                return true
              }
            }
            case WMBind(iface, _, _) -> {
              if typeExprMentionsFunctionType(iface) {
                return true
              }
            }
            case WMLocal(_, tyOpt, _, _) -> {
              match tyOpt {
                case Some(ty) -> {
                  if typeExprMentionsFunctionType(ty) {
                    return true
                  }
                }
                case None -> ()
              }
            }
            case WMContributes(iface, _, _, _, _, _) -> {
              if typeExprMentionsFunctionType(iface) {
                return true
              }
            }
            case WMConfigInst(cfgDecl, _) -> {
              if configFieldsNeedLambdaIface(cfgDecl.fields) {
                return true
              }
            }
            case _ -> ()
          }
          mi = mi + 1
        }
      }
      // `{ name, span }` only — nothing to scan.
      case IScopeKind(_) -> ()
      // Extern/FFI-boundary declarations describe the host (.NET/JVM) ABI;
      // any function-typed parameter there is resolved through the
      // auto-FFI / `@externTarget` bridge, never lowered to `invokeinterface
      // <Pkg>/Lyric$Lambda` — a wholly separate call-lowering path.
      case IExtern(_) -> ()
      case IExternType(_) -> ()
      // `extern func ... = "symbol"` is a native-target C-ABI declaration
      // (docs/N4 / D-N-007); its parameters describe the C calling
      // convention, not the JVM `Lyric$Lambda` closure ABI.
      case IExternFunc(_) -> ()
      // Test bodies declare no params of their own; any function value used
      // inside one is either a literal (caught by `closureAcc` when the
      // body is lowered) or flows in through an already-scanned typed
      // declaration elsewhere in the file.
      case ITest(_) -> ()
      case IProperty(decl) -> {
        var bi = 0
        while bi < decl.forAll.count {
          if typeExprMentionsFunctionType(decl.forAll[bi].ty) {
            return true
          }
          bi = bi + 1
        }
      }
      case IFixture(decl) -> {
        match decl.ty {
          case Some(ty) -> {
            if typeExprMentionsFunctionType(ty) {
              return true
            }
          }
          case None -> ()
        }
      }
      case IConfig(decl) -> {
        if configFieldsNeedLambdaIface(decl.fields) {
          return true
        }
      }
      case IAspect(decl) -> {
        if configFieldsNeedLambdaIface(decl.config) {
          return true
        }
        match decl.around {
          case Some(around) -> {
            match around.argsRow {
              case Some(rowFields) -> {
                var ri = 0
                while ri < rowFields.count {
                  if typeExprMentionsFunctionType(rowFields[ri].ty) {
                    return true
                  }
                  ri = ri + 1
                }
              }
              case None -> ()
            }
          }
          case None -> ()
        }
      }
      // Parse-error placeholder — no payload.
      case IError -> ()
    }
    i = i + 1
  }
  false
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
  // #6596: single-file entry point, so its "whole build" is just this file —
  // see `Lyric.ModeChecker.computeFieldLockSafetyForBuild`'s doc comment.
  val singleFileForAudit: List[SourceFile] = newList()
  singleFileForAudit.add(file)
  val unsafeFieldLockNames: Map[String, Bool] = newMap()
  computeFieldLockSafetyForBuild(singleFileForAudit, unsafeFieldLockNames)
  codegenPackageWithSigs(file, sigs, cases, ctors, autoFfi, allProjFqns, unsafeFieldLockNames)
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
  unsafeFieldLockNames: in Map[String, Bool],
): LPackage {
  val emptySeed: Map[String, String] = newMap()
  codegenPackageWithSigsSeeded(file, funcSigs, caseFields, ctors, autoFfi, allProjFqns, emptySeed, unsafeFieldLockNames)
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
  // #6596: see `lowerRecord`'s matching parameter doc comment.  Defaults to
  // an empty map at every existing caller below except the ones this fix
  // updates to pass a real, whole-build-computed set.
  unsafeFieldLockNames: in Map[String, Bool],
): LPackage {
  val pkgName = segmentsToJvmPath(file.packageDecl.path.segments)
  val funcsClass = pkgName

  // #6124: whether THIS FILE has `import Std.String` in scope — see
  // `FuncCtx.importsStdString`.  Computed once per file and threaded through
  // every function/method/wire-binding lowered below.
  val importsStdString = fileImportsStdString(file)

  // Collect extern-type declarations: alias → Java FQN.
  val externTypes = ownAwareExternTypes(file, externSeed)

  // #6393: same-file `alias X = ...` table, threaded through every function /
  // module-val FuncCtx below (mirrors `externTypes`'s own threading a few
  // lines up) — see `Lyric.BareFuncRef`'s module doc §2. #6413 audit: kept
  // for the stdlib-bundled-file gap — see `collectFileSigsSeeded`'s
  // matching comment above and D-progress-752.
  val aliasTargets = BareFuncRef.collectFuncAliasTargets(file)

  // m-2: collect the module-level `val NAME` declarations up front (name → JVM
  // type) so a bare reference to one resolves to `getstatic <hostClass>.<name>`
  // in every function of this package.
  val moduleVals: Map[String, JvmType] = newMap()
  collectFileValsExtern(file, pkgName, moduleVals, externTypes)
  // #3228: collect `config { … }` block field types up front (mirrors
  // `moduleVals` above) so a qualified read (`Settings.port`) anywhere in the
  // package resolves to `getstatic <pkgName>/<BlockName>.<fieldName>` — see
  // `FuncCtx.configFieldTypes`.
  val configFieldTypes: Map[String, JvmType] = newMap()
  collectFileConfigFieldTypes(file, pkgName, configFieldTypes)
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
  // Lazy-emission flag for `__lyricCount` (#4803): non-empty iff some function
  // in this package actually dispatches `.count`/`.length` on an erased
  // receiver (`02_exprs.l` appends a marker at the one call site that emits
  // `invokestatic __lyricCount`).  Threaded through every FuncCtx of the
  // package alongside `closureAcc`; checked below to decide whether the
  // helper method is worth emitting at all.
  val usesLyricCount: List[Bool] = newList()
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
    configFieldTypes,
    opaqueTypes,
    closureAcc,
    usesLyricCount,
    importsStdString,
    aliasTargets
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
        validateImplTargetIsInterfaceJvm(decl, pkgName, externTypes, autoFfi)
        val targetClass = typeExprToJvmClass(decl.target, pkgName)
        val ifaceClass = constraintRefToJvmClass(decl.iface, pkgName, externTypes)
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
                  configFieldTypes,
                  opaqueTypes,
                  closureAcc,
                  usesLyricCount,
                  importsStdString
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
            configFieldTypes,
            opaqueTypes,
            closureAcc,
            usesLyricCount,
            importsStdString
          )
          val genParams: List[LGenParam] = newList()
          var pi = 0
          while pi < decl.params.count {
            val p = decl.params[pi]
            genParams.add(LGenParam(paramName = p.name, paramType = typeExprToJvmExtern(p.ty, pkgName, externTypes)))
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
          fns.add(makeGeneratorFactory(decl, genClass, pkgName, externTypes))
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
              configFieldTypes,
              opaqueTypes,
              closureAcc,
              usesLyricCount,
              importsStdString,
              aliasTargets
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
          configFieldTypes,
          opaqueTypes,
          closureAcc,
          usesLyricCount,
          importsStdString,
          aliasTargets,
          unsafeFieldLockNames
        )
        val mergedMethods: List[LFunc] = newList()
        for fn in baseRec.methods.toArray() {
          mergedMethods.add(fn)
        }
        for fn in implFuncs.toArray() {
          mergedMethods.add(fn)
        }
        appendDeriveOverridesJvm(mergedMethods, baseRec.className, baseRec.fields, item.annotations)
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
          configFieldTypes,
          opaqueTypes,
          closureAcc,
          usesLyricCount,
          importsStdString,
          aliasTargets,
          unsafeFieldLockNames
        )
        val mergedMethods: List[LFunc] = newList()
        for fn in baseRec.methods.toArray() {
          mergedMethods.add(fn)
        }
        for fn in implFuncs.toArray() {
          mergedMethods.add(fn)
        }
        appendDeriveOverridesJvm(mergedMethods, baseRec.className, baseRec.fields, item.annotations)
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
        items.add(LPSealedUnion(su = lowerUnion(decl, pkgName, externTypes, aliasTargets)))
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
        items.add(
          LPDistinctType(
            dt = mkJvmDistinctTypeIR(
              pkgName + "/" + decl.name,
              inner,
              decl.rangeClause,
              isUnsignedNumericBaseType(decl.underlying)
            )
          )
        )
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
                // Extern-alias + generic-erasure aware so the emitted field /
                // `$<name>()` accessor descriptor names the real JVM class
                // (matches the `collectFileCasesExtern` opaque arm).
                case OMField(f) -> oFields.add(
                  LOpaqueField(
                    name = f.name,
                    fieldType = typeExprToJvmErasedExtern(
                      f.ty,
                      pkgName,
                      genericParamNames(decl.generics),
                      externTypes
                    )
                  )
                )
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
            configFieldTypes,
            opaqueTypes,
            closureAcc,
            usesLyricCount,
            importsStdString
          )
        )
      }
      case IInterface(decl) -> {
        // Emit a JVM interface ClassFile: one abstract method per IMSig member.
        val ifClassName = pkgName + "/" + decl.name
        val abstractMethods: List[MethodInfo] = newList()
        val concreteFuncs: List[LFunc] = newList()
        val emptyAttrs: List[Attribute] = newList()
        // The interface's own generic params must erase here exactly as they
        // do in registerIfaceSig, or the emitted abstract descriptor and the
        // registered call-site descriptor diverge (#5534).
        val ifaceEmitTps = genericParamNames(decl.generics)
        var imi = 0
        while imi < decl.members.count {
          match decl.members[imi] {
            case IMSig(sig) -> {
              // Strip an explicit `self: in Self` receiver exactly as
              // `registerIfaceSig` does — the emitted abstract descriptor
              // and the registered call-site descriptor must stay in
              // lockstep (#5607, same invariant as #5534).
              val sigRealParams = stripLeadingSelfParam(sig.params)
              val params = holderAwareParamTypes(sigRealParams, pkgName, true, ifaceEmitTps, externTypes)
              val ret = match sig.ret { case Some(te) -> typeExprToJvmExtern(te, pkgName, externTypes); case None -> JVoid }
              val desc = buildDescriptor(params, ret)
              abstractMethods.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, sig.name, desc, emptyAttrs))
            }
            case IMFunc(fn) -> {
              // #3604: an interface default method (a body-bearing `IMFunc`,
              // as opposed to the abstract `IMSig` case above) must be emitted
              // as a true non-static instance method (slot 0 = `this`, flags
              // 0x0001) via `lowerImplMethod` — exactly as an `impl` method is
              // — because `registerIfaceSig` registers it under
              // `<ifClass>#<method>` with `isIface = true`, so every call site
              // dispatches via `invokeinterface` (#3687).  `invokeinterface`
              // requires the target to be a non-static instance method;
              // `lowerFunc` (the static/free-function codegen path, flags
              // 0x0009, `setupStaticParamSlotsAndHolders` with slot 0 = the
              // first parameter) produced a static method here, so any call
              // through the interface-typed dispatch path threw
              // `IncompatibleClassChangeError` at class load — most visibly
              // for `out`/`inout` params (`setupInstanceParamSlotsAndHolders`
              // vs `setupStaticParamSlotsAndHolders` differ in slot 0
              // semantics), but the static/instance mismatch itself is
              // unconditional. `lowerImplMethod` also strips a leading
              // explicit `self: in Self` receiver — the same
              // `stripLeadingSelfParam` discipline `registerIfaceSig` already
              // applies (#5607) — so the emitted descriptor stays in lockstep
              // with the registered call-site descriptor.
              concreteFuncs.add(
                lowerImplMethod(
                  ifClassName,
                  fn,
                  pkgName,
                  funcSigs,
                  caseFields,
                  ctors,
                  externTypes,
                  autoFfi,
                  moduleVals,
                  configFieldTypes,
                  opaqueTypes,
                  closureAcc,
                  usesLyricCount,
                  importsStdString
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
              configFieldTypes,
              opaqueTypes,
              closureAcc,
              usesLyricCount,
              importsStdString
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
      case IConfig(decl) -> {
        // #3228: `config { … }` block (D046 / docs/25-config-blocks.md) — JVM
        // parity with the MSIL `.cctor` static-field path
        // (`Msil.Codegen`/`Msil.Lowering.lowerMConfig`).  Emits a static-field
        // holder class (`ACC_PUBLIC + ACC_SUPER`; the MSIL side additionally
        // marks its twin `sealed`, immaterial here since the class is never
        // instantiated or subclassed — access is purely via `getstatic`)
        // named `<pkgName>/<BlockName>` with one `public static final` field
        // per config field, populated by a synthesised `<clinit>` that reads
        // each field's env var and falls back to the declared default (or
        // aborts with exit code 78 for a required field).  Empty blocks emit
        // nothing, matching `Msil.Codegen`'s guard.  Field types are the
        // same map `collectFileConfigFieldTypes` seeded into
        // `configFieldTypes` above, so a qualified read anywhere in the
        // package sees the exact same JVM type as the field this emits.
        if decl.fields.count > 0 {
          val cfgFields: List[LConfigField] = newList()
          var cfi = 0
          while cfi < decl.fields.count {
            val cf = decl.fields[cfi]
            val fTy = typeExprToJvm(cf.ty, pkgName)
            val envVarName = deriveConfigEnvVarNameJvm(pkgName, decl.name, cf.name)
            val hasDefault = match cf.default { case Some(_) -> true; case None -> false }
            val defaultInsnsList: List[LInsn] = newList()
            if hasDefault {
              match cf.default {
                case Some(defExpr) -> {
                  val lowered = match defExpr.kind {
                    case ELiteral(lit) -> emitConfigDefaultLiteralJvm(fTy, lit, false, defaultInsnsList)
                    case EPrefix(op, inner) -> match op {
                      case PreNeg -> match inner.kind {
                        case ELiteral(lit2) -> emitConfigDefaultLiteralJvm(
                          fTy,
                          lit2,
                          true,
                          defaultInsnsList
                        )
                        case _ -> false
                      }
                      case _ -> false
                    }
                    case _ -> false
                  }
                  if not lowered {
                    // A silent fall-through here leaves the field at its
                    // zero-initialised value regardless of the declared
                    // default; the front-end's G0010 guard rejects these
                    // shapes before codegen (mirrors the MSIL ICE panic).
                    panic(
                      "Jvm.Codegen ICE: config default for '" + decl.name + "." + cf.name +
                        "' is not a literal of the declared type — the type checker (G0010) should have rejected this"
                    )
                  }
                }
                case None -> ()
              }
            }
            val requiredMsg = if hasDefault {
              ""
            } else {
              "error: required config field " + decl.name + "." + cf.name + " (env var " + envVarName + ") is not set"
            }
            cfgFields.add(
              LConfigField(
                name = cf.name,
                fieldType = fTy,
                envVarName = envVarName,
                hasDefault = hasDefault,
                defaultInsns = defaultInsnsList,
                requiredErrMsg = requiredMsg
              )
            )
            cfi = cfi + 1
          }
          items.add(LPConfig(ns = pkgName, blockName = decl.name, fields = cfgFields))
        }
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
      case JLong -> panic(
        "Jvm.Codegen: `func main(): Long` is not supported on the JVM target — wrap the result in `Int` or `Unit`"
      )
      case JDouble -> panic(
        "Jvm.Codegen: `func main(): Double` is not supported on the JVM target — wrap the result in `Int` or `Unit`"
      )
      case _ -> ()
    }
    val jvmMainParams: List[JvmType] = newList()
    jvmMainParams.add(JArray(elem = JRef(className = "java/lang/String")))
    val jvmMainInsns: List[LInsn] = newList()
    val lyricMainPs: List[JvmType] = newList()
    // #5377: stash the incoming argv into the package-independent holder
    // class BEFORE any other program code runs, regardless of whether the
    // Lyric `main` itself declares an `argv` parameter — `Std.Environment
    // .args()` must observe the real argv even when `main()` takes none.
    // See `LPRuntimeArgsHolder`'s doc in `Jvm.Lowering` and the matching
    // `getstatic` read in `lowerBuiltinOrStaticCall` (`04_calls.l`).
    jvmMainInsns.add(LAload(slot = 0))
    jvmMainInsns.add(
      LPutstatic(
        owner = "__LyricJvmRuntime",
        name = "commandLineArgs",
        t = JArray(elem = JRef(className = "java/lang/String"))
      )
    )
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
    // #5377: exactly one entry point exists per runnable JVM bundle (this
    // `hasMain` branch), so the holder class is emitted exactly once too —
    // no cross-package duplicate-class risk.
    items.add(LPRuntimeArgsHolder(className = "__LyricJvmRuntime", fieldName = "commandLineArgs"))
  }

  // `__lyricCount(Object)I` — the erased-receiver `.count`/`.length`
  // dispatch as a synthesised static helper.  Emitting the runtime-class
  // branches INLINE at the member-access site broke verification whenever
  // the access ran with values already stacked (`i < pairs.count` in a
  // while condition evaluates the dispatch with `i` on the stack, and the
  // StackMapTable declares an empty stack at every branch target).  A
  // static call is branch-free at the call site; the helper's own frames
  // start from an empty stack.  Every arm returns directly, so there is
  // no join.  Lazily emitted (#4803): `usesLyricCount` is only non-empty
  // when some function in this package actually emitted a call to it
  // (`02_exprs.l`'s erased-receiver `.count`/`.length` dispatch), so a
  // package that never exercises that path carries no dead ~40-byte helper.
  if usesLyricCount.count > 0 {
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
  }

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

  // Structured concurrency (D119 S4 / D120): emit the `__lyric_await` helper on
  // the host class whenever this package synthesized any closure.  A `Future`
  // (what `await` joins via the helper) can only originate from a `spawn` inside
  // a `scope { }`, which always appends a `Callable` closure to `closureAcc` —
  // so a non-empty accumulator is a sound (never-missing) signal that the helper
  // may be needed.  A package with only lambdas emits an unused helper (six
  // instructions over always-present JDK types); harmless.
  if closureAcc.count > 0 {
    fns.add(makeAwaitHelperFunc())
  }

  items.add(LPFuncs(funcsClass = funcsClass, fns = fns, staticVals = staticVals))

  // J2b closures (#2665): drain the accumulated lambda closures into package
  // items, and — if any lambda was emitted, OR this package's own signatures
  // call through a function type it never itself instantiates (#6113,
  // `fileNeedsLambdaIface`) — add the one shared functional interface
  // `<pkg>/Lyric$Lambda` they all implement
  // (`invoke([Ljava/lang/Object;)Ljava/lang/Object;`).
  if closureAcc.count > 0 or fileNeedsLambdaIface(file) {
    val ifaceName = lambdaIfaceName()
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
