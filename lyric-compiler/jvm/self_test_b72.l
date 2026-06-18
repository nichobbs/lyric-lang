// jvm/self_test_b72.l — Stage B72: StringBuilder chaining (mixed-type appends).
//
// Generates Builder.class with:
//   buildMsg(String,Int,Bool)String
//     — new StringBuilder()
//       .append(name)
//       .append(" score=")
//       .append(score)    (int)
//       .append(" ok=")
//       .append(flag)     (boolean, via Z)
//       .toString()
//
// Main prints:
//   buildMsg("Alice", 42, 1) → "Alice score=42 ok=true"
//   buildMsg("Bob",   0,  0) → "Bob score=0 ok=false"
//
// Exercises: invokevirtual StringBuilder.append(String/I/Z), each returning
//            StringBuilder for chaining; StringBuilder.toString().

package Jvm.SelfTestB72

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBuilderBytes(): List[Byte] {
  val pool     = poolNew()
  val sbClass  = poolClass(pool, "java/lang/StringBuilder")
  val sbInit   = poolMethodref(pool, "java/lang/StringBuilder", "<init>",    "()V")
  val appStr   = poolMethodref(pool, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
  val appInt   = poolMethodref(pool, "java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;")
  val appBool  = poolMethodref(pool, "java/lang/StringBuilder", "append", "(Z)Ljava/lang/StringBuilder;")
  val toStr    = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  // buildMsg(String,Int,Bool)String
  // slot 0=name, slot 1=score, slot 2=flag(int as Z)
  val asm = newAssembler(pool)
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)
  emitAload(asm, 0)
  emitInvokevirtual(asm, appStr)
  emitPushString(asm, " score=")
  emitInvokevirtual(asm, appStr)
  emitIload(asm, 1)
  emitInvokevirtual(asm, appInt)
  emitPushString(asm, " ok=")
  emitInvokevirtual(asm, appStr)
  emitIload(asm, 2)
  emitInvokevirtual(asm, appBool)
  emitInvokevirtual(asm, toStr)
  emitAreturn(asm)

  // maxStack: new(1)+dup(2); after dup+invokespecial=1 (sb), then aload(2), then append returns sb(1)
  // Peak is new(1)+dup(2) = 2
  val code = assembleCode(asm, 3, 3)
  val codeAttrs: List[Attribute] = newList()
  codeAttrs.add(code)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "buildMsg",
    "(Ljava/lang/String;IZ)Ljava/lang/String;", codeAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)
  val cf = makeClassWithMethods("Builder", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val buildRef  = poolMethodref(pool, "Builder", "buildMsg",
    "(Ljava/lang/String;IZ)Ljava/lang/String;")

  // println(Builder.buildMsg("Alice", 42, 1)) → "Alice score=42 ok=true"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Alice")
  emitPushInt(asm, 42)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, buildRef)
  emitInvokevirtual(asm, printlnS)

  // println(Builder.buildMsg("Bob", 0, 0)) → "Bob score=0 ok=false"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Bob")
  emitPushInt(asm, 0)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, buildRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  // maxStack: getstatic(1)+str(2)+int(3)+int(4) = 4 peak
  val codeAttr = assembleCode(asm, 4, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b72"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val builderBytes = makeBuilderBytes()
  val mainBytes    = makeMainClassBytes()

  val builderClass = BuiltClass(binaryName = "Builder", bytes = builderBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(builderClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB72",
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
