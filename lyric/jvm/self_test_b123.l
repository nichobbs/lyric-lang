// jvm/self_test_b123.l — Stage B123: lowerDeriveOrd (@derive(Compare/Add/Sub) on distinct types).
//
// Creates a `UserId` distinct type wrapping JLong with all three derives.
// Main:
//   uid1 = UserId(50L), uid2 = UserId(80L)
//   cmp = uid1.compareTo(uid2)  → -1 (uid1 < uid2, JVM lcmp)
//   sum = uid1.$add(uid2).$value()  → 130L
//
// Java output (java -jar):
//   cmp=-1
//   sum=130

package Jvm.SelfTestB123

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build UserId distinct type with derives ───────────────────────────────────

func makeUserIdBytes(pool: in Pool): List[Byte] {
  val d = LDistinctWithDerives(
    wrapperClass   = "UserId",
    underlyingType = JLong,
    deriveCompare  = true,
    deriveAdd      = true,
    deriveSub      = true
  )
  val cf = lowerDeriveOrd(d, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val vofIIdx    = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")
  val vofLIdx    = poolMethodref(pool, "java/lang/String",    "valueOf", "(J)Ljava/lang/String;")

  val uidClass    = poolClass(pool, "UserId")
  val uidCtor     = poolMethodref(pool, "UserId", "<init>", "(J)V")
  val uidCompare  = poolMethodref(pool, "UserId", "compareTo", "(LUserId;)I")
  val uidAdd      = poolMethodref(pool, "UserId", "$add",      "(LUserId;)LUserId;")
  val uidValue    = poolMethodref(pool, "UserId", "$value",    "()J")

  // uid1 = new UserId(50L)
  emitNew(asm, uidClass)
  emitDup(asm)
  emitPushLong(asm, 50i64)
  emitInvokespecial(asm, uidCtor)
  emitAstore(asm, 1)

  // uid2 = new UserId(80L)
  emitNew(asm, uidClass)
  emitDup(asm)
  emitPushLong(asm, 80i64)
  emitInvokespecial(asm, uidCtor)
  emitAstore(asm, 2)

  // println("cmp=" + uid1.compareTo(uid2))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "cmp=")
  emitAload(asm, 1)
  emitAload(asm, 2)
  emitInvokevirtual(asm, uidCompare)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // sum = uid1.$add(uid2).$value()
  emitAload(asm, 1)
  emitAload(asm, 2)
  emitInvokevirtual(asm, uidAdd)
  emitAstore(asm, 3)

  // println("sum=" + sum.$value())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "sum=")
  emitAload(asm, 3)
  emitInvokevirtual(asm, uidValue)
  emitInvokestatic(asm, vofLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 6, 4)
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
  val outDir = "/tmp/lyric-jvm-b123"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "UserId", bytes = makeUserIdBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main",   bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB123",
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
