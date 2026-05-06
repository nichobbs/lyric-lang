// jvm/self_test_b42.l — Stage B42: StringBuilder chained append for dynamic strings.
//
// Generates Builder.class with:
//   buildMessage(Ljava/lang/String;I)Ljava/lang/String;
//       — constructs "Name: " + name + ", Age: " + age via StringBuilder
//
// Main:
//   buildMessage("Alice", 30) → "Name: Alice, Age: 30"
//   buildMessage("Bob", 25)   → "Name: Bob, Age: 25"
//
// Expected output:
//   Name: Alice, Age: 30
//   Name: Bob, Age: 25
//
// Exercises: new StringBuilder, invokespecial <init>, multiple invokevirtual
// StringBuilder.append(String) and StringBuilder.append(I), toString.

package Jvm.SelfTestB42

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBuilderClassBytes(): List[Byte] {
  val pool = poolNew()

  val sbClass    = poolClass(pool, "java/lang/StringBuilder")
  val sbInit     = poolMethodref(pool, "java/lang/StringBuilder", "<init>",       "()V")
  val sbAppendS  = poolMethodref(pool, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
  val sbAppendI  = poolMethodref(pool, "java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;")
  val sbToStr    = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  // ── buildMessage(String, int)String ──────────────────────────────────────────
  // new StringBuilder(); dup; invokespecial <init>
  // ldc "Name: "; invokevirtual append(String)
  // aload_0; invokevirtual append(String)
  // ldc ", Age: "; invokevirtual append(String)
  // iload_1; invokevirtual append(I)
  // invokevirtual toString
  // areturn
  val asmBM = newAssembler(pool)
  emitNew(asmBM, sbClass)
  emitDup(asmBM)
  emitInvokespecial(asmBM, sbInit)
  emitPushString(asmBM, "Name: ")
  emitInvokevirtual(asmBM, sbAppendS)
  emitAload(asmBM, 0)
  emitInvokevirtual(asmBM, sbAppendS)
  emitPushString(asmBM, ", Age: ")
  emitInvokevirtual(asmBM, sbAppendS)
  emitIload(asmBM, 1)
  emitInvokevirtual(asmBM, sbAppendI)
  emitInvokevirtual(asmBM, sbToStr)
  emitAreturn(asmBM)

  val bmCode = assembleCode(asmBM, 3, 2)
  val bmAttrs: List[Attribute] = newList()
  bmAttrs.add(bmCode)
  val buildMsgMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "buildMessage",
    "(Ljava/lang/String;I)Ljava/lang/String;",
    bmAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(buildMsgMethod)
  val cf = makeClassWithMethods("Builder", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut      = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val buildMsgRef = poolMethodref(pool, "Builder", "buildMessage", "(Ljava/lang/String;I)Ljava/lang/String;")
  val printlnS    = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // buildMessage("Alice", 30) → "Name: Alice, Age: 30"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Alice")
  emitPushInt(asm, 30)
  emitInvokestatic(asm, buildMsgRef)
  emitInvokevirtual(asm, printlnS)

  // buildMessage("Bob", 25) → "Name: Bob, Age: 25"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Bob")
  emitPushInt(asm, 25)
  emitInvokestatic(asm, buildMsgRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b42"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val builderBytes = makeBuilderClassBytes()
  val mainBytes    = makeMainClassBytes()

  val builderClass = BuiltClass(binaryName = "Builder", bytes = builderBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(builderClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB42",
    mainClass   = "Main",
    version     = "0.1.0",
    outPath     = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
