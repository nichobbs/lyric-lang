//! jvm/self_test_b56.l — Stage B56: throw + catch with getMessage().
//!
//! Generates Validator.class (Java 5) with validate(I)V that throws
//! IllegalArgumentException("must be positive") when n <= 0.
//!
//! Main tries validate(-1) in a try/catch, catches the IAE, calls getMessage(),
//! prints the message.
//!
//! Expected output:
//!   must be positive
//!
//! Exercises: new java/lang/IllegalArgumentException, invokespecial <init>(String)V,
//!            athrow, exception handler table, invokevirtual Throwable.getMessage().
package Jvm.SelfTestB56

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeValidatorClassBytes(): List[Byte] {
  val pool = poolNew()
  val iaeClass = poolClass(pool, "java/lang/IllegalArgumentException")
  val iaeInit = poolMethodref(pool, "java/lang/IllegalArgumentException", "<init>", "(Ljava/lang/String;)V")

  // ── validate(I)V ─────────────────────────────────────────────────────────────
  // if n > 0: return
  // else: new IAE("must be positive"); athrow
  val asm = newAssembler(pool)
  emitIload(asm, 0)
  emitIfgt(asm, "DONE")
  emitNew(asm, iaeClass)
  emitDup(asm)
  emitPushString(asm, "must be positive")
  emitInvokespecial(asm, iaeInit)
  emitAthrow(asm)
  emitLabel(asm, "DONE")
  emitReturn(asm)

  // maxStack: new(1)+dup(2)+ldc(3) → invokespecial pops 2 → [1] → athrow pops 1
  val validateCode = assembleCode(asm, 3, 1)
  val validateAttrs: List[Attribute] = newList()
  validateAttrs.add(validateCode)
  val validateMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "validate", "(I)V", validateAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(validateMethod)
  val cf = makeClassWithMethodsV49("Validator", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val validateRef = poolMethodref(pool, "Validator", "validate", "(I)V")
  val getMessage = poolMethodref(pool, "java/lang/Throwable", "getMessage", "()Ljava/lang/String;")
  val iaeClassIdx = poolClass(pool, "java/lang/IllegalArgumentException")

  // Try block code:
  //   iconst_m1 (1 byte, offset 0)
  //   invokestatic validate (3 bytes, offsets 1-3)
  //   return (1 byte, offset 4) ← normal path return
  // TRY region: [0, 4)
  // Handler at offset 5:
  //   astore_1       (1 byte, offset 5) — exception object from stack into slot 1
  //   getstatic sysOut (3 bytes, offset 6-8)
  //   aload_1          (1 byte, offset 9)
  //   invokevirtual getMessage (3 bytes, offset 10-12)
  //   invokevirtual println    (3 bytes, offset 13-15)
  //   return           (1 byte, offset 16)
  val asmTry = newAssembler(pool)
  emitPushInt(asmTry, -1)
  // iconst_m1 (1 byte)
  emitInvokestatic(asmTry, validateRef)
  // 3 bytes
  emitReturn(asmTry)
  // 1 byte — normal-path return (offset 4)

  val ar = assembleRaw(asmTry)

  val asmHandler = newAssembler(pool)
  emitAstore(asmHandler, 1)
  // store exception; (1 byte)
  emitGetstatic(asmHandler, sysOut)
  // 3 bytes
  emitAload(asmHandler, 1)
  // 1 byte
  emitInvokevirtual(asmHandler, getMessage)
  // 3 bytes
  emitInvokevirtual(asmHandler, printlnStr)
  // 3 bytes
  emitReturn(asmHandler)
  // 1 byte

  val arH = assembleRaw(asmHandler)

  // Build combined code: try code + handler code
  val code: List[Byte] = newList()
  for b in ar.codeBytes.toArray() {
    code.add(b)
  }
  val handlerPc = code.count
  for b in arH.codeBytes.toArray() {
    code.add(b)
  }

  val codeAttr = makeCodeAttrWithHandler(2, 2, code, 0, 4, handlerPc, iaeClassIdx)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethodsV49("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b56"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val validatorBytes = makeValidatorClassBytes()
  val mainBytes = makeMainClassBytes()

  val validatorClass = BuiltClass(binaryName = "Validator", bytes = validatorBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(validatorClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB56",
    mainClass = "Main",
    version = "0.1.0",
    outPath = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
