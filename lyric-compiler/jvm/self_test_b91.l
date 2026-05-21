// jvm/self_test_b91.l — Stage B91: lowerRecord smoke test.
//
// Builds a Point record with two int fields (x, y) via lowerRecord,
// instantiates it from Main, and prints the field values.
//
// Main prints:
//   point.x=3
//   point.y=7

package Jvm.SelfTestB91

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makePointBytes(): List[Byte] {
  val pool = poolNew()

  val xField = LField(flags = ACC_PUBLIC, name = "x", fieldType = JInt)
  val yField = LField(flags = ACC_PUBLIC, name = "y", fieldType = JInt)
  val fields: List[LField] = newList()
  fields.add(xField)
  fields.add(yField)

  val methods: List[LFunc] = newList()

  val rec = LRecord(className = "Point", fields = fields, methods = methods, implementsIfaces = newList())
  val cf  = lowerRecord(rec, pool)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool, "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")
  val ptInitIdx  = poolMethodref(pool, "Point",               "<init>",  "(II)V")
  val ptXIdx     = poolFieldref(pool,  "Point",               "x",       "I")
  val ptYIdx     = poolFieldref(pool,  "Point",               "y",       "I")
  val ptClassIdx = poolClass(pool, "Point")

  // Point pt = new Point(3, 7);  [slot 0]
  emitNew(asm, ptClassIdx)
  emitDup(asm)
  emitPushInt(asm, 3)
  emitPushInt(asm, 7)
  emitInvokespecial(asm, ptInitIdx)
  emitAstore(asm, 0)

  // System.out.println("point.x=" + String.valueOf(pt.x))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "point.x=")
  emitAload(asm, 0)
  emitGetfield(asm, ptXIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("point.y=" + String.valueOf(pt.y))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "point.y=")
  emitAload(asm, 0)
  emitGetfield(asm, ptYIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b91"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pointClass = BuiltClass(binaryName = "Point", bytes = makePointBytes())
  val mainClass  = BuiltClass(binaryName = "Main",  bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(pointClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB91",
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
