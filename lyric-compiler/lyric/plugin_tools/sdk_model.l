//! sdk_model.l - Lyric.PluginSdk: reads a plugin API package (D207 Decision 1)
//! into the boundary model the SDK generators work from.
//!
//! The model is what crosses the wire: every `@plugin_point` and
//! `@capability` interface with its methods, and every record, union, enum
//! and `@plugin_handle` type those methods, the contributions types and the
//! grant types reach, with each type in the D207 Decision 4 encoding.  Type
//! aliases cross as the type they stand for; a distinct type or range
//! subtype crosses only as a `@plugin_handle` (K0001 in Lyric.PluginExpand,
//! the same rule).
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.PluginManifest as Pm

// ── Model ────────────────────────────────────────────────────────────────────
/// A boundary type in its wire encoding (D207 Decision 4).
pub union BType {
  case BBool
  case BByte
  case BInt
  case BLong
  case BUInt
  case BULong
  case BFloat
  case BDouble
  case BChar
  case BString
  case BUnit
  case BJson
  /// `List[Byte]` / `slice[Byte]`: a base64 string.
  case BBytes
  case BOption(inner: BType)
  case BResult(ok: BType, err: BType)
  case BList(elem: BType)
  /// `Map[String, T]`: an object.
  case BMap(value: BType)
  case BTuple(items: List[BType])
  /// A record, union, enum or handle of the model, by its declared name.
  case BNamed(name: String)
}

/// A field default the generated decoders apply when the member is missing.
pub union BDefault {
  case DefInt(value: Long)
  case DefFloat(text: String)
  case DefString(value: String)
  case DefBool(value: Bool)
  case DefNone
  case DefEmptyList
  case DefEmptyMap
  case DefEnum(typeName: String, caseName: String)
}

pub record BField {
  name: String
  ty: BType
  dflt: Option[BDefault]
}

pub record BCase {
  name: String
  fields: List[BField]
}

pub union BDeclKind {
  case KRecord(fields: List[BField])
  case KUnion(cases: List[BCase])
  case KEnum(cases: List[String])
  case KHandle
}

pub record BDecl {
  name: String
  pkg: String
  kind: BDeclKind
  doc: String
}

pub record BParam {
  name: String
  ty: BType
}

pub record BMethod {
  name: String
  params: List[BParam]
  ok: BType
  err: BType
  doc: String
}

pub record BPoint {
  name: String
  pkg: String
  /// `major.minor`; empty for a protocol point.
  version: String
  /// The contributions record's name, empty when the point declares none.
  contributions: String
  /// Package-qualified ids of the capabilities the point allows.
  allows: List[String]
  methods: List[BMethod]
  /// The protocol of a `@protocol_point`, empty for a `@plugin_point`.
  protocol: String
  doc: String
}

pub record BCapability {
  name: String
  pkg: String
  /// The grant record's name, empty when the capability has no grant.
  grant: String
  methods: List[BMethod]
  doc: String
}

pub record ApiModel {
  packageName: String
  decls: List[BDecl]
  points: List[BPoint]
  capabilities: List[BCapability]
}

pub record ModelResult {
  model: ApiModel
  errors: List[String]
}

/// One source file of the API package (or a package beside it).
pub record SdkSource {
  path: String
  text: String
}

/// The wire id of a point or capability: `<Pkg>.<Name>`.
pub func qualifiedId(pkg: in String, name: in String): String = pkg + "." + name

pub func pointId(p: in BPoint): String = qualifiedId(p.pkg, p.name)

pub func capabilityId(c: in BCapability): String = qualifiedId(c.pkg, c.name)

pub func findDecl(m: in ApiModel, name: in String): Option[BDecl] {
  for d in m.decls {
    if d.name == name {
      return Some(value = d)
    }
  }
  None
}

/// True when a record field may be missing on the wire: it has a default or
/// is an `Option`.
pub func fieldIsOptional(f: in BField): Bool {
  match f.dflt {
    case Some(_) -> true
    case None -> match f.ty { case BOption(_) -> true; case _ -> false }
  }
}

// ── Reading the sources ──────────────────────────────────────────────────────
record ImportAlias {
  short: String
  pkg: String
}

record FileScope {
  path: String
  pkg: String
  aliases: List[ImportAlias]
  imported: List[String]
}

record DeclSite {
  fsc: Int
  order: Int
  name: String
  item: Item
}

record Ctx {
  scopes: List[FileScope]
  sites: List[DeclSite]
  errors: List[String]
  /// Keys (`pkg.name`) of the named declarations reached so far, in order.
  reachedKeys: List[String]
  decls: List[BDecl]
  /// Distinct types and aliases being resolved (cycle guard).
  expanding: List[String]
}

func posText(fsc: in FileScope, sp: in Span): String {
  fsc.path + ":" + sp.startPos.line.toString() + ":" + sp.startPos.column.toString()
}

func report(ctx: in Ctx, fsc: in FileScope, sp: in Span, msg: in String): Unit {
  ctx.errors.add(posText(fsc, sp) + ": error: " + msg)
}

func docText(docs: in List[DocComment]): String {
  val parts: List[String] = newList()
  for d in docs {
    parts.add(Str.trim(d.text))
  }
  Str.joinList("\n", parts)
}

func isPub(item: in Item): Bool {
  match item.visibility {
    case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
    case None -> false
  }
}

func annotationNamed(item: in Item, name: in String): Option[Annotation] = findAnnotation(item.annotations, name)

func importScope(path: in String, file: in SourceFile): FileScope {
  val aliases: List[ImportAlias] = newList()
  val imported: List[String] = newList()
  for imp in file.imports {
    val pkg = modulePathJoin(imp.path.segments)
    imported.add(pkg)
    match imp.asAlias {
      case Some(a) -> aliases.add(ImportAlias(short = a, pkg = pkg))
      case None -> ()
    }
  }
  FileScope(path = path, pkg = modulePathJoin(file.packageDecl.path.segments), aliases = aliases, imported = imported)
}

func declName(item: in Item): String {
  match item.kind {
    case IRecord(d) -> d.name
    case IExposedRec(d) -> d.name
    case IUnion(d) -> d.name
    case IEnum(d) -> d.name
    case IDistinctType(d) -> d.name
    case ITypeAlias(d) -> d.name
    case IOpaque(d) -> d.name
    case IProtected(d) -> d.name
    case IInterface(d) -> d.name
    case _ -> ""
  }
}

// ── Type resolution ──────────────────────────────────────────────────────────
func builtinScalar(name: in String): Option[BType] {
  if name == "Bool" {
    Some(value = BBool)
  } else if name == "Byte" {
    Some(value = BByte)
  } else if name == "Int" {
    Some(value = BInt)
  } else if name == "Long" {
    Some(value = BLong)
  } else if name == "UInt" {
    Some(value = BUInt)
  } else if name == "ULong" {
    Some(value = BULong)
  } else if name == "Float" {
    Some(value = BFloat)
  } else if name == "Double" {
    Some(value = BDouble)
  } else if name == "Char" {
    Some(value = BChar)
  } else if name == "String" {
    Some(value = BString)
  } else if name == "Unit" {
    Some(value = BUnit)
  } else {
    None
  }
}

func joinSegs(segs: in List[String], count: in Int): String {
  val parts: List[String] = newList()
  var i = 0
  while i < count {
    parts.add(segs[i])
    i = i + 1
  }
  Str.joinList(".", parts)
}

/// The package a qualifier names in `fsc`: an import alias or the
/// qualifier itself.
func packageOfQualifier(fsc: in FileScope, q: in String): String {
  for a in fsc.aliases {
    if a.short == q {
      return a.pkg
    }
  }
  q
}

/// The declaration sites named `name` in package `pkg`.
func sitesIn(ctx: in Ctx, pkg: in String, name: in String): List[Int] {
  val found: List[Int] = newList()
  var i = 0
  while i < ctx.sites.count {
    val s = ctx.sites[i]
    if s.name == name and ctx.scopes[s.fsc].pkg == pkg {
      found.add(i)
    }
    i = i + 1
  }
  found
}

/// The site a type name refers to from `fsc`, or -1 after reporting.
func lookupSite(ctx: in Ctx, fsc: in FileScope, segs: in List[String], sp: in Span): Int {
  val name = segs[segs.count - 1]
  if segs.count > 1 {
    val pkg = packageOfQualifier(fsc, joinSegs(segs, segs.count - 1))
    val hits = sitesIn(ctx, pkg, name)
    if hits.count > 0 {
      return hits[0]
    }
    report(
      ctx,
      fsc,
      sp,
      "unknown type " + joinSegs(segs, segs.count) +
        " (the SDK generator reads the API package's sources; declare boundary types there or in a package beside it)"
    )
    return -1
  }
  val own = sitesIn(ctx, fsc.pkg, name)
  if own.count > 0 {
    return own[0]
  }
  val found: List[Int] = newList()
  for pkg in fsc.imported {
    for h in sitesIn(ctx, pkg, name) {
      found.add(h)
    }
  }
  if found.count == 1 {
    return found[0]
  }
  if found.count > 1 {
    report(ctx, fsc, sp, "type name " + name + " is ambiguous between imported packages; qualify it")
    return -1
  }
  report(
    ctx,
    fsc,
    sp,
    "unknown type " + name +
      " (the SDK generator reads the API package's sources; declare boundary types there or in a package beside it)"
  )
  return -1
}

func typeArgTypes(ctx: in Ctx, fsc: in FileScope, args: in List[TypeArg], sp: in Span): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  for a in args {
    match a {
      case TAType(t) -> tys.add(t)
      case TAValue(_) -> report(ctx, fsc, sp, "a value type argument cannot appear in a boundary type")
    }
  }
  tys
}

func isByte(t: in BType): Bool {
  match t {
    case BByte -> true
    case _ -> false
  }
}

func isOption(t: in BType): Bool {
  match t {
    case BOption(_) -> true
    case _ -> false
  }
}

func resolveType(ctx: in Ctx, fsc: in FileScope, te: in TypeExpr): BType {
  match te.kind {
    case TUnit -> BUnit
    case TParen(inner) -> resolveType(ctx, fsc, inner)
    case TSlice(elem) -> {
      val e = resolveType(ctx, fsc, elem)
      if isByte(e) {
        BBytes
      } else {
        BList(elem = e)
      }
    }
    case TTuple(types) -> {
      val items: List[BType] = newList()
      for t in types {
        items.add(resolveType(ctx, fsc, t))
      }
      BTuple(items = items)
    }
    case TRefined(underlying, _) -> resolvePath(ctx, fsc, underlying.segments, te.span)
    case TRef(path) -> resolvePath(ctx, fsc, path.segments, te.span)
    case TGenericApp(head, args) -> resolveGeneric(
      ctx,
      fsc,
      head.segments,
      typeArgTypes(ctx, fsc, args, te.span),
      te.span
    )
    case TNullable(_) -> {
      report(ctx, fsc, te.span, "a nullable type cannot cross a plugin boundary; use Option[T]")
      BUnit
    }
    case TFunction(_, _) -> {
      report(ctx, fsc, te.span, "a function type cannot cross a plugin boundary (a call cannot carry code)")
      BUnit
    }
    case TArray(_, _) -> {
      report(ctx, fsc, te.span, "a fixed-size array cannot cross a plugin boundary; use List[T]")
      BUnit
    }
    case _ -> {
      report(ctx, fsc, te.span, "this type cannot cross a plugin boundary")
      BUnit
    }
  }
}

func lastSeg(segs: in List[String]): String = segs[segs.count - 1]

func splitList(s: in String, sep: in String): List[String] {
  val parts: List[String] = newList()
  for p in Str.split(s, sep) {
    parts.add(p)
  }
  parts
}

func isStdQualified(segs: in List[String], pkg: in String): Bool {
  segs.count == 1 or joinSegs(segs, segs.count - 1) == pkg
}

func resolveGeneric(ctx: in Ctx, fsc: in FileScope, segs: in List[String], args: in List[TypeExpr], sp: in Span): BType {
  val name = lastSeg(segs)
  if name == "Option" and isStdQualified(segs, "Std.Core") and args.count == 1 {
    val inner = resolveType(ctx, fsc, args[0])
    if isOption(inner) {
      report(
        ctx,
        fsc,
        sp,
        "Option[Option[T]] cannot cross a plugin boundary (both None and Some(None) would encode as null)"
      )
    }
    return BOption(inner = inner)
  }
  if name == "Result" and isStdQualified(segs, "Std.Core") and args.count == 2 {
    return BResult(ok = resolveType(ctx, fsc, args[0]), err = resolveType(ctx, fsc, args[1]))
  }
  if name == "List" and isStdQualified(segs, "Std.Collections") and args.count == 1 {
    val e = resolveType(ctx, fsc, args[0])
    if isByte(e) {
      return BBytes
    }
    return BList(elem = e)
  }
  if name == "Map" and isStdQualified(segs, "Std.Collections") and args.count == 2 {
    match resolveType(ctx, fsc, args[0]) {
      case BString -> ()
      case _ -> report(ctx, fsc, sp, "only Map[String, T] can cross a plugin boundary (a JSON object's keys are strings)")
    }
    return BMap(value = resolveType(ctx, fsc, args[1]))
  }
  report(ctx, fsc, sp, "the generic type " + joinSegs(segs, segs.count) + " cannot cross a plugin boundary")
  BUnit
}

func resolvePath(ctx: in Ctx, fsc: in FileScope, segs: in List[String], sp: in Span): BType {
  val name = lastSeg(segs)
  if segs.count == 1 or joinSegs(segs, segs.count - 1) == "Std.Core" {
    match builtinScalar(name) {
      case Some(t) -> return t
      case None -> ()
    }
  }
  if name == "JsonValue" and (segs.count == 1 and listContains(fsc.imported, "Std.JsonValue") or packageOfQualifier(fsc, joinSegs(segs, segs.count - 1)) == "Std.JsonValue") {
    return BJson
  }
  if name == "Option" or name == "Result" or name == "List" or name == "Map" {
    report(ctx, fsc, sp, name + " needs its type arguments here")
    return BUnit
  }
  val idx = lookupSite(ctx, fsc, segs, sp)
  if idx < 0 {
    return BUnit
  }
  siteType(ctx, idx, sp, fsc)
}

func siteKey(ctx: in Ctx, idx: in Int): String {
  val s = ctx.sites[idx]
  ctx.scopes[s.fsc].pkg + "." + s.name
}

/// The boundary type of declaration site `idx`, converting it on first use.
func siteType(ctx: in Ctx, idx: in Int, sp: in Span, useScope: in FileScope): BType {
  val site = ctx.sites[idx]
  val fsc = ctx.scopes[site.fsc]
  val key = siteKey(ctx, idx)
  match site.item.kind {
    case ITypeAlias(d) -> {
      if isSome(d.generics) {
        report(ctx, fsc, d.span, "the generic alias " + d.name + " cannot cross a plugin boundary")
        return BUnit
      }
      return expandTransparent(ctx, fsc, key, d.rhs, d.span)
    }
    case IDistinctType(d) -> {
      match annotationNamed(site.item, "plugin_handle") {
        case Some(_) -> ()
        case None -> {
          report(
            ctx,
            useScope,
            sp,
            "the distinct type " + d.name + " cannot cross a plugin boundary; mark it @plugin_handle (as `pub type " +
              d.name +
              " = Long`) to pass it as a handle"
          )
          return BUnit
        }
      }
    }
    case IOpaque(d) -> {
      report(
        ctx,
        useScope,
        sp,
        "the opaque type " + d.name + " cannot cross a plugin boundary (its representation is private)"
      )
      return BUnit
    }
    case IProtected(d) -> {
      report(ctx, useScope, sp, "the protected type " + d.name + " cannot cross a plugin boundary")
      return BUnit
    }
    case IInterface(d) -> {
      report(
        ctx,
        useScope,
        sp,
        "the interface " + d.name + " cannot cross a plugin boundary (an interface value lives in one process)"
      )
      return BUnit
    }
    case _ -> ()
  }
  if listContains(ctx.reachedKeys, key) {
    return BNamed(name = site.name)
  }
  // A second declaration of the same name in another package would collide
  // in the generated code, which puts every boundary type in one namespace.
  for d in ctx.decls {
    if d.name == site.name {
      report(
        ctx,
        useScope,
        sp,
        "two boundary types are named " + site.name + " (" + d.pkg + " and " + fsc.pkg +
          "); the generated SDK puts them in one namespace, so rename one"
      )
      return BUnit
    }
  }
  ctx.reachedKeys.add(key)
  val placeholder = BDecl(name = site.name, pkg = fsc.pkg, kind = KHandle, doc = "")
  val slot = ctx.decls.count
  ctx.decls.add(placeholder)
  ctx.decls[slot] = convertDecl(ctx, fsc, site)
  BNamed(name = site.name)
}

func expandTransparent(ctx: in Ctx, fsc: in FileScope, key: in String, te: in TypeExpr, sp: in Span): BType {
  if listContains(ctx.expanding, key) {
    report(ctx, fsc, sp, "the type " + key + " is defined in terms of itself")
    return BUnit
  }
  ctx.expanding.add(key)
  val t = resolveType(ctx, fsc, te)
  ctx.expanding.removeAt(ctx.expanding.count - 1)
  t
}

func convertFields(ctx: in Ctx, fsc: in FileScope, members: in List[RecordMember]): List[BField] {
  val fields: List[BField] = newList()
  for m in members {
    match m {
      case RMField(f) -> {
        val ty = resolveType(ctx, fsc, f.ty)
        val dflt = match f.dflt { case Some(e) -> convertDefault(ctx, fsc, ty, e, f.name); case None -> None }
        fields.add(BField(name = f.name, ty = ty, dflt = dflt))
      }
      case _ -> ()
    }
  }
  fields
}

func convertDecl(ctx: in Ctx, fsc: in FileScope, site: in DeclSite): BDecl {
  val doc = docText(site.item.docComments)
  match site.item.kind {
    case IRecord(d) -> {
      if isSome(d.generics) {
        report(
          ctx,
          fsc,
          d.span,
          "the generic record " + d.name + " cannot cross a plugin boundary (a plugin boundary is not generic in v1)"
        )
      }
      BDecl(name = d.name, pkg = fsc.pkg, kind = KRecord(fields = convertFields(ctx, fsc, d.members)), doc = doc)
    }
    case IExposedRec(d) -> {
      if isSome(d.generics) {
        report(
          ctx,
          fsc,
          d.span,
          "the generic record " + d.name + " cannot cross a plugin boundary (a plugin boundary is not generic in v1)"
        )
      }
      BDecl(name = d.name, pkg = fsc.pkg, kind = KRecord(fields = convertFields(ctx, fsc, d.members)), doc = doc)
    }
    case IUnion(d) -> {
      if isSome(d.generics) {
        report(
          ctx,
          fsc,
          d.span,
          "the generic union " + d.name + " cannot cross a plugin boundary (a plugin boundary is not generic in v1)"
        )
      }
      val cases: List[BCase] = newList()
      for c in d.cases {
        val fields: List[BField] = newList()
        for uf in c.fields {
          match uf {
            case UFNamed(n, t, _) -> {
              if n == "case" {
                report(
                  ctx,
                  fsc,
                  c.span,
                  "union case " + c.name + " has a field named \"case\", which the encoding uses for the case name"
                )
              }
              fields.add(BField(name = n, ty = resolveType(ctx, fsc, t), dflt = None))
            }
            case UFPos(_, fsp) -> report(
              ctx,
              fsc,
              fsp,
              "union case " + c.name +
                " has an unnamed field; a boundary union's fields need names, which become JSON members"
            )
          }
        }
        cases.add(BCase(name = c.name, fields = fields))
      }
      BDecl(name = d.name, pkg = fsc.pkg, kind = KUnion(cases = cases), doc = doc)
    }
    case IEnum(d) -> {
      val cases: List[String] = newList()
      for c in d.cases {
        cases.add(c.name)
      }
      BDecl(name = d.name, pkg = fsc.pkg, kind = KEnum(cases = cases), doc = doc)
    }
    case IDistinctType(d) -> {
      match resolveType(ctx, fsc, d.underlying) {
        case BLong -> ()
        case _ -> report(ctx, fsc, d.span, "a @plugin_handle type must be `pub type " + d.name + " = Long`")
      }
      if not isPub(site.item) {
        report(ctx, fsc, d.span, "a @plugin_handle type must be pub")
      }
      BDecl(name = d.name, pkg = fsc.pkg, kind = KHandle, doc = doc)
    }
    case _ -> {
      report(ctx, fsc, site.item.span, site.name + " cannot cross a plugin boundary")
      BDecl(name = site.name, pkg = fsc.pkg, kind = KHandle, doc = doc)
    }
  }
}

// ── Field defaults ───────────────────────────────────────────────────────────
func negated(e: in Expr): Option[Literal] {
  match e.kind {
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match operand.kind {
        case ELiteral(lit) -> Some(value = lit)
        case _ -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

func floatText(v: in Double): String {
  val t = v.toString()
  if Str.contains(t, ".") or Str.contains(t, "E") or Str.contains(t, "e") {
    t
  } else {
    t + ".0"
  }
}

func unsupportedDefault(ctx: in Ctx, fsc: in FileScope, e: in Expr, field: in String): Option[BDefault] {
  report(
    ctx,
    fsc,
    e.span,
    "the default of field " + field +
      " is not a literal, [], None or an enum case, so the generated SDKs cannot reproduce it; give it one of those"
  )
  None
}

func convertDefault(ctx: in Ctx, fsc: in FileScope, ty: in BType, e: in Expr, field: in String): Option[BDefault] {
  match negated(e) {
    case Some(lit) -> match lit {
      case LInt(v, _, _) -> return Some(value = DefInt(value = 0 - v))
      case LFloat(v, _, _) -> return Some(value = DefFloat(text = "-" + floatText(v)))
      case _ -> return unsupportedDefault(ctx, fsc, e, field)
    }
    case None -> ()
  }
  match e.kind {
    case EParen(inner) -> convertDefault(ctx, fsc, ty, inner, field)
    case ELiteral(lit) -> match lit {
      case LInt(v, _, _) -> Some(value = DefInt(value = v))
      case LFloat(v, _, _) -> Some(value = DefFloat(text = floatText(v)))
      case LString(s) -> Some(value = DefString(value = s))
      case LTripleString(s) -> Some(value = DefString(value = s))
      case LRawString(s) -> Some(value = DefString(value = s))
      case LBool(b) -> Some(value = DefBool(value = b))
      case _ -> unsupportedDefault(ctx, fsc, e, field)
    }
    case EList(items) -> {
      if items.count == 0 {
        match ty {
          case BMap(_) -> Some(value = DefEmptyMap)
          case _ -> Some(value = DefEmptyList)
        }
      } else {
        unsupportedDefault(ctx, fsc, e, field)
      }
    }
    case EPath(path) -> {
      val segs = path.segments
      if segs.count == 1 and segs[0] == "None" {
        return Some(value = DefNone)
      }
      match ty {
        case BNamed(n) -> {
          val caseName = lastSeg(segs)
          if segs.count == 1 or segs[segs.count - 2] == n {
            return Some(value = DefEnum(typeName = n, caseName = caseName))
          }
          unsupportedDefault(ctx, fsc, e, field)
        }
        case _ -> unsupportedDefault(ctx, fsc, e, field)
      }
    }
    case EMember(recv, member) -> match recv.kind {
      case EPath(path) -> match ty {
        case BNamed(n) -> {
          if lastSeg(path.segments) == n {
            return Some(value = DefEnum(typeName = n, caseName = member))
          }
          unsupportedDefault(ctx, fsc, e, field)
        }
        case _ -> unsupportedDefault(ctx, fsc, e, field)
      }
      case _ -> unsupportedDefault(ctx, fsc, e, field)
    }
    case ECall(fn, args) -> {
      // `newList()` / `newMap()` spell an empty collection too.
      match fn.kind {
        case EPath(path) -> {
          val n = lastSeg(path.segments)
          if args.count == 0 and n == "newList" {
            return Some(value = DefEmptyList)
          }
          if args.count == 0 and n == "newMap" {
            return Some(value = DefEmptyMap)
          }
          unsupportedDefault(ctx, fsc, e, field)
        }
        case _ -> unsupportedDefault(ctx, fsc, e, field)
      }
    }
    case _ -> unsupportedDefault(ctx, fsc, e, field)
  }
}

// ── Points and capabilities ──────────────────────────────────────────────────
func annStringArg(a: in Annotation, name: in String): Option[String] {
  for arg in a.args {
    match arg {
      case AAName(n, v, _) -> {
        if n == name {
          match v {
            case AVString(s, _) -> return Some(value = s)
            case AVIdent(s, _) -> return Some(value = s)
            case _ -> return Some(value = "")
          }
        }
      }
      case _ -> ()
    }
  }
  None
}

/// The names inside `allows(A, B)`.
func annCallNames(a: in Annotation, callName: in String): List[String] {
  val names: List[String] = newList()
  for arg in a.args {
    match arg {
      case AACall(n, inner, _) -> {
        if n == callName {
          for x in inner {
            match x {
              case ABare(bn, _) -> names.add(bn)
              case ALiteral(v, _) -> match v {
                case AVIdent(s, _) -> names.add(s)
                case AVString(s, _) -> names.add(s)
                case _ -> ()
              }
              case _ -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  names
}

func checkAnnArgs(ctx: in Ctx, fsc: in FileScope, a: in Annotation, allowed: in List[String]): Unit {
  for arg in a.args {
    val n = match arg {
      case AAName(nm, _, _) -> nm
      case ABare(nm, _) -> nm
      case AACall(nm, _, _) -> nm
      case ALiteral(_, _) -> "(literal)"
    }
    if not listContains(allowed, n) {
      report(ctx, fsc, a.span, "unknown argument " + n + " to @" + modulePathJoin(a.name.segments))
    }
  }
}

func convertMethods(ctx: in Ctx, fsc: in FileScope, iface: in InterfaceDecl, what: in String): List[BMethod] {
  val methods: List[BMethod] = newList()
  for m in iface.members {
    match m {
      case IMSig(sig) -> {
        if isSome(sig.generics) {
          report(ctx, fsc, sig.span, what + " method " + sig.name + " is generic; a boundary method cannot be")
        }
        val params: List[BParam] = newList()
        for p in sig.params {
          match p.mode {
            case PMIn -> ()
            case _ -> report(
              ctx,
              fsc,
              p.span,
              "parameter " + p.name + " of " + sig.name + " is out or inout; a boundary method's parameters are in"
            )
          }
          params.add(BParam(name = p.name, ty = resolveType(ctx, fsc, p.ty)))
        }
        var ok: BType = BUnit
        var err: BType = BUnit
        var isResult = false
        match sig.ret {
          case Some(rt) -> match resolveType(ctx, fsc, rt) {
            case BResult(o, e) -> {
              ok = o
              err = e
              isResult = true
            }
            case _ -> ()
          }
          case None -> ()
        }
        if not isResult {
          report(
            ctx,
            fsc,
            sig.span,
            what + " method " + sig.name + " must return Result[T, E] (a call across a plugin boundary can fail)"
          )
        }
        methods.add(BMethod(name = sig.name, params = params, ok = ok, err = err, doc = docText(sig.docComments)))
      }
      case IMFunc(fn) -> report(
        ctx,
        fsc,
        fn.span,
        what + " method " + fn.name + " has a body; boundary interfaces declare signatures only"
      )
      case IMAssoc(a) -> report(ctx, fsc, a.span, "an associated type cannot appear in a " + what + " interface")
    }
  }
  methods
}

/// The record a `contributions`/`grant` argument names, by name, or "".
func recordArg(ctx: in Ctx, fsc: in FileScope, a: in Annotation, argName: in String): String {
  match annStringArg(a, argName) {
    case None -> ""
    case Some(text) -> {
      if text.length == 0 {
        report(ctx, fsc, a.span, argName + " must name a record type")
        return ""
      }
      val segs = splitList(text, ".")
      match resolvePath(ctx, fsc, segs, a.span) {
        case BNamed(n) -> match findDeclIn(ctx, n) {
          case Some(d) -> match d.kind {
            case KRecord(_) -> n
            case _ -> {
              report(ctx, fsc, a.span, argName + " = " + text + " must name a record")
              ""
            }
          }
          case None -> n
        }
        case _ -> {
          report(ctx, fsc, a.span, argName + " = " + text + " must name a record")
          ""
        }
      }
    }
  }
}

func findDeclIn(ctx: in Ctx, name: in String): Option[BDecl] {
  for d in ctx.decls {
    if d.name == name {
      return Some(value = d)
    }
  }
  None
}

func interfaceOf(item: in Item): Option[InterfaceDecl] {
  match item.kind {
    case IInterface(d) -> Some(value = d)
    case _ -> None
  }
}

func checkBoundaryInterface(ctx: in Ctx, fsc: in FileScope, item: in Item, ann: in String): Option[InterfaceDecl] {
  match interfaceOf(item) {
    case Some(d) -> {
      if not isPub(item) {
        report(ctx, fsc, item.span, "@" + ann + " must be on a pub interface")
        return None
      }
      if isSome(d.generics) {
        report(ctx, fsc, d.span, "@" + ann + " interface " + d.name + " is generic; a plugin boundary is not generic in v1")
        return None
      }
      Some(value = d)
    }
    case None -> {
      report(ctx, fsc, item.span, "@" + ann + " must be on a pub interface")
      None
    }
  }
}

/// Builds the boundary model of the API package in `sources`.  Every
/// `@plugin_point`, `@protocol_point` and `@capability` must be in one package
/// (the API package); the types they reach may come from any of the sources.
pub func buildApiModel(sources: in List[SdkSource]): ModelResult {
  val ctx = Ctx(
    scopes = newList(),
    sites = newList(),
    errors = newList(),
    reachedKeys = newList(),
    decls = newList(),
    expanding = newList()
  )
  val files: List[SourceFile] = newList()
  for src in sources {
    val pr = parse(src.text)
    var parseFailed = false
    for d in pr.diagnostics {
      match d.severity {
        case DiagError -> {
          ctx.errors.add(
            src.path + ":" + d.span.startPos.line.toString() + ":" + d.span.startPos.column.toString() + ": error[" + d.code +
              "]: " +
              d.message
          )
          parseFailed = true
        }
        case DiagWarning -> ()
      }
    }
    if parseFailed {
      continue
    }
    val scopeIdx = ctx.scopes.count
    ctx.scopes.add(importScope(src.path, pr.file))
    files.add(pr.file)
    var order = 0
    for item in pr.file.items {
      val n = declName(item)
      if n.length > 0 {
        ctx.sites.add(DeclSite(fsc = scopeIdx, order = order, name = n, item = item))
      }
      order = order + 1
    }
  }
  val points: List[BPoint] = newList()
  val caps: List[BCapability] = newList()
  // Capabilities first, so `allows(...)` can be checked against them.
  var fi = 0
  while fi < files.count {
    val fsc = ctx.scopes[fi]
    for item in files[fi].items {
      match annotationNamed(item, "capability") {
        case Some(a) -> {
          match checkBoundaryInterface(ctx, fsc, item, "capability") {
            case Some(d) -> {
              val allowedArgs: List[String] = newList()
              allowedArgs.add("grant")
              checkAnnArgs(ctx, fsc, a, allowedArgs)
              val grant = recordArg(ctx, fsc, a, "grant")
              caps.add(
                BCapability(
                  name = d.name,
                  pkg = fsc.pkg,
                  grant = grant,
                  methods = convertMethods(ctx, fsc, d, "capability"),
                  doc = docText(item.docComments)
                )
              )
            }
            case None -> ()
          }
        }
        case None -> ()
      }
    }
    fi = fi + 1
  }
  fi = 0
  while fi < files.count {
    val fsc = ctx.scopes[fi]
    for item in files[fi].items {
      val pointAnn = annotationNamed(item, "plugin_point")
      val protocolAnn = annotationNamed(item, "protocol_point")
      val isProtocol = isSome(protocolAnn)
      val annOpt = if isProtocol { protocolAnn } else { pointAnn }
      match annOpt {
        case Some(a) -> {
          val annName = if isProtocol { "protocol_point" } else { "plugin_point" }
          match checkBoundaryInterface(ctx, fsc, item, annName) {
            case Some(d) -> {
              val allowedArgs: List[String] = newList()
              allowedArgs.add("contributions")
              allowedArgs.add("allows")
              if isProtocol {
                allowedArgs.add("protocol")
              } else {
                allowedArgs.add("version")
              }
              checkAnnArgs(ctx, fsc, a, allowedArgs)
              var version = ""
              var protocol = ""
              if isProtocol {
                protocol = match annStringArg(a, "protocol") { case Some(p) -> p; case None -> "" }
                if protocol.length == 0 {
                  report(ctx, fsc, a.span, "@protocol_point needs protocol = \"<name>/<version>\"")
                }
                if d.members.count > 0 {
                  report(ctx, fsc, d.span, "a @protocol_point interface has no members; its protocol defines the messages")
                }
              } else {
                version = match annStringArg(a, "version") { case Some(v) -> v; case None -> "" }
                if not Pm.isMajorMinor(version) {
                  report(ctx, fsc, a.span, "@plugin_point needs version = \"<major>.<minor>\"")
                }
              }
              val allows: List[String] = newList()
              for n in annCallNames(a, "allows") {
                val segs = splitList(n, ".")
                val idx = lookupSite(ctx, fsc, segs, a.span)
                if idx >= 0 {
                  val site = ctx.sites[idx]
                  val capPkg = ctx.scopes[site.fsc].pkg
                  var known = false
                  for c in caps {
                    if c.name == site.name and c.pkg == capPkg {
                      known = true
                    }
                  }
                  if known {
                    allows.add(qualifiedId(capPkg, site.name))
                  } else {
                    report(ctx, fsc, a.span, "allows(" + n + ") names an interface that is not a @capability")
                  }
                }
              }
              var methods: List[BMethod] = newList()
              if not isProtocol {
                methods = convertMethods(ctx, fsc, d, "plugin point")
              }
              points.add(
                BPoint(
                  name = d.name,
                  pkg = fsc.pkg,
                  version = version,
                  contributions = recordArg(ctx, fsc, a, "contributions"),
                  allows = allows,
                  methods = methods,
                  protocol = protocol,
                  doc = docText(item.docComments)
                )
              )
            }
            case None -> ()
          }
        }
        case None -> ()
      }
    }
    fi = fi + 1
  }
  var apiPkg = ""
  for p in points {
    if apiPkg.length == 0 {
      apiPkg = p.pkg
    } else if apiPkg != p.pkg {
      ctx.errors.add(
        "error: plugin points are declared in two packages (" + apiPkg + " and " + p.pkg +
          "); an SDK is generated for one API package"
      )
    }
  }
  for c in caps {
    if apiPkg.length == 0 {
      apiPkg = c.pkg
    } else if apiPkg != c.pkg {
      ctx.errors.add(
        "error: capabilities are declared in two packages (" + apiPkg + " and " + c.pkg +
          "); an SDK is generated for one API package"
      )
    }
  }
  if points.count == 0 and caps.count == 0 and ctx.errors.count == 0 {
    ctx.errors.add("error: no @plugin_point, @protocol_point or @capability interface found in the API sources")
  }
  // Declaration order in the sources, so the generated files are stable.
  val ordered: List[BDecl] = newList()
  for site in ctx.sites {
    for d in ctx.decls {
      if d.name == site.name and d.pkg == ctx.scopes[site.fsc].pkg {
        ordered.add(d)
      }
    }
  }
  ModelResult(
    model = ApiModel(packageName = apiPkg, decls = ordered, points = points, capabilities = caps),
    errors = ctx.errors
  )
}
