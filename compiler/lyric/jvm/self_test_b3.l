// jvm/self_test_b3.l — Stage B3 smoke test for Jvm.Lowering.
//
// Builds two JVM class files using the high-level `LInsn` / `LRecord` API:
//
//   Adder.class  — a class with a static `add(int, int) : int` method.
//   Point.class  — a record class with `int x` and `int y` fields.
//
// Each class is written to /tmp/lyric-jvm-b3/ and the file name is printed.

package Jvm.SelfTestB3

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering

// ── Adder.class ───────────────────────────────────────────────────────────────
// public class Adder {
//   public static int add(int a, int b) { return a + b; }
// }

func makeAdderBytes(): List[Byte] {
  val pool = poolNew()

  val addInsns: List[LInsn] = newList()
  addInsns.add(LIload(slot = 0))
  addInsns.add(LIload(slot = 1))
  addInsns.add(LIadd)
  addInsns.add(LIreturn)

  val addFunc = LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "add",
    params    = { val ps: List[JvmType] = newList(); ps.add(JInt); ps.add(JInt); ps },
    ret       = JInt,
    insns     = addInsns,
    maxStack  = 2,
    maxLocals = 2
  )

  val adderMethods: List[LFunc] = newList()
  adderMethods.add(addFunc)

  val adderFields: List[LField] = newList()
  val adder = LRecord(
    className = "Adder",
    fields    = adderFields,
    methods   = adderMethods
  )

  val cf = lowerRecord(adder, pool)
  serializeClassWithPool(cf, pool)
}

// ── Point.class ───────────────────────────────────────────────────────────────
// public class Point {
//   public int x;
//   public int y;
//   public Point(int x, int y) { this.x = x; this.y = y; }
// }

func makePointBytes(): List[Byte] {
  val pool = poolNew()

  val xField = LField(flags = ACC_PUBLIC, name = "x", fieldType = JInt)
  val yField = LField(flags = ACC_PUBLIC, name = "y", fieldType = JInt)

  val pointFields: List[LField] = newList()
  pointFields.add(xField)
  pointFields.add(yField)

  val pointMethods: List[LFunc] = newList()

  val point = LRecord(
    className = "Point",
    fields    = pointFields,
    methods   = pointMethods
  )

  val cf = lowerRecord(point, pool)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b3"
  val _ = createDir(outDir)

  val adderPath = outDir + "/Adder.class"
  val adderBytes = makeAdderBytes()
  match writeBytes(adderPath, adderBytes) {
    case Ok(_)    -> println("wrote Adder.class (" + toString(adderBytes.count) + " bytes)")
    case Err(err) -> println("writeBytes failed for Adder.class")
  }

  val pointPath = outDir + "/Point.class"
  val pointBytes = makePointBytes()
  match writeBytes(pointPath, pointBytes) {
    case Ok(_)    -> println("wrote Point.class (" + toString(pointBytes.count) + " bytes)")
    case Err(err) -> println("writeBytes failed for Point.class")
  }
}
