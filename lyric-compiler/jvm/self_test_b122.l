//! jvm/self_test_b122.l — Stage B122: lowerDeriveEquality (@generate(Equals) and @generate(Hash)).
//!
//! Creates a `Point` record (x: JInt, y: JInt) with both Equals and Hash derived.
//! Main:
//!   - p1=(3,4), p2=(3,4): p1.equals(p2) → "equals=true"
//!   - p1.hashCode() XOR p2.hashCode() = 0 → "hash_xor=0"
//!
//! Java output (java -jar):
//!   equals=true
//!   hash_xor=0
package Jvm.SelfTestB122

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Point record with @generate(Equals, Hash) ─────────────────────────────
func makePointBytes(pool: in Pool): List[Byte] {
  val fields: List[LField] = newList()
  fields.add(LField(flags = ACC_PUBLIC, name = "x", fieldType = JInt))
  fields.add(LField(flags = ACC_PUBLIC, name = "y", fieldType = JInt))

  val d = LRecordWithDerives(className = "Point", fields = fields, deriveEq = true, deriveHash = true)
  val cf = lowerDeriveEquality(d, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val vofBIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(Z)Ljava/lang/String;")
  val vofIIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  val ptClass = poolClass(pool, "Point")
  val ptCtor = poolMethodref(pool, "Point", "<init>", "(II)V")
  val ptEquals = poolMethodref(pool, "Point", "equals", "(Ljava/lang/Object;)Z")
  val ptHash = poolMethodref(pool, "Point", "hashCode", "()I")

  // p1 = new Point(3, 4)
  emitNew(asm, ptClass)
  emitDup(asm)
  emitIconst(asm, 3)
  emitIconst(asm, 4)
  emitInvokespecial(asm, ptCtor)
  emitAstore(asm, 1)

  // p2 = new Point(3, 4)
  emitNew(asm, ptClass)
  emitDup(asm)
  emitIconst(asm, 3)
  emitIconst(asm, 4)
  emitInvokespecial(asm, ptCtor)
  emitAstore(asm, 2)

  // println("equals=" + String.valueOf(p1.equals(p2)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "equals=")
  emitAload(asm, 1)
  emitAload(asm, 2)
  emitInvokevirtual(asm, ptEquals)
  emitInvokestatic(asm, vofBIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("hash_xor=" + (p1.hashCode() ^ p2.hashCode()))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "hash_xor=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, ptHash)
  emitAload(asm, 2)
  emitInvokevirtual(asm, ptHash)
  emitIxor(asm)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 3)
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
  val outDir = "/tmp/lyric-jvm-b122"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Point", bytes = makePointBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB122",
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
