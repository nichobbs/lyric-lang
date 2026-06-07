//! jvm/codegen_4_calls.l — Jvm.Codegen: call lowering.
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

  val resultSlot = allocSlot(
    ctx,
    "__catch_result_" + toString(ctx.slotTicker.count),
    JRef(className = "java/lang/Object")
  )
  val exSlot = allocSlot(ctx, "__catch_ex_" + toString(ctx.slotTicker.count), JRef(className = "java/lang/Object"))

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

      val isStatic = isStaticExternByName(decl.name)
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
        case Some(te) -> if wrapResult { extractResultValueType(te, ctx.pkgName) } else { typeExprToJvm(te, ctx.pkgName) }
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
    case CAPositional(e) -> lowerExpr(ctx, insns, e)
    case CANamed(_, e, _) -> lowerExpr(ctx, insns, e)
  }
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
    insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      // Convert to String if needed for println.
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "println", params = printPs, ret = JVoid))
    } else {
      val emptyPs: List[JvmType] = newList()
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "println", params = emptyPs, ret = JVoid))
    }
    JVoid
  } else if funcName == "print" {
    insns.add(LGetstatic(owner = "java/lang/System", name = "out", t = JRef(className = "java/io/PrintStream")))
    if args.count > 0 {
      val argTy = lowerCallArg(ctx, insns, args[0])
      val printPs: List[JvmType] = newList()
      printPs.add(printArgType(argTy))
      insns.add(LInvokevirtual(owner = "java/io/PrintStream", name = "print", params = printPs, ret = JVoid))
    } else {
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
  } else if funcName == "mapGet" {
    // mapGet(map, key) → Option[V]
    if args.count >= 2 {
      lowerCallArg(ctx, insns, args[0])
      lowerCallArg(ctx, insns, args[1])
      boxIfNeeded(insns, JInt)  // key might be primitive
      val mgPs: List[JvmType] = newList()
      mgPs.add(JRef(className = "java/lang/Object"))
      insns.add(
        LInvokevirtual(owner = "java/util/HashMap", name = "get", params = mgPs, ret = JRef(className = "java/lang/Object"))
      )
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

// Emit a widening numeric coercion instruction from `fromDesc` to `toDesc`.
// No-op when the types are identical or the widening is handled at the JVM
// reference level (reference → Object).
func emitFfiCoerce(insns: in List[LInsn], fromDesc: in String, toDesc: in String): Unit {
  if fromDesc == toDesc {
    return ()
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
      match findBestMethod(ci, methodName, argDescs, true) {
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
            emitFfiCoerce(insns, argDescs[j], paramDesc)
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
        emitFfiCoerce(insns, argDescs[j], paramDesc)
        paramJvms.add(descStrToJvmType(paramDesc))
        j = j + 1
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
// Abstract classes are rejected at compile time: emitting `new` for an
// abstract class produces bytecode that throws `InstantiationError` at runtime
// rather than a clear diagnostic (#2215).
func lowerAutoFfiConstructorCall(
  ctx: in FuncCtx, insns: in List[LInsn], ci: in ClassInfo, args: in List[CallArg]
): JvmType {
  if ci.isAbstract {
    val fqn = ci.binaryName.replace("/", ".")
    panic(
      "JVM auto-FFI: cannot construct abstract class '" + fqn +
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
  match findBestConstructor(ci, argDescs) {
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
      insns.add(LNew(className = ci.binaryName))
      insns.add(LDup)
      val paramDescs = parseDescriptorParams(ctor.descriptor)
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
        emitFfiCoerce(insns, argDescs[j], paramDesc)
        paramJvms.add(descStrToJvmType(paramDesc))
        j = j + 1
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
      }
    }
    case JDouble -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Double"))
        insns.add(LUnboxDouble)
      }
    }
    case JFloat -> {
      if fromRef {
        insns.add(LCheckcast(className = "java/lang/Float"))
        insns.add(LUnboxFloat)
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
        insns.add(LCheckcast(className = "java/lang/Byte"))
        insns.add(LUnboxByte)
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
        case JRef(fromCls) -> {
          if not (fromCls == toCls) and not (toCls == "java/lang/Object") {
            insns.add(LCheckcast(className = toCls))
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
      insns.add(LNew(className = className))
      insns.add(LDup)
      val ordered = orderCtorArgs(fields, args)
      val paramTys: List[JvmType] = newList()
      var i = 0
      while i < fields.count {
        val fty = fields[i].ty
        paramTys.add(fty)
        if i < ordered.count {
          val aTy = lowerCallArg(ctx, insns, ordered[i])
          coerceArgTo(insns, aTy, fty)
        } else {
          pushDefaultValue(insns, fty)
        }
        i = i + 1
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

func lowerGeneralStaticCall(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  funcName: in String,
  path: in ModulePath,
  args: in List[CallArg],
): JvmType {
  // Construction: a call whose head names a record or union case lowers to a
  // real `new`/`invokespecial` rather than a (non-existent) static method.
  match mapGet(ctx.ctors, funcName) {
    case Some(cls) -> return lowerConstruction(ctx, insns, cls, args)
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
  val sigOpt = if path.segments.count > 1 {
    val ownerSegs: List[String] = newList()
    var si = 0
    while si < path.segments.count - 1 {
      ownerSegs.add(path.segments[si])
      si = si + 1
    }
    val qkey = joinSegments(ownerSegs, "/") + "/" + funcName
    match mapGet(ctx.funcSigs, qkey) {
      case Some(sig) -> Some(value = sig)
      case None -> mapGet(ctx.funcSigs, funcName)
    }
  } else {
    mapGet(ctx.funcSigs, funcName)
  }
  match sigOpt {
    case Some(sig) -> {
      var ai = 0
      while ai < args.count {
        val aTy = lowerCallArg(ctx, insns, args[ai])
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

// Normalise a numeric value already on the stack to an `int` (JVM `I`).  Byte /
// char / short / int already occupy an int slot (no-op); long / float / double
// narrow with the matching conversion opcode.
func emitToIntJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JLong -> insns.add(LL2i)
    case JFloat -> insns.add(LF2i)
    case JDouble -> insns.add(LD2i)
    case _ -> {
    }
  }   // JByte / JChar / JShort / JInt are int-on-stack
}

func emitToLongJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JLong -> {
    }            // already long
    case JFloat -> insns.add(LF2l)
    case JDouble -> insns.add(LD2l)
    case _ -> insns.add(LI2l)
  }   // int-like → long
}

func emitToDoubleJvm(insns: in List[LInsn], srcTy: in JvmType): Unit {
  match srcTy {
    case JDouble -> {
    }            // already double
    case JLong -> insns.add(LL2d)
    case JFloat -> insns.add(LF2d)
    case _ -> insns.add(LI2d)
  }   // int-like → double
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
