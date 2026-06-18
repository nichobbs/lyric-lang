// jvm/self_test_b108.l — Stage B108: lowerDistinctType.
//
// Creates two distinct-type wrapper classes (§6.2 bootstrap form):
//   UserId  — wraps long  (type UserId = Long)
//   OrderId — wraps int   (type OrderId = Int)
// Each has a private final `$value` field, a public constructor, and a
// public `$value()` accessor.
//
// A Main class instantiates both, calls $value(), and prints results.
//
// Java output (java -jar):
//   userId.$value=42
//   orderId.$value=7

package Jvm.SelfTestB108

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build wrapper classes ─────────────────────────────────────────────────────

func makeUserIdBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerDistinctType(LDistinctType(wrapperClass = "UserId", underlyingType = JLong), pool)
  serializeClassWithPool(cf, pool)
}

func makeOrderIdBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerDistinctType(LDistinctType(wrapperClass = "OrderId", underlyingType = JInt), pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")

  val userIdNewIdx  = poolClass(pool, "UserId")
  val userIdCtorIdx = poolMethodref(pool, "UserId",  "<init>", "(J)V")
  val userIdAccIdx  = poolMethodref(pool, "UserId",  "$value", "()J")

  val orderIdNewIdx  = poolClass(pool, "OrderId")
  val orderIdCtorIdx = poolMethodref(pool, "OrderId", "<init>", "(I)V")
  val orderIdAccIdx  = poolMethodref(pool, "OrderId", "$value", "()I")

  val valueOfLIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(J)Ljava/lang/String;")
  val valueOfIIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  // UserId uid = new UserId(42L); println("userId.$value=" + uid.$value())
  emitNew(asm, userIdNewIdx)
  emitDup(asm)
  emitPushLong(asm, 42i64)
  emitInvokespecial(asm, userIdCtorIdx)
  emitAstore(asm, 1)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "userId.$value=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, userIdAccIdx)
  emitInvokestatic(asm, valueOfLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // OrderId oid = new OrderId(7); println("orderId.$value=" + oid.$value())
  emitNew(asm, orderIdNewIdx)
  emitDup(asm)
  emitPushInt(asm, 7)
  emitInvokespecial(asm, orderIdCtorIdx)
  emitAstore(asm, 2)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "orderId.$value=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, orderIdAccIdx)
  emitInvokestatic(asm, valueOfIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  // maxStack=4 (new+dup+ldc2_w+invokespecial for long), maxLocals=3 (0=args,1=uid,2=oid)
  val codeAttr = assembleCode(asm, 4, 3)
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
  val outDir = "/tmp/lyric-jvm-b108"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "UserId",  bytes = makeUserIdBytes()))
  classes.add(BuiltClass(binaryName = "OrderId", bytes = makeOrderIdBytes()))
  classes.add(BuiltClass(binaryName = "Main",    bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB108",
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
