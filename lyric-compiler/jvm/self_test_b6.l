//! jvm/self_test_b6.l — Stage B6 smoke test: protected types and wire blocks.
//!
//! Builds three class files in /tmp/lyric-jvm-b6/:
//!   B6Counter.class  — a protected-type counter with increment() / getCount()
//!   B6Services.class — a wire class that exposes a counter binding
//!   B6Driver.class   — a main-method driver that exercises both
//!
//! The Expecto test (JvmLoweringB6Test.fs) runs this program to write the
//! class files, then executes `java -cp /tmp/lyric-jvm-b6 B6Driver` and
//! verifies exit code 0.  A malformed class (bad StackMapTable, wrong lock
//! descriptor, missing method) causes a VerifyError or NoSuchMethodError at
//! load time (exit != 0).
package Jvm.SelfTestB6

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering

// ── B6Counter (protected type) ────────────────────────────────────────────────
//
// protected type B6Counter {
//   var _count: Int = 0
//   entry increment(): Unit  -> _count = _count + 1
//   entry getCount(): Int    -> _count
// }
func makeCounterProtected(): LProtected {
  val countFld: List[LField] = newList()
  countFld.add(LField(flags = ACC_PRIVATE, name = "_count", fieldType = JInt))

  // increment() insns: push `this`, push `this._count + 1`, putfield _count.
  // Stack at end: empty (void return).
  val incrInsns: List[LInsn] = newList()
  incrInsns.add(LAload(slot = 0))
  // [this]
  incrInsns.add(LAload(slot = 0))
  // [this, this]
  incrInsns.add(LGetfield(owner = "B6Counter", name = "_count", t = JInt))
  // [this, count]
  incrInsns.add(LIconst(v = 1))
  // [this, count, 1]
  incrInsns.add(LIadd)
  // [this, count+1]
  incrInsns.add(LPutfield(owner = "B6Counter", name = "_count", t = JInt))
  // []

  // getCount() insns: push `this._count`.  Stack at end: [count].
  val getCountInsns: List[LInsn] = newList()
  getCountInsns.add(LAload(slot = 0))
  getCountInsns.add(LGetfield(owner = "B6Counter", name = "_count", t = JInt))

  val incrParams: List[JvmType] = newList()
  val incrEntry = LFunc(
    flags = ACC_PUBLIC,
    name = "increment",
    params = incrParams,
    ret = JVoid,
    insns = incrInsns,
    maxStack = 3,
    maxLocals = 1
  )

  val getCountParams: List[JvmType] = newList()
  val getCountEntry = LFunc(
    flags = ACC_PUBLIC,
    name = "getCount",
    params = getCountParams,
    ret = JInt,
    insns = getCountInsns,
    maxStack = 2,
    maxLocals = 1
  )

  val entries: List[LFunc] = newList()
  entries.add(incrEntry)
  entries.add(getCountEntry)

  LProtected(className = "B6Counter", fields = countFld, entries = entries)
}

// ── B6Services (wire block) ───────────────────────────────────────────────────
//
// wire B6Services {
//   singleton counter = new B6Counter()
//   expose counter
// }
func makeServicesWire(): LWire {
  // Insns that push a new B6Counter: new B6Counter; dup; invokespecial <init>()V
  val counterInsns: List[LInsn] = newList()
  counterInsns.add(LNew(className = "B6Counter"))
  counterInsns.add(LDup)
  val initPs: List[JvmType] = newList()
  counterInsns.add(LInvokespecial(owner = "B6Counter", name = "<init>", params = initPs, ret = JVoid))

  val counterBinding = LWireBinding(
    name = "counter",
    valType = JRef(className = "B6Counter"),
    insns = counterInsns,
    tempSlots = 0
  )

  val bindings: List[LWireBinding] = newList()
  bindings.add(counterBinding)

  val exposes: List[String] = newList()
  exposes.add("counter")

  LWire(className = "B6Services", providedParams = newList(), bindings = bindings, exposes = exposes)
}

// ── B6Driver (test driver) ────────────────────────────────────────────────────
//
// public class B6Driver {
//   public static void main(String[] args) {
//     B6Counter c = new B6Counter();
//     c.increment(); c.increment();
//     int v = c.getCount();             // exercises protected-type locking
//     B6Services.bootstrap();
//     B6Counter wc = B6Services.counter(); wc.increment();
//                                        // exercises wire bootstrap + accessor
//   }
// }
func makeDriverClass(pool: in Pool): ClassFile {
  val counterRef = JRef(className = "B6Counter")
  val stringArrRef = JRef(className = "java/lang/String")

  val emptyPs: List[JvmType] = newList()

  // increment / getCount param lists (no params)
  val incrPs: List[JvmType] = newList()
  val gcPs: List[JvmType] = newList()

  val mainInsns: List[LInsn] = newList()

  // new B6Counter; dup; invokespecial <init>; astore 1
  mainInsns.add(LNew(className = "B6Counter"))
  mainInsns.add(LDup)
  mainInsns.add(LInvokespecial(owner = "B6Counter", name = "<init>", params = emptyPs, ret = JVoid))
  mainInsns.add(LAstore(slot = 1))

  // c.increment() x2
  mainInsns.add(LAload(slot = 1))
  mainInsns.add(LInvokevirtual(owner = "B6Counter", name = "increment", params = incrPs, ret = JVoid))
  mainInsns.add(LAload(slot = 1))
  mainInsns.add(LInvokevirtual(owner = "B6Counter", name = "increment", params = incrPs, ret = JVoid))

  // c.getCount() — just discard result
  mainInsns.add(LAload(slot = 1))
  mainInsns.add(LInvokevirtual(owner = "B6Counter", name = "getCount", params = gcPs, ret = JInt))
  mainInsns.add(LPop)

  // B6Services.bootstrap()
  mainInsns.add(LInvokestatic(owner = "B6Services", name = "bootstrap", params = emptyPs, ret = JVoid))

  // B6Services.counter() — discard result
  mainInsns.add(LInvokestatic(owner = "B6Services", name = "counter", params = emptyPs, ret = counterRef))
  mainInsns.add(LPop)

  mainInsns.add(LReturn)

  // main is static; slot 0 = String[] args, slot 1 = counter local
  val mainParamsList: List[JvmType] = newList()
  mainParamsList.add(JArray(elem = stringArrRef))

  val mainFunc = LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "main",
    params = mainParamsList,
    ret = JVoid,
    insns = mainInsns,
    maxStack = 2,
    maxLocals = 2
  )

  val driverMethods: List[MethodInfo] = newList()
  driverMethods.add(lowerFunc(mainFunc, pool))

  val driverFields: List[FieldInfo] = newList()
  makeClassFull("B6Driver", driverFields, driverMethods)
}

// ── Entry point ───────────────────────────────────────────────────────────────
func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b6"
  val _ = createDir(outDir)

  val pool = poolNew()

  val counterCf = lowerProtected(makeCounterProtected(), pool)
  val counterBytes = serializeClassWithPool(counterCf, pool)
  match writeBytes(outDir + "/B6Counter.class", counterBytes) {
    case Ok(_) -> println("wrote B6Counter.class (" + toString(counterBytes.count) + " bytes)")
    case Err(_) -> println("writeBytes failed for B6Counter.class")
  }

  val servicesCf = lowerWire(makeServicesWire(), pool)
  val servicesBytes = serializeClassWithPool(servicesCf, pool)
  match writeBytes(outDir + "/B6Services.class", servicesBytes) {
    case Ok(_) -> println("wrote B6Services.class (" + toString(servicesBytes.count) + " bytes)")
    case Err(_) -> println("writeBytes failed for B6Services.class")
  }

  val driverCf = makeDriverClass(pool)
  val driverBytes = serializeClassWithPool(driverCf, pool)
  match writeBytes(outDir + "/B6Driver.class", driverBytes) {
    case Ok(_) -> println("wrote B6Driver.class (" + toString(driverBytes.count) + " bytes)")
    case Err(_) -> println("writeBytes failed for B6Driver.class")
  }
}
