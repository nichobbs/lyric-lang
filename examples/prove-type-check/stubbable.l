//! A program that uses the stub `@stubbable` synthesises.  The dotnet and JVM
//! front ends synthesise it before the type check; the native front end does
//! not (`Lyric.Pipeline.pipeExpandProfile`), so `lyric build --target native`
//! rejects the use, and so does `lyric prove --target native` (#8311).
@proof_required
package StubbableUse

@stubbable
pub interface Source {
  func next(): Int
}

func stubbedNext(): Int {
  val s = SourceStub(next_value = 7)
  s.next()
}

func pick(x: in Int): Int
  requires: x != 0
  ensures: result == x
{
  x
}
