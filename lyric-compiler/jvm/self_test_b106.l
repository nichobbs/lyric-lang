// jvm/self_test_b106.l — Stage B106: lowerClosure (closure / inner-class codegen).
//
// Creates two classes:
//   Adder — a functional interface with a single method add(int,int):int
//   AddN  — a closure class implementing Adder; captures an int field `n`;
//           add(a,b) returns a + b + n
//
// A Main class instantiates AddN(10) and calls add(3,4) expecting 17,
// then AddN(0) and calls add(5,6) expecting 11.
//
// Java output (java -jar):
//   result(3+4+10)=17
//   result(5+6+0)=11

package Jvm.SelfTestB106

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Adder interface ─────────────────────────────────────────────────────

func makeAdderBytes(): List[Byte] {
  val pool = poolNew()
  val emptyAttrs: List[Attribute] = newList()
  val ps: List[JvmType] = newList()
  ps.add(JInt)
  ps.add(JInt)
  val m = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "add", buildDescriptor(ps, JInt), emptyAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(m)
  val cf = makeInterfaceWithMethods("Adder", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build AddN closure class ──────────────────────────────────────────────────

func makeAddNBytes(): List[Byte] {
  val pool = poolNew()

  val captures: List[LClosureCapture] = newList()
  captures.add(LClosureCapture(captureName = "n", captureType = JInt))

  val params: List[JvmType] = newList()
  params.add(JInt)
  params.add(JInt)

  // body: aload 0; getfield n; iload 1; iload 2; iadd; iadd; ireturn
  val body: List[LInsn] = newList()
  body.add(LAload(slot = 0))
  body.add(LGetfield(owner = "AddN", name = "n", t = JInt))
  body.add(LIload(slot = 1))
  body.add(LIload(slot = 2))
  body.add(LIadd)
  body.add(LIadd)
  body.add(LIreturn)

  val c = LClosure(
    closureClass = "AddN",
    ifaceClass   = "Adder",
    ifaceMethod  = "add",
    captures     = captures,
    methodParams = params,
    methodRet    = JInt,
    bodyInsns    = body
  )
  val cf = lowerClosure(c, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")

  val addNPs: List[JvmType] = newList()
  addNPs.add(JInt)
  val addNCtorIdx = poolMethodref(pool, "AddN", "<init>", buildDescriptor(addNPs, JVoid))
  val addNNewIdx  = poolClass(pool, "AddN")

  val addPs: List[JvmType] = newList()
  addPs.add(JInt)
  addPs.add(JInt)
  val addIdx = poolMethodref(pool, "AddN", "add", buildDescriptor(addPs, JInt))

  // result(3+4+10): new AddN(10).add(3,4) → 17
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result(3+4+10)=")
  emitNew(asm, addNNewIdx)
  emitDup(asm)
  emitPushInt(asm, 10)
  emitInvokespecial(asm, addNCtorIdx)
  emitPushInt(asm, 3)
  emitPushInt(asm, 4)
  emitInvokevirtual(asm, addIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // result(5+6+0): new AddN(0).add(5,6) → 11
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result(5+6+0)=")
  emitNew(asm, addNNewIdx)
  emitDup(asm)
  emitPushInt(asm, 0)
  emitInvokespecial(asm, addNCtorIdx)
  emitPushInt(asm, 5)
  emitPushInt(asm, 6)
  emitInvokevirtual(asm, addIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b106"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Adder", bytes = makeAdderBytes()))
  classes.add(BuiltClass(binaryName = "AddN",  bytes = makeAddNBytes()))
  classes.add(BuiltClass(binaryName = "Main",  bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB106",
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
