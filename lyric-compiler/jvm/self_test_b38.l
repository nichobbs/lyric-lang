// jvm/self_test_b38.l — Stage B38: static class initializer <clinit>.
//
// Generates StaticInit.class with:
//   static String msg — initialized in <clinit>()V via ldc + putstatic
//   getMessage()Ljava/lang/String; — getstatic + areturn
//
// Main calls getMessage() and prints it.
// Expected output: "hello from clinit"
//
// Exercises: emitting a <clinit>()V method, static field initialization
// at class load time, makeClassFull with fields + methods.

package Jvm.SelfTestB38

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeStaticInitClassBytes(): List[Byte] {
  val pool = poolNew()

  val msgField = poolFieldref(pool, "StaticInit", "msg", "Ljava/lang/String;")

  // ── <clinit>()V ──────────────────────────────────────────────────────────────
  // ldc "hello from clinit"; putstatic StaticInit.msg; return
  val asmClinit = newAssembler(pool)
  emitPushString(asmClinit, "hello from clinit")
  emitPutstatic(asmClinit, msgField)
  emitReturn(asmClinit)
  val clinitCode = assembleCode(asmClinit, 1, 0)
  val clinitAttrs: List[Attribute] = newList()
  clinitAttrs.add(clinitCode)
  val clinitMethod = makeMethodInfo(
    ACC_STATIC,
    "<clinit>",
    "()V",
    clinitAttrs
  )

  // ── getMessage()Ljava/lang/String; ────────────────────────────────────────────
  // getstatic StaticInit.msg; areturn
  val asmGet = newAssembler(pool)
  emitGetstatic(asmGet, msgField)
  emitAreturn(asmGet)
  val getCode = assembleCode(asmGet, 1, 0)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "getMessage",
    "()Ljava/lang/String;",
    getAttrs
  )

  // ── field declaration ─────────────────────────────────────────────────────────
  val noAttrs: List[Attribute] = newList()
  val msgFieldInfo = makeFieldInfo(
    ACC_PUBLIC + ACC_STATIC,
    "msg",
    "Ljava/lang/String;",
    noAttrs
  )

  val fields: List[FieldInfo] = newList()
  fields.add(msgFieldInfo)

  val methods: List[MethodInfo] = newList()
  methods.add(clinitMethod)
  methods.add(getMethod)

  val cf = makeClassFull("StaticInit", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut       = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val getMsgRef    = poolMethodref(pool, "StaticInit", "getMessage", "()Ljava/lang/String;")
  val printlnS     = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, getMsgRef)
  emitInvokevirtual(asm, printlnS)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b38"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val staticInitBytes = makeStaticInitClassBytes()
  val mainBytes       = makeMainClassBytes()

  val staticInitClass = BuiltClass(binaryName = "StaticInit", bytes = staticInitBytes)
  val mainClass       = BuiltClass(binaryName = "Main",       bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(staticInitClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB38",
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
