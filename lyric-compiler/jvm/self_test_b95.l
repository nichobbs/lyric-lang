// jvm/self_test_b95.l — Stage B95: float fields in lowerRecord.
//
// Builds a Vector2 record with two JFloat fields (x, y) via lowerRecord,
// proving that the float-field fixes (LFload/LFstore/LFreturn) work correctly.
// Also exercises lowerFunc returning JFloat (LFreturn via returnInsn fix).
//
// Main prints:
//   vec.x=1.5
//   vec.y=2.5
//   len=1.5

package Jvm.SelfTestB95

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeVector2Bytes(): List[Byte] {
  val pool = poolNew()

  val xField = LField(flags = ACC_PUBLIC, name = "x", fieldType = JFloat)
  val yField = LField(flags = ACC_PUBLIC, name = "y", fieldType = JFloat)
  val fields: List[LField] = newList()
  fields.add(xField)
  fields.add(yField)

  // getX(Vector2 this): float — returns this.x, exercises LFreturn via returnInsn
  val getXInsns: List[LInsn] = newList()
  getXInsns.add(LAload(slot = 0))
  getXInsns.add(LGetfield(owner = "Vector2", name = "x", t = JFloat))
  getXInsns.add(LFreturn)

  val getXParams: List[JvmType] = newList()
  val maxFn = LFunc(
    flags     = ACC_PUBLIC,
    name      = "getX",
    params    = getXParams,
    ret       = JFloat,
    insns     = getXInsns,
    maxStack  = 1,
    maxLocals = 1
  )

  val methods: List[LFunc] = newList()
  methods.add(maxFn)

  val rec = LRecord(className = "Vector2", fields = fields, methods = methods, implementsIfaces = newList())
  val cf  = lowerRecord(rec, pool)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool, "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfFIdx = poolMethodref(pool, "java/lang/String",   "valueOf", "(F)Ljava/lang/String;")
  val v2InitIdx  = poolMethodref(pool, "Vector2",             "<init>",  "(FF)V")
  val v2XIdx     = poolFieldref(pool,  "Vector2",             "x",       "F")
  val v2YIdx     = poolFieldref(pool,  "Vector2",             "y",       "F")
  val maxCompIdx = poolMethodref(pool,  "Vector2",            "getX", "()F")
  val v2ClassIdx = poolClass(pool, "Vector2")

  // Vector2 v = new Vector2(1.5f, 2.5f);  [slot 0]
  emitNew(asm, v2ClassIdx)
  emitDup(asm)
  emitPushFloat(asm, 1.5)
  emitPushFloat(asm, 2.5)
  emitInvokespecial(asm, v2InitIdx)
  emitAstore(asm, 0)

  // System.out.println("vec.x=" + String.valueOf(v.x))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "vec.x=")
  emitAload(asm, 0)
  emitGetfield(asm, v2XIdx)
  emitInvokestatic(asm, valueOfFIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("vec.y=" + String.valueOf(v.y))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "vec.y=")
  emitAload(asm, 0)
  emitGetfield(asm, v2YIdx)
  emitInvokestatic(asm, valueOfFIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("len=" + String.valueOf(v.getX()))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "len=")
  emitAload(asm, 0)
  emitInvokevirtual(asm, maxCompIdx)
  emitInvokestatic(asm, valueOfFIdx)
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

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b95"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val vec2Class = BuiltClass(binaryName = "Vector2", bytes = makeVector2Bytes())
  val mainClass = BuiltClass(binaryName = "Main",    bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(vec2Class)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB95",
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
