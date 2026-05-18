// jvm/self_test_b4.l — Stage B4 smoke test for union-type lowering.
//
// Builds three JVM class files that together implement the `Option` union:
//
//   Option.class        — abstract base class (ACC_ABSTRACT)
//   Option$Some.class   — concrete case carrying `int value`
//   Option$None.class   — concrete case with no fields
//
// Then builds a helper class `OptionHelper.class` with a static method:
//
//   public static int unwrapOr(Option opt, int defaultVal)
//
// That method uses `instanceof` + `checkcast` to pattern-match the union,
// returning `value` for Some and `defaultVal` for None.
//
// All class files are written to /tmp/lyric-jvm-b4/ and verified by
// the Expecto test via `javap -c`.

package Jvm.SelfTestB4

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering

// ── Option union hierarchy ─────────────────────────────────────────────────────

func makeOptionClasses(pool: in Pool): List[ClassFile] {
  // Case Some: one int field `value`
  val someField = LField(flags = ACC_PUBLIC, name = "value", fieldType = JInt)
  val someFields: List[LField] = newList()
  someFields.add(someField)
  val someCase = LUnionCase(caseName = "Some", fields = someFields)

  // Case None: no fields
  val noneFields: List[LField] = newList()
  val noneCase = LUnionCase(caseName = "None", fields = noneFields)

  val cases: List[LUnionCase] = newList()
  cases.add(someCase)
  cases.add(noneCase)

  val unionMethods: List[LFunc] = newList()
  val opt = LUnion(baseName = "Option", cases = cases, methods = unionMethods)
  lowerUnion(opt, pool)
}

// ── OptionHelper.class: static `unwrapOr(Option, int): int` ──────────────────
//
// Pseudo-code:
//   if (opt instanceof Option$Some) {
//     return ((Option$Some) opt).value;
//   } else {
//     return defaultVal;
//   }
//
// LInsn sequence:
//   LAload(0)                          // load opt
//   LInstanceof("Option$Some")         // push 1/0
//   LIfeq("isNone")                    // if 0 → isNone
//   LAload(0)                          // load opt again
//   LCheckcast("Option$Some")          // cast
//   LGetfield("Option$Some","value",JInt)
//   LIreturn
//   LLabel("isNone")
//   LIload(1)                          // load defaultVal
//   LIreturn

func makeHelperClass(pool: in Pool): ClassFile {
  val insns: List[LInsn] = newList()
  insns.add(LAload(slot = 0))
  insns.add(LInstanceof(className = "Option$Some"))
  insns.add(LIfeq(label = "isNone"))
  insns.add(LAload(slot = 0))
  insns.add(LCheckcast(className = "Option$Some"))
  insns.add(LGetfield(owner = "Option$Some", name = "value", t = JInt))
  insns.add(LIreturn)
  insns.add(LLabel(name = "isNone"))
  insns.add(LIload(slot = 1))
  insns.add(LIreturn)

  val paramTypes: List[JvmType] = newList()
  paramTypes.add(JRef(className = "Option"))
  paramTypes.add(JInt)

  val fn = LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "unwrapOr",
    params    = paramTypes,
    ret       = JInt,
    insns     = insns,
    maxStack  = 2,
    maxLocals = 2
  )

  val helperMethods: List[LFunc] = newList()
  helperMethods.add(fn)
  val helperFields: List[LField] = newList()
  val helper = LRecord(
    className = "OptionHelper",
    fields    = helperFields,
    methods   = helperMethods
  )
  lowerRecord(helper, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b4"
  val _ = createDir(outDir)

  // Write Option hierarchy
  val pool = poolNew()
  val optionClasses = makeOptionClasses(pool)
  val names: List[String] = newList()
  names.add("Option")
  names.add("Option$Some")
  names.add("Option$None")

  var i = 0
  while i < optionClasses.count {
    val cf = optionClasses[i]
    val name = names[i]
    val bytes = serializeClassWithPool(cf, pool)
    val path = outDir + "/" + name + ".class"
    match writeBytes(path, bytes) {
      case Ok(_)    -> println("wrote " + name + ".class (" + toString(bytes.count) + " bytes)")
      case Err(_)   -> println("writeBytes failed for " + name + ".class")
    }
    i = i + 1
  }

  // Write OptionHelper
  val helperPool = poolNew()
  val helperCf = makeHelperClass(helperPool)
  val helperBytes = serializeClassWithPool(helperCf, helperPool)
  val helperPath = outDir + "/OptionHelper.class"
  match writeBytes(helperPath, helperBytes) {
    case Ok(_)    -> println("wrote OptionHelper.class (" + toString(helperBytes.count) + " bytes)")
    case Err(_)   -> println("writeBytes failed for OptionHelper.class")
  }
}
