// jvm/self_test_b47.l — Stage B47: explicit super.method() call from override.
//
// Generates two class files:
//   Base.class  — getValue()I returns 10
//   Child.class — extends Base; getValue()I returns super.getValue() * 2 = 20
//   Main.class  — creates Base (→10) and Child (→20), prints both
//
// Expected output:
//   10
//   20
//
// Exercises: invokespecial on parent class method from within a subclass override
//            (the distinguishing feature from B44 which used invokevirtual dispatch).

package Jvm.SelfTestB47

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeBaseBytes(): List[Byte] {
  val pool    = poolNew()
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")

  // <init>()V
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // getValue()I — returns 10
  val asmGet = newAssembler(pool)
  emitPushInt(asmGet, 10)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 1, 1)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC, "getValue", "()I", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(getMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeClassFull("Base", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeChildBytes(): List[Byte] {
  val pool      = poolNew()
  val baseInit  = poolMethodref(pool, "Base", "<init>", "()V")
  val baseGet   = poolMethodref(pool, "Base", "getValue", "()I")

  // <init>()V — calls Base.<init>
  val asmInit = newAssembler(pool)
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, baseInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // getValue()I — returns super.getValue() * 2
  // aload_0; invokespecial Base.getValue; bipush 2; imul; ireturn
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitInvokespecial(asmGet, baseGet)
  emitPushInt(asmGet, 2)
  emitImul(asmGet)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 2, 1)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC, "getValue", "()I", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(getMethod)
  val fields: List[FieldInfo] = newList()
  val cf = makeCaseClass("Child", "Base", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val baseGet   = poolMethodref(pool, "Base", "getValue", "()I")
  val baseClass = poolClass(pool, "Base")
  val baseInit  = poolMethodref(pool, "Base", "<init>", "()V")
  val childClass = poolClass(pool, "Child")
  val childInit  = poolMethodref(pool, "Child", "<init>", "()V")

  // println(new Base().getValue())  → 10
  emitGetstatic(asm, sysOut)
  emitNew(asm, baseClass)
  emitDup(asm)
  emitInvokespecial(asm, baseInit)
  emitInvokevirtual(asm, baseGet)
  emitInvokevirtual(asm, printlnI)

  // println(new Child().getValue()) → 20
  emitGetstatic(asm, sysOut)
  emitNew(asm, childClass)
  emitDup(asm)
  emitInvokespecial(asm, childInit)
  emitInvokevirtual(asm, baseGet)
  emitInvokevirtual(asm, printlnI)

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
  val outDir = "/tmp/lyric-jvm-b47"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val baseBytes  = makeBaseBytes()
  val childBytes = makeChildBytes()
  val mainBytes  = makeMainClassBytes()

  val baseClass  = BuiltClass(binaryName = "Base",  bytes = baseBytes)
  val childClass = BuiltClass(binaryName = "Child", bytes = childBytes)
  val mainClass  = BuiltClass(binaryName = "Main",  bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(baseClass)
  classes.add(childClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB47",
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
