// jvm/self_test_b24.l — Stage B24: object arrays (anewarray, aaload, aastore).
//
// Generates StringArray.class with a static join()String method that:
//   1. Creates String[3] via anewarray java/lang/String
//   2. Stores "hello", " world", "!" at indices 0, 1, 2 (aastore)
//   3. Reads them back with aaload and concatenates via StringBuilder
//   4. Returns the joined string
//
// Main calls join() and prints "hello world!".
// Exercises: anewarray, aaload, aastore.

package Jvm.SelfTestB24

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeStringArrayClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // join()Ljava/lang/String;
  //   bipush 3
  //   anewarray java/lang/String  → String[3]
  //   astore_0                    // slot 0 = arr
  //
  //   aload_0; iconst_0; ldc "hello";  aastore   // arr[0] = "hello"
  //   aload_0; iconst_1; ldc " world"; aastore   // arr[1] = " world"
  //   aload_0; iconst_2; ldc "!";      aastore   // arr[2] = "!"
  //
  //   new StringBuilder; dup; invokespecial <init>
  //   aload_0; iconst_0; aaload; invokevirtual append(String)
  //   aload_0; iconst_1; aaload; invokevirtual append(String)
  //   aload_0; iconst_2; aaload; invokevirtual append(String)
  //   invokevirtual toString()
  //   areturn

  val strClass  = poolClass(pool, "java/lang/String")
  val sbClass   = poolClass(pool, "java/lang/StringBuilder")
  val sbInit    = poolMethodref(pool, "java/lang/StringBuilder", "<init>", "()V")
  val sbAppend  = poolMethodref(pool, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
  val sbToStr   = poolMethodref(pool, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;")

  // Create String[3]
  emitPushInt(asm, 3)
  emitAnewarray(asm, strClass)
  emitAstore(asm, 0)

  // arr[0] = "hello"
  emitAload(asm, 0)
  emitPushInt(asm, 0)
  emitPushString(asm, "hello")
  emitAastore(asm)

  // arr[1] = " world"
  emitAload(asm, 0)
  emitPushInt(asm, 1)
  emitPushString(asm, " world")
  emitAastore(asm)

  // arr[2] = "!"
  emitAload(asm, 0)
  emitPushInt(asm, 2)
  emitPushString(asm, "!")
  emitAastore(asm)

  // StringBuilder sb = new StringBuilder()
  emitNew(asm, sbClass)
  emitDup(asm)
  emitInvokespecial(asm, sbInit)

  // sb.append(arr[0]).append(arr[1]).append(arr[2]).toString()
  emitAload(asm, 0)
  emitPushInt(asm, 0)
  emitAaload(asm)
  emitInvokevirtual(asm, sbAppend)

  emitAload(asm, 0)
  emitPushInt(asm, 1)
  emitAaload(asm)
  emitInvokevirtual(asm, sbAppend)

  emitAload(asm, 0)
  emitPushInt(asm, 2)
  emitAaload(asm)
  emitInvokevirtual(asm, sbAppend)

  emitInvokevirtual(asm, sbToStr)
  emitAreturn(asm)

  // No branches so no StackMapTable needed; max_stack=3, max_locals=1
  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val joinMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "join", "()Ljava/lang/String;", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(joinMethod)
  val cf = makeClassWithMethods("StringArray", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut  = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val joinRef = poolMethodref(pool, "StringArray", "join", "()Ljava/lang/String;")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, joinRef)
  emitInvokevirtual(asm, println_)
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
  val outDir = "/tmp/lyric-jvm-b24"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val stringArrayBytes = makeStringArrayClassBytes()
  val mainBytes        = makeMainClassBytes()

  val stringArrayClass = BuiltClass(binaryName = "StringArray", bytes = stringArrayBytes)
  val mainClass        = BuiltClass(binaryName = "Main",        bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(stringArrayClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB24",
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
