//! jvm/self_test_b57.l — Stage B57: java.util.Arrays.sort(int[]).
//!
//! Generates Sorter.class with a static sortAndPrint(int[])V that calls
//! Arrays.sort(arr) and then prints each element.
//!
//! Main creates int[]{5, 3, 1, 4, 2}, calls sortAndPrint.
//!
//! Expected output (sorted):
//!   1
//!   2
//!   3
//!   4
//!   5
//!
//! Exercises: newarray T_INT, iastore, invokestatic Arrays.sort([I)V,
//!            arraylength, iaload for reading sorted elements.
package Jvm.SelfTestB57

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeSorterClassBytes(): List[Byte] {
  val pool = poolNew()

  val arraysSort = poolMethodref(pool, "java/util/Arrays", "sort", "([I)V")
  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // ── sortAndPrint([I)V ─────────────────────────────────────────────────────────
  // slot 0 = arr
  // slot 1 = i (loop index)
  // Arrays.sort(arr)
  // i = 0
  // LOOP: if i >= arr.length goto DONE
  //   println(arr[i])
  //   i++
  //   goto LOOP
  // DONE: return
  val asm = newAssembler(pool)

  emitAload(asm, 0)
  emitInvokestatic(asm, arraysSort)
  // Arrays.sort(arr)

  emitIconst(asm, 0)
  emitIstore(asm, 1)
  // i = 0

  emitLabel(asm, "LOOP")
  emitIload(asm, 1)
  emitAload(asm, 0)
  emitArraylength(asm)
  // arr.length
  emitIfIcmpge(asm, "DONE")
  // if i >= length: done

  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitIload(asm, 1)
  emitIaload(asm)
  // arr[i]
  emitInvokevirtual(asm, printlnI)

  emitIinc(asm, 1, 1)
  // i++
  emitGoto(asm, "LOOP")

  emitLabel(asm, "DONE")
  emitReturn(asm)

  // maxStack: getstatic(1) + aload(2) + iload(3) peak
  val sortCode = assembleCode(asm, 3, 2)
  val sortAttrs: List[Attribute] = newList()
  sortAttrs.add(sortCode)
  val sortMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sortAndPrint", "([I)V", sortAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(sortMethod)
  val cf = makeClassWithMethodsV49("Sorter", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sortRef = poolMethodref(pool, "Sorter", "sortAndPrint", "([I)V")
  val T_INT = 10
  // newarray type code for int[]

  // Create int[5] = {5, 3, 1, 4, 2}
  emitPushInt(asm, 5)
  emitNewarray(asm, T_INT)
  // new int[5]
  // store into local 1
  emitAstore(asm, 1)

  emitAload(asm, 1)
  emitIconst(asm, 0)
  emitPushInt(asm, 5)
  emitIastore(asm)
  // arr[0] = 5

  emitAload(asm, 1)
  emitIconst(asm, 1)
  emitPushInt(asm, 3)
  emitIastore(asm)
  // arr[1] = 3

  emitAload(asm, 1)
  emitIconst(asm, 2)
  emitIconst(asm, 1)
  emitIastore(asm)
  // arr[2] = 1

  emitAload(asm, 1)
  emitIconst(asm, 3)
  emitPushInt(asm, 4)
  emitIastore(asm)
  // arr[3] = 4

  emitAload(asm, 1)
  emitPushInt(asm, 4)
  emitPushInt(asm, 2)
  emitIastore(asm)
  // arr[4] = 2

  emitAload(asm, 1)
  emitInvokestatic(asm, sortRef)

  emitReturn(asm)

  // maxStack: aload(1) + iconst(2) + value(3) peak for iastore operations
  val codeAttr = assembleCode(asm, 3, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethodsV49("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b57"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val sorterBytes = makeSorterClassBytes()
  val mainBytes = makeMainClassBytes()

  val sorterClass = BuiltClass(binaryName = "Sorter", bytes = sorterBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(sorterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB57",
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
