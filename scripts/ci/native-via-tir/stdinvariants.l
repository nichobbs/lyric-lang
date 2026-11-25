//! stdinvariants.l - a record with `invariant:` clauses declared in a bundled standard library package, constructed
//! and passed around from TIR (docs/70 phase 4a part 8, D856): the checker `Std.HttpEngine.Hpack` never gets an AST
//! copy of is lowered from its TIR declaration on the first call that names it.  `native-via-tir-e2e.sh` also
//! compiles a violated invariant and checks the panic message.
package StdInvariantsViaTir

import Std.Core
import Std.Console as Console
import Std.Collections
import Std.HttpEngine.Hpack

func sizeOf(t: in DynamicTable): Int {
  t.maxSize
}

func main(): Unit {
  val t = newDynamicTable(100)
  println(toString(sizeOf(t)))
  val e: List[DynEntry] = newList()
  val u = DynamicTable(entries = e, size = 0, maxSize = 7)
  println(toString(sizeOf(u)))
}
