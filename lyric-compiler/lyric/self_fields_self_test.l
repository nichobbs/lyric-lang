//! self_fields_self_test.l — unit tests for `Lyric.SelfFields` (#8264).
//!
//! A member body's bare field references are written as `self.<field>`
//! before any backend runs, inside the member's lambdas too.  A lambda in a
//! member of a type with type parameters reads the receiver on every target:
//! MSIL hosts it in a closure class generic over the type's parameters
//! (#8284).  The runtime behaviour is covered by
//! `member_local_shadow_self_test.l` and `generic_closure_self_test.l`.
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
import Lyric.ContractElaborator as Ast

func resolved(text: in String): SourceFile {
  val pr = parse(text)
  if pr.diagnostics.count > 0 {
    panic("test source does not parse: " + pr.diagnostics[0].message)
  }
  val noRecords: List[RecordDecl] = newList()
  val noSites: Map[String, Bool] = newMap()
  SelfFields.resolveSelfFieldsInFile(pr.file, noRecords, noSites)
}

// How many lambdas in `text` read the receiver once it is resolved.
func receiverLambdas(text: in String): Int {
  val found: List[Bool] = newList()
  val _ = Ast.mapExprsInFile(resolved(text), { e: Expr -> noteReceiverLambda(e, found) })
  found.count
}

func noteReceiverLambda(e: in Expr, found: in List[Bool]): Expr {
  match e.kind {
    case ELambda(_, body) -> {
      val seen: List[Bool] = newList()
      val _ = Ast.mapBlock(body, { x: Expr -> noteSelf(x, seen) })
      if seen.count > 0 {
        found.add(true)
      }
    }
    case _ -> ()
  }
  e
}

func noteSelf(x: in Expr, seen: in List[Bool]): Expr {
  match x.kind {
    case ESelf -> seen.add(true)
    case _ -> ()
  }
  x
}

test "a bare field read in a lambda of a generic record method reads self" {
  val n = receiverLambdas(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val g = { k: Int -> k + n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(n, 1, "the lambda reads the receiver")
}

test "a generic protected type's nested lambdas read self" {
  val n = receiverLambdas(
    "package P\nprotected type Cell[T] {\n  var item: T\n  var n: Int = 2\n  entry f(): Int {\n    val g = { k: Int ->\n      val h = { j: Int -> j + n }\n      h(k)\n    }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(n, 2, "the inner lambda and the one enclosing it")
}

test "a local of the field's name and a lambda parameter shadow the field" {
  val viaLocal = receiverLambdas(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val n = n\n    val g = { k: Int -> k + n }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(viaLocal, 0, "a local of the field's name")
  val param = receiverLambdas(
    "package P\nrecord Box[T] {\n  item: T\n  n: Int\n  func f(): Int {\n    val g = { n: Int -> n + 1 }\n    g(1)\n  }\n}\n"
  )
  assertEqualInt(param, 0, "a lambda parameter of the field's name")
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
