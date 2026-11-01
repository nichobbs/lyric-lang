//! resolve_collect.l - declarations and their DefPaths (docs/70 §4.2, D313).
//!
//! Walks a package's items and registers every declaration with the path
//! that names it: a type is `Pkg::Name`, a union case `Pkg::Union::Case`, a
//! function `Pkg::name(P1,P2)`, a method `Pkg::Type::name(P1)`, an impl
//! method `Pkg::Target::$impl(Iface)::name(P1)`.  A function's path carries
//! its parameter types as written because an overload set shares one name, and
//! a path must name one declaration the same way in every compilation and in
//! an interface artifact.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

func joinWith(parts: in List[String], sep: in String): String {
  var s = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      s = s + sep
    }
    s = s + parts[i]
    i = i + 1
  }
  s
}

func renderPath(p: in ModulePath): String {
  modulePathJoin(p.segments)
}

func renderTypeArgs(args: in List[TypeArg]): String {
  val parts: List[String] = newList()
  for a in args {
    match a {
      case TAType(te) -> parts.add(renderTypeExprKey(te))
      case TAValue(_) -> parts.add("_")
    }
  }
  "[" + joinWith(parts, ",") + "]"
}

/// A type as written, in a canonical spelling with no whitespace: the part of
/// a function's DefPath that tells its overloads apart.  An alias is not
/// expanded, so the key is the same before and after alias resolution.
pub func renderTypeExprKey(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> renderPath(path)
    case TGenericApp(head, args) -> renderPath(head) + renderTypeArgs(args)
    case TArray(size, element) -> {
      val sz = match size {
        case TAType(t) -> renderTypeExprKey(t)
        case TAValue(_) -> "_"
      }
      "array[" + sz + "," + renderTypeExprKey(element) + "]"
    }
    case TSlice(element) -> "slice[" + renderTypeExprKey(element) + "]"
    case TRefined(underlying, _) -> renderPath(underlying) + " range"
    case TTuple(types) -> {
      val parts: List[String] = newList()
      for t in types {
        parts.add(renderTypeExprKey(t))
      }
      "(" + joinWith(parts, ",") + ")"
    }
    case TNullable(inner) -> renderTypeExprKey(inner) + "?"
    case TFunction(ps, ret) -> {
      val parts: List[String] = newList()
      for t in ps {
        parts.add(renderTypeExprKey(t))
      }
      "(" + joinWith(parts, ",") + ")->" + renderTypeExprKey(ret)
    }
    case TUnit -> "()"
    case TSelf -> "Self"
    case TNever -> "Never"
    case TParen(inner) -> renderTypeExprKey(inner)
    case TError -> "?"
  }
}

/// `(P1,P2)`: the parameter types of a declaration, modes left out.
pub func paramsKey(params: in List[Param]): String {
  val parts: List[String] = newList()
  for p in params {
    parts.add(renderTypeExprKey(p.ty))
  }
  "(" + joinWith(parts, ",") + ")"
}

/// The DefPath of the function `name` with parameters `params` declared by
/// `pkg`.
pub func funcDefPath(pkg: in String, name: in String, params: in List[Param]): DefPath {
  topDefPath(pkg, name + paramsKey(params))
}

/// The DefPath of the method `name` of the declaration at `owner`.
pub func methodDefPath(owner: in DefPath, name: in String, params: in List[Param]): DefPath {
  memberDefPath(owner, name + paramsKey(params))
}

pub func declVisOf(v: in Option[Visibility]): DeclVis {
  match v {
    case Some(vis) -> match vis {
      case VisPub(_) -> DVPublic
      case VisInternal(_) -> DVInternal
    }
    case None -> DVPrivate
  }
}

/// Whether a declaration can be named from another package.
pub func declCrossPackageVisible(d: in Decl): Bool {
  match d.vis {
    case DVPrivate -> false
    case _ -> true
  }
}

/// Register the package `pkg` and the packages it re-exports.
pub func registerPackage(tbl: in DeclTable, pkg: in String, reexports: in List[String]): Unit {
  if tbl.packages.containsKey(pkg) {
    tbl.packages.remove(pkg)
  }
  tbl.packages.add(pkg, PackageInfo(name = pkg, reexports = reexports))
}

func addDecl(
  tbl: in DeclTable,
  pkg: in String,
  path: in DefPath,
  name: in String,
  kind: in SymKind,
  vis: in DeclVis,
  parent: in Option[SymbolId],
  bare: in Bool,
  span: in Span,
): SymbolId {
  val id = internDefPath(tbl.interner, path)
  val ix = tbl.decls.count
  tbl.decls.add(Decl(id = id, path = path, name = name, kind = kind, vis = vis, pkg = pkg, parent = parent, bare = bare, span = span))
  if tbl.byId.containsKey(toString(id.id)) {
    tbl.byId.remove(toString(id.id))
  }
  tbl.byId.add(toString(id.id), ix)
  if bare {
    match mapGet(tbl.byName, name) {
      case Some(ixs) -> ixs.add(ix)
      case None -> {
        val ixs: List[Int] = newList()
        ixs.add(ix)
        tbl.byName.add(name, ixs)
      }
    }
  }
  id
}

func dotIndex(s: in String): Int {
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == "." {
      return i
    }
    i = i + 1
  }
  -1
}

func addMethod(
  tbl: in DeclTable, pkg: in String, owner: in DefPath, fn: in FunctionDecl, vis: in DeclVis
): Unit {
  val _ = addDecl(tbl, pkg, methodDefPath(owner, fn.name, fn.params), fn.name, SKMethod, vis, None, false, fn.span)
}

func addSigMethod(
  tbl: in DeclTable, pkg: in String, owner: in DefPath, sig: in FunctionSig, vis: in DeclVis
): Unit {
  val _ = addDecl(tbl, pkg, methodDefPath(owner, sig.name, sig.params), sig.name, SKMethod, vis, None, false, sig.span)
}

/// Register the declarations of `items`, which package `pkg` declares.
pub func registerItems(tbl: in DeclTable, pkg: in String, items: in List[Item]): Unit {
  for it in items {
    registerItem(tbl, pkg, it)
  }
}

func registerItem(tbl: in DeclTable, pkg: in String, it: in Item): Unit {
  val vis = declVisOf(it.visibility)
  val span = it.span
  match it.kind {
    case IRecord(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val _ = addDecl(tbl, pkg, path, decl.name, SKRecord, vis, None, true, span)
      registerRecordMembers(tbl, pkg, path, decl, vis)
    }
    case IExposedRec(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val _ = addDecl(tbl, pkg, path, decl.name, SKExposedRecord, vis, None, true, span)
      registerRecordMembers(tbl, pkg, path, decl, vis)
    }
    case IUnion(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val uid = addDecl(tbl, pkg, path, decl.name, SKUnion, vis, None, true, span)
      for c in decl.cases {
        val _ = addDecl(tbl, pkg, memberDefPath(path, c.name), c.name, SKUnionCase, vis, Some(value = uid), true, c.span)
      }
    }
    case IEnum(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val eid = addDecl(tbl, pkg, path, decl.name, SKEnum, vis, None, true, span)
      for c in decl.cases {
        val _ = addDecl(tbl, pkg, memberDefPath(path, c.name), c.name, SKEnumCase, vis, Some(value = eid), true, c.span)
      }
    }
    case IOpaque(decl) -> {
      val _ = addDecl(tbl, pkg, typeDefPath(pkg, decl.name), decl.name, SKOpaque, vis, None, true, span)
    }
    case IProtected(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val _ = addDecl(tbl, pkg, path, decl.name, SKProtected, vis, None, true, span)
      for m in decl.members {
        match m {
          case PMFunc(fn) -> addMethod(tbl, pkg, path, fn, vis)
          case PMEntry(e) -> {
            val _ = addDecl(tbl, pkg, methodDefPath(path, e.name, e.params), e.name, SKMethod, vis, None, false, e.span)
          }
          case _ -> ()
        }
      }
    }
    case IDistinctType(decl) -> {
      val _ = addDecl(tbl, pkg, typeDefPath(pkg, decl.name), decl.name, SKDistinct, vis, None, true, span)
    }
    case ITypeAlias(decl) -> {
      val _ = addDecl(tbl, pkg, typeDefPath(pkg, decl.name), decl.name, SKAlias, vis, None, true, span)
    }
    case IInterface(decl) -> {
      val path = typeDefPath(pkg, decl.name)
      val _ = addDecl(tbl, pkg, path, decl.name, SKInterface, vis, None, true, span)
      for m in decl.members {
        match m {
          case IMSig(sig) -> addSigMethod(tbl, pkg, path, sig, vis)
          case IMFunc(fn) -> addMethod(tbl, pkg, path, fn, vis)
          case IMAssoc(_) -> ()
        }
      }
    }
    case IExternType(decl) -> {
      val path = if decl.clrName.length > 0 {
        externTypeDefPath(decl.clrName)
      } else {
        typeDefPath(pkg, decl.name)
      }
      val _ = addDecl(tbl, pkg, path, decl.name, SKExternType, vis, None, true, span)
    }
    case IFunc(decl) -> registerFunc(tbl, pkg, decl, vis)
    case IExternFunc(decl) -> {
      val _ = addDecl(tbl, pkg, funcDefPath(pkg, decl.name, decl.params), decl.name, SKFunc, vis, None, true, span)
    }
    case IConst(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKConst, vis, None, true, span)
    }
    case IVal(decl) -> {
      match decl.pattern.kind {
        case PBinding(name, None) -> {
          val _ = addDecl(tbl, pkg, topDefPath(pkg, name), name, SKVal, vis, None, true, span)
        }
        case _ -> ()
      }
    }
    case IFixture(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKVal, vis, None, true, span)
    }
    case IWire(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKWire, vis, None, true, span)
    }
    case IScopeKind(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKScopeKind, vis, None, true, span)
    }
    case IConfig(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKConfig, vis, None, true, span)
    }
    case IAspect(decl) -> {
      val _ = addDecl(tbl, pkg, topDefPath(pkg, decl.name), decl.name, SKAspect, vis, None, true, span)
    }
    case IExtern(decl) -> {
      val blockPkg = renderPath(decl.path)
      for m in decl.members {
        match m.kind {
          case EMSig(sig) -> {
            val _ = addDecl(
              tbl,
              blockPkg,
              funcDefPath(blockPkg, sig.name, sig.params),
              sig.name,
              SKFunc,
              declVisOf(m.visibility),
              None,
              true,
              sig.span
            )
          }
          case _ -> ()
        }
      }
    }
    case IImpl(decl) -> {
      val owner = implDefPath(pkg, decl)
      for m in decl.members {
        match m {
          case IMplFunc(fn) -> addMethod(tbl, pkg, owner, fn, vis)
          case IMplAssoc(_) -> ()
        }
      }
    }
    case ITest(_) -> ()
    case IProperty(_) -> ()
    case IError -> ()
  }
}

/// `Pkg::Target::$impl(Iface)`: the path an impl's methods nest under.
pub func implDefPath(pkg: in String, decl: in ImplDecl): DefPath {
  val iface = renderPath(decl.iface.head) + renderTypeArgs(decl.iface.args)
  val segs: List[String] = newList()
  segs.add(renderTypeExprKey(decl.target))
  segs.add("$impl(" + iface + ")")
  DefPath(pkg = pkg, segments = segs)
}

func registerRecordMembers(
  tbl: in DeclTable, pkg: in String, owner: in DefPath, decl: in RecordDecl, vis: in DeclVis
): Unit {
  for m in decl.members {
    match m {
      case RMFunc(fn) -> addMethod(tbl, pkg, owner, fn, vis)
      case _ -> ()
    }
  }
}

func registerFunc(tbl: in DeclTable, pkg: in String, decl: in FunctionDecl, vis: in DeclVis): Unit {
  val dot = dotIndex(decl.name)
  if dot > 0 {
    // `func Type.method(...)`: a method of `Type`, reached through a receiver.
    val owner = typeDefPath(pkg, decl.name.substring(0, dot))
    val member = decl.name.substring(dot + 1)
    val _ = addDecl(tbl, pkg, methodDefPath(owner, member, decl.params), member, SKMethod, vis, None, false, decl.span)
  } else {
    val _ = addDecl(tbl, pkg, funcDefPath(pkg, decl.name, decl.params), decl.name, SKFunc, vis, None, true, decl.span)
  }
}
