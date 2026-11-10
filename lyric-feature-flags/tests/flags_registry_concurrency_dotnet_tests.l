//! tests/flags_registry_concurrency_dotnet_tests.l: Flags.Registry under real threads on --target dotnet (#8950).
@cfg(target = "dotnet")
@test_module
package Flags.FlagsRegistryConcurrencyDotnetTests

import Std.Core
import Std.Collections
import Std.Testing
import Flags.Registry as Registry

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

func runAll(works: in List[() -> Unit]): Unit {
  var tasks: List[Task] = newList()
  var i = 0
  while i < works.count {
    tasks.add(taskRun(works[i]))
    i = i + 1
  }
  var j = 0
  while j < tasks.count {
    taskWait(tasks[j])
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
