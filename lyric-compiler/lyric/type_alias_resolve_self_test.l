//! Unit-level self-test for `Lyric.TypeAliasResolve` (#6404/#6410/#6412):
//! exercises the resolver's pure functions directly against hand-built ASTs,
//! most importantly the cyclic-alias depth-bound guard, which cannot be a
//! runtime test (a cyclic program must FAIL type-check, and the guard's
//! whole job is making sure it reaches the type checker instead of hanging
//! the pre-pass).  Runtime/dual-target coverage for the resolved SHAPES
//! lives in `bare_func_ref_self_test.l`.
@test_module
package Lyric.TypeAliasResolveSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Parser
import Lyric.TypeAliasResolve

func tref(name: String): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = syntheticSpan())), span = syntheticSpan())
}

func trefName(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "<multi>" }
    case TUnit -> "<unit>"
    case _ -> "<other>"
  }
}

test "linear alias chain resolves to its target" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("A", tref("B"))
  at.add("B", tref("Long"))
  val noGenerics: List[String] = newList()
  val resolved = resolveTypeExpr(at, noGenerics, tref("A"))
  assertEqual(trefName(resolved), "Long", "A -> B -> Long bottoms out")
}

test "mutually-cyclic alias chain terminates and stays unresolved (#6410)" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("A", tref("B"))
  at.add("B", tref("A"))
  val noGenerics: List[String] = newList()
  // The whole point: this must RETURN (bounded), not hang — and the result
  // must still be a TRef so the type checker's T0017 fires downstream.
  val resolved = resolveTypeExpr(at, noGenerics, tref("A"))
  match resolved.kind {
    case TRef(_) -> assertTrue(true, "cycle returned an unresolved TRef")
    case _ -> assertTrue(false, "cycle must stay an unresolved TRef")
  }
}

test "self-referential alias terminates (#6410)" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("A", tref("A"))
  val noGenerics: List[String] = newList()
  val resolved = resolveTypeExpr(at, noGenerics, tref("A"))
  match resolved.kind {
    case TRef(_) -> assertTrue(true, "self-cycle returned an unresolved TRef")
    case _ -> assertTrue(false, "self-cycle must stay an unresolved TRef")
  }
}

test "a generic type-parameter name shadows an alias of the same name" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("T", tref("Long"))
  val generics: List[String] = newList()
  generics.add("T")
  val resolved = resolveTypeExpr(at, generics, tref("T"))
  assertEqual(trefName(resolved), "T", "in-scope type param wins over the alias")
}

test "impl header target and iface resolve through aliases (#6414)" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("Handler2", tref("Applier"))
  at.add("AliasIface", tref("SomeIface"))
  val ifaceSegs: List[String] = newList()
  ifaceSegs.add("AliasIface")
  val noArgs: List[TypeArg] = newList()
  val noMembers: List[ImplMember] = newList()
  val decl = ImplDecl(
    generics = None,
    iface = ConstraintRef(
      head = ModulePath(segments = ifaceSegs, span = syntheticSpan()),
      args = noArgs,
      span = syntheticSpan()
    ),
    target = tref("Handler2"),
    whereClause = None,
    members = noMembers,
    span = syntheticSpan()
  )
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val item = Item(
    docComments = noDocs,
    annotations = noAnns,
    visibility = None,
    kind = IImpl(decl = decl),
    span = syntheticSpan()
  )
  val resolved = resolveItem(at, item)
  match resolved.kind {
    case IImpl(d2) -> {
      assertEqual(trefName(d2.target), "Applier", "impl target resolves through the alias")
      val ifaceHead = if d2.iface.head.segments.count == 1 { d2.iface.head.segments[0] } else { "<multi>" }
      assertEqual(ifaceHead, "SomeIface", "impl iface head resolves through the alias")
    }
    case _ -> assertTrue(false, "resolved item must still be an IImpl")
  }
}

test "non-alias names pass through untouched" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("A", tref("Long"))
  val noGenerics: List[String] = newList()
  val resolved = resolveTypeExpr(at, noGenerics, tref("NotAnAlias"))
  assertEqual(trefName(resolved), "NotAnAlias", "unknown name unchanged")
}
