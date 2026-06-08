//! jvm/codegen_6_items.l — Jvm.Codegen: function/record/union lowering and package entry.
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
  closureCounter: in List[Int],
): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, JvmType] = newMap()
  val slotTicker: List[Int] = newList()
  val labelTicker: List[Int] = newList()
  val loopBreak: List[String] = newList()
  val loopCont: List[String] = newList()
  val deferStack: List[Block] = newList()
  val loopDeferDepth: List[Int] = newList()
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
    selfClass = None,
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    closureCounter = closureCounter
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
  closureCounter: in List[Int],
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
    selfClass = None,
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    closureCounter = closureCounter
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
  closureCounter: in List[Int],
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
    selfClass = Some(value = className),
    moduleVals = moduleVals,
    opaqueTypes = opaqueTypes,
    closureAcc = closureAcc,
    closureCounter = closureCounter
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
    case JArray(fe) -> match fe { case JByte -> match toTy { case JArray(te) -> match te { case JRef(_) -> true; case _ -> false }; case _ -> false }; case _ -> false }
    case _ -> false
  }
}

// Replace a primitive `byte[]` on top of the operand stack with a freshly
// built `java.lang.Object[]` of boxed `java.lang.Byte` (the erased Lyric
// `slice[Byte]` representation).  The inverse of `emitFfiCoerce`'s
// `[Ljava/lang/Object; -> [B` arg coercion.  Generated bytecode mirrors the
// element-copy loop documented there.
func emitBoxByteArray(ctx: in FuncCtx, insns: in List[LInsn]): Unit {
  val srcSlot = allocSlot(ctx, "__box_arr_src_" + toString(ctx.slotTicker.count), JArray(elem = JByte))
  val dstSlot = allocSlot(
    ctx,
    "__box_arr_dst_" + toString(ctx.slotTicker.count),
    JArray(elem = JRef(className = "java/lang/Object"))
  )
  val idxSlot = allocSlot(ctx, "__box_arr_idx_" + toString(ctx.slotTicker.count), JInt)
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
  insns.add(LIconst(v = 0))
  insns.add(LIstore(slot = idxSlot))
  insns.add(LLabel(name = loopL))
  insns.add(LIload(slot = idxSlot))
  insns.add(LAload(slot = srcSlot))
  insns.add(LArraylength)
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
  closureCounter: in List[Int],
): LFunc {
  val retTy = match decl.ret { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }

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
    closureAcc,
    closureCounter
  )
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
              if not endsWithReturn(insns) {
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
          if retTy == JVoid and not endsWithReturn(insns) {
            emitReturn(insns, retTy)
          }
        }
        case FBExpr(e) -> {
          val ty = lowerExpr(ctx, insns, e)
          emitReturnArrayCoerced(ctx, insns, ty, retTy)
        }
      }
    }
    case None -> {
      match findExternTarget(decl) {
        case Some(target) -> {
          lowerExternTargetBody(decl, ctx, insns, target);
          ()
        }
        case None -> emitReturn(insns, retTy)
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
    flags = 0x0009,
    // public static
    name = decl.name,
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
            fieldType = typeExprToJvmErased(f.ty, pkgName, tps)
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

  // Lower any RMFunc members.  Lambdas inside a record method are outside the
  // J2b closure slice (#2665) — a throwaway accumulator keeps `lowerFunc` total;
  // an `ELambda` here still panics in codegen (unchanged from pre-J2b).
  val recClosureAcc: List[LClosure] = newList()
  val recClosureCounter: List[Int] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case RMFunc(fn) -> {
        methods.add(
          lowerFunc(
            fn,
            pkgName,
            className,
            funcSigs,
            caseFields,
            ctors,
            externTypes,
            autoFfi,
            moduleVals,
            opaqueTypes,
            recClosureAcc,
            recClosureCounter
          )
        )
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
pub func lowerUnion(decl: in UnionDecl, pkgName: in String): LSealedUnion {
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
          caseFields.add(LField(flags = 0x0001, name = name, fieldType = typeExprToJvmErased(ty, pkgName, tps)))
        }
        case UFPos(ty, _) -> {
          caseFields.add(
            LField(flags = 0x0001, name = "field" + toString(fi), fieldType = typeExprToJvmErased(ty, pkgName, tps))
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
): LFunc {
  val retTy = match retOpt { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }
  // Lambdas inside a protected-type entry/helper are not part of the J2b
  // closure slice (#2665): the shared package accumulator is threaded only
  // through the top-level `func` / `impl` / `interface` paths.  A throwaway
  // accumulator keeps `makeFuncCtxInstance` total here; an `ELambda` in this
  // position still panics in codegen (unchanged from pre-J2b).
  val protClosureAcc: List[LClosure] = newList()
  val protClosureCounter: List[Int] = newList()
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
    protClosureAcc,
    protClosureCounter
  )
  val insns: List[LInsn] = newList()
  val paramTypes: List[JvmType] = newList()
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    val paramTy = typeExprToJvm(p.ty, pkgName)
    allocSlot(ctxSelf, p.name, paramTy)
    paramTypes.add(paramTy)
    pi = pi + 1
  }
  match body {
    case FBBlock(block) -> {
      match retTy {
        case JVoid -> {
          lowerBlock(ctxSelf, insns, block)
          if not endsWithReturn(insns) {
            emitReturn(insns, JVoid)
          }
        }
        case _ -> {
          val tailTy = lowerBlockExpr(ctxSelf, insns, block)
          if not endsWithReturn(insns) {
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
      val ty = lowerExpr(ctxSelf, insns, e)
      coerceArgTo(insns, ty, retTy)
      emitReturn(insns, retTy)
    }
  }
  LFunc(flags = flags, name = name, params = paramTypes, ret = retTy, insns = insns, maxStack = 0, maxLocals = 0)
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
): LPackageItem {
  val className = pkgName + "/" + decl.name
  val fields: List[LField] = newList()
  val methods: List[LFunc] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _) -> fields.add(LField(flags = 0x0001, name = name, fieldType = typeExprToJvm(ty, pkgName)))
          case PFLet(name, ty, _, _) -> fields.add(LField(flags = 0x0001, name = name, fieldType = typeExprToJvm(ty, pkgName)))
          case PFImmutable(f) -> fields.add(LField(flags = 0x0001, name = f.name, fieldType = typeExprToJvm(f.ty, pkgName)))
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
            opaqueTypes
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
                opaqueTypes
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

// Build a wire-block DI factory class.  Each `singleton` / `local` binding's
// initialiser is lowered to instructions that push the constructed value (no
// return); `lowerWire` emits a private static field per binding, a `bootstrap()`
// that runs every binding initialiser then `putstatic`s it, and a public static
// accessor for each `expose`d binding.  A binding initialiser may reference an
// earlier binding by name — the shared `wireCtx` resolves such a reference to a
// `getstatic` on the wire class so the dependency graph wires up in order.
// Mirrors the MSIL `lowerWireMsil` member subset (singleton / local / expose).
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
): LWire {
  val className = pkgName + "/" + decl.name
  val bindings: List[LWireBinding] = newList()
  val exposes: List[String] = newList()
  // Track binding name → static-field type so a later binding referencing an
  // earlier one resolves to `getstatic <wire>.<name>`.
  val bindingTypes: Map[String, JvmType] = newMap()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
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
          initInsns,
          init,
          bty
        )
        bindings.add(LWireBinding(name = name, valType = bty, insns = initInsns))
        if not bindingTypes.containsKey(name) {
          bindingTypes.add(name, bty)
        }
      }
      case WMExpose(name, _) -> exposes.add(name)
      case _ -> ()
    }
    mi = mi + 1
  }
  LWire(className = className, bindings = bindings, exposes = exposes)
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
    // Wire-binding initialisers are outside the J2b closure slice (#2665) — a
    // throwaway accumulator keeps `makeFuncCtx` total.
    val wireClosureAcc: List[LClosure] = newList()
    val wireClosureCounter: List[Int] = newList()
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
      wireClosureAcc,
      wireClosureCounter
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
// name="main" with no parameters (Lyric convention).
func isMainFunc(decl: in FunctionDecl): Bool {
  decl.name == "main" and decl.params.count == 0
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
  closureCounter: in List[Int],
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
    closureAcc,
    closureCounter
  )

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

// Collect every top-level `func` item's JVM call signature from `file` into
// `into` (keyed by bare function name; first declaration of a given name
// wins).  Owner is the file's package host class.  Used to build the
// cross-package call registry so any package's call sites can resolve a
// callee's owner + descriptor.  See JvmFuncSig.
pub func collectFileSigs(file: in SourceFile, into: in Map[String, JvmFuncSig]): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        val params: List[JvmType] = newList()
        var pi = 0
        while pi < decl.params.count {
          params.add(typeExprToJvm(decl.params[pi].ty, owner))
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
            case Some(te) -> typeExprToJvm(te, owner)
            case None -> JVoid
          }
        }
        val sig = JvmFuncSig(owner = owner, params = params, ret = ret)
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
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              registerInstanceSig(into, recClass, fn.name, fn.params, fn.ret, owner)
            }
            case _ -> ()
          }
          mi = mi + 1
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
  val ps: List[JvmType] = newList()
  var pi = 0
  while pi < params.count {
    ps.add(typeExprToJvm(params[pi].ty, owner))
    pi = pi + 1
  }
  val ret = match retOpt { case Some(te) -> typeExprToJvm(te, owner); case None -> JVoid }
  val key = className + "#" + methodName
  if not into.containsKey(key) {
    into.add(key, JvmFuncSig(owner = className, params = ps, ret = ret))
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
    into.add(key, JvmFuncSig(owner = wireClass, params = params, ret = ret))
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
                case UFNamed(name, ty, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvmErased(ty, owner, tps)))
                case UFPos(ty, _) -> flds.add(JvmCaseField(name = "field" + toString(fi), ty = typeExprToJvmErased(ty, owner, tps)))
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
              case RMField(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvmErased(f.ty, owner, tps)))
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
                  case PFVar(name, ty, _, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvm(ty, owner)))
                  case PFLet(name, ty, _, _) -> flds.add(JvmCaseField(name = name, ty = typeExprToJvm(ty, owner)))
                  case PFImmutable(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvm(f.ty, owner)))
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
                case OMField(f) -> flds.add(JvmCaseField(name = f.name, ty = typeExprToJvm(f.ty, owner)))
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
pub func collectFileCtors(file: in SourceFile, into: in Map[String, String]): Unit {
  val owner = segmentsToJvmPath(file.packageDecl.path.segments)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        if not into.containsKey(decl.name) {
          into.add(decl.name, owner + "/" + decl.name)
        }
      }
      case IUnion(decl) -> {
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          if not into.containsKey(c.name) {
            into.add(c.name, owner + "/" + decl.name + "$" + c.name)
          }
          ci = ci + 1
        }
      }
      case IProtected(decl) -> {
        // J3 M-3: protected types are constructed like records (`TokenBucket(…)`).
        if not into.containsKey(decl.name) {
          into.add(decl.name, owner + "/" + decl.name)
        }
      }
      case IOpaque(decl) -> {
        // J3 M-3: opaque types are constructed like records (`Counter(value=…)`).
        if decl.hasBody {
          if not into.containsKey(decl.name) {
            into.add(decl.name, owner + "/" + decl.name)
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Collect every module-level `val NAME [: T] = expr` binding from `file` into
// `into`, keyed by `NAME` with its JVM field type.  Drives bare-name reads of
// module-level vals (lowered to `getstatic <hostClass>.<name>`).  Only the
// simple `PBinding` form participates; destructuring module-level vals emit no
// host field and so are not registered (m-2).
pub func collectFileVals(file: in SourceFile, owner: in String, into: in Map[String, JvmType]): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(name, _) -> {
            if not into.containsKey(name) {
              val vty = match decl.ty { case Some(te) -> typeExprToJvm(te, owner); case None -> inferValType(decl.init, owner) }
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
        case LFloat(_, _, _) -> JDouble
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
            val fieldTy = match decl.ty { case Some(te) -> typeExprToJvm(te, pkgName); case None -> valTy }
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
  val autoFfi = buildAutoFfiCtx()
  codegenPackageWithSigs(file, sigs, cases, ctors, autoFfi)
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
): LPackage {
  val pkgName = segmentsToJvmPath(file.packageDecl.path.segments)
  val funcsClass = pkgName

  // Collect extern-type declarations: alias → Java FQN.
  val externTypes: Map[String, String] = newMap()
  var eti = 0
  while eti < file.items.count {
    match file.items[eti].kind {
      case IExternType(decl) -> {
        if not externTypes.containsKey(decl.name) {
          externTypes.add(decl.name, decl.clrName)
        }
      }
      case _ -> {
      }
    }
    eti = eti + 1
  }

  // m-2: collect the module-level `val NAME` declarations up front (name → JVM
  // type) so a bare reference to one resolves to `getstatic <hostClass>.<name>`
  // in every function of this package.
  val moduleVals: Map[String, JvmType] = newMap()
  collectFileVals(file, pkgName, moduleVals)
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
  // J2b closures (#2665): the package-shared closure accumulator + name counter,
  // threaded through every top-level `func` / module-`val` / `impl` / `interface`
  // FuncCtx so that an `ELambda` anywhere on those paths registers its synthesised
  // inner class here.  Drained into `LPClosureClass` items after the item loop.
  val closureAcc: List[LClosure] = newList()
  val closureCounter: List[Int] = newList()
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
    closureAcc,
    closureCounter
  )
  // #2853: lower every module-level `val` once, now, and overwrite `moduleVals`
  // with the real field type before any function (or the `<clinit>` itself) is
  // lowered — so a bare reference's `getstatic` descriptor matches the emitted
  // field.  The IVal item loop below reuses these cached insns / types.
  val loweredVals = prelowerModuleVals(file, pkgName, valInitCtx, moduleVals)
  var hasMain = false
  // Captured return type of the Lyric `main(): T` so the JVM wrapper can
  // emit a correctly-typed invokestatic.  `JVoid` until / unless a main is
  // observed.  When the Lyric main returns `Int`, the wrapper pops the int
  // off the stack (POSIX-style exit code semantics are not propagated yet —
  // a follow-up can route through `java.lang.System.exit(int)`).
  var mainRet: JvmType = JVoid

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
            case IMplFunc(fn) -> implFuncs.add(lowerFunc(fn, pkgName, targetClass, funcSigs, caseFields, ctors, externTypes, autoFfi, moduleVals, opaqueTypes, closureAcc, closureCounter))
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
            closureAcc,
            closureCounter
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
              closureAcc,
              closureCounter
            )
          )
          if isMainFunc(decl) {
            hasMain = true
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
        val baseRec = lowerRecord(decl, pkgName, funcSigs, caseFields, ctors, externTypes, autoFfi, moduleVals, opaqueTypes)
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
        val baseRec = lowerRecord(decl, pkgName, funcSigs, caseFields, ctors, externTypes, autoFfi, moduleVals, opaqueTypes)
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
        items.add(LPSealedUnion(su = lowerUnion(decl, pkgName)))
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
        if decl.hasBody {
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
      case IProtected(decl) -> {
        // J3 M-3: emit a record-shaped class via `buildProtected` (an
        // `LPRecord`).  Field members become private data fields; each `entry`
        // / helper `func` becomes an instance method whose bare field
        // references resolve through `selfClass` (slot 0 = `this`).  Real
        // ReentrantLock guarding is a documented cross-target gap — MSIL also
        // emits protected types as plain records.
        items.add(buildProtected(decl, pkgName, funcSigs, caseFields, ctors, externTypes, autoFfi, moduleVals, opaqueTypes))
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
              val params: List[JvmType] = newList()
              var spi = 0
              while spi < sig.params.count {
                params.add(typeExprToJvm(sig.params[spi].ty, pkgName))
                spi = spi + 1
              }
              val ret = match sig.ret { case Some(te) -> typeExprToJvm(te, pkgName); case None -> JVoid }
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
                  closureAcc,
                  closureCounter
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
          LPWire(w = buildWire(decl, pkgName, funcSigs, caseFields, ctors, externTypes, autoFfi, moduleVals, opaqueTypes))
        )
      }
      case IScopeKind(_) -> {
      }
      case IExtern(_) -> {
      }
      case IExternType(_) -> {
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
    // Currently emits main():()V regardless of Lyric main's return type.
    // Long/Double return would require POP2; Int/Bool etc. would require POP.
    // Tracked as a follow-up once the JVM wrapper records the Lyric main return type.
    jvmMainInsns.add(LInvokestatic(owner = funcsClass, name = "main", params = lyricMainPs, ret = mainRet))
    // Discard the Lyric main's return value (when any) before issuing the
    // JVM `void` return.  The Long/Double 2-slot cases are rejected above,
    // so every remaining non-void return is category-1 (Int, Boolean,
    // references, etc.) — a single `LPop` is correct.  Exposing the value
    // as a process exit code is a follow-up via java.lang.System.exit.
    match mainRet {
      case JVoid -> ()
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
