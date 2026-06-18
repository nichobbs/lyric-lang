//! jvm/self_test_b19.l — Stage B19: backward-branch loop with StackMapTable.
//!
//! Implements factorial(int n) iteratively using a while-loop (backward branch).
//! The loop requires a StackMapTable entry at the loop header.
//! Main calls factorial(5), verifying the result is 120.
//!
//! Loop frame: [VInteger, VInteger] — slots 0 (n) and 1 (acc)
//! Exercises: emitIfle (loop exit), backward goto, iimul, multi-local frame.
package Jvm.SelfTestB19

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // factorial(I)I:
  //   slot 0 = n (parameter)
  //   slot 1 = acc (local, starts at 1)
  //
  //   iconst_1 ; istore_1          // acc = 1
  // loopHead:
  //   iload_0                      // push n
  //   ifle "done"                  // if n <= 0, jump to done
  //   iload_1                      // push acc
  //   iload_0                      // push n
  //   imul                         // acc * n
  //   istore_1                     // acc = acc * n
  //   iload_0                      // push n
  //   iconst_1 (via emitPushInt)   // push 1
  //   isub                         // n - 1
  //   istore_0                     // n = n - 1
  //   goto "loopHead"
  // done:
  //   iload_1                      // push acc
  //   ireturn

  emitPushInt(asm, 1)
  emitIstore(asm, 1)

  emitLabel(asm, "loopHead")
  emitIload(asm, 0)
  emitIfle(asm, "done")

  emitIload(asm, 1)
  emitIload(asm, 0)
  emitImul(asm)
  emitIstore(asm, 1)

  emitIload(asm, 0)
  emitPushInt(asm, 1)
  emitIsub(asm)
  emitIstore(asm, 0)

  emitGoto(asm, "loopHead")

  emitLabel(asm, "done")
  emitIload(asm, 1)
  emitIreturn(asm)

  // Frame at both labels: [VInteger (n), VInteger (acc)]
  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VInteger)
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 2, 2, frameLocals)

  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val factMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "factorial", "(I)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(factMethod)
  val cf = makeClassWithMethods("MathB19", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val factRef = poolMethodref(pool, "MathB19", "factorial", "(I)I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, factRef)
  emitInvokevirtual(asm, printlnI)
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
  val outDir = "/tmp/lyric-jvm-b19"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val mathBytes = makeMathClassBytes()
  val mainBytes = makeMainClassBytes()

  val mathClass = BuiltClass(binaryName = "MathB19", bytes = mathBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB19",
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
