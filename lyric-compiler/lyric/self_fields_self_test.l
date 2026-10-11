//! self_fields_self_test.l — unit tests for `Lyric.SelfFields` and the
//! F0048 check built on it (#8264, #8284).
//!
//! F0048: on `--target dotnet` a lambda in a member of a type with type
//! parameters cannot read the receiver (`self`, or a field by bare name),
//! because MSIL lifts the lambda into a method of the non-generic package
//! class.  `Lyric.Pipeline.genericReceiverLambdaDiagnostics` reports it at the
//! lambda, before codegen, once per outermost such lambda.  The runtime
//! behaviour of field resolution is covered by `member_local_shadow_self_test.l`.
//!
//!   lyric test lyric-compiler/lyric/self_fields_self_test.l
@test_module
package Lyric.SelfFields.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.SelfFields as SelfFields
import Lyric.Pipeline as Pipe

func resolved(text: in String): SourceFile {
  val pr = parse(text)
  if pr.diagnostics.count > 0 {
    panic("test source does not parse: " + pr.diagnostics[0].message)
  }
  val noRecords: List[RecordDecl] = newList()
  val noSites: Map[String, Bool] = newMap()
  SelfFields.resolveSelfFieldsInFile(pr.file, noRecords, noSites)
}

func f0048Lines(text: in String): List[Int] {
  val lines: List[Int] = newList()
  for d in Pipe.genericReceiverLambdaDiagnostics(resolved(text)) {
    if d.code == "F0048" {
      lines.add(d.span.startPos.line)
    }
  }
  lines
}

test "a bare field read in a lambda of a generic record method is F0048 at the lambda" {
  val lines = f0048Lines(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val g = { k: Int -> k + n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(lines.count, 1, "one diagnostic")
  assertEqualInt(lines[0], 6, "on the lambda's line")
}

test "an explicit self read in a lambda of a generic impl method is F0048" {
  val lines = f0048Lines(
    "package P\ninterface I {\n  func f(): Int\n}\nrecord Box[T] {\n  item: T\n  n: Int\n}\nimpl[T] I for Box[T] {\n  func f(): Int {\n    val g = { k: Int -> k + self.n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(lines.count, 1, "one diagnostic")
}

test "a generic protected type's lambda nested in another is reported once" {
  val lines = f0048Lines(
    "package P\nprotected type Cell[T] {\n  var item: T\n  var n: Int = 2\n  entry f(): Int {\n    val g = { k: Int ->\n      val h = { j: Int -> j + n }\n      h(k)\n    }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(lines.count, 1, "the outer lambda only")
  assertEqualInt(lines[0], 6, "on the outer lambda's line")
}

test "a local read into the lambda, a non-generic type and a shadowing parameter are not F0048" {
  val viaLocal = f0048Lines(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val n = n\n    val g = { k: Int -> k + n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(viaLocal.count, 0, "a local of the field's name")
  val plain = f0048Lines(
    "package P\nrecord Plain {\n  n: Int\n  func f(): Int {\n    val g = { k: Int -> k + n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(plain.count, 0, "a non-generic record")
  val param = f0048Lines(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val g = { n: Int -> n + 1 }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(param.count, 0, "a lambda parameter of the field's name")
}

test "a value-only generic is not F0048" {
  val lines = f0048Lines(
    "package P\nprotected type Ring[N: Nat] {\n  var next: Int = 0\n  entry f(): Int {\n    val g = { k: Int -> k + next }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(lines.count, 0, "no type parameter")
}

test "resolution marks each member it resolves, once" {
  val f = resolved("package P\nrecord R {\n  n: Int\n  func get(): Int {\n    n\n  }\n}\n")
  val again = SelfFields.resolveSelfFieldsInFile(f, newList(), newMap())
  match again.items[0].kind {
    case IRecord(decl) -> match decl.members[1] {
      case RMFunc(fn) -> {
        var marks = 0
        for a in fn.annotations {
          if a.name.segments[0] == selfResolvedAnnotationName() {
            marks = marks + 1
          }
        }
        assertEqualInt(marks, 1, "one marker")
      }
      case _ -> assertTrue(false, "the method")
    }
    case _ -> assertTrue(false, "the record")
  }
}
