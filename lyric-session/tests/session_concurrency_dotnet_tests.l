//! tests/session_concurrency_dotnet_tests.l — `InProcessSessionStore` under
//! real threads on `--target dotnet` (#8950).  Each worker owns its own
//! session, so the expected end state is deterministic; an unsynchronised map
//! loses entries.
@cfg(target = "dotnet")
@test_module
package Session.SessionConcurrencyDotnetTests

import Std.Core
import Std.Collections
import Std.Testing
import Session

// One slot per worker: each worker writes only its own.
ref record Slot {
  var id: String
}

func newSlots(): List[Slot] {
  val slots: List[Slot] = newList()
  var i = 0
  while i < 4 {
    slots.add(Slot(id = ""))
    i = i + 1
  }
  return slots
}

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

func hammer(store: in Session.SessionStore, slot: in Slot, rounds: in Int): Unit {
  val id = unwrapResult(store.create())
  var n = 0
  while n < rounds {
    val key = "k" + n.toString()
    match store.set(id, key, "v" + n.toString()) {
      case Ok(_) -> ()
      case Err(e) -> panic("set failed: " + e.message)
    }
    if n % 4 == 0 {
      match store.delete(id, key) {
        case Ok(_) -> ()
        case Err(e) -> panic("delete failed: " + e.message)
      }
    }
    n = n + 1
  }
  slot.id = id
}

test "concurrent sessions lose no create, set or delete" {
  val store = Session.inMemory()
  val slots = newSlots()
  val rounds = 400
  runAll(
    [
      { -> hammer(store, slots[0], rounds) },
      { -> hammer(store, slots[1], rounds) },
      { -> hammer(store, slots[2], rounds) },
      { -> hammer(store, slots[3], rounds) }
    ]
  )
  var w = 0
  var missing = 0
  var resurrected = 0
  while w < 4 {
    val id = slots[w].id
    var n = 0
    while n < rounds {
      val got = unwrapResult(store.get(id, "k" + n.toString()))
      if n % 4 == 0 {
        if isSome(got) {
          resurrected = resurrected + 1
        }
      } else if not isSome(got) {
        missing = missing + 1
      }
      n = n + 1
    }
    w = w + 1
  }
  assertEqualInt(missing, 0, "every key that was set and not deleted is still present")
  assertEqualInt(resurrected, 0, "every deleted key is gone")
}

test "concurrent creates issue distinct ids" {
  val store = Session.inMemory()
  val slots = newSlots()
  runAll(
    [
      { -> hammer(store, slots[0], 1) },
      { -> hammer(store, slots[1], 1) },
      { -> hammer(store, slots[2], 1) },
      { -> hammer(store, slots[3], 1) }
    ]
  )
  assertTrue(
    slots[0].id != slots[1].id and slots[1].id != slots[2].id and slots[2].id != slots[3].id and
      slots[0].id != slots[3].id,
    "four concurrent creates, four ids"
  )
}
