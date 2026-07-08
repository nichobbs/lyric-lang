//! jvm/codegen/04_calls.l — Jvm.Codegen: call lowering.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! Std.Jvm.catch intrinsic, @externTarget call-site lowering, builtin/general/
//! method/construction calls, and auto-FFI resolution.
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

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
  val tryStartL = freshLabel(ctx)
  val tryEndL = freshLabel(ctx)
  val catchStartL = freshLabel(ctx)
  val afterL = freshLabel(ctx)

  val resultSlot = allocSlot(ctx, "__catch_result_" + freshLabel(ctx), JRef(className = "java/lang/Object"))
  val exSlot = allocSlot(ctx, "__catch_ex_" + freshLabel(ctx), JRef(className = "java/lang/Object"))

  // Class names for Result cases as compiled from Std.Core
  // (pkgName="Std/Core", union="Result", cases "Ok" and "Err").
  val okClass = "Std/Core/Result$Ok"
  val errClass = "Std/Core/Result$Err"

  // ── try body ────────────────────────────────────────────────────────────────
  insns.add(LLabel(name = tryStartL))
  val bodyTy = lowerBlockExpr(ctx, insns, lambdaBody)
  match bodyTy {
    case JVoid -> insns.add(LAconstNull)  // Unit result: represent as null
    case _ -> boxIfNeeded(insns, bodyTy)
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
  insns.add(LInvokespecial(owner = errClass, name = "<init>", params = errPs, ret = JVoid))
  insns.add(LGoto(label = afterL))

  // ── exception table entry ────────────────────────────────────────────────────
  insns.add(
    LTryCatch(
      startLabel = tryStartL,
      endLabel = tryEndL,
      handlerLabel = catchStartL,
      catchClass = "java/lang/Exception"
    )
  )

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
              case _ -> {
              }
            }
          }
          case _ -> {
          }
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
          } else {
            false
          }
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
      } else {
        false
      }
    }
  }
}

// Emit the body of a body-less function that has `@externTarget("java.Class.method")`.
// Loads all params, emits invokestatic or invokevirtual, and wraps the result in
// Result$Ok / Result$Err when the declared return type is Result[T, JvmException].
func lowerExternTargetBody(decl: in FunctionDecl, ctx: in FuncCtx, insns: in List[LInsn], target: in String): JvmType {
  match lastIndexOf(target, ".") {
    case None -> {
      emitReturn(insns, JVoid)
      JVoid
    }
    case Some(dotIdx) -> {
      val javaClass = replace(substring(target, 0, dotIdx), ".", "/")
      val methodName = substring(target, dotIdx + 1, length(target) - dotIdx - 1)

      // Staticness comes from JDK metadata, not the legacy name heuristic
      // (which mis-classified e.g. `currentTimeMillis` — no underscore — as
      // an instance call and emitted `invokevirtual` against an empty stack).
      // If the target class resolves and a static overload matches the full
      // declared parameter list, emit `invokestatic`; if the class resolves
      // but no static overload matches, treat the first parameter as the
      // receiver.  Classes absent from the metadata index keep the name
      // heuristic.
      val allParamDescs: List[String] = newList()
      var apdI = 0
      while apdI < decl.params.count {
        allParamDescs.add(jvmTypeToDescStr(typeExprToJvm(decl.params[apdI].ty, ctx.pkgName)))
        apdI = apdI + 1
      }
      val targetFqnDot = replace(javaClass, "/", ".")
      // A constructor target (`@externTarget("java.util.ArrayList.<init>")`)
      // is `new; dup; <args>; invokespecial <init>; areturn` — neither the
      // static nor the instance method shapes fit it (treating the first
      // parameter as a receiver consumed a real argument; hit by
      // `Std.CollectionsHost.newListWithCapacity`).
      if methodName == "<init>" {
        val ctorParamTys: List[JvmType] = newList()
        var cpI = 0
        while cpI < decl.params.count {
          ctorParamTys.add(typeExprToJvm(decl.params[cpI].ty, ctx.pkgName))
          cpI = cpI + 1
        }
        insns.add(LNew(className = javaClass))
        insns.add(LDup)
        // Parameter slots: long/double occupy two local slots.
        var cpSlot = 0
        var cpJ = 0
        while cpJ < decl.params.count {
          emitLoad(insns, cpSlot, ctorParamTys[cpJ])
          val w = match ctorParamTys[cpJ] { case JLong -> 2; case JDouble -> 2; case _ -> 1 }
          cpSlot = cpSlot + w
          cpJ = cpJ + 1
        }
        insns.add(LInvokespecial(owner = javaClass, name = "<init>", params = ctorParamTys, ret = JVoid))
        val ctorRet = JRef(className = javaClass)
        emitReturn(insns, ctorRet)
        return ctorRet
      }
      // A zero-parameter @externTarget whose member resolves to a public
      // STATIC FIELD (e.g. `java.time.Duration.ZERO`, `java.lang.System.in`)
      // is a constant read: emit `getstatic` with the field's descriptor and
      // return.  Checked before method resolution so a field target never
      // falls into the instance-call guess.
      if decl.params.count == 0 {
        match loadClass(ctx.autoFfi, targetFqnDot) {
          case Some(fci) -> {
            match findStaticField(ctx.autoFfi, fci, methodName) {
              case Some(fld) -> {
                val fldTy = descStrToJvmType(fld.descriptor)
                insns.add(LGetstatic(owner = javaClass, name = methodName, t = fldTy))
                emitReturn(insns, fldTy)
                return fldTy
              }
              case None -> ()
            }
          }
          case None -> ()
        }
      }
      val isStatic = match loadClass(ctx.autoFfi, targetFqnDot) {
        case Some(ci) -> {
          match findBestMethod(ctx.autoFfi, ci, methodName, allParamDescs, true) {
            case Some(_) -> true
            case None -> false
          }
        }
        case None -> isStaticExternByName(decl.name)
      }
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
        case Some(te) -> if wrapResult { extractResultValueType(te, ctx.pkgName) } else { typeExprToJvmExtern(te, ctx.pkgName, ctx.externTypes) }
      }

      // F0015-J: verify the declared @externTarget signature against JDK class
      // metadata.  Returns true when the class is not found (non-JDK types
      // like Lyric.Jvm.Hosts.* pass through with no false positive) or when a
      // matching overload exists.  Fires a build-time panic only when the class
      // IS found in the metadata index but no overload matches the declared
      // descriptor — catching typos and signature drift before codegen.
      val f5ArgDescs: List[String] = newList()
      var f5ai = 0
      while f5ai < javaArgTypes.count {
        f5ArgDescs.add(jvmTypeToDescStr(javaArgTypes[f5ai]))
        f5ai = f5ai + 1
      }
      val javaFqnDot = replace(javaClass, "/", ".")
      if not verifyExternTargetJvm(ctx.autoFfi, javaFqnDot, methodName, f5ArgDescs, isStatic) {
        var f5SigStr = "("
        var f5si = 0
        while f5si < javaArgTypes.count {
          if f5si > 0 {
            f5SigStr = f5SigStr + ", "
          }
          f5SigStr = f5SigStr + jvmTypeToDescStr(javaArgTypes[f5si])
          f5si = f5si + 1
        }
        f5SigStr = f5SigStr + ") -> " + jvmTypeToDescStr(javaRet)
        panic(
          "F0015-J: @externTarget '" + target + "' on '" + decl.name + "': " + "declared signature " + f5SigStr +
            " does not match any overload of '" +
            javaFqnDot +
            "." +
            methodName +
            "' in JDK class metadata. " +
            "Verify the Lyric parameter/return types match the Java method."
        )
      }

      // Load all params in order: receiver first for instance calls.
      var li = 0
      while li < decl.params.count {
        val p = decl.params[li]
        val paramTy = typeExprToJvm(p.ty, ctx.pkgName)
        match lookupSlot(ctx, p.name) {
          case Some(s) -> emitLoad(insns, s, paramTy)
          case None -> insns.add(LAconstNull)
        }
        li = li + 1
      }

      if wrapResult {
        val okClass = "Std/Core/Result$Ok"
        val errClass = "Std/Core/Result$Err"
        val tryStartL = freshLabel(ctx)
        val tryEndL = freshLabel(ctx)
        val catchStartL = freshLabel(ctx)
        val afterL = freshLabel(ctx)
        val resultSlot = allocSlot(ctx, "__ext_result", JRef(className = "java/lang/Object"))
        val exSlot = allocSlot(ctx, "__ext_ex", JRef(className = "java/lang/Object"))

        insns.add(LLabel(name = tryStartL))
        if isStatic {
          insns.add(LInvokestatic(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        } else {
          insns.add(LInvokevirtual(owner = javaClass, name = methodName, params = javaArgTypes, ret = javaRet))
        }
        match javaRet {
          case JVoid -> insns.add(LAconstNull)
          case _ -> boxIfNeeded(insns, javaRet)
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

        insns.add(
          LTryCatch(
            startLabel = tryStartL,
            endLabel = tryEndL,
            handlerLabel = catchStartL,
            catchClass = "java/lang/Exception"
          )
        )
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
func lowerCall(ctx: in FuncCtx, insns: in List[LInsn], fn: in Expr, args: in List[CallArg]): JvmType {
  // Resolve the function name from the callee expression.
  match fn.kind {
    case EPath(path) -> {
      val funcName = lastSegment(path)
      // Structured concurrency (D119 S4 / D120): the compiler-synthesized close
      // intrinsic emitted by `scope { }` lowering.  Its single argument is the
      // executor local; emit `ExecutorService.close()` on it (blocks until every
      // submitted task terminates).  Intercepted before name resolution because
      // no real function of this reserved `__lyric_`-prefixed name exists.
      if path.segments.count == 1 and funcName == jvmCloseExecutorIntrinsic() {
        lowerCloseExecutorIntrinsic(ctx, insns, args)
      } else if path.segments.count == 1 and isLambdaLocal(ctx, funcName) {
        lowerLambdaInvoke(ctx, insns, funcName, args)
      } else {
        lowerBuiltinOrStaticCall(ctx, insns, funcName, path, args)
      }
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

// Emit `<execLocal>.close()` for the `scope { }` close intrinsic (D119 S4 /
// D120).  The single positional argument is an `EPath` naming the executor
// local; load it and `invokeinterface ExecutorService.close()` (default method,
// JDK 19+), which performs an orderly shutdown and blocks until every submitted
// task terminates.  Returns `JVoid` (the `defer` body discards it).
func lowerCloseExecutorIntrinsic(ctx: in FuncCtx, insns: in List[LInsn], args: in List[CallArg]): JvmType {
  val execTy = JRef(className = "java/util/concurrent/ExecutorService")
  if args.count == 1 {
    val argExpr = match args[0] { case CAPositional(e) -> e; case CANamed(_, e, _) -> e }
    match argExpr.kind {
      case EPath(p) -> {
        val nm = lastSegment(p)
        match lookupSlot(ctx, nm) {
          case Some(s) -> {
            emitLoad(insns, s, execTy)
            insns.add(
              LInvokeinterface(
                owner = "java/util/concurrent/ExecutorService",
                name = "close",
                params = newList(),
                ret = JVoid,
                argCount = 1
              )
            )
          }
          case None -> panic("Jvm.Codegen: scope close intrinsic references unknown executor local '" + nm + "' (unreachable)")
        }
      }
      case _ -> panic("Jvm.Codegen: scope close intrinsic argument is not an executor local path (unreachable)")
    }
  }
  JVoid
}

// True when `name` is a local/param slot holding a lambda (closure) value: a
// slot typed as the package's shared `Lyric$Lambda` interface (a `val f =
// (x) -> …` binding) or as the erased `Object` (a higher-order-function
// parameter declared `(…) -> R`, which `typeExprToJvm` maps to `Object`).  A
// matching local shadows any static function of the same name, so a call on it
// must dispatch through the functional interface rather than `invokestatic`.
func isLambdaLocal(ctx: in FuncCtx, name: in String): Bool {
  match lookupSlot(ctx, name) {
    case Some(_) -> {
      val ifaceName = lambdaIfaceName(ctx.pkgName)
      match lookupType(ctx, name) {
        case Some(t) -> match t { case JRef(cls) -> cls == ifaceName or cls == "java/lang/Object"; case _ -> false }
        case None -> false
      }
    }
    case None -> false
  }
}

// JVM operand slots occupied by a parameter list: long/double take two,
// everything else one.  Feeds `invokeinterface`'s count operand (JVMS §6.5:
// receiver slot + argument slots).
func jvmArgSlotCount(params: in List[JvmType]): Int {
  var n = 0
  var i = 0
  while i < params.count {
    val w = match params[i] { case JLong -> 2; case JDouble -> 2; case _ -> 1 }
    n = n + w
    i = i + 1
  }
  n
}

// Invoke a lambda value held in local `name`: load the closure, checkcast to the
// shared functional interface, pack the (boxed) args into an `Object[]`, and
// `invokeinterface invoke([Ljava/lang/Object;)Ljava/lang/Object;`.  The result
// is `Object`; the caller context narrows / unboxes it via the usual paths.
func lowerLambdaInvoke(ctx: in FuncCtx, insns: in List[LInsn], name: in String, args: in List[CallArg]): JvmType {
  val ifaceName = lambdaIfaceName(ctx.pkgName)
  val slot = match lookupSlot(ctx, name) {
    case Some(s) -> s
    case None -> panic("lowerLambdaInvoke: unresolved lambda slot for '" + name + "'")
  }
  // Load the closure reference and ensure its static type is the iface.
  insns.add(LAload(slot = slot))
  insns.add(LCheckcast(className = ifaceName))
  // Build the Object[] of boxed args.
  insns.add(LIconst(v = args.count))
  insns.add(LAnewarray(className = "java/lang/Object"))
  var i = 0
  while i < args.count {
    insns.add(LDup)
    insns.add(LIconst(v = i))
    val aTy = lowerCallArg(ctx, insns, args[i])
    boxIfNeeded(insns, aTy)
    insns.add(LAastore)
    i = i + 1
  }
  val invPs: List[JvmType] = newList()
  invPs.add(JArray(elem = JRef(className = "java/lang/Object")))
  // invokeinterface arg-count = receiver(1) + the Object[](1) = 2.
  insns.add(
    LInvokeinterface(
      owner = ifaceName,
      name = lambdaIfaceMethod(),
      params = invPs,
      ret = JRef(className = "java/lang/Object"),
      argCount = 2
    )
  )
  JRef(className = "java/lang/Object")
}

// Lower a single call argument.
func lowerCallArg(ctx: in FuncCtx, insns: in List[LInsn], arg: in CallArg): JvmType {
  match arg {
    case CAPositional(e) -> lowerExpr(ctx, insns, e)
    case CANamed(_, e, _) -> lowerExpr(ctx, insns, e)
  }
}

// Reorder a function call's arguments to parameter-declaration order and fill
// missing defaulted parameters (#1503).  Uses `sig.paramNames` and
// `sig.paramDefaults` when present.  Returns `args` unchanged when: any arg
// is positional but count equals sig.params.count (already in order), no
// param names are registered, or a required param is missing.
func reorderAndFillJvmArgs(sig: in JvmFuncSig, args: in List[CallArg]): List[CallArg] {
  if args.count == 0 and sig.params.count == 0 {
    return args
  }
  if sig.paramNames.count == 0 {
    return args  // no name info available
  }
  // Check if any arg is named.
  var anyNamed = false
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(_, _, _) -> {
        anyNamed = true
      }
      case CAPositional(_) -> ()
    }
    i = i + 1
  }
  if not anyNamed {
    // Positional call: only append defaults for trailing missing params.
    if args.count >= sig.paramNames.count {
      return args
    }
    val filled: List[CallArg] = newList()
    var j = 0
    while j < args.count {
      filled.add(args[j])
      j = j + 1
    }
    var k = args.count
    while k < sig.paramNames.count {
      match sig.paramDefaults[k] {
        case Some(dflt) -> filled.add(CAPositional(expr = dflt))
        case None -> return args  // required param missing — bail
      }
      k = k + 1
    }
    return filled
  }
  // Named call: build name → arg map, then reassemble in declaration order.
  val byName: Map[String, CallArg] = newMap()
  var ni = 0
  while ni < args.count {
    match args[ni] {
      case CANamed(nm, _, _) -> {
        if not byName.containsKey(nm) {
          byName.add(nm, args[ni])
        }
      }
      case CAPositional(_) -> return args  // mixed call — already in order
    }
    ni = ni + 1
  }
  val ordered: List[CallArg] = newList()
  var pi = 0
  while pi < sig.paramNames.count {
    val pname = sig.paramNames[pi]
    match mapGet(byName, pname) {
      case Some(a) -> ordered.add(a)
      case None -> {
        if pi < sig.paramDefaults.count {
          match sig.paramDefaults[pi] {
            case Some(dflt) -> ordered.add(CAPositional(expr = dflt))
            case None -> return args  // required param missing — bail
          }
        } else {
          return args
        }
      }
    }
    pi = pi + 1
  }
  ordered
}

// Lower a builtin or static function call.
func lowerBuiltinOrStaticCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  funcName: in String,
  path: in ModulePath,
  args: in List[CallArg],
): JvmType {
  if funcName == "println" {
    // Lower the argument BEFORE pushing the PrintStream receiver: a branchy
    // sub-expression (a comparison, an if-expression) inside the argument
    // lands branch targets, and the StackMapTable declares an empty operand
    // stack at every branch target — with the receiver already on the stack
    // the frames disagree and the class fails verification.  Stash the
    // lowered argument to a temp, then push the receiver and reload.
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      val aSlot = allocSlot(ctx, "__println_a_" + freshLabel(ctx), argTy)
      emitStore(insns, aSlot, argTy)
      insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
      emitLoad(insns, aSlot, argTy)
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "println", params = printPs, ret = JVoid))
    } else {
      insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
      val emptyPs: List[JvmType] = newList()
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "println", params = emptyPs, ret = JVoid))
    }
    JVoid
  } else if funcName == "print" {
    // Same receiver-after-argument discipline as println above.
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      val aSlot = allocSlot(ctx, "__print_a_" + freshLabel(ctx), argTy)
      emitStore(insns, aSlot, argTy)
      insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
      emitLoad(insns, aSlot, argTy)
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "print", params = printPs, ret = JVoid))
    } else {
      insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
      val emptyPs2: List[JvmType] = newList()
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "print", params = emptyPs2, ret = JVoid))
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
          insns.add(
            LInvokevirtual(
              owner = "java/lang/Object",
              name = "toString",
              params = tsPs,
              ret = JRef(className = "java/lang/String")
            )
          )
        }
        case _ -> {
          boxIfNeeded(insns, argTy)
          val tsPs2: List[JvmType] = newList()
          insns.add(
            LInvokevirtual(
              owner = "java/lang/Object",
              name = "toString",
              params = tsPs2,
              ret = JRef(className = "java/lang/String")
            )
          )
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
    insns.add(LInvokespecial(owner = "java/util/ArrayList", name = "<init>", params = nlPs, ret = JVoid))
    JRef(className = "java/util/ArrayList")
  } else if funcName == "newMap" {
    insns.add(LNew(className = "java/util/HashMap"))
    insns.add(LDup)
    val nmPs: List[JvmType] = newList()
    insns.add(LInvokespecial(owner = "java/util/HashMap", name = "<init>", params = nmPs, ret = JVoid))
    JRef(className = "java/util/HashMap")
  } else if funcName == "newListWithCapacity" {
    // Generic `@externTarget` kernel funcs are not emitted as methods (they
    // are excluded from monomorphization and have no non-generic body), so
    // like `newList`/`newMap` this is an intrinsic: ArrayList(int).
    if args.count > 0 {
      // Arg lowers to a temp BEFORE `new; dup` (branch-target discipline).
      val cTy = lowerCallArg(ctx, insns, args[0])
      coerceArgTo(insns, cTy, JInt)
      val capSlot = allocSlot(ctx, "__nlc_" + freshLabel(ctx), JInt)
      emitStore(insns, capSlot, JInt)
      insns.add(LNew(className = "java/util/ArrayList"))
      insns.add(LDup)
      emitLoad(insns, capSlot, JInt)
      val ncPs: List[JvmType] = newList()
      ncPs.add(JInt)
      insns.add(LInvokespecial(owner = "java/util/ArrayList", name = "<init>", params = ncPs, ret = JVoid))
    } else {
      insns.add(LNew(className = "java/util/ArrayList"))
      insns.add(LDup)
      val ncPs0: List[JvmType] = newList()
      insns.add(LInvokespecial(owner = "java/util/ArrayList", name = "<init>", params = ncPs0, ret = JVoid))
    }
    JRef(className = "java/util/ArrayList")
  } else if funcName == "mapGet" {
    // mapGet(map, key) → Option[V]: a containsKey-gated Some/None construction
    // (#3229 / #3676).  The previous lowering returned the raw `HashMap.get`
    // value — never an Option, so every `case Some(...)` match on a mapGet
    // result silently failed — and boxed the key as if it were always an Int
    // (`Integer.valueOf(I)` on a String key fails verification).  The map and
    // the boxed key are stashed to locals, and the constructed Option routes
    // through a result local, so the operand stack is empty at every branch
    // target (the StackMapTable declares an empty stack there).
    if args.count >= 2 {
      val mTy = lowerCallArg(ctx, insns, args[0])
      coerceArgTo(insns, mTy, JRef(className = "java/util/HashMap"))
      val mSlot = allocSlot(ctx, "__mapget_m_" + freshLabel(ctx), JRef(className = "java/util/HashMap"))
      insns.add(LAstoreAs(slot = mSlot, className = "java/util/HashMap"))
      val kTy = lowerCallArg(ctx, insns, args[1])
      boxIfNeeded(insns, kTy)
      val kSlot = allocSlot(ctx, "__mapget_k_" + freshLabel(ctx), JRef(className = "java/lang/Object"))
      insns.add(LAstore(slot = kSlot))
      val rSlot = allocSlot(ctx, "__mapget_r_" + freshLabel(ctx), JRef(className = "Std/Core/Option"))
      val noneL = freshLabel(ctx)
      val afterMgL = freshLabel(ctx)
      insns.add(LAload(slot = mSlot))
      insns.add(LAload(slot = kSlot))
      val ckPs: List[JvmType] = newList()
      ckPs.add(JRef(className = "java/lang/Object"))
      insns.add(LInvokevirtual(owner = "java/util/HashMap", name = "containsKey", params = ckPs, ret = JBoolean))
      insns.add(LIfeq(label = noneL))
      insns.add(LNew(className = "Std/Core/Option$Some"))
      insns.add(LDup)
      insns.add(LAload(slot = mSlot))
      insns.add(LAload(slot = kSlot))
      val mgPs: List[JvmType] = newList()
      mgPs.add(JRef(className = "java/lang/Object"))
      insns.add(
        LInvokevirtual(owner = "java/util/HashMap", name = "get", params = mgPs, ret = JRef(className = "java/lang/Object"))
      )
      val someCtorPs: List[JvmType] = newList()
      someCtorPs.add(JRef(className = "java/lang/Object"))
      insns.add(LInvokespecial(owner = "Std/Core/Option$Some", name = "<init>", params = someCtorPs, ret = JVoid))
      insns.add(LAstoreAs(slot = rSlot, className = "Std/Core/Option"))
      insns.add(LGoto(label = afterMgL))
      insns.add(LLabel(name = noneL))
      insns.add(LNew(className = "Std/Core/Option$None"))
      insns.add(LDup)
      val noneCtorPs: List[JvmType] = newList()
      insns.add(LInvokespecial(owner = "Std/Core/Option$None", name = "<init>", params = noneCtorPs, ret = JVoid))
      insns.add(LAstoreAs(slot = rSlot, className = "Std/Core/Option"))
      insns.add(LLabel(name = afterMgL))
      insns.add(LAload(slot = rSlot))
      JRef(className = "Std/Core/Option")
    } else {
      insns.add(LAconstNull)
      JRef(className = "java/lang/Object")
    }
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
    insns.add(
      LInvokevirtual(
        owner = "java/lang/Character",
        name = "toString",
        params = csPs,
        ret = JRef(className = "java/lang/String")
      )
    )
    JRef(className = "java/lang/String")
  } else if funcName == "stringToUtf8Bytes" {
    if args.count > 0 {
      lowerCallArg(ctx, insns, args[0])
    }
    insns.add(
      LGetstatic(
        owner = "java/nio/charset/StandardCharsets",
        name = "UTF_8",
        t = JRef(className = "java/nio/charset/Charset")
      )
    )
    val subPs: List[JvmType] = newList()
    subPs.add(JRef(className = "java/nio/charset/Charset"))
    insns.add(LInvokevirtual(owner = "java/lang/String", name = "getBytes", params = subPs, ret = JArray(elem = JByte)))
    JArray(elem = JByte)
  } else if funcName == "catch" {
    // Std.Jvm.catch intrinsic: macroexpand to inline try-catch when the
    // argument is a zero-parameter lambda literal.  See lowerCatchIntrinsic.
    if args.count > 0 {
      val argExpr: Expr = match args[0] { case CAPositional(e) -> e; case CANamed(_, e, _) -> e }
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

// ── Auto-FFI helpers ──────────────────────────────────────────────────────────
// Convert a JvmType to a JVM descriptor string, e.g. JInt → "I".
func jvmTypeToDescStr(ty: JvmType): String {
  match ty {
    case JInt -> "I"
    case JLong -> "J"
    case JDouble -> "D"
    case JFloat -> "F"
    case JBoolean -> "Z"
    case JByte -> "B"
    case JChar -> "C"
    case JShort -> "S"
    case JVoid -> "V"
    case JRef(cn) -> "L" + cn + ";"
    case JArray(elem) -> "[" + jvmTypeToDescStr(elem)
  }
}

// Convert a single JVM descriptor string to a JvmType.
func descStrToJvmType(desc: String): JvmType {
  if desc == "I" {
    JInt
  } else if desc == "J" {
    JLong
  } else if desc == "D" {
    JDouble
  } else if desc == "F" {
    JFloat
  } else if desc == "Z" {
    JBoolean
  } else if desc == "B" {
    JByte
  } else if desc == "C" {
    JChar
  } else if desc == "S" {
    JShort
  } else if desc == "V" {
    JVoid
  } else if desc.length > 0 and desc[0] == '[' {
    JArray(elem = descStrToJvmType(desc.substring(1, desc.length - 1)))
  } else if desc.length > 1 and desc[0] == 'L' {
    JRef(className = desc.substring(1, desc.length - 2))
  } else {
    JRef(className = "java/lang/Object")
  }
}

// Extract the return-type descriptor from a JVM method descriptor "(params)ret".
func returnDescFromMethodDesc(descriptor: String): String {
  val len = descriptor.length
  var i = 0
  while i < len {
    if descriptor[i] == ')' {
      if i + 1 < len {
        return descriptor.substring(i + 1, len - i - 1)
      }
      return "V"
    }
    i = i + 1
  }
  "V"
}

// True when `elemTy` is one of the 8 JVM primitive types — a valid
// primitive array element type (`boolean[]`/`char[]`/`float[]`/`double[]`/
// `byte[]`/`short[]`/`int[]`/`long[]`).
func isJvmPrimitiveElemType(elemTy: in JvmType): Bool {
  match elemTy {
    case JInt -> true
    case JLong -> true
    case JDouble -> true
    case JFloat -> true
    case JBoolean -> true
    case JByte -> true
    case JChar -> true
    case JShort -> true
    case _ -> false
  }
}

// The `newarray` type code (JVM spec §6.5.newarray) for a primitive array
// element type.
func primitiveNewarrayCode(elemTy: in JvmType): Int {
  match elemTy {
    case JBoolean -> 4
    case JChar -> 5
    case JFloat -> 6
    case JDouble -> 7
    case JByte -> 8
    case JShort -> 9
    case JInt -> 10
    case JLong -> 11
    case _ -> panic("primitiveNewarrayCode: not a JVM primitive array element type")
  }
}

// The boxed wrapper class binary name for a primitive array element type
// (used to `LAnewarray` an `Object[]`-compatible array of boxed instances —
// distinct from `primitiveNewarrayCode`, which allocates the primitive
// array itself via `LNewarray`).
func wrapperClassNameFor(elemTy: in JvmType): String {
  match elemTy {
    case JInt -> "java/lang/Integer"
    case JLong -> "java/lang/Long"
    case JFloat -> "java/lang/Float"
    case JDouble -> "java/lang/Double"
    case JBoolean -> "java/lang/Boolean"
    case JByte -> "java/lang/Byte"
    case JChar -> "java/lang/Character"
    case JShort -> "java/lang/Short"
    case _ -> panic("wrapperClassNameFor: not a JVM primitive array element type")
  }
}

// The `Txaload` instruction for reading one element out of a primitive array
// of element type `elemTy`.  `boolean[]` shares `baload` with `byte[]`.
func primitiveArrayLoadInsn(elemTy: in JvmType): LInsn {
  match elemTy {
    case JInt -> LIaload
    case JLong -> LLaload
    case JFloat -> LFaload
    case JDouble -> LDaload
    case JBoolean -> LBaload
    case JByte -> LBaload
    case JChar -> LCaload
    case JShort -> LSaload
    case _ -> panic("primitiveArrayLoadInsn: not a JVM primitive array element type")
  }
}

// The `Txastore` instruction for writing one element into a primitive array
// of element type `elemTy`.  `boolean[]` shares `bastore` with `byte[]`.
func primitiveArrayStoreInsn(elemTy: in JvmType): LInsn {
  match elemTy {
    case JInt -> LIastore
    case JLong -> LLastore
    case JFloat -> LFastore
    case JDouble -> LDastore
    case JBoolean -> LBastore
    case JByte -> LBastore
    case JChar -> LCastore
    case JShort -> LSastore
    case _ -> panic("primitiveArrayStoreInsn: not a JVM primitive array element type")
  }
}

// Unbox one boxed-wrapper reference already loaded on the operand stack down
// to the primitive `elemTy`.  Byte and Short tolerate a wider boxed numeric
// type (an int literal added to a `List[Byte]`/`List[Short]` boxes as
// `Integer`, not `Byte`/`Short`): unbox through `Number.intValue` + a
// narrowing conversion, mirroring the pre-existing byte-only tolerance this
// generalizes.
func unboxArrayElement(insns: in List[LInsn], elemTy: in JvmType): Unit {
  match elemTy {
    case JInt -> {
      insns.add(LCheckcast(className = "java/lang/Integer"))
      insns.add(LUnboxInt)
    }
    case JLong -> {
      insns.add(LCheckcast(className = "java/lang/Long"))
      insns.add(LUnboxLong)
    }
    case JFloat -> {
      insns.add(LCheckcast(className = "java/lang/Float"))
      insns.add(LUnboxFloat)
    }
    case JDouble -> {
      insns.add(LCheckcast(className = "java/lang/Double"))
      insns.add(LUnboxDouble)
    }
    case JBoolean -> {
      insns.add(LCheckcast(className = "java/lang/Boolean"))
      insns.add(LUnboxBool)
    }
    case JChar -> {
      insns.add(LCheckcast(className = "java/lang/Character"))
      insns.add(LUnboxChar)
    }
    case JByte -> {
      insns.add(LCheckcast(className = "java/lang/Number"))
      val ps: List[JvmType] = newList()
      insns.add(LInvokevirtual(owner = "java/lang/Number", name = "intValue", params = ps, ret = JInt))
      insns.add(LI2b)
    }
    case JShort -> {
      insns.add(LCheckcast(className = "java/lang/Number"))
      val ps: List[JvmType] = newList()
      insns.add(LInvokevirtual(owner = "java/lang/Number", name = "intValue", params = ps, ret = JInt))
      insns.add(LI2s)
    }
    case _ -> panic("unboxArrayElement: not a JVM primitive array element type")
  }
}

// Replace a Lyric slice (`[Ljava/lang/Object;`) on top of the operand stack
// with a freshly built primitive array of element type `elemTy`, unboxing
// each element.  Generalizes the byte-only loop this replaced (see
// `emitBoxPrimitiveArray` in `06_items.l` for the inverse direction).
func emitUnboxObjectArray(ctx: in FuncCtx, insns: in List[LInsn], elemTy: in JvmType): Unit {
  val srcSlot = allocSlot(ctx, "__ffi_arr_src_" + freshLabel(ctx), JArray(elem = JRef(className = "java/lang/Object")))
  val dstSlot = allocSlot(ctx, "__ffi_arr_dst_" + freshLabel(ctx), JArray(elem = elemTy))
  val idxSlot = allocSlot(ctx, "__ffi_arr_idx_" + freshLabel(ctx), JInt)
  val lenSlot = allocSlot(ctx, "__ffi_arr_len_" + freshLabel(ctx), JInt)
  val loopL = freshLabel(ctx)
  val endL = freshLabel(ctx)
  // `LAstoreAs` carries the array descriptor so the StackMapTable types the
  // slots precisely (`[Ljava/lang/Object;` / the primitive array descriptor);
  // a plain-Object slot type makes `aaload` / a primitive `Txastore` a
  // VerifyError.
  insns.add(LAstoreAs(slot = srcSlot, className = "[Ljava/lang/Object;"))
  insns.add(LAload(slot = srcSlot))
  insns.add(LArraylength)
  insns.add(LNewarray(typeCode = primitiveNewarrayCode(elemTy)))
  insns.add(LAstoreAs(slot = dstSlot, className = jvmTypeToDescStr(JArray(elem = elemTy))))
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
  insns.add(LAaload)
  unboxArrayElement(insns, elemTy)
  insns.add(primitiveArrayStoreInsn(elemTy))
  insns.add(LIinc(slot = idxSlot, delta = 1))
  insns.add(LGoto(label = loopL))
  insns.add(LLabel(name = endL))
  insns.add(LAload(slot = dstSlot))
}

// Emit a widening numeric coercion instruction from `fromDesc` to `toDesc`.
// No-op when the types are identical or the widening is handled at the JVM
// reference level (reference → Object).  Also bridges a Lyric slice
// (`[Ljava/lang/Object;`, of boxed wrapper values) to any JDK primitive
// array by materialising a fresh primitive array and unboxing each element —
// see `scoreParamMatch`'s `[Ljava/lang/Object; -> primitive[]` arm.
func emitFfiCoerce(ctx: in FuncCtx, insns: in List[LInsn], fromDesc: in String, toDesc: in String): Unit {
  if fromDesc == toDesc {
    return ()
  }
  // Primitive → Object parameter: box (the score-2 arm in scoreParamMatch).
  if toDesc == "Ljava/lang/Object;" {
    val fromTy = descStrToJvmType(fromDesc)
    match fromTy {
      case JRef(_) -> ()
      case JArray(_) -> ()
      case _ -> {
        boxIfNeeded(insns, fromTy)
        return ()
      }
    }
  }
  if fromDesc == "I" {
    if toDesc == "J" {
      insns.add(LI2l)
      return ()
    }
    if toDesc == "D" {
      insns.add(LI2d)
      return ()
    }
    if toDesc == "F" {
      insns.add(LI2f)
      return ()
    }
  }
  if fromDesc == "J" {
    if toDesc == "D" {
      insns.add(LL2d)
      return ()
    }
    if toDesc == "F" {
      insns.add(LL2f)
      return ()
    }
  }
  if fromDesc == "F" {
    if toDesc == "D" {
      insns.add(LF2d)
      return ()
    }
  }
  // Lyric slice (`[Ljava/lang/Object;`) → any JDK primitive array.  The
  // source array reference is on the operand stack; `emitUnboxObjectArray`
  // replaces it with a freshly-built primitive array copy (element-copy
  // loop with per-element unboxing, generalized from the byte-only loop this
  // replaced to all 8 JVM primitive array element types).
  if fromDesc == "[Ljava/lang/Object;" {
    match descStrToJvmType(toDesc) {
      case JArray(elemTy) -> {
        if isJvmPrimitiveElemType(elemTy) {
          emitUnboxObjectArray(ctx, insns, elemTy)
          return ()
        }
      }
      case _ -> ()
    }
  }
}

// Lower a static auto-FFI call where `javaFqn` is the dotted Java class name
// and `methodName` is the Java method.  Resolves the best-matching overload
// from JDK metadata and emits invokestatic / invokevirtual with the real
// descriptor.  Falls back to an Object-typed guess when the JDK is unavailable.
func lowerAutoFfiStaticCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  javaFqn: in String,
  methodName: in String,
  args: in List[CallArg],
): JvmType {
  // Buffer each arg's lowering so coercions can be inserted per-overload.
  val argBufs: List[List[LInsn]] = newList()
  val argDescs: List[String] = newList()
  var i = 0
  while i < args.count {
    val buf: List[LInsn] = newList()
    val aTy = lowerCallArg(ctx, buf, args[i])
    argBufs.add(buf)
    argDescs.add(jvmTypeToDescStr(aTy))
    i = i + 1
  }

  val binaryName = javaFqn.replace(".", "/")

  match loadClass(ctx.autoFfi, javaFqn) {
    case None -> {
      if ctx.autoFfi.jmodsDir.length > 0 or ctx.autoFfi.jarPaths.count > 0 {
        // Metadata was available but the class wasn't found — hard compile error.
        panic("JVM auto-FFI: class '" + javaFqn + "' not found in JDK jmods or LYRIC_FFI_JARS")
      }
      // No JDK / JARs found.  Fall back to the legacy object-typed binding;
      // resolution may fail at JVM link time.
      // For constructors, LNew + LDup must appear before args on the operand stack.
      val paramTys: List[JvmType] = newList()
      if methodName == "new" {
        insns.add(LNew(className = binaryName))
        insns.add(LDup)
      }
      var j = 0
      while j < argBufs.count {
        val buf = argBufs[j]
        var k = 0
        while k < buf.count {
          insns.add(buf[k])
          k = k + 1
        }
        paramTys.add(JRef(className = "java/lang/Object"))
        j = j + 1
      }
      if methodName == "new" {
        // No-metadata constructor fallback: Object-typed invokespecial <init>.
        insns.add(LInvokespecial(owner = binaryName, name = "<init>", params = paramTys, ret = JVoid))
        JRef(className = binaryName)
      } else {
        insns.add(
          LInvokestatic(owner = binaryName, name = methodName, params = paramTys, ret = JRef(className = "java/lang/Object"))
        )
        JRef(className = "java/lang/Object")
      }
    }
    case Some(ci) -> {
      // Intercept "new" pseudo-method: T.new(args) → new + dup + invokespecial <init>.
      if methodName == "new" {
        return lowerAutoFfiConstructorCall(ctx, insns, ci, args)
      }
      match findBestMethod(ctx.autoFfi, ci, methodName, argDescs, true) {
        case None -> {
          // No static overload matches — compile-time diagnostic.
          var argStr = ""
          var ai = 0
          while ai < argDescs.count {
            if ai > 0 {
              argStr = argStr + ", "
            }
            argStr = argStr + argDescs[ai]
            ai = ai + 1
          }
          panic(
            "JVM auto-FFI: no matching static overload for '" + javaFqn + "." + methodName + "(" + argStr +
              ")' — check the method name, argument types, and that it is a static method"
          )
        }
        case Some(method) -> {
          if not method.isStatic {
            panic(
              "JVM auto-FFI: '" + javaFqn + "." + methodName +
                "' is an instance method, not static; call it on an instance value, not on the type name"
            )
          }
          val paramDescs = parseDescriptorParams(method.descriptor)
          val retDesc = returnDescFromMethodDesc(method.descriptor)
          val retJvm = descStrToJvmType(retDesc)
          val paramJvms: List[JvmType] = newList()
          var j = 0
          while j < argBufs.count {
            val buf = argBufs[j]
            var k = 0
            while k < buf.count {
              insns.add(buf[k])
              k = k + 1
            }
            val paramDesc = if j < paramDescs.count { paramDescs[j] } else { argDescs[j] }
            emitFfiCoerce(ctx, insns, argDescs[j], paramDesc)
            paramJvms.add(descStrToJvmType(paramDesc))
            j = j + 1
          }
          insns.add(LInvokestatic(owner = ci.binaryName, name = methodName, params = paramJvms, ret = retJvm))
          retJvm
        }
      }
    }
  }
}

// Instance method call on a JDK class through auto-FFI.  The receiver is
// already on the operand stack when this is called; this function lowers
// `args`, resolves the overload from metadata, and emits `invokevirtual`.
func lowerAutoFfiInstanceCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  ci: in ClassInfo,
  methodName: in String,
  args: in List[CallArg],
): JvmType {
  val argBufs: List[List[LInsn]] = newList()
  val argDescs: List[String] = newList()
  var i = 0
  while i < args.count {
    val buf: List[LInsn] = newList()
    val aTy = lowerCallArg(ctx, buf, args[i])
    argBufs.add(buf)
    argDescs.add(jvmTypeToDescStr(aTy))
    i = i + 1
  }
  match findBestInstanceMethod(ctx.autoFfi, ci, methodName, argDescs) {
    case None -> {
      var argStr = ""
      var ai = 0
      while ai < argDescs.count {
        if ai > 0 {
          argStr = argStr + ", "
        }
        argStr = argStr + argDescs[ai]
        ai = ai + 1
      }
      val fqn = ci.binaryName.replace("/", ".")
      panic("JVM auto-FFI: no matching instance or inherited method for '" + fqn + "." + methodName + "(" + argStr + ")'")
    }
    case Some(method) -> {
      val paramDescs = parseDescriptorParams(method.descriptor)
      val retDesc = returnDescFromMethodDesc(method.descriptor)
      val retJvm = descStrToJvmType(retDesc)
      // A `[Ljava/lang/Object; -> [B` arg coercion (see `emitFfiCoerce`)
      // emits a back-branch loop, and the StackMapTable generator assumes an
      // empty operand stack at every branch target.  The receiver is already
      // on the stack here, so stash it to a temp first, run the (now
      // empty-stack) arg lowering + coercions, then reload it before the
      // invoke.  Only done when such a coercion is actually present, to leave
      // the common path's bytecode shape unchanged.
      var needsRecvStash = false
      var nj = 0
      while nj < paramDescs.count {
        if nj < argDescs.count and argDescs[nj] == "[Ljava/lang/Object;" and paramDescs[nj] == "[B" {
          needsRecvStash = true
        }
        nj = nj + 1
      }
      val recvSlot = if needsRecvStash {
        val rs = allocSlot(ctx, "__ffi_recv_" + freshLabel(ctx), JRef(className = ci.binaryName))
        insns.add(LAstoreAs(slot = rs, className = ci.binaryName))
        rs
      } else {
        -1
      }
      val paramJvms: List[JvmType] = newList()
      // When the receiver was stashed, accumulate each coerced arg into a temp
      // slot too, so we can reload `receiver, arg0, arg1, …` in order after all
      // the (empty-stack-safe) coercion loops have run.
      val argSlots: List[Int] = newList()
      var j = 0
      while j < argBufs.count {
        val buf = argBufs[j]
        var k = 0
        while k < buf.count {
          insns.add(buf[k])
          k = k + 1
        }
        val paramDesc = if j < paramDescs.count { paramDescs[j] } else { argDescs[j] }
        emitFfiCoerce(ctx, insns, argDescs[j], paramDesc)
        val pj = descStrToJvmType(paramDesc)
        paramJvms.add(pj)
        if needsRecvStash {
          val aslot = allocSlot(ctx, "__ffi_arg_" + freshLabel(ctx), pj)
          emitStore(insns, aslot, pj)
          argSlots.add(aslot)
        }
        j = j + 1
      }
      if needsRecvStash {
        insns.add(LAload(slot = recvSlot))
        var aj = 0
        while aj < argSlots.count {
          emitLoad(insns, argSlots[aj], paramJvms[aj])
          aj = aj + 1
        }
      }
      insns.add(LInvokevirtual(owner = ci.binaryName, name = methodName, params = paramJvms, ret = retJvm))
      retJvm
    }
  }
}

// Constructor call on a JDK class through auto-FFI.  `T.new(args)` maps to
// `new <class>; dup; <args>; invokespecial <init>`.  Receiver reference is
// produced by the `new` opcode and duplicated so the initialised reference
// remains on the stack after `invokespecial` consumes the bottom copy.
// Abstract classes are rejected at compile time under `error[J005]`: emitting
// `new` for an abstract class would otherwise produce bytecode that throws
// `InstantiationError` at runtime instead of a clear diagnostic (#2215).
func lowerAutoFfiConstructorCall(
  ctx: in FuncCtx, insns: in List[LInsn], ci: in ClassInfo, args: in List[CallArg]
): JvmType {
  if ci.isAbstract {
    val fqn = ci.binaryName.replace("/", ".")
    panic(
      "error[J005]: JVM auto-FFI: cannot construct abstract class '" + fqn +
        "' — declare a concrete subclass and instantiate that instead"
    )
  }
  val argBufs: List[List[LInsn]] = newList()
  val argDescs: List[String] = newList()
  var i = 0
  while i < args.count {
    val buf: List[LInsn] = newList()
    val aTy = lowerCallArg(ctx, buf, args[i])
    argBufs.add(buf)
    argDescs.add(jvmTypeToDescStr(aTy))
    i = i + 1
  }
  match findBestConstructor(ctx.autoFfi, ci, argDescs) {
    case None -> {
      var argStr = ""
      var ai = 0
      while ai < argDescs.count {
        if ai > 0 {
          argStr = argStr + ", "
        }
        argStr = argStr + argDescs[ai]
        ai = ai + 1
      }
      val fqn = ci.binaryName.replace("/", ".")
      panic("JVM auto-FFI: no matching constructor for 'new " + fqn + "(" + argStr + ")' — check argument types")
    }
    case Some(ctor) -> {
      // Lower and coerce every argument into a temp slot BEFORE emitting
      // `new; dup`: an arg coercion may branch (the `[Ljava/lang/Object;` →
      // `[B` conversion loop), and the StackMapTable declares an empty
      // operand stack at every branch target — running it with the
      // uninitialised receiver refs on the stack fails verification (hit by
      // `String(byte[], "UTF-8")` in the Std.FileHost kernel).
      val paramDescs = parseDescriptorParams(ctor.descriptor)
      val paramJvms: List[JvmType] = newList()
      val argSlots: List[Int] = newList()
      var j = 0
      while j < argBufs.count {
        val buf = argBufs[j]
        var k = 0
        while k < buf.count {
          insns.add(buf[k])
          k = k + 1
        }
        val paramDesc = if j < paramDescs.count { paramDescs[j] } else { argDescs[j] }
        emitFfiCoerce(ctx, insns, argDescs[j], paramDesc)
        val pj = descStrToJvmType(paramDesc)
        paramJvms.add(pj)
        val aslot = allocSlot(ctx, "__ctor_arg_" + freshLabel(ctx), pj)
        emitStore(insns, aslot, pj)
        argSlots.add(aslot)
        j = j + 1
      }
      insns.add(LNew(className = ci.binaryName))
      insns.add(LDup)
      var lj = 0
      while lj < argSlots.count {
        emitLoad(insns, argSlots[lj], paramJvms[lj])
        lj = lj + 1
      }
      insns.add(LInvokespecial(owner = ci.binaryName, name = "<init>", params = paramJvms, ret = JVoid))
      JRef(className = ci.binaryName)
    }
  }
}

// Coerce the value on top of the stack (statically `fromTy`) to `toTy`.  Used
// at call/construction argument boundaries where a value of erased static type
// (`Object`, e.g. a tuple element bound by `PTuple`) must satisfy a declared
// primitive or reference parameter type: a boxed primitive is checkcast to its
// wrapper and unboxed; a reference is narrowed with checkcast.  A no-op when the
// value already has the target representation.
func coerceArgTo(insns: in List[LInsn], fromTy: in JvmType, toTy: in JvmType): Unit {
  val fromRef = isRefJvm(fromTy)
  match toTy {
    case JInt -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Integer"))
        insns.add(LUnboxInt)
      }
    }
    case JLong -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Long"))
        insns.add(LUnboxLong)
      } else {
        // Primitive widening into a Long slot (mirrors the JDouble arm):
        // an int-like value widens with i2l.  Without it `value = 0` on an
        // `out Long` parameter left a one-slot int for a two-slot lstore —
        // operand-stack underflow at verification.
        match fromTy {
          case JInt -> insns.add(LI2l)
          case JByte -> insns.add(LI2l)
          case JChar -> insns.add(LI2l)
          case JShort -> insns.add(LI2l)
          case _ -> ()
        }
      }
    }
    case JDouble -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Double"))
        insns.add(LUnboxDouble)
      } else {
        // Primitive widening into a Double slot: a Float value widens with f2d;
        // int-like values widen with i2f then f2d (the JVM has no direct i2d on
        // the int subset other than i2d, so use it directly); long with l2d.
        match fromTy {
          case JFloat -> insns.add(LF2d)
          case JInt -> insns.add(LI2d)
          case JByte -> insns.add(LI2d)
          case JChar -> insns.add(LI2d)
          case JShort -> insns.add(LI2d)
          case JLong -> insns.add(LL2d)
          case _ -> ()
        }
      }
    }
    case JFloat -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Float"))
        insns.add(LUnboxFloat)
      } else {
        // Primitive coercion into a Float slot: a Double narrows with d2f;
        // int-like / long values convert with i2f / l2f.
        match fromTy {
          case JDouble -> insns.add(LD2f)
          case JInt -> insns.add(LI2f)
          case JByte -> insns.add(LI2f)
          case JChar -> insns.add(LI2f)
          case JShort -> insns.add(LI2f)
          case JLong -> insns.add(LL2f)
          case _ -> ()
        }
      }
    }
    case JBoolean -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Boolean"))
        insns.add(LUnboxBool)
      }
    }
    case JByte -> {
      if fromRef {
        // The boxed value may be Byte OR Integer (an int literal stored into
        // a Byte-typed position boxes as Integer): unbox through
        // Number.intValue + i2b.
        insns.add(LCheckcast(className = "java/lang/Number"))
        val nbcPs: List[JvmType] = newList()
        insns.add(LInvokevirtual(owner = "java/lang/Number", name = "intValue", params = nbcPs, ret = JInt))
        insns.add(LI2b)
      }
    }
    case JChar -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Character"))
        insns.add(LUnboxChar)
      }
    }
    case JRef(toCls) -> {
      match fromTy {
        // Lyric Unit (`()`) lowers to JVoid: nothing on the stack.  A
        // Unit-typed argument flowing into a reference slot must push `null`
        // so the JVM sees a value for the parameter (#1722 / Ok(()) pattern).
        case JVoid -> insns.add(LAconstNull)
        case JRef(fromCls) -> {
          if not (fromCls == toCls) and not (toCls == "java/lang/Object") {
            insns.add(LCheckcast(className = toCls))
          }
        }
        case JArray(_) -> ()
        // A primitive value flowing into a reference slot (e.g. an `Int` payload
        // of a generic case field erased to `Object`) must be boxed so the
        // verifier accepts the `Ljava/lang/Object;` store.  Match-extraction
        // later checkcasts + unboxes back to the binding's concrete type.
        case _ -> boxIfNeeded(insns, fromTy)
      }
    }
    case JArray(_) -> {
      // A list value (an `EList` literal or any List-typed expression) flowing
      // into an erased `slice[T]` parameter (`[Ljava/lang/Object;`) must be
      // converted: an ArrayList is not assignable to an array and fails
      // verification at class load (#4700).  `ArrayList.toArray()` yields the
      // `Object[]` the slice ABI expects.  A value already of array type
      // needs no conversion (JVM ref-array covariance).
      match fromTy {
        case JRef(fromCls) -> {
          if fromCls == "java/util/ArrayList" {
            val taPs: List[JvmType] = newList()
            insns.add(
              LInvokevirtual(
                owner = "java/util/ArrayList",
                name = "toArray",
                params = taPs,
                ret = JArray(elem = JRef(className = "java/lang/Object"))
              )
            )
          }
        }
        case _ -> ()
      }
    }
    case _ -> ()
  }
}

// Push a benign default value of `ty` (only reached if a construction call is
// missing an argument — the type-checker normally guarantees arity).
func pushDefaultValue(insns: in List[LInsn], ty: in JvmType): Unit {
  match ty {
    case JLong -> insns.add(LLconst(v = 0i64))
    case JDouble -> insns.add(LDconst(v = 0.0))
    case JRef(_) -> insns.add(LAconstNull)
    case JArray(_) -> insns.add(LAconstNull)
    case JVoid -> insns.add(LNop)
    case _ -> insns.add(LIconst(v = 0))
  }
}

// Reorder construction arguments to the constructor's field-declaration order.
// A `<init>` consumes fields positionally; named-argument call sites (`Point(y
// = 2, x = 1)`) must be permuted to match.  All-positional calls are returned
// unchanged (already in declaration order).
func orderCtorArgs(fields: in List[JvmCaseField], args: in List[CallArg]): List[CallArg] {
  var anyNamed = false
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(_, _, _) -> {
        anyNamed = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  if not anyNamed {
    return args
  }
  val byName: Map[String, CallArg] = newMap()
  var j = 0
  while j < args.count {
    match args[j] {
      case CANamed(nm, _, _) -> {
        if not byName.containsKey(nm) {
          byName.add(nm, args[j])
        }
      }
      case _ -> ()
    }
    j = j + 1
  }
  val reordered: List[CallArg] = newList()
  var f = 0
  while f < fields.count {
    match mapGet(byName, fields[f].name) {
      case Some(a) -> {
        reordered.add(a)
      }
      case None -> ()
    }
    f = f + 1
  }
  reordered
}

// Lower a record / union-case construction to `new`/`invokespecial`.  Arguments
// are reordered to field-declaration order and coerced to each field's declared
// type.  A record yields its own class type; a union case yields the union's
// sealed-interface type (so the value flows into interface-typed slots and
// `match` re-narrows via checkcast).
func lowerConstruction(ctx: in FuncCtx, insns: in List[LInsn], className: in String, args: in List[CallArg]): JvmType {
  val fieldsOpt: Option[List[JvmCaseField]] = mapGet(ctx.caseFields, className)
  match fieldsOpt {
    case Some(fields) -> {
      // Evaluate every provided argument into a fresh local BEFORE `new; dup`
      // (#5003).  An argument expression can itself contain internal
      // branches/labels whose StackMapTable assumes the operand stack is
      // empty at entry — the `mapGet` intrinsic's containsKey-gated
      // Some/None construction is the common case (`Ok(mapGet(m, k))`).  If
      // `new; dup` ran first, those two uninitialized-object stack slots
      // would sit underneath the argument's own branch labels, desyncing the
      // verifier's declared frame from the actual runtime stack shape
      // ("Inconsistent stackmap frames").  Storing each argument to a local
      // first guarantees the stack is empty when any such branching argument
      // lowers, regardless of the enclosing constructor call.
      val ordered = orderCtorArgs(fields, args)
      val argSlots: List[Int] = newList()
      var i = 0
      while i < fields.count {
        val fty = fields[i].ty
        if i < ordered.count {
          val aTy = lowerCallArg(ctx, insns, ordered[i])
          coerceArgTo(insns, aTy, fty)
          val slot = allocSlot(ctx, "__ctor_arg_" + freshLabel(ctx), fty)
          emitStore(insns, slot, fty)
          argSlots.add(slot)
        } else {
          argSlots.add(-1)
        }
        i = i + 1
      }
      insns.add(LNew(className = className))
      insns.add(LDup)
      val paramTys: List[JvmType] = newList()
      var j = 0
      while j < fields.count {
        val fty = fields[j].ty
        paramTys.add(fty)
        if argSlots[j] >= 0 {
          emitLoad(insns, argSlots[j], fty)
        } else {
          pushDefaultValue(insns, fty)
        }
        j = j + 1
      }
      insns.add(LInvokespecial(owner = className, name = "<init>", params = paramTys, ret = JVoid))
      if jvmClassIsUnionCase(className) {
        JRef(className = jvmUnionBaseClass(className))
      } else {
        JRef(className = className)
      }
    }
    case None -> {
      // Unknown constructor class (should not occur — every registered ctor has
      // a field entry).  Emit null to keep the stack balanced.
      insns.add(LAconstNull)
      JRef(className = className)
    }
  }
}

// The argument expression of a CallArg (positional or named).
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(e) -> e
    case CANamed(_, e, _) -> e
  }
}

// The name a path-shaped expression resolves to, or "" if the expression is not
// a bare/qualified path.  An `out`/`inout` argument must be an assignable
// variable (the mode checker guarantees V0001–V0006); this recovers its name.
func pathExprName(e: in Expr): String {
  match e.kind {
    case EPath(p) -> {
      val n = p.segments.count
      if n == 0 {
        ""
      } else {
        p.segments[n - 1]
      }
    }
    case _ -> ""
  }
}

// True when `modes` declares at least one `out`/`inout` parameter.
func anyHolderMode(modes: in List[ParamMode]): Bool {
  var i = 0
  while i < modes.count {
    if isHolderMode(modes[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// Emit a static call whose callee has one or more `out`/`inout` parameters
// (#1763).  Each holder argument must be an assignable local (or a forwarded
// `out`/`inout` parameter of the current function); it is wrapped in a fresh
// single-element holder array pre-filled with the local's current value, the
// array is passed in that argument position, and after the call the callee's
// write to `holder[0]` is copied back into the caller's local.
//
// Build order: holder arrays are materialised into temp slots *before* the
// argument-push loop so the post-call readback can reach them, then the loop
// pushes either the temp (holder arg) or the lowered value (by-value arg) in
// declaration order.  `callArgs` is already reordered/defaulted to match
// `sig.params`.
// Pre-build one holder argument's single-element array into a temp slot and
// record it in the parallel bookkeeping lists.  An assignable local reads its
// current value into `holder[0]`; a field access `obj.field` (#3628, JVM
// analog of MSIL #3547) stashes the lowered receiver in its own temp slot,
// reads the field into `holder[0]`, and records the receiver slot + class so
// `writeBackHolderArg` can `putfield` the updated value.  `hRecvSlot` is -1
// (and `hRecvCls` "") for the local case.
func prepareHolderArg(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  calleeLabel: in String,
  bi: in Int,
  argExpr: in Expr,
  elemTy: in JvmType,
  hArgIdx: in List[Int],
  hTempSlot: in List[Int],
  hElemTy: in List[JvmType],
  hBackName: in List[String],
  hRecvSlot: in List[Int],
  hRecvCls: in List[String],
): Unit {
  val name = pathExprName(argExpr)
  if name != "" {
    match lookupSlot(ctx, name) {
      case Some(srcSlot) -> {
        val srcTy = match lookupType(ctx, name) { case Some(t) -> t; case None -> elemTy }
        // holder := new [elemTy](1); holder[0] := <current value of `name`>
        emitNewHolder(insns, elemTy)
        insns.add(LDup)
        insns.add(LIconst(v = 0))
        emitLoad(insns, srcSlot, srcTy)
        coerceArgTo(insns, srcTy, elemTy)
        emitHolderElemStore(insns, elemTy)
        // Stash the array reference in a temp slot, typed precisely so the
        // StackMapTable verifies the later aload + element load.
        val tmpSlot = allocSlot(ctx, "__holderarg$" + calleeLabel + "$" + toString(bi), holderArrayType(elemTy))
        insns.add(LAstoreAs(slot = tmpSlot, className = holderArrayDescriptor(elemTy)))
        hArgIdx.add(bi)
        hTempSlot.add(tmpSlot)
        hElemTy.add(elemTy)
        hBackName.add(name)
        hRecvSlot.add(0 - 1)
        hRecvCls.add("")
      }
      case None -> panic("Jvm.Codegen: out/inout argument '" + name + "' to '" + calleeLabel + "' is not a local or parameter (the mode checker should have rejected this)")
    }
    return
  }
  match argExpr.kind {
    case EMember(recv, fieldName) -> {
      val recvTy = lowerExpr(ctx, insns, recv)
      match recvTy {
        case JRef(cls) -> {
          val rSlot = allocSlot(ctx, "__holderrecv$" + calleeLabel + "$" + toString(bi), JRef(className = cls))
          insns.add(LAstoreAs(slot = rSlot, className = cls))
          val fty = match recordFieldType(ctx, cls, fieldName) {
            case Some(t) -> t
            case None -> JRef(className = "java/lang/Object")
          }
          emitNewHolder(insns, elemTy)
          insns.add(LDup)
          insns.add(LIconst(v = 0))
          emitLoad(insns, rSlot, JRef(className = cls))
          insns.add(LGetfield(owner = cls, name = fieldName, t = fty))
          coerceArgTo(insns, fty, elemTy)
          emitHolderElemStore(insns, elemTy)
          val tmpSlot = allocSlot(ctx, "__holderarg$" + calleeLabel + "$" + toString(bi), holderArrayType(elemTy))
          insns.add(LAstoreAs(slot = tmpSlot, className = holderArrayDescriptor(elemTy)))
          hArgIdx.add(bi)
          hTempSlot.add(tmpSlot)
          hElemTy.add(elemTy)
          hBackName.add(fieldName)
          hRecvSlot.add(rSlot)
          hRecvCls.add(cls)
        }
        case _ -> panic("Jvm.Codegen: out/inout argument " + toString(bi) + " to '" + calleeLabel + "' is a field access on a non-reference receiver (the mode checker should have rejected this)")
      }
    }
    case _ -> panic("Jvm.Codegen: out/inout argument " + toString(bi) + " to '" + calleeLabel + "' is not an assignable variable or field (the mode checker should have rejected this)")
  }
}

// Copy a holder's element 0 back to its target after the call: the caller's
// local (write-through so a forwarded out/inout parameter's own holder stays
// in sync) or, for a field-access argument (#3628), `putfield` through the
// stashed receiver.
func writeBackHolderArg(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  ts: in Int,
  elemTy: in JvmType,
  name: in String,
  recvSlot: in Int,
  recvCls: in String,
): Unit {
  if recvSlot >= 0 {
    val fty = match recordFieldType(ctx, recvCls, name) {
      case Some(t) -> t
      case None -> JRef(className = "java/lang/Object")
    }
    emitLoad(insns, recvSlot, JRef(className = recvCls))
    insns.add(LAload(slot = ts))
    insns.add(LIconst(v = 0))
    emitHolderElemLoad(insns, elemTy)
    coerceArgTo(insns, elemTy, fty)
    insns.add(LPutfield(owner = recvCls, name = name, t = fty))
    return
  }
  match lookupSlot(ctx, name) {
    case Some(destSlot) -> {
      val destTy = match lookupType(ctx, name) { case Some(t) -> t; case None -> elemTy }
      insns.add(LAload(slot = ts))
      insns.add(LIconst(v = 0))
      emitHolderElemLoad(insns, elemTy)
      coerceArgTo(insns, elemTy, destTy)
      emitStoreLocalWriteThrough(ctx, insns, destSlot, destTy)
    }
    case None -> ()
  }
}

func lowerStaticCallWithHolders(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  funcName: in String,
  sig: in JvmFuncSig,
  callArgs: in List[CallArg],
): JvmType {
  // Pre-build each holder argument's array into a temp slot.  Parallel lists
  // (index into callArgs, temp slot, element type, write-back local name or
  // field name + receiver slot/class) rather than a record-valued map,
  // matching the bootstrap-safe style used elsewhere in this file.
  val hArgIdx: List[Int] = newList()
  val hTempSlot: List[Int] = newList()
  val hElemTy: List[JvmType] = newList()
  val hBackName: List[String] = newList()
  val hRecvSlot: List[Int] = newList()
  val hRecvCls: List[String] = newList()
  var bi = 0
  while bi < callArgs.count {
    val isHolder = if bi < sig.paramModes.count { isHolderMode(sig.paramModes[bi]) } else { false }
    if isHolder {
      val elemTy = match sig.params[bi] { case JArray(el) -> el; case other -> other }
      prepareHolderArg(
        ctx,
        insns,
        funcName,
        bi,
        callArgExpr(callArgs[bi]),
        elemTy,
        hArgIdx,
        hTempSlot,
        hElemTy,
        hBackName,
        hRecvSlot,
        hRecvCls
      )
    }
    bi = bi + 1
  }
  // Pre-lower every by-value argument into a temp slot: a byte-array boxing
  // coercion branches, and branch targets require an empty operand stack
  // (see the slice-shaped-param stash in `lowerGeneralStaticCall`).  Holder
  // args already live in temps, so the push loop below is branch-free.
  val bvSlots: List[Int] = newList()
  val bvIdx: List[Int] = newList()
  var pvi = 0
  while pvi < callArgs.count {
    val isHolderPre = if pvi < sig.paramModes.count { isHolderMode(sig.paramModes[pvi]) } else { false }
    if not isHolderPre {
      val aTy = lowerCallArg(ctx, insns, callArgs[pvi])
      var slotTy = aTy
      if pvi < sig.params.count {
        if isPrimitiveArrayToObjectArray(aTy, sig.params[pvi]) {
          match aTy {
            case JArray(fe) -> emitBoxPrimitiveArray(ctx, insns, fe)
            case _ -> ()
          }
        } else {
          coerceArgTo(insns, aTy, sig.params[pvi])
        }
        slotTy = sig.params[pvi]
      }
      val s = allocSlot(ctx, "__hbv_" + freshLabel(ctx), slotTy)
      emitStore(insns, s, slotTy)
      bvSlots.add(s)
      bvIdx.add(pvi)
    }
    pvi = pvi + 1
  }
  // Push arguments in declaration order: a holder arg reloads its prepared temp
  // array; a by-value arg reloads its pre-lowered temp.
  var ai = 0
  while ai < callArgs.count {
    val isHolder = if ai < sig.paramModes.count { isHolderMode(sig.paramModes[ai]) } else { false }
    if isHolder {
      val ts = holderTempSlotFor(hArgIdx, hTempSlot, ai)
      insns.add(LAload(slot = ts))
    } else {
      val bs = holderTempSlotFor(bvIdx, bvSlots, ai)
      val lTy = if ai < sig.params.count { sig.params[ai] } else { JRef(className = "java/lang/Object") }
      emitLoad(insns, bs, lTy)
    }
    ai = ai + 1
  }
  insns.add(LInvokestatic(owner = sig.owner, name = funcName, params = sig.params, ret = sig.ret))
  // Copy each holder's element 0 back into its target (caller local or
  // field-access receiver, #3628).
  var ri = 0
  while ri < hArgIdx.count {
    writeBackHolderArg(ctx, insns, hTempSlot[ri], hElemTy[ri], hBackName[ri], hRecvSlot[ri], hRecvCls[ri])
    ri = ri + 1
  }
  sig.ret
}

// True when any declared parameter is a reference array — the erased Lyric
// slice shape whose argument may need the branching byte-array boxing
// conversion, forcing the stash-all-args-first call form.
func anyRefArrayParam(params: in List[JvmType]): Bool {
  var i = 0
  while i < params.count {
    match params[i] {
      case JArray(e) -> {
        match e {
          case JRef(_) -> {
            return true
          }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// Linear lookup of the temp slot prepared for the holder argument at call-arg
// index `argIdx` (the parallel-list companion to `lowerStaticCallWithHolders`).
func holderTempSlotFor(hArgIdx: in List[Int], hTempSlot: in List[Int], argIdx: in Int): Int {
  var i = 0
  while i < hArgIdx.count {
    if hArgIdx[i] == argIdx {
      return hTempSlot[i]
    }
    i = i + 1
  }
  panic("Jvm.Codegen: holder temp slot not found for argument index " + toString(argIdx))
}

// Emit a virtual method call whose callee has one or more `out`/`inout` parameters
// (#1763).  Mirrors `lowerStaticCallWithHolders` but emits `invokevirtual` instead
// of `invokestatic`.  The receiver must already be on the operand stack when this
// is called (pushed by the caller via `lowerExpr` or `LAload(0)` for sibling calls).
// `args` are the user-level arguments (not including `this`); `sig.params` are the
// declared JVM param types (also not including `this`).
func lowerVirtualCallWithHolders(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  owner: in String,
  methodName: in String,
  sig: in JvmFuncSig,
  args: in List[CallArg],
): JvmType {
  val hArgIdx: List[Int] = newList()
  val hTempSlot: List[Int] = newList()
  val hElemTy: List[JvmType] = newList()
  val hBackName: List[String] = newList()
  val hRecvSlot: List[Int] = newList()
  val hRecvCls: List[String] = newList()
  var bi = 0
  while bi < args.count {
    val isHolder = if bi < sig.paramModes.count { isHolderMode(sig.paramModes[bi]) } else { false }
    if isHolder {
      val elemTy = match sig.params[bi] { case JArray(el) -> el; case other -> other }
      prepareHolderArg(
        ctx,
        insns,
        owner + "." + methodName,
        bi,
        callArgExpr(args[bi]),
        elemTy,
        hArgIdx,
        hTempSlot,
        hElemTy,
        hBackName,
        hRecvSlot,
        hRecvCls
      )
    }
    bi = bi + 1
  }
  var ai = 0
  while ai < args.count {
    val isHolder = if ai < sig.paramModes.count { isHolderMode(sig.paramModes[ai]) } else { false }
    if isHolder {
      val ts = holderTempSlotFor(hArgIdx, hTempSlot, ai)
      insns.add(LAload(slot = ts))
    } else {
      val aTy = lowerCallArg(ctx, insns, args[ai])
      if ai < sig.params.count {
        coerceArgTo(insns, aTy, sig.params[ai])
      }
    }
    ai = ai + 1
  }
  insns.add(LInvokevirtual(owner = owner, name = methodName, params = sig.params, ret = sig.ret))
  var ri = 0
  while ri < hArgIdx.count {
    writeBackHolderArg(ctx, insns, hTempSlot[ri], hElemTy[ri], hBackName[ri], hRecvSlot[ri], hRecvCls[ri])
    ri = ri + 1
  }
  sig.ret
}

func lowerGeneralStaticCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  funcName: in String,
  path: in ModulePath,
  args: in List[CallArg],
): JvmType {
  // Construction: a call whose head names a record or union case lowers to a
  // real `new`/`invokespecial` rather than a (non-existent) static method.
  match ctorClassFor(ctx, funcName) {
    case Some(cls) -> return lowerConstruction(ctx, insns, cls, args)
    case None -> ()
  }

  // Bare sibling call inside an impl / record / protected-type method body
  // (#1722): when `ctx.selfClass` is set (the enclosing method is an instance
  // method) and `selfClass#funcName` is registered, lower `m(args)` as
  // `aload_0; invokevirtual selfClass.m` rather than a static call.  This
  // covers both the explicit `self.m()` form (which goes through `lowerMethodCall`
  // and already finds `<cls>#m`) and the bare `m()` form here.  Must come after
  // the ctor check above (constructors are never dispatched as instance calls)
  // and before the general funcSigs lookup (to override any static function of
  // the same bare name visible at the call site).
  match ctx.selfClass {
    case Some(selfCls) -> {
      match mapGet(ctx.funcSigs, selfCls + "#" + funcName) {
        case Some(sig) -> {
          insns.add(LAload(slot = 0))
          val callArgs = reorderAndFillJvmArgs(sig, args)
          if anyHolderMode(sig.paramModes) {
            return lowerVirtualCallWithHolders(ctx, insns, selfCls, funcName, sig, callArgs)
          }
          var ai = 0
          while ai < callArgs.count {
            val aTy = lowerCallArg(ctx, insns, callArgs[ai])
            if ai < sig.params.count {
              coerceArgTo(insns, aTy, sig.params[ai])
            }
            ai = ai + 1
          }
          insns.add(LInvokevirtual(owner = selfCls, name = funcName, params = sig.params, ret = sig.ret))
          return sig.ret
        }
        case None -> ()
      }
    }
    case None -> ()
  }

  // Preferred path: resolve against the cross-package function registry, which
  // carries the callee's declaring host class and its exact JVM descriptor
  // (declared param + return types).  Args are lowered against the resolved
  // signature and coerced to each declared parameter type, so an erased
  // `Object` value (e.g. a tuple element) satisfies a primitive / reference
  // parameter.  This is what makes an imported call (`assertEqualInt` from
  // `Std.Testing`) and a void-returning call link correctly.
  //
  // Two-stage lookup: a qualified call site (`Std.Testing.assertEqualInt`)
  // tries the `owner/funcName` key first so it resolves to the explicit
  // package, even if another package in the bundle exports the same short
  // name; an unqualified call falls back to the bare-name key (the legacy
  // single-package shape).  #1680.
  // Exact-arity keys (`…@<argc>`) are tried before the name keys so
  // same-name overloads pick the descriptor matching this call's argument
  // count; a call that relies on parameter defaults misses the arity key
  // and falls back to the name key exactly as before.
  val argcSuffix = "@" + toString(args.count)
  val sigOpt = if path.segments.count > 1 {
    val ownerSegs: List[String] = newList()
    var si = 0
    while si < path.segments.count - 1 {
      ownerSegs.add(path.segments[si])
      si = si + 1
    }
    val qkey = joinSegments(ownerSegs, "/") + "/" + funcName
    match mapGet(ctx.funcSigs, qkey + argcSuffix) {
      case Some(sig) -> Some(value = sig)
      case None -> {
        match mapGet(ctx.funcSigs, qkey) {
          case Some(sig) -> Some(value = sig)
          case None -> {
            match mapGet(ctx.funcSigs, funcName + argcSuffix) {
              case Some(sig) -> Some(value = sig)
              case None -> mapGet(ctx.funcSigs, funcName)
            }
          }
        }
      }
    }
  } else {
    match mapGet(ctx.funcSigs, funcName + argcSuffix) {
      case Some(sig) -> Some(value = sig)
      case None -> mapGet(ctx.funcSigs, funcName)
    }
  }
  match sigOpt {
    case Some(sig) -> {
      // Std.Core's generic Option/Result predicates lower to `instanceof`
      // against the runtime case class.  They are GENERIC functions — never
      // emitted as JVM methods (excluded from method emission, and the
      // call-site monomorphizer cannot infer type args from an unannotated
      // call-result binding) — so the registered erased call
      // (`Std/Core.isErr(Object)Z`) linked against nothing
      // (NoSuchMethodError; hit across the lyric-storage suite).
      if sig.owner == "Std/Core" and args.count == 1 {
        if funcName == "isErr" {
          lowerCallArg(ctx, insns, args[0])
          insns.add(LInstanceof(className = "Std/Core/Result$Err"))
          return JBoolean
        }
        if funcName == "isOk" {
          lowerCallArg(ctx, insns, args[0])
          insns.add(LInstanceof(className = "Std/Core/Result$Ok"))
          return JBoolean
        }
        if funcName == "isSome" {
          lowerCallArg(ctx, insns, args[0])
          insns.add(LInstanceof(className = "Std/Core/Option$Some"))
          return JBoolean
        }
        if funcName == "isNone" {
          lowerCallArg(ctx, insns, args[0])
          insns.add(LInstanceof(className = "Std/Core/Option$None"))
          return JBoolean
        }
      }
      if sig.owner == "Std/Core" and args.count == 2 {
        if funcName == "unwrapOr" {
          // Generic Option unwrap via the synthesised `__lyricUnwrapOr`
          // helper (see codegen 06's emission note) — the erased-call
          // descriptor otherwise references the phantom `Std/Core/T`.
          val uoT0 = lowerCallArg(ctx, insns, args[0])
          boxIfNeeded(insns, uoT0)
          val uoT1 = lowerCallArg(ctx, insns, args[1])
          boxIfNeeded(insns, uoT1)
          val uoPs: List[JvmType] = newList()
          uoPs.add(JRef(className = "java/lang/Object"))
          uoPs.add(JRef(className = "java/lang/Object"))
          insns.add(
            LInvokestatic(
              owner = ctx.pkgName,
              name = "__lyricUnwrapOr",
              params = uoPs,
              ret = JRef(className = "java/lang/Object")
            )
          )
          return JRef(className = "java/lang/Object")
        }
      }
      val callArgs = reorderAndFillJvmArgs(sig, args)
      // `out`/`inout` parameters need holder-array wrapping + write-back (#1763).
      if anyHolderMode(sig.paramModes) {
        return lowerStaticCallWithHolders(ctx, insns, funcName, sig, callArgs)
      }
      // A primitive array (e.g. a JDK `getBytes()` / `digest()` `byte[]`, or
      // any other primitive array) passed where a Lyric `slice[T]`
      // (`[Ljava/lang/Object;`) is declared is boxed element-by-element by
      // `emitBoxPrimitiveArray` — a BRANCHING conversion, and the
      // StackMapTable declares an empty operand stack at every branch
      // target, so it must never run with earlier arguments already
      // stacked.  When any parameter is slice-shaped (a reference array),
      // lower and coerce EVERY argument into a temp slot first (the
      // constructor-path pattern), then reload in order (hit by
      // `hostWriteAllBytes(path, stringToUtf8Bytes(s))` in Std.FileHost).
      if anyRefArrayParam(sig.params) {
        val argSlots: List[Int] = newList()
        var si = 0
        while si < callArgs.count {
          val aTy = lowerCallArg(ctx, insns, callArgs[si])
          var slotTy = aTy
          if si < sig.params.count {
            if isPrimitiveArrayToObjectArray(aTy, sig.params[si]) {
              match aTy {
                case JArray(fe) -> emitBoxPrimitiveArray(ctx, insns, fe)
                case _ -> ()
              }
            } else {
              coerceArgTo(insns, aTy, sig.params[si])
            }
            slotTy = sig.params[si]
          }
          val s = allocSlot(ctx, "__arg_stash_" + freshLabel(ctx), slotTy)
          emitStore(insns, s, slotTy)
          argSlots.add(s)
          si = si + 1
        }
        var li = 0
        while li < argSlots.count {
          val lTy = if li < sig.params.count { sig.params[li] } else { JRef(className = "java/lang/Object") }
          emitLoad(insns, argSlots[li], lTy)
          li = li + 1
        }
        insns.add(LInvokestatic(owner = sig.owner, name = funcName, params = sig.params, ret = sig.ret))
        return sig.ret
      }
      var ai = 0
      while ai < callArgs.count {
        val aTy = lowerCallArg(ctx, insns, callArgs[ai])
        if ai < sig.params.count {
          coerceArgTo(insns, aTy, sig.params[ai])
        }
        ai = ai + 1
      }
      insns.add(LInvokestatic(owner = sig.owner, name = funcName, params = sig.params, ret = sig.ret))
      return sig.ret
    }
    case None -> ()
  }

  // Fallback (unregistered name): lower args as-is and derive the owner from a
  // qualified path when present, else assume the current package.  Return type
  // is unknown, so use Object.  Reached only for names absent from every
  // compiled package — i.e. genuinely unresolved references, which fail loudly
  // at JVM link time.
  val paramTys: List[JvmType] = newList()
  var i = 0
  while i < args.count {
    val aTy = lowerCallArg(ctx, insns, args[i])
    paramTys.add(aTy)
    i = i + 1
  }
  val owner = if path.segments.count > 1 {
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

  insns.add(
    LInvokestatic(owner = owner, name = funcName, params = paramTys, ret = JRef(className = "java/lang/Object"))
  )
  JRef(className = "java/lang/Object")
}

// Lower a method call on a receiver: recv.memberName(args...).
// Numeric / character primitives accepted by the conversion intrinsics
// (`.toInt()` etc., #1901).  `JBoolean` is excluded — not a numeric type.
func isNumericJvm(ty: in JvmType): Bool {
  match ty {
    case JByte -> true
    case JChar -> true
    case JShort -> true
    case JInt -> true
    case JLong -> true
    case JFloat -> true
    case JDouble -> true
    case _ -> false
  }
}

// Zero-extend a signed JVM `byte` to its unsigned Lyric value (`& 0xFF`): Lyric
// `Byte` is 0..255 but a JVM `byte` sign-extends on reload (200 -> -56), so every
// Byte-source widening masks first to match MSIL's `conv.u1` (#4855, cf. #4551).
func maskByteUnsigned(insns: in List[LInsn]): Unit {
  insns.add(LIconst(v = 255))
  insns.add(LIand)
}

// Normalise a numeric value already on the stack to an `int` (JVM `I`).  Char /
// short / int already occupy an int slot (no-op); long / float / double narrow
// with the matching conversion opcode; a Byte source zero-extends (`& 0xFF`).
func emitToIntJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JLong -> insns.add(LL2i)
    case JFloat -> insns.add(LF2i)
    case JDouble -> insns.add(LD2i)
    case JByte -> maskByteUnsigned(insns)
    case _ -> {
    }
  }   // JChar / JShort / JInt are int-on-stack
}

func emitToLongJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JLong -> {
    }            // already long
    case JFloat -> insns.add(LF2l)
    case JDouble -> insns.add(LD2l)
    case JByte -> {
      maskByteUnsigned(insns)
      insns.add(LI2l)
    }
    case _ -> insns.add(LI2l)
  }   // int-like → long
}

func emitToDoubleJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JDouble -> {
    }            // already double
    case JLong -> insns.add(LL2d)
    case JFloat -> insns.add(LF2d)
    case JByte -> {
      maskByteUnsigned(insns)
      insns.add(LI2d)
    }
    case _ -> insns.add(LI2d)
  }   // int-like → double
}

// ── slice[T] non-mutating ops: .append/.concat/.slice (#5244) ──────────────
// `slice[T]` (`JArray(elemTy)`) is always a genuine fixed-size JVM array —
// unlike the MSIL backend, there is no second (List-backed) runtime
// representation to reconcile — so building a new slice is just a fresh
// `newarray`/`anewarray` plus `System.arraycopy` bulk copies; no per-element
// read loop is needed.
// Store an `Int` constant into a fresh local slot, returning the slot.
func storeIntConstSlotJvm(ctx: in FuncCtx, insns: in List[LInsn], v: in Int): Int {
  val slot = allocSlot(ctx, "__sliceconst_" + toString(ctx.slotTicker.count), JInt)
  insns.add(LIconst(v = v))
  emitStore(insns, slot, JInt)
  slot
}

// `System.arraycopy(src, srcPos, dest, destPos, length): void`.
func emitArraycopyJvm(
  insns: in List[LInsn],
  srcSlot: in Int,
  srcTy: in JvmType,
  srcPosSlot: in Int,
  dstSlot: in Int,
  dstTy: in JvmType,
  dstPosSlot: in Int,
  lenSlot: in Int,
): Unit {
  val objTy = JRef(className = "java/lang/Object")
  emitLoad(insns, srcSlot, srcTy)
  emitLoad(insns, srcPosSlot, JInt)
  emitLoad(insns, dstSlot, dstTy)
  emitLoad(insns, dstPosSlot, JInt)
  emitLoad(insns, lenSlot, JInt)
  val acPs: List[JvmType] = newList()
  acPs.add(objTy)
  acPs.add(JInt)
  acPs.add(objTy)
  acPs.add(JInt)
  acPs.add(JInt)
  insns.add(LInvokestatic(owner = "java/lang/System", name = "arraycopy", params = acPs, ret = JVoid))
}

// The element type of a slice receiver, defaulting to `Object` for a non-
// `JArray` receiver (never reached in practice — `.append`/`.concat`/`.slice`
// are exclusively slice ops, dispatched by name in `lowerMethodCall` below).
func sliceElemTypeJvm(recvTy: in JvmType): JvmType {
  match recvTy {
    case JArray(e) -> e
    case _ -> JRef(className = "java/lang/Object")
  }
}

// `xs.append(x)`: a new slice one element longer than `xs`, `x` at the end.
func lowerSliceAppendJvm(ctx: in FuncCtx, insns: in List[LInsn], recvTy: in JvmType, args: in List[CallArg]): JvmType {
  val e = sliceElemTypeJvm(recvTy)
  val recvSlot = allocSlot(ctx, "__sliceapp_recv_" + toString(ctx.slotTicker.count), recvTy)
  emitStore(insns, recvSlot, recvTy)
  emitLoad(insns, recvSlot, recvTy)
  insns.add(LArraylength)
  val cntSlot = allocSlot(ctx, "__sliceapp_cnt_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, cntSlot, JInt)
  // `append`'s builtinMember TyFunction signature (typechecker_exprs.l) hard-
  // requires exactly 1 arg (T0042 otherwise); the `else` below is an
  // unreachable defensive default, matching the MSIL lowering's comment.
  val argTy = if args.count > 0 {
    lowerCallArg(ctx, insns, args[0])
  } else {
    insns.add(LAconstNull)
    JRef(className = "java/lang/Object")
  }
  coerceArgTo(insns, argTy, e)
  val argSlot = allocSlot(ctx, "__sliceapp_arg_" + toString(ctx.slotTicker.count), e)
  emitStore(insns, argSlot, e)
  val zeroSlot = storeIntConstSlotJvm(ctx, insns, 0)
  emitLoad(insns, cntSlot, JInt)
  insns.add(LIconst(v = 1))
  insns.add(LIadd)
  emitNewarray(insns, e)
  val newSlot = allocSlot(ctx, "__sliceapp_new_" + toString(ctx.slotTicker.count), JArray(elem = e))
  emitStore(insns, newSlot, JArray(elem = e))
  emitArraycopyJvm(insns, recvSlot, recvTy, zeroSlot, newSlot, JArray(elem = e), zeroSlot, cntSlot)
  emitLoad(insns, newSlot, JArray(elem = e))
  emitLoad(insns, cntSlot, JInt)
  emitLoad(insns, argSlot, e)
  emitArrayStore(insns, e)
  emitLoad(insns, newSlot, JArray(elem = e))
  JArray(elem = e)
}

// `xs.concat(ys)`: a new slice holding every element of `xs` then every
// element of `ys`.
func lowerSliceConcatJvm(ctx: in FuncCtx, insns: in List[LInsn], recvTy: in JvmType, args: in List[CallArg]): JvmType {
  val e = sliceElemTypeJvm(recvTy)
  val recvSlot = allocSlot(ctx, "__sliceccat_recv_" + toString(ctx.slotTicker.count), recvTy)
  emitStore(insns, recvSlot, recvTy)
  emitLoad(insns, recvSlot, recvTy)
  insns.add(LArraylength)
  val cntSlot = allocSlot(ctx, "__sliceccat_cnt_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, cntSlot, JInt)
  // See the matching comment in `lowerSliceAppendJvm`: `concat`'s signature
  // hard-requires exactly 1 arg, so this `else` is unreachable.
  val otherTyRaw = if args.count > 0 {
    lowerCallArg(ctx, insns, args[0])
  } else {
    insns.add(LAconstNull)
    JArray(elem = e)
  }
  // Unlike a normal function call, this dispatch bypasses the usual call-arg
  // `coerceArgTo` against a declared param type — so an inline `slice[T]`
  // literal argument (still a `java/util/ArrayList` at this point, per the
  // `EList` lowering) must be explicitly converted to a genuine array here,
  // or `arraylength`/`arraycopy` below fault on a non-array reference.
  coerceArgTo(insns, otherTyRaw, JArray(elem = e))
  val otherTy = JArray(elem = e)
  val otherSlot = allocSlot(ctx, "__sliceccat_other_" + toString(ctx.slotTicker.count), otherTy)
  emitStore(insns, otherSlot, otherTy)
  emitLoad(insns, otherSlot, otherTy)
  insns.add(LArraylength)
  val otherCntSlot = allocSlot(ctx, "__sliceccat_ocnt_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, otherCntSlot, JInt)
  val zeroSlot = storeIntConstSlotJvm(ctx, insns, 0)
  emitLoad(insns, cntSlot, JInt)
  emitLoad(insns, otherCntSlot, JInt)
  insns.add(LIadd)
  emitNewarray(insns, e)
  val newSlot = allocSlot(ctx, "__sliceccat_new_" + toString(ctx.slotTicker.count), JArray(elem = e))
  emitStore(insns, newSlot, JArray(elem = e))
  emitArraycopyJvm(insns, recvSlot, recvTy, zeroSlot, newSlot, JArray(elem = e), zeroSlot, cntSlot)
  emitArraycopyJvm(insns, otherSlot, otherTy, zeroSlot, newSlot, JArray(elem = e), cntSlot, otherCntSlot)
  emitLoad(insns, newSlot, JArray(elem = e))
  JArray(elem = e)
}

// `xs.slice(start, end)`: a new slice holding the half-open sub-range
// `[start, end)`.  `start < 0`, `end < start`, or `end > xs.length` all throw
// explicitly with the same panic convention (#5252) — otherwise an
// out-of-range `start`/`end` would fall through to `System.arraycopy` and
// surface as a raw `ArrayIndexOutOfBoundsException` instead of the project's
// user-panic convention, and disagree with what MSIL's `IList`-backed path
// would fault on first.
func lowerSliceSliceJvm(ctx: in FuncCtx, insns: in List[LInsn], recvTy: in JvmType, args: in List[CallArg]): JvmType {
  val e = sliceElemTypeJvm(recvTy)
  val recvSlot = allocSlot(ctx, "__slicesub_recv_" + toString(ctx.slotTicker.count), recvTy)
  emitStore(insns, recvSlot, recvTy)
  if args.count > 0 {
    val _ = lowerCallArg(ctx, insns, args[0])
  } else {
    insns.add(LIconst(v = 0))
  }
  val startSlot = allocSlot(ctx, "__slicesub_start_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, startSlot, JInt)
  if args.count > 1 {
    val _ = lowerCallArg(ctx, insns, args[1])
  } else {
    insns.add(LIconst(v = 0))
  }
  val endSlot = allocSlot(ctx, "__slicesub_end_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, endSlot, JInt)
  val lengthSlot = allocSlot(ctx, "__slicesub_len_" + toString(ctx.slotTicker.count), JInt)
  emitLoad(insns, recvSlot, recvTy)
  insns.add(LArraylength)
  emitStore(insns, lengthSlot, JInt)
  emitLoad(insns, endSlot, JInt)
  emitLoad(insns, startSlot, JInt)
  insns.add(LIsub)
  val cntSlot = allocSlot(ctx, "__slicesub_cnt_" + toString(ctx.slotTicker.count), JInt)
  emitStore(insns, cntSlot, JInt)
  val badL = freshLabel(ctx)
  val okL = freshLabel(ctx)
  emitLoad(insns, startSlot, JInt)
  insns.add(LIflt(label = badL))
  emitLoad(insns, endSlot, JInt)
  emitLoad(insns, startSlot, JInt)
  insns.add(LIfIcmplt(label = badL))
  emitLoad(insns, endSlot, JInt)
  emitLoad(insns, lengthSlot, JInt)
  insns.add(LIfIcmpgt(label = badL))
  insns.add(LGoto(label = okL))
  insns.add(LLabel(name = badL))
  insns.add(LPushString(s = "slice(start, end) requires 0 <= start <= end <= length"))
  emitPanicFromStack(ctx, insns)
  insns.add(LLabel(name = okL))
  val zeroSlot = storeIntConstSlotJvm(ctx, insns, 0)
  emitLoad(insns, cntSlot, JInt)
  emitNewarray(insns, e)
  val newSlot = allocSlot(ctx, "__slicesub_new_" + toString(ctx.slotTicker.count), JArray(elem = e))
  emitStore(insns, newSlot, JArray(elem = e))
  emitArraycopyJvm(insns, recvSlot, recvTy, startSlot, newSlot, JArray(elem = e), zeroSlot, cntSlot)
  emitLoad(insns, newSlot, JArray(elem = e))
  JArray(elem = e)
}

func lowerMethodCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  recv: in Expr,
  memberName: in String,
  args: in List[CallArg],
): JvmType {
  // Auto-FFI: a call whose receiver is an extern-type name (e.g. `JMath` for
  // `extern type JMath = "java.lang.Math"`) is a static method on the Java
  // class, not an instance dispatch.  `A.b(args)` parses as
  // `EMember(EPath{A}, b)`, so the static auto-FFI fast path must live here —
  // resolve the overload from JDK metadata and emit a typed invokestatic
  // rather than lowering the type name as a value (which yields a bogus
  // `java/lang/Object.b` guess).  Mirrors `lowerMethodCallMsil`.
  match recv.kind {
    case EPath(path) -> {
      // The Lyric dot-named registration is checked FIRST: the imported-type
      // seed (docs/44 m-58) put every bundled package's declared types into
      // `externTypes`, so `ParseError.message(e)` — a dot-named FUNCTION on
      // Std.Errors' union — otherwise resolved as a static JDK call on
      // "Std.Errors.ParseError" and panicked in metadata resolution
      // (#4799; Std.Parse was J003-skipped by exactly this).  A genuine
      // extern JDK type never has a dot-named funcSigs registration, so the
      // FFI fast path below is unaffected for real externs.
      // J3 M-3: this same key also serves `AppWire.bootstrap()` /
      // `AppWire.<exposed>()` — a static call on the wire factory class.
      match mapGet(ctx.funcSigs, lastSegment(path) + "." + memberName) {
        case Some(sig) -> {
          var wi = 0
          while wi < args.count {
            val aTy = lowerCallArg(ctx, insns, args[wi])
            if wi < sig.params.count {
              coerceArgTo(insns, aTy, sig.params[wi])
            }
            wi = wi + 1
          }
          insns.add(LInvokestatic(owner = sig.owner, name = memberName, params = sig.params, ret = sig.ret))
          return sig.ret
        }
        case None -> ()
      }
      match mapGet(ctx.externTypes, lastSegment(path)) {
        case Some(javaFqn) -> return lowerAutoFfiStaticCall(ctx, insns, javaFqn, memberName, args)
        case None -> ()
      }
    }
    case _ -> ()
  }
  val recvTy = lowerExpr(ctx, insns, recv)
  // `shr` is arithmetic (ISHR/LSHR — sign-replicating); Lyric's Int/Long/
  // Byte are signed and the JVM backend has no unsigned integer type, so the
  // logical-shift opcodes (IUSHR/LUSHR) are not reachable here.  Byte uses
  // the int opcodes (JVM byte arithmetic is int-width).  Long shifts take an
  // int shift count per the JVM spec, matching `.shl(n: Int)` / `.shr(n: Int)`.
  if (memberName == "and" or memberName == "or" or memberName == "xor" or memberName == "shl" or memberName == "shr") and args.count == 1 {
    lowerCallArg(ctx, insns, args[0])
    val isLong = match recvTy {
      case JLong -> true
      case JInt -> false
      // Byte uses int-width opcodes on JVM (byte arithmetic is int-width per JVMS §2.11.1).
      case JByte -> false
      case _ -> panic("Jvm.Codegen: bitwise op on non-integer JVM type (expected JInt, JByte, or JLong)")
      // Defense-in-depth: the type checker should reject bitwise ops on non-integer
      // types before reaching codegen, but emit a clear panic rather than silently
      // mis-emitting int opcodes for a float/ref receiver (#1615).
    }
    if memberName == "and" {
      insns.add(if isLong { LLand } else { LIand })
    } else if memberName == "or" {
      insns.add(if isLong { LLor } else { LIor })
    } else if memberName == "xor" {
      insns.add(if isLong { LLxor } else { LIxor })
    } else if memberName == "shl" {
      insns.add(if isLong { LLshl } else { LIshl })
    } else {
      insns.add(if isLong { LLshr } else { LIshr })
    }
    return recvTy
  }
  // Numeric / character primitive conversion intrinsics (#1901): `x.toInt()`,
  // `b.toLong()`, etc.  Mirrors the MSIL `conv.*` path.  On the JVM, byte / char
  // / short all occupy an int operand slot, so the int-target conversions are a
  // no-op from an int-like source; `toByte` / `toChar` first normalise to int,
  // then narrow.  `toFloat` is intentionally absent (parity with the type
  // checker, which does not offer it).
  if (memberName == "toInt" or memberName == "toLong" or memberName == "toByte" or memberName == "toChar" or memberName == "toDouble") and args.count == 0 and isNumericJvm(recvTy) {
    if memberName == "toLong" {
      emitToLongJvm(insns, recvTy)
      return JLong
    } else if memberName == "toDouble" {
      emitToDoubleJvm(insns, recvTy)
      return JDouble
    } else if memberName == "toByte" {
      // Lyric `Byte` is UNSIGNED (the MSIL backend uses `conv.u1` / U1, range
      // 0..255).  The JVM `i2b` opcode produces a *signed* byte (-128..127) and
      // sign-extends on reload, which would diverge from MSIL for values 128..255
      // (e.g. `300.toByte()` is 44 on both, but `200.toByte()` must stay 200, not
      // -56).  Mask to the low 8 bits to reproduce the unsigned result.
      emitToIntJvm(insns, recvTy)
      insns.add(LIconst(v = 255))
      insns.add(LIand)
      return JByte
    } else if memberName == "toChar" {
      emitToIntJvm(insns, recvTy)
      insns.add(LI2c)
      return JChar
    } else {
      emitToIntJvm(insns, recvTy)
      return JInt
    }
  }
  // `x.toString()` on a primitive receiver: box and call Object.toString.
  // Without this the value reaches the generic fallback (or a string-concat
  // append(String)) still unboxed and fails JVM verification ("Bad type on
  // operand stack").  Reference receivers fall through to the instance
  // auto-FFI / registry paths below, which resolve the real toString.
  // Note: Java's Double.toString renders a trailing ".0" for whole values
  // where .NET renders none — a documented cross-target formatting
  // divergence, not a correctness gap.
  val recvIsBoxablePrim = isNumericJvm(recvTy) or (match recvTy { case JBoolean -> true; case _ -> false })
  if memberName == "toString" and args.count == 0 and recvIsBoxablePrim {
    // String.valueOf(<primitive>) — no boxing, unlike Object.toString on a
    // boxed wrapper (keeps the closure zero-overhead boxing gate flat).
    val prTsPs: List[JvmType] = newList()
    prTsPs.add(stringValueOfParam(recvTy))
    insns.add(
      LInvokestatic(
        owner = "java/lang/String",
        name = "valueOf",
        params = prTsPs,
        ret = JRef(className = "java/lang/String")
      )
    )
    return JRef(className = "java/lang/String")
  }
  // String predicate methods return `boolean` (Z), not Object.  Emitting them
  // through the generic path below (ret = Object) makes a following `ifeq`/`ifne`
  // pop an Object and fail verification ("Bad type on operand stack").  Pin the
  // precise descriptor here.  `contains` takes a CharSequence (a String arg is
  // assignable); `startsWith`/`endsWith` take a String.
  val isStringRecv = match recvTy { case JRef(c) -> c == "java/lang/String"; case _ -> false }
  if isStringRecv and args.count == 1 and (memberName == "contains" or memberName == "startsWith" or memberName == "endsWith") {
    lowerCallArg(ctx, insns, args[0])
    val ps: List[JvmType] = newList()
    if memberName == "contains" {
      ps.add(JRef(className = "java/lang/CharSequence"))
    } else {
      ps.add(JRef(className = "java/lang/String"))
    }
    insns.add(LInvokevirtual(owner = "java/lang/String", name = memberName, params = ps, ret = JBoolean))
    return JBoolean
  }

  // String instance methods with non-Object returns (#1585).  The generic
  // fallback below emits ret=Object, which fails JVM verification whenever the
  // value is used as a typed operand (e.g. an `indexOf` result compared to 0
  // via `iflt`/`ifge`, or `trim` passed to a String parameter).  Pin the exact
  // JVM descriptor here.  Java spellings:
  //   trim → strip()  (Unicode-aware; Java 11+, JDK 21 baseline)
  //   trimStart → stripLeading()  (Java 11+)
  //   trimEnd  → stripTrailing()  (Java 11+)
  //   toUpper  → toUpperCase()
  //   toLower  → toLowerCase()
  //   length   → length()  (returns int)
  //   indexOf / lastIndexOf(String) → indexOf / lastIndexOf(String) → int
  //   replace(old, new) → replace(CharSequence, CharSequence) → String
  if isStringRecv and args.count == 0 and (memberName == "trim" or memberName == "trimStart" or memberName == "trimEnd" or memberName == "toUpper" or memberName == "toLower" or memberName == "length") {
    val noPs: List[JvmType] = newList()
    val javaName = if memberName == "trim" {
      "strip"
    } else if memberName == "trimStart" {
      "stripLeading"
    } else if memberName == "trimEnd" {
      "stripTrailing"
    } else if memberName == "toUpper" {
      "toUpperCase"
    } else if memberName == "toLower" {
      "toLowerCase"
    } else {
      "length"
    }
    val retT: JvmType = if memberName == "length" { JInt } else { JRef(className = "java/lang/String") }
    insns.add(LInvokevirtual(owner = "java/lang/String", name = javaName, params = noPs, ret = retT))
    return retT
  }
  if isStringRecv and args.count == 1 and (memberName == "indexOf" or memberName == "lastIndexOf") {
    lowerCallArg(ctx, insns, args[0])
    val ps1: List[JvmType] = newList()
    ps1.add(JRef(className = "java/lang/String"))
    insns.add(LInvokevirtual(owner = "java/lang/String", name = memberName, params = ps1, ret = JInt))
    return JInt
  }
  if isStringRecv and args.count == 2 and memberName == "replace" {
    lowerCallArg(ctx, insns, args[0])
    lowerCallArg(ctx, insns, args[1])
    val ps2: List[JvmType] = newList()
    ps2.add(JRef(className = "java/lang/CharSequence"))
    ps2.add(JRef(className = "java/lang/CharSequence"))
    insns.add(
      LInvokevirtual(
        owner = "java/lang/String",
        name = "replace",
        params = ps2,
        ret = JRef(className = "java/lang/String")
      )
    )
    return JRef(className = "java/lang/String")
  }
  // Lyric's two-arg `s.substring(start, count)` takes a LENGTH (matching .NET
  // `String.Substring(start, length)` and `Std.String.substring`), but Java's
  // `substring(int, int)` takes an END INDEX.  Letting it fall to the auto-FFI
  // pass-through silently reinterprets the count as an end index (wrong result
  // or StringIndexOutOfBoundsException — this broke the kernel's
  // `parseArgString`).  Translate: begin, begin + count.  The one-arg form has
  // identical semantics on both platforms and passes through auto-FFI.
  if isStringRecv and args.count == 2 and memberName == "substring" {
    val startTy = lowerCallArg(ctx, insns, args[0])
    coerceArgTo(insns, startTy, JInt)
    val subStartSlot = allocSlot(ctx, "__substr_start_" + freshLabel(ctx), JInt)
    emitStore(insns, subStartSlot, JInt)
    emitLoad(insns, subStartSlot, JInt)
    val countTy = lowerCallArg(ctx, insns, args[1])
    coerceArgTo(insns, countTy, JInt)
    emitLoad(insns, subStartSlot, JInt)
    insns.add(LIadd)
    val subPs: List[JvmType] = newList()
    subPs.add(JInt)
    subPs.add(JInt)
    insns.add(
      LInvokevirtual(
        owner = "java/lang/String",
        name = "substring",
        params = subPs,
        ret = JRef(className = "java/lang/String")
      )
    )
    return JRef(className = "java/lang/String")
  }

  // HashMap intrinsics: Lyric Map[K,V] maps to java/util/HashMap on JVM.
  // BCL Dictionary[K,V] uses `Add(K,V)` / `Remove(K)` / `ContainsKey(K)` /
  // `Count`, but HashMap spells them `put(K,V)` / `remove(K)` / `containsKey(K)`
  // / `size()`.  Emit the correct invokevirtual before falling through to the
  // generic auto-FFI path, which would panic on a missing `add` method.
  val isHashMapRecv = match recvTy { case JRef(c) -> c == "java/util/HashMap"; case _ -> false }
  if isHashMapRecv {
    val objTy = JRef(className = "java/lang/Object")
    if memberName == "add" and args.count == 2 {
      val kPs: List[JvmType] = newList()
      kPs.add(objTy)
      kPs.add(objTy)
      // Box primitive keys/values: put(Object, Object) with a raw int on the
      // stack fails verification ("Type integer ... not assignable to
      // 'java/lang/Object'").
      val kTy = lowerCallArg(ctx, insns, args[0])
      boxIfNeeded(insns, kTy)
      val vTy = lowerCallArg(ctx, insns, args[1])
      boxIfNeeded(insns, vTy)
      insns.add(LInvokevirtual(owner = "java/util/HashMap", name = "put", params = kPs, ret = objTy))
      insns.add(LPop)
      return JVoid
    } else if memberName == "remove" and args.count == 1 {
      val rPs: List[JvmType] = newList()
      rPs.add(objTy)
      val rkTy = lowerCallArg(ctx, insns, args[0])
      boxIfNeeded(insns, rkTy)
      insns.add(LInvokevirtual(owner = "java/util/HashMap", name = "remove", params = rPs, ret = objTy))
      insns.add(LPop)
      return JVoid
    } else if memberName == "containsKey" and args.count == 1 {
      val ckPs: List[JvmType] = newList()
      ckPs.add(objTy)
      val ckTy = lowerCallArg(ctx, insns, args[0])
      boxIfNeeded(insns, ckTy)
      insns.add(LInvokevirtual(owner = "java/util/HashMap", name = "containsKey", params = ckPs, ret = JBoolean))
      return JBoolean
    }
  }

  // `xs.removeAt(i)` on a List receiver — including one erased to `Object`
  // (same erased-receiver leniency as `.toArray()` above).  Lyric's
  // `List[T].removeAt(index: Int): Unit` (MSIL: `List<object>.RemoveAt(int32)`)
  // has no same-named JDK counterpart: `java.util.ArrayList` spells
  // index-based removal `remove(int)` — and critically, `ArrayList` also
  // overloads `remove(Object)` (value-based removal), so the arg must reach
  // the call site as a raw (unboxed) `int` to select the index-based overload
  // rather than autoboxing into the `Object` one.  Emitted before the generic
  // auto-FFI path, which panics on a missing `removeAt` method (first hit by
  // `Jobs.InProcessJobScheduler.cancel`'s `self.queue.removeAt(i)`, #5382
  // follow-up — every other List mutator name happens to already match its
  // JDK method 1:1 except this one).
  if memberName == "removeAt" and args.count == 1 {
    val isListRecv = match recvTy {
      case JRef(c) -> c == "java/lang/Object" or c == "java/util/ArrayList" or c == "java/util/List"
      case _ -> false
    }
    if isListRecv {
      insns.add(LCheckcast(className = "java/util/ArrayList"))
      val idxTy = lowerCallArg(ctx, insns, args[0])
      coerceArgTo(insns, idxTy, JInt)
      val raPs: List[JvmType] = newList()
      raPs.add(JInt)
      insns.add(
        LInvokevirtual(
          owner = "java/util/ArrayList",
          name = "remove",
          params = raPs,
          ret = JRef(className = "java/lang/Object")
        )
      )
      insns.add(LPop)
      return JVoid
    }
  }

  // `xs.toArray()` on a List receiver — including one erased to `Object`
  // (a generic `in List[T]` parameter): the Lyric runtime List is always
  // `java/util/ArrayList`, so checkcast + `toArray()[Ljava/lang/Object;`
  // is exact.  Same erased-receiver intrinsic precedent as `.count` →
  // `size()`.  Without this, an Object-typed receiver reached instance
  // auto-FFI resolution, which panics (`Object` has no `toArray`) — hit by
  // `Std.File.writeBytes`' `bytes.toArray()`.
  if memberName == "toArray" and args.count == 0 {
    val isListRecv = match recvTy {
      case JRef(c) -> c == "java/lang/Object" or c == "java/util/ArrayList" or c == "java/util/List"
      case _ -> false
    }
    if isListRecv {
      insns.add(LCheckcast(className = "java/util/ArrayList"))
      val taPs: List[JvmType] = newList()
      insns.add(
        LInvokevirtual(
          owner = "java/util/ArrayList",
          name = "toArray",
          params = taPs,
          ret = JArray(elem = JRef(className = "java/lang/Object"))
        )
      )
      return JArray(elem = JRef(className = "java/lang/Object"))
    }
  }

  // `.append`/`.concat`/`.slice` (#5244): exclusively slice ops, so dispatch
  // by name against a genuine `JArray` receiver before any auto-FFI /
  // record-field fallback gets a chance to mis-resolve them.
  match recvTy {
    case JArray(_) -> {
      if memberName == "append" and args.count == 1 {
        return lowerSliceAppendJvm(ctx, insns, recvTy, args)
      } else if memberName == "concat" and args.count == 1 {
        return lowerSliceConcatJvm(ctx, insns, recvTy, args)
      } else if memberName == "slice" and args.count == 2 {
        return lowerSliceSliceJvm(ctx, insns, recvTy, args)
      }
    }
    case _ -> ()
  }

  // Instance auto-FFI: when the receiver is a JRef to a JDK class (returned
  // by a prior static auto-FFI call, e.g. JInteger.valueOf(42).toString()),
  // resolve the instance method from JDK metadata and emit a correctly-typed
  // invokevirtual.  Receiver is already on the stack from lowerExpr above.
  match recvTy {
    case JRef(cls) -> {
      val fqn = cls.replace("/", ".")
      match loadClass(ctx.autoFfi, fqn) {
        case Some(ci) -> return lowerAutoFfiInstanceCall(ctx, insns, ci, memberName, args)
        case None -> ()
      }
    }
    case _ -> ()
  }

  // Instance methods of in-package record / protected types / impls: when the
  // receiver class and method are registered under `<class>#<method>` (J3 M-3),
  // emit a precisely-typed `invokevirtual` (args coerced to declared params,
  // real return type) rather than the `()Object` guess — which would mis-resolve
  // a `void` entry like `c.increment()` to a non-existent `()Object` method.
  // When the sig has out/inout params, route through `lowerVirtualCallWithHolders`
  // so the call site wraps/unwraps holder arrays (#1763).
  match recvTy {
    case JRef(cls) -> {
      match mapGet(ctx.funcSigs, cls + "#" + memberName) {
        case Some(sig) -> {
          if anyHolderMode(sig.paramModes) {
            return lowerVirtualCallWithHolders(ctx, insns, cls, memberName, sig, args)
          }
          var ai = 0
          while ai < args.count {
            val aTy = lowerCallArg(ctx, insns, args[ai])
            if ai < sig.params.count {
              coerceArgTo(insns, aTy, sig.params[ai])
            }
            ai = ai + 1
          }
          if sig.isIface {
            // An interface-typed receiver dispatches via `invokeinterface`;
            // `invokevirtual` against an interface owner fails class-load
            // verification (#3687).
            insns.add(
              LInvokeinterface(
                owner = cls,
                name = memberName,
                params = sig.params,
                ret = sig.ret,
                argCount = 1 + jvmArgSlotCount(sig.params)
              )
            )
          } else {
            insns.add(LInvokevirtual(owner = cls, name = memberName, params = sig.params, ret = sig.ret))
          }
          return sig.ret
        }
        case None -> ()
      }
      // Synthesized free functions callable as instance methods (#1507):
      // @derive(Equals/Hash/Show/Ord) appends free functions TypeName.method(self, args...)
      // registered in funcSigs as `cls + "." + memberName` (matching the qkey in
      // collectFileSigs: owner + "/" + decl.name).  The receiver is already on the stack
      // as arg 0 (self); the remaining args correspond to sig.params[1..].
      // lowerFunc strips the "TypeName." prefix from decl.name (JVMS §4.2.2 forbids dots
      // in unqualified names), so the JVM classfile method name is just memberName.
      match mapGet(ctx.funcSigs, cls + "." + memberName) {
        case Some(sig) -> {
          var ai = 0
          while ai < args.count {
            val aTy = lowerCallArg(ctx, insns, args[ai])
            if (ai + 1) < sig.params.count {
              coerceArgTo(insns, aTy, sig.params[ai + 1])
            }
            ai = ai + 1
          }
          insns.add(LInvokestatic(owner = sig.owner, name = memberName, params = sig.params, ret = sig.ret))
          return sig.ret
        }
        case None -> ()
      }
    }
    case _ -> ()
  }

  val paramTys: List[JvmType] = newList()
  var i = 0
  while i < args.count {
    val aTy = lowerCallArg(ctx, insns, args[i])
    paramTys.add(aTy)
    i = i + 1
  }
  match recvTy {
    case JRef(cls) -> {
      insns.add(
        LInvokevirtual(owner = cls, name = memberName, params = paramTys, ret = JRef(className = "java/lang/Object"))
      )
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
    case JInt -> JInt
    case JLong -> JLong
    case JDouble -> JDouble
    case JBoolean -> JBoolean
    case JChar -> JChar
    case JVoid -> JRef(className = "java/lang/String")
    case _ -> JRef(className = "java/lang/String")
  }
}
