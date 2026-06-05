//! doc/doc.l — self-hosted `lyric doc` documentation generator.
//! Mirrors compiler/src/Lyric.Cli/Doc.fs (Phase 5 §M5.3 shim elimination).
//! Generates Markdown from the public surface of a Lyric source file.
package Lyric.Doc

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

func pathStr(mp: in ModulePath): String {
  if mp.segments.count == 0 {
    return ""
  }
  var s = mp.segments[0]
  var i = 1
  while i < mp.segments.count {
    s = s + "." + mp.segments[i]
    i = i + 1
  }
  s
}

// ─── Type expression → string ─────────────────────────────────────────────────
func typeArgStr(ta: in TypeArg): String {
  match ta {
    case TAType(ty) -> typeStr(ty)
    case TAValue(_) -> "<expr>"
  }
}

func typeArgsStr(args: in List[TypeArg]): String {
  if args.count == 0 {
    return ""
  }
  var s = typeArgStr(args[0])
  var i = 1
  while i < args.count {
    s = s + ", " + typeArgStr(args[i])
    i = i + 1
  }
  s
}

func typeStr(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> pathStr(path)
    case TGenericApp(head, args) -> pathStr(head) + "[" + typeArgsStr(args) + "]"
    case TArray(_, elem) -> "array[..., " + typeStr(elem) + "]"
    case TSlice(elem) -> "slice[" + typeStr(elem) + "]"
    case TRefined(under, _) -> pathStr(under) + " range ..."
    case TTuple(types) -> "(" + typesStr(types) + ")"
    case TNullable(inner) -> typeStr(inner) + "?"
    case TFunction(params, retTy) -> "(" + typesStr(params) + ") -> " + typeStr(retTy)
    case TUnit -> "Unit"
    case TSelf -> "Self"
    case TNever -> "Never"
    case TParen(inner) -> "(" + typeStr(inner) + ")"
    case TError -> "<?>"
  }
}

func typesStr(ts: in List[TypeExpr]): String {
  if ts.count == 0 {
    return ""
  }
  var s = typeStr(ts[0])
  var i = 1
  while i < ts.count {
    s = s + ", " + typeStr(ts[i])
    i = i + 1
  }
  s
}

// ─── Generics + params ────────────────────────────────────────────────────────
func genParamName(gp: in GenericParam): String {
  match gp {
    case GPType(n, _) -> n
    case GPValue(n, _, _) -> n
  }
}

func genericsStr(g: in Option[GenericParams]): String {
  match g {
    case None -> ""
    case Some(gp) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < gp.params.count {
        parts.add(genParamName(gp.params[i]))
        i = i + 1
      }
      "[" + Str.joinList(", ", parts) + "]"
    }
  }
}

func modeStr(m: in ParamMode): String {
  match m {
    case PMIn -> "in"
    case PMOut -> "out"
    case PMInout -> "inout"
  }
}

func paramStr(p: in Param): String {
  p.name + ": " + modeStr(p.mode) + " " + typeStr(p.ty)
}

func paramsStr(ps: in List[Param]): String {
  if ps.count == 0 {
    return ""
  }
  val parts: List[String] = newList()
  var i = 0
  while i < ps.count {
    parts.add(paramStr(ps[i]))
    i = i + 1
  }
  Str.joinList(", ", parts)
}

// ─── Signature builders ───────────────────────────────────────────────────────
func functionSignature(fn: in FunctionDecl): String {
  val ret = match fn.ret { case None -> ""; case Some(te) -> ": " + typeStr(te) }
  val asyncTok = if fn.isAsync { "async " } else { "" }
  asyncTok + "pub func " + fn.name + genericsStr(fn.generics) + "(" + paramsStr(fn.params) + ")" + ret
}

func fieldStr(f: in FieldDecl): String {
  val vis = match f.visibility { case None -> ""; case Some(_) -> "pub " }
  "  " + vis + f.name + ": " + typeStr(f.ty)
}

func recordSignature(kind: in String, rd: in RecordDecl): String {
  val fields: List[String] = newList()
  var i = 0
  while i < rd.members.count {
    match rd.members[i] {
      case RMField(f) -> {
        fields.add(fieldStr(f))
      }
      case _ -> ()
    }
    i = i + 1
  }
  val header = "pub " + kind + " " + rd.name + genericsStr(rd.generics) + " {"
  if fields.count == 0 {
    header + " }"
  } else {
    header + "\n" + Str.joinList("\n", fields) + "\n}"
  }
}

func caseStr(c: in UnionCase): String {
  if c.fields.count == 0 {
    "  case " + c.name
  } else {
    val parts: List[String] = newList()
    var i = 0
    while i < c.fields.count {
      val fs = match c.fields[i] { case UFNamed(n, te, _) -> n + ": " + typeStr(te); case UFPos(te, _) -> typeStr(te) }
      parts.add(fs)
      i = i + 1
    }
    "  case " + c.name + "(" + Str.joinList(", ", parts) + ")"
  }
}

func unionSignature(ud: in UnionDecl): String {
  val cases: List[String] = newList()
  var i = 0
  while i < ud.cases.count {
    cases.add(caseStr(ud.cases[i]))
    i = i + 1
  }
  "pub union " + ud.name + genericsStr(ud.generics) + " {\n" + Str.joinList("\n", cases) + "\n}"
}

func enumSignature(ed: in EnumDecl): String {
  val cases: List[String] = newList()
  var i = 0
  while i < ed.cases.count {
    cases.add("  case " + ed.cases[i].name)
    i = i + 1
  }
  "pub enum " + ed.name + " {\n" + Str.joinList("\n", cases) + "\n}"
}

func opaqueSignature(od: in OpaqueTypeDecl): String {
  val parts: List[String] = newList()
  var ai = 0
  while ai < od.annotations.count {
    parts.add("@" + pathStr(od.annotations[ai].name))
    ai = ai + 1
  }
  val prefix = if parts.count == 0 { "" } else { Str.joinList(" ", parts) + "\n" }
  prefix + "pub opaque type " + od.name + genericsStr(od.generics)
}

func interfaceMethodStr(m: in InterfaceMember): String {
  match m {
    case IMSig(sg) -> {
      val ps = paramsStr(sg.params)
      val ret = match sg.ret { case None -> ""; case Some(te) -> ": " + typeStr(te) }
      val asyncTok = if sg.isAsync { "async " } else { "" }
      "  " + asyncTok + "func " + sg.name + genericsStr(sg.generics) + "(" + ps + ")" + ret
    }
    case IMFunc(fn) -> "  // default: " + fn.name
    case IMAssoc(a) -> "  type " + a.name
  }
}

func interfaceSignature(id: in InterfaceDecl): String {
  val methods: List[String] = newList()
  var i = 0
  while i < id.members.count {
    methods.add(interfaceMethodStr(id.members[i]))
    i = i + 1
  }
  "pub interface " + id.name + genericsStr(id.generics) + " {\n" + Str.joinList("\n", methods) + "\n}"
}

func distinctSignature(dt: in DistinctTypeDecl): String {
  val derives = if dt.derives.count == 0 { "" } else { " derives " + Str.joinList(", ", dt.derives) }
  "pub distinct type " + dt.name + genericsStr(dt.generics) + " = " + typeStr(dt.underlying) + derives
}

func typeAliasSignature(ta: in TypeAliasDecl): String {
  "pub type " + ta.name + genericsStr(ta.generics) + " = " + typeStr(ta.rhs)
}

func constSignature(c: in ConstDecl): String {
  "pub const " + c.name + ": " + typeStr(c.ty) + " = ..."
}

// ─── Doc comment rendering ────────────────────────────────────────────────────
func docText(d: in DocComment): String {
  val s = d.text
  if s.length > 0 and s[0] == ' ' {
    Str.substring(s, 1, s.length - 1)
  } else {
    s
  }
}

func renderDocComments(docs: in List[DocComment]): String {
  if docs.count == 0 {
    return ""
  }
  var s = ""
  var i = 0
  while i < docs.count {
    s = s + docText(docs[i]) + "\n"
    i = i + 1
  }
  s + "\n"
}

// ─── Item rendering ───────────────────────────────────────────────────────────
func renderItem(item: in Item): String {
  match item.visibility {
    case None -> ""
    case Some(_) -> {
      val docs = item.docComments
      match item.kind {
        case IFunc(fn) -> {
          "### func `" + fn.name + "`\n\n" + "```lyric\n" + functionSignature(fn) + "\n```\n\n" + renderDocComments(docs)
        }
        case IRecord(rd) -> {
          "### record `" + rd.name + "`\n\n" + "```lyric\n" + recordSignature("record", rd) + "\n```\n\n" +
            renderDocComments(docs)
        }
        case IExposedRec(rd) -> {
          "### exposed record `" + rd.name + "`\n\n" + "```lyric\n" + recordSignature("exposed record", rd) + "\n```\n\n" +
            renderDocComments(docs)
        }
        case IUnion(ud) -> {
          "### union `" + ud.name + "`\n\n" + "```lyric\n" + unionSignature(ud) + "\n```\n\n" + renderDocComments(docs)
        }
        case IEnum(ed) -> {
          "### enum `" + ed.name + "`\n\n" + "```lyric\n" + enumSignature(ed) + "\n```\n\n" + renderDocComments(docs)
        }
        case IOpaque(od) -> {
          "### opaque type `" + od.name + "`\n\n" + "```lyric\n" + opaqueSignature(od) + "\n```\n\n" + renderDocComments(docs)
        }
        case IInterface(id) -> {
          "### interface `" + id.name + "`\n\n" + "```lyric\n" + interfaceSignature(id) + "\n```\n\n" + renderDocComments(docs)
        }
        case IDistinctType(dt) -> {
          "### distinct type `" + dt.name + "`\n\n" + "```lyric\n" + distinctSignature(dt) + "\n```\n\n" +
            renderDocComments(docs)
        }
        case ITypeAlias(ta) -> {
          "### type alias `" + ta.name + "`\n\n" + "```lyric\n" + typeAliasSignature(ta) + "\n```\n\n" + renderDocComments(docs)
        }
        case IConst(c) -> {
          "### const `" + c.name + "`\n\n" + "```lyric\n" + constSignature(c) + "\n```\n\n" + renderDocComments(docs)
        }
        case _ -> ""
      }
    }
  }
}

// ─── Top-level entry ──────────────────────────────────────────────────────────
pub func generate(source: in String): String {
  val pr = parse(source)
  val file = pr.file
  val pkgName = pathStr(file.packageDecl.path)
  var s = "# Package `" + pkgName + "`\n\n"
  // Module-level (//!) doc comments
  var mi = 0
  while mi < file.moduleDoc.count {
    if file.moduleDoc[mi].isModule {
      s = s + docText(file.moduleDoc[mi]) + "\n"
    }
    mi = mi + 1
  }
  // Count pub items
  var pubCount = 0
  var i = 0
  while i < file.items.count {
    match file.items[i].visibility {
      case Some(_) -> {
        pubCount = pubCount + 1
      }
      case None -> ()
    }
    i = i + 1
  }
  if pubCount == 0 {
    s = s + "_No public surface._\n\n"
  } else {
    var j = 0
    while j < file.items.count {
      s = s + renderItem(file.items[j])
      j = j + 1
    }
  }
  s
}
