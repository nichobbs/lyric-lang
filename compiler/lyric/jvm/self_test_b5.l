// jvm/self_test_b5.l — Stage B5 smoke test: stack-map frame computation.
//
// Builds B5Test.class in /tmp/lyric-jvm-b5/ with two static methods:
//
//   public static int max(int a, int b)   — has an if/else branch
//   public static void main(String[] args) — entry point (just returns)
//
// The `max` method requires a StackMapTable attribute (JVMS §4.7.4) because
// it contains a branch instruction.  Without a correct StackMapTable the JVM
// class verifier rejects the class at load time with a VerifyError.
//
// The Expecto test (JvmLoweringB5Test.fs) runs this program to write the
// class file, then executes `java -cp /tmp/lyric-jvm-b5 B5Test` and verifies
// exit code 0, proving the generated StackMapTable is accepted.

package Jvm.SelfTestB5

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering

// ── max(int a, int b): int ────────────────────────────────────────────────────
//
// if (a >= b) return a; else return b;
//
// LInsn sequence:
//   LIload(0)              // push a
//   LIload(1)              // push b
//   LIfIcmpge("thenBranch")
//   LIload(1)              // else: push b
//   LIreturn
//   LLabel("thenBranch")
//   LIload(0)              // then: push a
//   LIreturn

func makeMaxMethod(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LIload(slot = 0))
  insns.add(LIload(slot = 1))
  insns.add(LIfIcmpge(label = "thenBranch"))
  insns.add(LIload(slot = 1))
  insns.add(LIreturn)
  insns.add(LLabel(name = "thenBranch"))
  insns.add(LIload(slot = 0))
  insns.add(LIreturn)

  val params: List[JvmType] = newList()
  params.add(JInt)
  params.add(JInt)

  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "max",
    params    = params,
    ret       = JInt,
    insns     = insns,
    maxStack  = 2,
    maxLocals = 2
  )
}

// ── main(String[] args): void ─────────────────────────────────────────────────
//
// No-op entry point; just returns.  The JVM verifier will load (and verify)
// `max` even though it is never called by `main`.

func makeMainMethod(): LFunc {
  val insns: List[LInsn] = newList()
  insns.add(LReturn)

  val params: List[JvmType] = newList()
  params.add(JArray(elem = JRef(className = "java/lang/String")))

  LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "main",
    params    = params,
    ret       = JVoid,
    insns     = insns,
    maxStack  = 0,
    maxLocals = 1
  )
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b5"
  val _ = createDir(outDir)

  val pool = poolNew()

  val maxMethod  = lowerFunc(makeMaxMethod(),  pool)
  val mainMethod = lowerFunc(makeMainMethod(), pool)

  val methods: List[MethodInfo] = newList()
  methods.add(maxMethod)
  methods.add(mainMethod)

  val fields: List[FieldInfo] = newList()
  val cf = makeClassFull("B5Test", fields, methods)

  val bytes = serializeClassWithPool(cf, pool)
  val path  = outDir + "/B5Test.class"
  match writeBytes(path, bytes) {
    case Ok(_)  -> println("wrote B5Test.class (" + toString(bytes.count) + " bytes)")
    case Err(_) -> println("writeBytes failed for B5Test.class")
  }
}
