//! jvm/self_test_b45.l — Stage B45: multiple interface implementation.
//!
//! Generates four class files:
//!   Nameable.class  — interface with getName()Ljava/lang/String;
//!   Scoreable.class — interface with getScore()I
//!   Player.class    — implements both Nameable and Scoreable
//!   Main.class      — calls both methods via invokeinterface
//!
//! Expected output:
//!   Alice
//!   42
//!
//! Exercises: ClassFile with interfaces list containing two entries,
//!            invokeinterface on two different interface types.
package Jvm.SelfTestB45

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeNameableBytes(): List[Byte] {
  val pool = poolNew()
  val noAttrs: List[Attribute] = newList()
  val getNameMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "getName", "()Ljava/lang/String;", noAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(getNameMethod)
  val ifaces: List[String] = newList()
  val fields: List[FieldInfo] = newList()
  val attrs: List[Attribute] = newList()
  val cf = ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = "Nameable",
    superClass = "java/lang/Object",
    interfaces = ifaces,
    fields = fields,
    methods = methods,
    attrs = attrs
  )
  serializeClassWithPool(cf, pool)
}

func makeScoreableBytes(): List[Byte] {
  val pool = poolNew()
  val noAttrs: List[Attribute] = newList()
  val getScoreMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "getScore", "()I", noAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(getScoreMethod)
  val ifaces: List[String] = newList()
  val fields: List[FieldInfo] = newList()
  val attrs: List[Attribute] = newList()
  val cf = ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = "Scoreable",
    superClass = "java/lang/Object",
    interfaces = ifaces,
    fields = fields,
    methods = methods,
    attrs = attrs
  )
  serializeClassWithPool(cf, pool)
}

func makePlayerBytes(): List[Byte] {
  val pool = poolNew()
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

  // getName()Ljava/lang/String; — returns "Alice"
  val asmName = newAssembler(pool)
  emitPushString(asmName, "Alice")
  emitAreturn(asmName)
  val nameCode = assembleCode(asmName, 1, 1)
  val nameAttrs: List[Attribute] = newList()
  nameAttrs.add(nameCode)
  val nameMethod = makeMethodInfo(ACC_PUBLIC, "getName", "()Ljava/lang/String;", nameAttrs)

  // getScore()I — returns 42
  val asmScore = newAssembler(pool)
  emitPushInt(asmScore, 42)
  emitIreturn(asmScore)
  val scoreCode = assembleCode(asmScore, 1, 1)
  val scoreAttrs: List[Attribute] = newList()
  scoreAttrs.add(scoreCode)
  val scoreMethod = makeMethodInfo(ACC_PUBLIC, "getScore", "()I", scoreAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(nameMethod)
  methods.add(scoreMethod)

  val ifaces: List[String] = newList()
  ifaces.add("Nameable")
  ifaces.add("Scoreable")
  val fields: List[FieldInfo] = newList()
  val attrs: List[Attribute] = newList()
  val cf = ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = "Player",
    superClass = "java/lang/Object",
    interfaces = ifaces,
    fields = fields,
    methods = methods,
    attrs = attrs
  )
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnStr = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val playerClass = poolClass(pool, "Player")
  val playerInit = poolMethodref(pool, "Player", "<init>", "()V")
  val getNameIface = poolIfaceMethodref(pool, "Nameable", "getName", "()Ljava/lang/String;")
  val getScoreIface = poolIfaceMethodref(pool, "Scoreable", "getScore", "()I")

  // val p = new Player()
  // stored in local 1 (local 0 is args, but this is static main so no this)
  // Actually, local 0 = args (String[]), we use local 1 for player
  emitNew(asm, playerClass)
  emitDup(asm)
  emitInvokespecial(asm, playerInit)
  emitAstore(asm, 1)

  // println(p.getName())
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitInvokeinterface(asm, getNameIface, 1)
  emitInvokevirtual(asm, printlnStr)

  // println(p.getScore())
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitInvokeinterface(asm, getScoreIface, 1)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b45"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val nameableBytes = makeNameableBytes()
  val scoreableBytes = makeScoreableBytes()
  val playerBytes = makePlayerBytes()
  val mainBytes = makeMainClassBytes()

  val nameableClass = BuiltClass(binaryName = "Nameable", bytes = nameableBytes)
  val scoreableClass = BuiltClass(binaryName = "Scoreable", bytes = scoreableBytes)
  val playerClass = BuiltClass(binaryName = "Player", bytes = playerBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(nameableClass)
  classes.add(scoreableClass)
  classes.add(playerClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB45",
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
