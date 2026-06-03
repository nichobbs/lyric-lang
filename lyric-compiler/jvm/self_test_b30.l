// jvm/self_test_b30.l — Stage B30: multianewarray (multi-dimensional arrays).
//
// Generates Grid.class with a static makeGrid(I,I)[[I method that creates
// a 2D int array using multianewarray.  Main calls makeGrid(2,3), checks
// outer length (2) and inner length (3), and prints both.
//
// Exercises: emitMultiANewArray, multi-dim array access (aaload for inner arrays),
// arraylength on both dimensions.

package Jvm.SelfTestB30

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeGridClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // makeGrid(I,I)[[I
  //   iload_0  (rows)
  //   iload_1  (cols)
  //   multianewarray "[[I" 2   → allocates int[rows][cols]
  //   areturn
  val gridType = poolClass(pool, "[[I")
  emitIload(asm, 0)
  emitIload(asm, 1)
  emitMultiANewArray(asm, gridType, 2)
  emitAreturn(asm)

  // max_stack = 2 (two ints before multianewarray), max_locals = 2
  val codeAttr = assembleCode(asm, 2, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val makeGridMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "makeGrid",
    "(II)[[I",
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(makeGridMethod)
  val cf = makeClassWithMethods("Grid", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut      = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val makeGridRef = poolMethodref(pool, "Grid", "makeGrid", "(II)[[I")
  val printlnI    = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // val grid = Grid.makeGrid(2, 3)
  emitPushInt(asm, 2)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, makeGridRef)
  emitAstore(asm, 1)

  // println(grid.length)  → 2 (outer dimension)
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitArraylength(asm)
  emitInvokevirtual(asm, printlnI)

  // println(grid[0].length)  → 3 (inner dimension)
  emitGetstatic(asm, sysOut)
  emitAload(asm, 1)
  emitPushInt(asm, 0)
  emitAaload(asm)
  emitArraylength(asm)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // max_stack = 3 (ps + array + int), max_locals = 2 (args + grid)
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
  val outDir = "/tmp/lyric-jvm-b30"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val gridBytes = makeGridClassBytes()
  val mainBytes = makeMainClassBytes()

  val gridClass = BuiltClass(binaryName = "Grid", bytes = gridBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(gridClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB30",
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
