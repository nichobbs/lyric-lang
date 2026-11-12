//! heaprecords.l - heap records (a reference field or a `var` field) lowered from TIR (docs/70
//! phase 4a, D520): allocation with the destructor, fields owned by the object, `.copy` as a new
//! object.  `native-via-tir-e2e.sh` runs it both ways and then under AddressSanitizer, so a leak
//! or a double release fails the run.
package HeapRecordsViaTir

import Std.Core
import Std.Console as Console

record Person {
  name: String
  age: Int
}

record Team {
  lead: Person
  label: String
}

func make(name: in String, age: in Int): Person {
  Person(name = name, age = age)
}

func greeting(p: in Person): String {
  "hi " + p.name
}

func older(p: in Person): Person {
  p.copy(age = p.age + 1)
}

func relabelled(t: in Team, label: in String): Team {
  t.copy(label = label)
}

func describe(t: in Team): String {
  t.lead.name + "/" + t.label
}

func main(): Unit {
  val p = make("ann", 30)
  println(greeting(p))
  val q = older(p)
  println(toString(q.age))
  println(q.name)
  println(toString(p.age))
  val t = Team(lead = q, label = "core")
  println(describe(t))
  val u = relabelled(t, "ops")
  println(describe(u))
  println(describe(t))
}
