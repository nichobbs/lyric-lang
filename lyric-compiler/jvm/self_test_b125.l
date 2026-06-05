//! jvm/self_test_b125.l — Stage B125: lowerOpaqueFacade (Java interop facade codegen).
//!
//! Creates an opaque type `OpaquePoint` with two int fields: x and y.
//! Then generates its companion `OpaquePoint$Facade` class via lowerOpaqueFacade.
//!
//! The facade provides:
//!   • static create(int, int): OpaquePoint  — constructs via the package-private ctor
//!   • static x(OpaquePoint): int            — delegates to $x() accessor
//!   • static y(OpaquePoint): int            — delegates to $y() accessor
//!
//! A Main class:
//!   - Creates OpaquePoint(10, 20) via OpaquePoint$Facade.create(10, 20)
//!   - Reads fields via OpaquePoint$Facade.x(obj) and OpaquePoint$Facade.y(obj)
//!
//! Java output (java -jar):
//!   x=10
//!   y=20
package Jvm.SelfTestB125

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeFlds(): List[LOpaqueField] {
  val flds: List[LOpaqueField] = newList()
  flds.add(LOpaqueField(name = "x", fieldType = JInt))
  flds.add(LOpaqueField(name = "y", fieldType = JInt))
  flds
}

func makeOpaqueBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerOpaqueType(LOpaqueType(className = "OpaquePoint", fields = makeFlds()), pool)
  serializeClassWithPool(cf, pool)
}

func makeFacadeBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerOpaqueFacade(LOpaqueType(className = "OpaquePoint", fields = makeFlds()), pool)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val vofIIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  val facadeCreate = poolMethodref(pool, "OpaquePoint$Facade", "create", "(II)LOpaquePoint;")
  val facadeX = poolMethodref(pool, "OpaquePoint$Facade", "x", "(LOpaquePoint;)I")
  val facadeY = poolMethodref(pool, "OpaquePoint$Facade", "y", "(LOpaquePoint;)I")

  // OpaquePoint obj = OpaquePoint$Facade.create(10, 20)
  emitPushInt(asm, 10)
  emitPushInt(asm, 20)
  emitInvokestatic(asm, facadeCreate)
  emitAstore(asm, 1)

  // println("x=" + OpaquePoint$Facade.x(obj))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "x=")
  emitAload(asm, 1)
  emitInvokestatic(asm, facadeX)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("y=" + OpaquePoint$Facade.y(obj))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "y=")
  emitAload(asm, 1)
  emitInvokestatic(asm, facadeY)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  // maxStack=3 (getstatic + ldc + aload peak during println)
  // maxLocals=2 (slot 0=args, slot 1=obj)
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
  val outDir = "/tmp/lyric-jvm-b125"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "OpaquePoint", bytes = makeOpaqueBytes()))
  classes.add(BuiltClass(binaryName = "OpaquePoint$Facade", bytes = makeFacadeBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB125",
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
