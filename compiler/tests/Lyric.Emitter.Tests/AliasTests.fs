/// End-to-end tests for `import X as Y` aliases (D-progress-018).
///
/// Two flavours:
///   - selector alias `import X.{foo as bar}` — clones the imported
///     IFunc under the alias name during stdlib resolution.
///   - package alias `import X as A` — handled by `AliasRewriter` as
///     a post-parse AST transform (`A.foo` → `foo`, `A.Type[T]` →
///     `Type[T]`, etc.).  After rewriting, downstream passes are
///     alias-blind.
module Lyric.Emitter.Tests.AliasTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "selector_alias_function_call",
    """
package AL1
import Std.Collections.{newList as mkList}

func main(): Unit {
  val xs: List[Int] = mkList()
  xs.add(7)
  xs.add(11)
  println(xs.count)
}
""",
    "2"

    "selector_alias_multiple",
    """
package AL2
import Std.Collections.{newList as mkList, newMap as mkMap}

func main(): Unit {
  val xs: List[Int] = mkList()
  xs.add(1)
  println(xs.count)

  val m: Map[String, Int] = mkMap()
  m.add("a", 1)
  println(m.count)
}
""",
    "1\n1"

    "package_alias_function_call",
    """
package AL3
import Std.Collections as Coll

func main(): Unit {
  val xs: List[Int] = Coll.newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  println(xs.count)
}
""",
    "3"

    "package_alias_in_type_position",
    """
package AL4
import Std.Collections as Coll

func make(): Coll.List[Int] {
  val xs: Coll.List[Int] = Coll.newList()
  xs.add(1)
  xs.add(2)
  return xs
}

func main(): Unit {
  val xs = make()
  println(xs.count)
}
""",
    "2"

    "alias_does_not_remove_original_name",
    """
package AL5
import Std.Collections.{newList as mkList}

func main(): Unit {
  // `import X.{foo as bar}` adds `bar` without removing `foo`.
  val a: List[Int] = mkList()
  val b: List[Int] = newList()
  a.add(1)
  b.add(2)
  println(a.count + b.count)
}
""",
    "2"
]

let tests =
    testSequenced
    <| testList "import X as Y aliases (D-progress-018)"
                (cases |> List.map mk)
