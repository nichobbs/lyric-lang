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

// #6416 slice (a): `aspect` advice bodies used to pass through `resolveItem`
// unchanged — an alias reference inside `around(...)`'s body reached the
// weaver/codegen unresolved. Build a minimal `IAspect` item by hand (a local
// `val x: Meters = ...` inside the advice body) and assert `resolveItem`
// now resolves it, exactly like an ordinary function body would.
test "aspect around-advice body resolves aliases in local annotations (#6416)" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("Meters", tref("Long"))
  val bindPat = Pattern(kind = PBinding(name = "x", inner = None), span = syntheticSpan())
  val unitInit = Expr(kind = ELiteral(lit = LUnit), span = syntheticSpan())
  val localStmt = Statement(
    kind = SLocal(binding = LBVal(pat = bindPat, ty = Some(value = tref("Meters")), init = unitInit)),
    span = syntheticSpan()
  )
  val stmts: List[Statement] = newList()
  stmts.add(localStmt)
  val body = Block(statements = stmts, span = syntheticSpan())
  val noRow: Option[List[ArgsRowField]] = None
  val around = AspectAround(argsName = "call", retName = None, argsRow = noRow, body = body, span = syntheticSpan())
  val noConfig: List[ConfigField] = newList()
  val noMatches: List[AspectMatcher] = newList()
  val noExcept: List[String] = newList()
  val noContracts: List[ContractClause] = newList()
  val noWraps: List[String] = newList()
  val noInside: List[String] = newList()
  val decl = AspectDecl(
    name = "Timed",
    from = None,
    config = noConfig,
    matches = noMatches,
    exceptNames = noExcept,
    around = Some(value = around),
    contracts = noContracts,
    wraps = noWraps,
    inside = noInside,
    span = syntheticSpan()
  )
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val item = Item(
    docComments = noDocs,
    annotations = noAnns,
    visibility = None,
    kind = IAspect(decl = decl),
    span = syntheticSpan()
  )
  val resolved = resolveItem(at, item)
  match resolved.kind {
    case IAspect(d2) -> {
      match d2.around {
        case Some(a2) -> {
          match a2.body.statements[0].kind {
            case SLocal(b2) -> {
              match b2 {
                case LBVal(_, tyOpt, _) -> {
                  match tyOpt {
                    case Some(te2) -> assertEqual(trefName(te2), "Long", "aspect body local alias resolves to Long")
                    case None -> assertTrue(false, "expected a resolved type annotation")
                  }
                }
                case _ -> assertTrue(false, "expected LBVal")
              }
            }
            case _ -> assertTrue(false, "expected SLocal")
          }
        }
        case None -> assertTrue(false, "expected around advice to survive resolveItem")
      }
    }
    case _ -> assertTrue(false, "resolved item must still be an IAspect")
  }
}

// #6416 slice (b): a cycle routed through a const-generic VALUE expression
// (`TAValue`'s `expr` re-entering the expr walker) used to escape the
// depth-64 cycle guard entirely, because `resolveExpr`'s depth-0 wrapper
// reset the counter on every re-entry — a hand-built alias whose own rhs
// embeds a lambda param annotation naming ITSELF, reachable only through
// the array-size `TAValue`, would recurse unboundedly. The whole point of
// this test is that it RETURNS at all: before the depth-threading fix, this
// exact shape crashed the self-hosted compiler with a stack overflow
// (verified live via `lyric build` against the pre-fix compiler) instead of
// terminating — a regression here hangs/crashes the test process, not just
// fails an assertion.
test "cycle routed through a const-generic value expression's lambda-param annotation terminates (#6416)" {
  val lambdaParam = LambdaParam(name = "x", ty = Some(value = tref("A")), span = syntheticSpan())
  val lambdaParams: List[LambdaParam] = newList()
  lambdaParams.add(lambdaParam)
  val noStmts: List[Statement] = newList()
  val lambdaBody = Block(statements = noStmts, span = syntheticSpan())
  val lambdaExpr = Expr(kind = ELambda(lambdaParams = lambdaParams, body = lambdaBody), span = syntheticSpan())
  val sizeArg = TAValue(expr = lambdaExpr)
  val arrRhs = TypeExpr(kind = TArray(size = sizeArg, element = tref("Int")), span = syntheticSpan())
  val at: Map[String, TypeExpr] = newMap()
  at.add("A", arrRhs)
  val noGenerics: List[String] = newList()
  val resolved = resolveTypeExpr(at, noGenerics, tref("A"))
  match resolved.kind {
    case TArray(_, _) -> assertTrue(true, "pathological const-generic-value cycle terminates with an array shape")
    case _ -> assertTrue(false, "expected the array shape to survive (possibly with a nested unresolved residual)")
  }
}

// #6469 (PR #6468 review): the `where TArgs has { field: Type }` row
// clause's field types are real TypeExprs the weaver's row-satisfaction
// check compares BY NAME against the matched function's already-resolved
// parameter types (`bmodeTypeExprKey`) — an unresolved alias here
// spuriously key-mismatches (A0047) and drops the field. Assert
// `resolveAspectDecl` (via `resolveItem`) resolves row-field types like
// every other aspect surface.
test "aspect argsRow field types resolve aliases (#6469)" {
  val at: Map[String, TypeExpr] = newMap()
  at.add("Meters", tref("Long"))
  val emptyStmts: List[Statement] = newList()
  val body = Block(statements = emptyStmts, span = syntheticSpan())
  val rowFields: List[ArgsRowField] = newList()
  rowFields.add(ArgsRowField(name = "bonus", ty = tref("Meters"), span = syntheticSpan()))
  rowFields.add(ArgsRowField(name = "label", ty = tref("String"), span = syntheticSpan()))
  val around = AspectAround(
    argsName = "call",
    retName = None,
    argsRow = Some(value = rowFields),
    body = body,
    span = syntheticSpan()
  )
  val noConfig: List[ConfigField] = newList()
  val noMatches: List[AspectMatcher] = newList()
  val noExcept: List[String] = newList()
  val noContracts: List[ContractClause] = newList()
  val noWraps: List[String] = newList()
  val noInside: List[String] = newList()
  val decl = AspectDecl(
    name = "ValidateBonus",
    from = None,
    config = noConfig,
    matches = noMatches,
    exceptNames = noExcept,
    around = Some(value = around),
    contracts = noContracts,
    wraps = noWraps,
    inside = noInside,
    span = syntheticSpan()
  )
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val item = Item(
    docComments = noDocs,
    annotations = noAnns,
    visibility = None,
    kind = IAspect(decl = decl),
    span = syntheticSpan()
  )
  val resolved = resolveItem(at, item)
  match resolved.kind {
    case IAspect(d2) -> {
      match d2.around {
        case Some(a2) -> {
          match a2.argsRow {
            case Some(fields2) -> {
              assertEqualInt(fields2.count, 2, "both row fields survive resolution")
              assertEqual(trefName(fields2[0].ty), "Long", "aliased row-field type resolves through the alias")
              assertEqual(fields2[0].name, "bonus", "row-field name untouched")
              assertEqual(trefName(fields2[1].ty), "String", "non-alias row-field type unchanged")
            }
            case None -> assertTrue(false, "argsRow must survive resolution")
          }
        }
        case None -> assertTrue(false, "around must survive resolution")
      }
    }
    case _ -> assertTrue(false, "resolved item must still be an IAspect")
  }
}
