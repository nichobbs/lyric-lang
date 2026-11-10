//! tests/flags_registry_concurrency_jvm_tests.l: Flags.Registry under real threads on --target jvm (#8950).
@cfg(target = "jvm")
@test_module
package Flags.FlagsRegistryConcurrencyJvmTests

import Std.Core
import Std.Collections
import Std.Testing
import Flags.Registry as Registry

extern type JThread = "java.lang.Thread"

func runAll(works: in List[() -> Unit]): Unit {
  var threads: List[JThread] = newList()
  var i = 0
  while i < works.count {
    val w = works[i]
    val t = JThread.new({ -> w() })
    t.start()
    threads.add(t)
    i = i + 1
  }
  var j = 0
  while j < threads.count {
    threads[j].join()
    j = j + 1
  }
}

func registerMany(worker: in Int, count: in Int): Unit {
  var n = 0
  while n < count {
    Registry.registerBoolFlag("w" + worker.toString() + "-b" + n.toString(), n % 2 == 0)
    Registry.registerStringFlag("w" + worker.toString() + "-s" + n.toString(), "v" + n.toString())
    n = n + 1
  }
}

test "concurrent registrations lose no flag" {
  runAll(
    [{ -> registerMany(0, 400) }, { -> registerMany(1, 400) }, { -> registerMany(2, 400) }, { -> registerMany(3, 400) }]
  )
  var wrongBool = 0
  var wrongString = 0
  var w = 0
  while w < 4 {
    var n = 0
    while n < 400 {
      if Registry.checkFlag("w" + w.toString() + "-b" + n.toString(), n % 2 != 0) != (n % 2 == 0) {
        wrongBool = wrongBool + 1
      }
      if Registry.getStringFlag("w" + w.toString() + "-s" + n.toString(), "missing") != "v" + n.toString() {
        wrongString = wrongString + 1
      }
      n = n + 1
    }
    w = w + 1
  }
  assertEqualInt(wrongBool, 0, "every Bool flag reads back its value")
  assertEqualInt(wrongString, 0, "every String flag reads back its value")
}
