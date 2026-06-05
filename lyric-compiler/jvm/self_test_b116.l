//! jvm/self_test_b116.l — Stage B116: lowerExposedRecord (unmangled fields + Record attribute).
//!
//! Creates an exposed record `Address` with two String fields: street and city.
//! Fields are NOT dollar-mangled; unmangled accessor methods are generated.
//!
//! A Main class constructs Address and calls the accessors.
//!
//! Java output (java -jar):
//!   street=Main St
//!   city=Springfield
package Jvm.SelfTestB116

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Address exposed record ──────────────────────────────────────────────
func makeAddressBytes(pool: in Pool): List[Byte] {
  val fields: List[LField] = newList()
  fields.add(LField(flags = ACC_PUBLIC, name = "street", fieldType = JRef(className = "java/lang/String")))
  fields.add(LField(flags = ACC_PUBLIC, name = "city", fieldType = JRef(className = "java/lang/String")))
  val r = LExposedRecord(className = "Address", fields = fields)
  val cf = lowerExposedRecord(r, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")

  val addrClass = poolClass(pool, "Address")
  val addrCtor = poolMethodref(pool, "Address", "<init>", "(Ljava/lang/String;Ljava/lang/String;)V")
  val streetAcc = poolMethodref(pool, "Address", "street", "()Ljava/lang/String;")
  val cityAcc = poolMethodref(pool, "Address", "city", "()Ljava/lang/String;")

  // Address addr = new Address("Main St", "Springfield")
  emitNew(asm, addrClass)
  emitDup(asm)
  emitPushString(asm, "Main St")
  emitPushString(asm, "Springfield")
  emitInvokespecial(asm, addrCtor)
  emitAstore(asm, 1)

  // println("street=" + addr.street())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "street=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, streetAcc)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("city=" + addr.city())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "city=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, cityAcc)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 2)
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
  val outDir = "/tmp/lyric-jvm-b116"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Address", bytes = makeAddressBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB116",
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
