//! plugin_expand.l — Lyric.PluginExpand: the plugin desugaring pass (D207).
//!
//! Runs in `Lyric.Pipeline.pipeExpandAndRewriteCollect` right after
//! `Lyric.WireExpand`, before the alias rewrite and the type check, on every
//! target.  It reads the plugin annotations of D207 Decision 1, reports
//! K0001-K0012, and appends ordinary Lyric items, so no backend knows about
//! plugins:
//!
//!   - an API package (one declaring `@plugin_point`, `@protocol_point`,
//!     `@capability` or `@plugin_handle` items) gets `pluginEncode<T>` /
//!     `pluginDecode<T>` for every record, exposed record, union, enum and
//!     handle its boundary declarations reach (Decision 4's encoding), a
//!     `<C>Client` / `<C>Server` / `<c>Provider` / `<c>CapabilityInfo` per
//!     capability, and a `<P>Remote` / `<p>Remotes` / `<p>PointInfo` /
//!     `pluginDispatch<P>` (plus `<P>Contribution` / `<p>Contributions` when
//!     it declares contributions) per point;
//!   - a package with a `@plugin` record `R` gets `<R>Server`, an
//!     `impl PluginServer for <R>Server`, and `func main(): Int`.
//!
//! The generated items are produced as Lyric source text and parsed with
//! `Lyric.Parser`; each chunk is padded so its first line is the line of the
//! declaration it comes from, so a diagnostic inside generated code points
//! at (or just below) that declaration.
//!
//! Cross-package references.  `collectPluginPackage` is called by every
//! bridge for each package whose source the build has (its own packages and
//! path dependencies), before any file is expanded, like
//! `WireExpand.collectWireTemplates`.  A referenced point, capability or
//! boundary type is resolved through the file's imports against that map.
//! A package generates encoders only for the types its own boundary
//! declarations reach, so a type from another source package must be
//! reached there (K0001 otherwise).  A name that resolves to a package the
//! build does not have the source of (a restored dependency) is trusted to
//! have been compiled through this pass: the generated code calls its
//! `pluginEncode<T>` / `<c>CapabilityInfo` / `pluginDispatch<P>` and the
//! checks that need its declaration (K0002, K0003, the contributions and
//! request type checks of K0009) are skipped for it.
package Lyric.PluginExpand

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public surface.
// ─────────────────────────────────────────────────────────────────────────────
/// One package's source, collected before expansion so other packages can
/// resolve its points, capabilities and boundary types.
pub record PluginPackage {
  pkgName: String
  imports: List[ImportDecl]
  items: List[Item]
}

/// The expanded file and the K-diagnostics.  `file` is meaningful only when
/// `diagnostics` holds no error.
pub record PluginExpandResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// Record `file`'s package in `dest`.  A package split over several files is
/// merged.
pub func collectPluginPackage(file: in SourceFile, dest: in Map[String, PluginPackage]): Unit {
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  match mapGet(dest, pkg) {
    case Some(existing) -> {
      val items: List[Item] = newList()
      for it in existing.items {
        items.add(it)
      }
      for it in file.items {
        items.add(it)
      }
      val imps: List[ImportDecl] = newList()
      for im in existing.imports {
        imps.add(im)
      }
      for im in file.imports {
        imps.add(im)
      }
      dest[pkg] = PluginPackage(pkgName = pkg, imports = imps, items = items)
    }
    case None -> {
      dest[pkg] = PluginPackage(pkgName = pkg, imports = file.imports, items = file.items)
    }
  }
}

/// Whether `file` uses any plugin annotation (the pass leaves every other
/// file untouched).
pub func usesPluginAnnotations(file: in SourceFile): Bool {
  for it in file.items {
    if hasPluginAnnotation(it.annotations) {
      return true
    }
    match it.kind {
      case IFunc(fn) -> {
        if hasPluginAnnotation(fn.annotations) {
          return true
        }
      }
      case _ -> ()
    }
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Annotation helpers.
// ─────────────────────────────────────────────────────────────────────────────
val annPoint: String = "plugin_point"

val annProtocol: String = "protocol_point"

val annCapability: String = "capability"

val annHandle: String = "plugin_handle"

val annPlugin: String = "plugin"

val annContributions: String = "plugin_contributions"

val annRequest: String = "plugin_request"

func annName(a: in Annotation): String {
  modulePathJoin(a.name.segments)
}

func isPluginAnnName(n: in String): Bool {
  n == annPoint or n == annProtocol or n == annCapability or n == annHandle or n == annPlugin or n == annContributions or
    n == annRequest
}

func hasPluginAnnotation(anns: in List[Annotation]): Bool {
  for a in anns {
    if isPluginAnnName(annName(a)) {
      return true
    }
  }
  false
}

func findAnn(anns: in List[Annotation], name: in String): Option[Annotation] {
  for a in anns {
    if annName(a) == name {
      return Some(value = a)
    }
  }
  None
}

func hasAnn(anns: in List[Annotation], name: in String): Bool {
  match findAnn(anns, name) {
    case Some(_) -> true
    case None -> false
  }
}

func countAnn(anns: in List[Annotation], name: in String): Int {
  var n = 0
  for a in anns {
    if annName(a) == name {
      n = n + 1
    }
  }
  n
}

func withoutPluginAnns(anns: in List[Annotation]): List[Annotation] {
  val kept: List[Annotation] = newList()
  for a in anns {
    if not isPluginAnnName(annName(a)) {
      kept.add(a)
    }
  }
  kept
}

/// The annotations of an item, its function's own list included.
func allAnns(it: in Item): List[Annotation] {
  val acc: List[Annotation] = newList()
  for a in it.annotations {
    acc.add(a)
  }
  match it.kind {
    case IFunc(fn) -> {
      for a in fn.annotations {
        var dup = false
        for b in acc {
          if b.span == a.span and annName(b) == annName(a) {
            dup = true
          }
        }
        if not dup {
          acc.add(a)
        }
      }
    }
    case _ -> ()
  }
  acc
}

func isPub(it: in Item): Bool {
  match it.visibility {
    case Some(v) -> match v { case VisPub(_) -> true; case VisInternal(_) -> false }
    case None -> false
  }
}

/// A name and where it was written.
record NameAt {
  name: String
  span: Span
}

func avText(v: in AnnotationValue): String {
  match v {
    case AVInt(n, _) -> n.toString()
    case AVString(s, _) -> s
    case AVBool(b, _) -> if b { "true" } else { "false" }
    case AVIdent(s, _) -> s
  }
}

func argSpan(a: in AnnotationArg): Span {
  match a {
    case AAName(_, _, s) -> s
    case ABare(_, s) -> s
    case AACall(_, _, s) -> s
    case ALiteral(_, s) -> s
  }
}

func argName(a: in AnnotationArg): String {
  match a {
    case AAName(n, _, _) -> n
    case ABare(n, _) -> n
    case AACall(n, _, _) -> n
    case ALiteral(v, _) -> avText(v)
  }
}

func splitDotted(s: in String): List[String] {
  val parts: List[String] = newList()
  for p in Str.split(s, ".") {
    parts.add(p)
  }
  parts
}

func lowerFirst(s: in String): String {
  if s.length == 0 {
    return s
  }
  Str.toLower(Str.substring(s, 0, 1)) + Str.substring(s, 1)
}

func isDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if c < 48 or c > 57 {
      return false
    }
    i = i + 1
  }
  true
}

/// `major.minor`.
func isMajorMinor(s: in String): Bool {
  val parts = splitDotted(s)
  parts.count == 2 and isDigits(parts[0]) and isDigits(parts[1])
}

/// `major.minor` or `major.minor.patch`, optionally followed by a `-` or
/// `+` suffix (a plugin's own release version).
func isReleaseVersion(s: in String): Bool {
  var core = s
  val dash = Str.indexOfRaw(s, "-")
  val plus = Str.indexOfRaw(s, "+")
  var cut = -1
  if dash >= 0 {
    cut = dash
  }
  if plus >= 0 and (cut < 0 or plus < cut) {
    cut = plus
  }
  if cut >= 0 {
    if cut == s.length - 1 {
      return false
    }
    core = Str.substring(s, 0, cut)
  }
  val parts = splitDotted(core)
  if parts.count == 2 {
    return isDigits(parts[0]) and isDigits(parts[1])
  }
  parts.count == 3 and isDigits(parts[0]) and isDigits(parts[1]) and isDigits(parts[2])
}

func lit(s: in String): String {
  "\"" + Fmt.escapeStr(s) + "\""
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Scopes and name resolution.
// ─────────────────────────────────────────────────────────────────────────────
record Ctx {
  pkg: String
  imports: List[ImportDecl]
  items: List[Item]
  decls: Map[String, Item]
}

record St {
  packages: Map[String, PluginPackage]
  reachMemo: Map[String, List[String]]
  diags: List[Diagnostic]
}

func itemDeclName(it: in Item): String {
  match it.kind {
    case IRecord(d) -> d.name
    case IExposedRec(d) -> d.name
    case IUnion(d) -> d.name
    case IEnum(d) -> d.name
    case IDistinctType(d) -> d.name
    case ITypeAlias(d) -> d.name
    case IInterface(d) -> d.name
    case IOpaque(d) -> d.name
    case IProtected(d) -> d.name
    case _ -> ""
  }
}

func makeCtx(pkg: in String, imports: in List[ImportDecl], items: in List[Item]): Ctx {
  val decls: Map[String, Item] = newMap()
  for it in items {
    val n = itemDeclName(it)
    if n != "" and not decls.containsKey(n) {
      decls[n] = it
    }
  }
  Ctx(pkg = pkg, imports = imports, items = items, decls = decls)
}

func ctxOf(pkg: in String, home: in Ctx, st: in St): Option[Ctx] {
  if pkg == home.pkg {
    return Some(value = home)
  }
  match mapGet(st.packages, pkg) {
    case Some(pp) -> Some(value = makeCtx(pp.pkgName, pp.imports, pp.items))
    case None -> None
  }
}

/// A resolved named type or interface.  `found` means its declaration is
/// at hand (`item`); `pkg` is the declaring package when it is known even
/// without the declaration (a restored dependency); `qualifier` is the
/// prefix a derived name (`pluginEncode<T>`, `<c>CapabilityInfo`, ...)
/// takes in the file that wrote the reference.
record NamedRef {
  found: Bool
  pkg: String
  declName: String
  qualifier: String
  item: Option[Item]
  collected: Bool
}

func unresolved(name: in String, pkg: in String, qualifier: in String): NamedRef {
  NamedRef(found = false, pkg = pkg, declName = name, qualifier = qualifier, item = None, collected = false)
}

func pubItemNamed(items: in List[Item], name: in String): Option[Item] {
  for it in items {
    if isPub(it) and itemDeclName(it) == name {
      return Some(value = it)
    }
  }
  None
}

func refInPackage(st: in St, pkg: in String, name: in String, writtenQual: in String): NamedRef {
  match mapGet(st.packages, pkg) {
    case Some(pp) -> match pubItemNamed(pp.items, name) {
      case Some(it) -> NamedRef(
        found = true,
        pkg = pkg,
        declName = name,
        qualifier = pkg + ".",
        item = Some(value = it),
        collected = true
      )
      case None -> NamedRef(
        found = false,
        pkg = pkg,
        declName = name,
        qualifier = pkg + ".",
        item = None,
        collected = true
      )
    }
    case None -> {
      val q = if writtenQual == "" { "" } else { pkg + "." }
      unresolved(name, pkg, q)
    }
  }
}

func importPath(im: in ImportDecl): String {
  modulePathJoin(im.path.segments)
}

func lastSegOf(segs: in List[String]): String {
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

func isStdPkg(p: in String): Bool {
  p == "Std" or Str.startsWith(p, "Std.")
}

/// Resolve the written name `segs` in `ctx`.
func resolveNamed(segs: in List[String], ctx: in Ctx, st: in St): NamedRef {
  if segs.count == 0 {
    return unresolved("", "", "")
  }
  val name = segs[segs.count - 1]
  if segs.count == 1 {
    match mapGet(ctx.decls, name) {
      case Some(it) -> return NamedRef(
        found = true,
        pkg = ctx.pkg,
        declName = name,
        qualifier = "",
        item = Some(value = it),
        collected = true
      )
      case None -> ()
    }
    for im in ctx.imports {
      if not im.isExtern {
        match im.selector {
          case Some(sel) -> {
            val sitems: List[ImportItem] = newList()
            match sel {
              case ISSingle(x) -> sitems.add(x)
              case ISGroup(xs) -> {
                for x in xs {
                  sitems.add(x)
                }
              }
            }
            for x in sitems {
              val visible = match x.asAlias { case Some(a) -> a; case None -> x.name }
              if visible == name {
                val p = importPath(im)
                return refInPackage(st, p, x.name, p)
              }
            }
          }
          case None -> ()
        }
      }
    }
    var restored = ""
    var restoredCount = 0
    for im in ctx.imports {
      val whole = match im.selector { case Some(_) -> false; case None -> true }
      val bare = match im.asAlias { case Some(_) -> false; case None -> true }
      if not im.isExtern and whole and bare {
        val p = importPath(im)
        match mapGet(st.packages, p) {
          case Some(pp) -> match pubItemNamed(pp.items, name) {
            case Some(it) -> return NamedRef(
              found = true,
              pkg = p,
              declName = name,
              qualifier = p + ".",
              item = Some(value = it),
              collected = true
            )
            case None -> ()
          }
          case None -> {
            if not isStdPkg(p) {
              restored = p
              restoredCount = restoredCount + 1
            }
          }
        }
      }
    }
    if restoredCount == 1 {
      return unresolved(name, restored, "")
    }
    return unresolved(name, "", "")
  }
  val qsegs: List[String] = newList()
  var i = 0
  while i < segs.count - 1 {
    qsegs.add(segs[i])
    i = i + 1
  }
  val q = modulePathJoin(qsegs)
  if q == ctx.pkg {
    match mapGet(ctx.decls, name) {
      case Some(it) -> return NamedRef(
        found = true,
        pkg = ctx.pkg,
        declName = name,
        qualifier = "",
        item = Some(value = it),
        collected = true
      )
      case None -> return unresolved(name, "", "")
    }
  }
  for im in ctx.imports {
    if not im.isExtern {
      val p = importPath(im)
      val aliasHit = match im.asAlias { case Some(a) -> a == q; case None -> false }
      if aliasHit or p == q or (qsegs.count == 1 and lastSegOf(im.path.segments) == q) {
        return refInPackage(st, p, name, q)
      }
    }
  }
  if st.packages.containsKey(q) {
    return refInPackage(st, q, name, q)
  }
  unresolved(name, "", q + ".")
}

/// The qualifier for a derived name in `home` of a type declared in `pkg`.
func qualifierIn(ref: in NamedRef, home: in String): String {
  if ref.pkg == home {
    ""
  } else if ref.pkg != "" {
    ref.pkg + "."
  } else {
    ref.qualifier
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Boundary types (Decision 4).
// ─────────────────────────────────────────────────────────────────────────────
union BKind {
  case BPrim(name: String)
  case BJson
  case BOption(inner: BT)
  case BResult(okTy: BT, errTy: BT)
  case BList(elem: BT, isSlice: Bool)
  case BBytes(isSlice: Bool)
  case BMap(valueTy: BT)
  case BTuple(elems: List[BT])
  case BNamed(declName: String, qualifier: String, kind: String)
  case BBad
}

/// A classified boundary type and its spelling in the file being expanded.
record BT {
  kind: BKind
  text: String
}

func isBad(b: in BT): Bool {
  match b.kind {
    case BBad -> true
    case _ -> false
  }
}

func badBT(): BT {
  BT(kind = BBad, text = "")
}

func isPrimName(n: in String): Bool {
  n == "Bool" or n == "Byte" or n == "Int" or n == "Long" or n == "UInt" or n == "ULong" or n == "Float" or
    n == "Double" or
    n == "Char" or
    n == "String" or
    n == "Unit"
}

func k0001(st: in St, sp: in Span, whereText: in String, msg: in String): BT {
  st.diags.add(errorDiagnostic("K0001", whereText + ": " + msg, sp))
  badBT()
}

func typeArgTy(a: in TypeArg): Option[TypeExpr] {
  match a {
    case TAType(t) -> Some(value = t)
    case TAValue(_) -> None
  }
}

func isPlainName(te: in TypeExpr, ctx: in Ctx, n: in String): Bool {
  match te.kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == n and not ctx.decls.containsKey(n)
    case TParen(inner) -> isPlainName(inner, ctx, n)
    case _ -> false
  }
}

func optionOf(inner: in BT, st: in St, sp: in Span, whereText: in String): BT {
  if isBad(inner) {
    return inner
  }
  val nullable = match inner.kind {
    case BOption(_) -> true
    case BJson -> true
    case BPrim(n) -> n == "Unit"
    case _ -> false
  }
  if nullable {
    return k0001(
      st,
      sp,
      whereText,
      "Option[" + inner.text +
        "] cannot cross a plugin boundary: the inner value's encoding can already be null, so None and Some would be indistinguishable"
    )
  }
  BT(kind = BOption(inner = inner), text = "Option[" + inner.text + "]")
}

/// Classify `te`, written in `ctx`, for code generated in package `home`.
/// Reports K0001 at `sp` for a type that cannot cross a boundary.
func classify(
  te: in TypeExpr, ctx: in Ctx, home: in String, st: in St, sp: in Span, whereText: in String, depth: in Int
): BT {
  if depth > 32 {
    return k0001(st, sp, whereText, "the type alias chain is too deep")
  }
  match te.kind {
    case TParen(inner) -> classify(inner, ctx, home, st, sp, whereText, depth + 1)
    case TUnit -> BT(kind = BPrim(name = "Unit"), text = "Unit")
    case TNullable(inner) -> optionOf(classify(inner, ctx, home, st, sp, whereText, depth + 1), st, sp, whereText)
    case TSlice(elem) -> {
      if isPlainName(elem, ctx, "Byte") {
        return BT(kind = BBytes(isSlice = true), text = "slice[Byte]")
      }
      val e = classify(elem, ctx, home, st, sp, whereText, depth + 1)
      if isBad(e) {
        return e
      }
      BT(kind = BList(elem = e, isSlice = true), text = "slice[" + e.text + "]")
    }
    case TTuple(types) -> {
      val elems: List[BT] = newList()
      var text = "("
      for t in types {
        val e = classify(t, ctx, home, st, sp, whereText, depth + 1)
        if isBad(e) {
          return e
        }
        if elems.count > 0 {
          text = text + ", "
        }
        text = text + e.text
        elems.add(e)
      }
      BT(kind = BTuple(elems = elems), text = text + ")")
    }
    case TRef(path) -> classifyNamed(path.segments, ctx, home, st, sp, whereText, depth)
    case TGenericApp(head, args) -> classifyGeneric(head, args, ctx, home, st, sp, whereText, depth)
    case TArray(_, _) -> k0001(st, sp, whereText, "a fixed-size array cannot cross a plugin boundary; use List[T]")
    case TRefined(_, _) -> k0001(st, sp, whereText, "a range type cannot cross a plugin boundary; use its base type")
    case TFunction(_, _) -> k0001(st, sp, whereText, "a function cannot cross a plugin boundary")
    case TSelf -> k0001(st, sp, whereText, "Self cannot cross a plugin boundary")
    case TNever -> k0001(st, sp, whereText, "Never cannot cross a plugin boundary")
    case TError -> badBT()
  }
}

func classifyGeneric(
  head: in ModulePath,
  args: in List[TypeArg],
  ctx: in Ctx,
  home: in String,
  st: in St,
  sp: in Span,
  whereText: in String,
  depth: in Int,
): BT {
  val hname = lastSegOf(head.segments)
  val tys: List[TypeExpr] = newList()
  for a in args {
    match typeArgTy(a) {
      case Some(t) -> tys.add(t)
      case None -> return k0001(st, sp, whereText, "a value type argument cannot cross a plugin boundary")
    }
  }
  val builtin = head.segments.count == 1 and not ctx.decls.containsKey(hname)
  if builtin and hname == "Option" and tys.count == 1 {
    return optionOf(classify(tys[0], ctx, home, st, sp, whereText, depth + 1), st, sp, whereText)
  }
  if builtin and hname == "Result" and tys.count == 2 {
    val o = classify(tys[0], ctx, home, st, sp, whereText, depth + 1)
    if isBad(o) {
      return o
    }
    val e = classify(tys[1], ctx, home, st, sp, whereText, depth + 1)
    if isBad(e) {
      return e
    }
    return BT(kind = BResult(okTy = o, errTy = e), text = "Result[" + o.text + ", " + e.text + "]")
  }
  if builtin and hname == "List" and tys.count == 1 {
    if isPlainName(tys[0], ctx, "Byte") {
      return BT(kind = BBytes(isSlice = false), text = "List[Byte]")
    }
    val e = classify(tys[0], ctx, home, st, sp, whereText, depth + 1)
    if isBad(e) {
      return e
    }
    return BT(kind = BList(elem = e, isSlice = false), text = "List[" + e.text + "]")
  }
  if builtin and hname == "Map" and tys.count == 2 {
    if not isPlainName(tys[0], ctx, "String") {
      return k0001(
        st,
        sp,
        whereText,
        "a Map crosses a plugin boundary only with String keys (it is encoded as a JSON object)"
      )
    }
    val v = classify(tys[1], ctx, home, st, sp, whereText, depth + 1)
    if isBad(v) {
      return v
    }
    return BT(kind = BMap(valueTy = v), text = "Map[String, " + v.text + "]")
  }
  k0001(
    st,
    sp,
    whereText,
    "the generic type " + modulePathJoin(head.segments) +
      " cannot cross a plugin boundary (only Option, Result, List, slice and Map[String, T] are generic boundary types)"
  )
}

func classifyNamed(
  segs: in List[String],
  ctx: in Ctx,
  home: in String,
  st: in St,
  sp: in Span,
  whereText: in String,
  depth: in Int,
): BT {
  val name = lastSegOf(segs)
  val written = modulePathJoin(segs)
  if segs.count == 1 and not ctx.decls.containsKey(name) and isPrimName(name) {
    return BT(kind = BPrim(name = name), text = name)
  }
  if name == "JsonValue" and not (segs.count == 1 and ctx.decls.containsKey(name)) {
    return BT(kind = BJson, text = "JsonValue")
  }
  val ref = resolveNamed(segs, ctx, st)
  if not ref.found {
    if ref.pkg != "" and not ref.collected and not isStdPkg(ref.pkg) {
      val q = qualifierIn(ref, home)
      return BT(kind = BNamed(declName = name, qualifier = q, kind = "restored"), text = q + name)
    }
    if ref.pkg != "" and isStdPkg(ref.pkg) {
      return k0001(st, sp, whereText, written + " (from " + ref.pkg + ") has no plugin encoding")
    }
    if ref.collected {
      return k0001(st, sp, whereText, ref.pkg + " declares no public type " + name)
    }
    return k0001(
      st,
      sp,
      whereText,
      written +
        " is not a type a plugin boundary can carry (it is not declared in this package or in an imported Lyric package)"
    )
  }
  val it = match ref.item { case Some(x) -> x; case None -> return badBT() }
  var kind = ""
  match it.kind {
    case ITypeAlias(d) -> {
      match d.generics {
        case Some(_) -> return k0001(st, sp, whereText, "the generic alias " + written + " cannot cross a plugin boundary")
        case None -> ()
      }
      match ctxOf(ref.pkg, ctx, st) {
        case Some(dc) -> return classify(d.rhs, dc, home, st, sp, whereText, depth + 1)
        case None -> return badBT()
      }
    }
    case IRecord(d) -> {
      kind = "record"
      match d.generics {
        case Some(_) -> return k0001(st, sp, whereText, "the generic record " + written + " cannot cross a plugin boundary")
        case None -> ()
      }
    }
    case IExposedRec(d) -> {
      kind = "record"
      match d.generics {
        case Some(_) -> return k0001(st, sp, whereText, "the generic record " + written + " cannot cross a plugin boundary")
        case None -> ()
      }
    }
    case IUnion(d) -> {
      kind = "union"
      match d.generics {
        case Some(_) -> return k0001(st, sp, whereText, "the generic union " + written + " cannot cross a plugin boundary")
        case None -> ()
      }
      for c in d.cases {
        for f in c.fields {
          match f {
            case UFPos(_, _) -> return k0001(
              st,
              sp,
              whereText,
              "union case " + name + "." + c.name + " has positional fields; a boundary union needs named case fields"
            )
            case UFNamed(_, _, _) -> ()
          }
        }
      }
    }
    case IEnum(_) -> {
      kind = "enum"
    }
    case IDistinctType(d) -> {
      match findAnn(it.annotations, annHandle) {
        case Some(_) -> {
          kind = "handle"
        }
        case None -> return k0001(
          st,
          sp,
          whereText,
          "the distinct type " + written + " cannot cross a plugin boundary; mark it @plugin_handle (as `pub type " +
            d.name +
            " = Long`) to pass it as a handle"
        )
      }
    }
    case IInterface(_) -> return k0001(st, sp, whereText, "the interface " + written + " cannot cross a plugin boundary")
    case IOpaque(_) -> return k0001(st, sp, whereText, "the opaque type " + written + " cannot cross a plugin boundary")
    case IProtected(_) -> return k0001(st, sp, whereText, "the protected type " + written + " cannot cross a plugin boundary")
    case _ -> return k0001(st, sp, whereText, written + " is not a type")
  }
  if ref.pkg != home {
    val reached = reachOf(ref.pkg, st)
    if not reached.contains(name) {
      return k0001(
        st,
        sp,
        whereText,
        written + " is declared in " + ref.pkg +
          ", which does not use it in a plugin point, capability, grant or contributions type, so it has no generated encoder; declare it in the package of the point or capability that carries it, or use it at a boundary in " +
          ref.pkg
      )
    }
  }
  val q = qualifierIn(ref, home)
  BT(kind = BNamed(declName = name, qualifier = q, kind = kind), text = q + name)
}

// The local types a package's own boundary declarations reach.
func reachOf(pkg: in String, st: in St): List[String] {
  match mapGet(st.reachMemo, pkg) {
    case Some(r) -> return r
    case None -> ()
  }
  val acc: List[String] = newList()
  st.reachMemo[pkg] = acc
  match mapGet(st.packages, pkg) {
    case Some(pp) -> computeReach(makeCtx(pp.pkgName, pp.imports, pp.items), acc)
    case None -> ()
  }
  acc
}

func identType(name: in String, sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  for s in splitDotted(name) {
    segs.add(s)
  }
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func annIdentValue(a: in Annotation, key: in String): Option[String] {
  for arg in a.args {
    match arg {
      case AAName(n, v, _) -> {
        if n == key {
          match v {
            case AVIdent(s, _) -> return Some(value = s)
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
  }
  None
}

func boundaryRoots(ctx: in Ctx): List[TypeExpr] {
  val roots: List[TypeExpr] = newList()
  for it in ctx.items {
    match it.kind {
      case IInterface(d) -> {
        var isBoundary = false
        for a in it.annotations {
          val n = annName(a)
          if n == annPoint or n == annProtocol or n == annCapability {
            isBoundary = true
            match annIdentValue(a, "contributions") {
              case Some(k) -> roots.add(identType(k, a.span))
              case None -> ()
            }
            match annIdentValue(a, "grant") {
              case Some(g) -> roots.add(identType(g, a.span))
              case None -> ()
            }
          }
        }
        if isBoundary {
          for m in d.members {
            match m {
              case IMSig(sig) -> {
                for p in sig.params {
                  roots.add(p.ty)
                }
                match sig.ret {
                  case Some(r) -> roots.add(r)
                  case None -> ()
                }
              }
              case IMFunc(fn) -> {
                for p in fn.params {
                  roots.add(p.ty)
                }
                match fn.ret {
                  case Some(r) -> roots.add(r)
                  case None -> ()
                }
              }
              case IMAssoc(_) -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  roots
}

func computeReach(ctx: in Ctx, into: in List[String]): Unit {
  val seen: Map[String, Bool] = newMap()
  for te in boundaryRoots(ctx) {
    walkLocal(te, ctx, seen)
  }
  for it in ctx.items {
    val n = itemDeclName(it)
    var take = seen.containsKey(n)
    match it.kind {
      case IDistinctType(_) -> {
        match findAnn(it.annotations, annHandle) {
          case Some(_) -> {
            take = true
          }
          case None -> ()
        }
      }
      case ITypeAlias(_) -> {
        take = false
      }
      case IInterface(_) -> {
        take = false
      }
      case _ -> ()
    }
    if take and n != "" and not into.contains(n) {
      into.add(n)
    }
  }
}

func walkLocal(te: in TypeExpr, ctx: in Ctx, seen: in Map[String, Bool]): Unit {
  match te.kind {
    case TParen(inner) -> walkLocal(inner, ctx, seen)
    case TNullable(inner) -> walkLocal(inner, ctx, seen)
    case TSlice(elem) -> walkLocal(elem, ctx, seen)
    case TArray(_, elem) -> walkLocal(elem, ctx, seen)
    case TTuple(types) -> {
      for t in types {
        walkLocal(t, ctx, seen)
      }
    }
    case TGenericApp(_, args) -> {
      for a in args {
        match typeArgTy(a) {
          case Some(t) -> walkLocal(t, ctx, seen)
          case None -> ()
        }
      }
    }
    case TRef(path) -> {
      val segs = path.segments
      var name = ""
      if segs.count == 1 {
        name = segs[0]
      } else {
        val qsegs: List[String] = newList()
        var i = 0
        while i < segs.count - 1 {
          qsegs.add(segs[i])
          i = i + 1
        }
        if modulePathJoin(qsegs) == ctx.pkg {
          name = lastSegOf(segs)
        }
      }
      if name != "" and not seen.containsKey(name) {
        match mapGet(ctx.decls, name) {
          case Some(it) -> {
            seen[name] = true
            match it.kind {
              case IRecord(d) -> walkRecordFields(d, ctx, seen)
              case IExposedRec(d) -> walkRecordFields(d, ctx, seen)
              case IUnion(d) -> {
                for c in d.cases {
                  for f in c.fields {
                    match f {
                      case UFNamed(_, t, _) -> walkLocal(t, ctx, seen)
                      case UFPos(t, _) -> walkLocal(t, ctx, seen)
                    }
                  }
                }
              }
              case ITypeAlias(d) -> walkLocal(d.rhs, ctx, seen)
              case _ -> ()
            }
          }
          case None -> ()
        }
      }
    }
    case _ -> ()
  }
}

func walkRecordFields(d: in RecordDecl, ctx: in Ctx, seen: in Map[String, Bool]): Unit {
  for m in d.members {
    match m {
      case RMField(f) -> walkLocal(f.ty, ctx, seen)
      case _ -> ()
    }
  }
}

func recordFields(d: in RecordDecl): List[FieldDecl] {
  val fs: List[FieldDecl] = newList()
  for m in d.members {
    match m {
      case RMField(f) -> fs.add(f)
      case _ -> ()
    }
  }
  fs
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Models of the annotated declarations.
// ─────────────────────────────────────────────────────────────────────────────
record MethodModel {
  name: String
  params: List[Param]
  paramTys: List[BT]
  okTy: BT
  errTy: BT
  guards: List[ContractClause]
  hasBody: Bool
}

record IfaceModel {
  name: String
  kind: String
  version: String
  protocol: String
  hasProtocol: Bool
  contributions: Option[BT]
  grant: Option[BT]
  allows: List[NameAt]
  methods: List[MethodModel]
  line: Int
}

record HandleModel {
  name: String
}

record PointRef {
  key: String
  declName: String
  qualifier: String
  pkg: String
  item: Option[Item]
  span: Span
}

record CapField {
  fieldName: String
  fieldTy: TypeExpr
  optional: Bool
  capName: String
  qualifier: String
  pkg: String
  item: Option[Item]
  key: String
  span: Span
}

record PluginModel {
  name: String
  id: String
  version: String
  publisher: String
  points: List[PointRef]
  caps: List[CapField]
  contribFns: Map[String, String]
  contribTys: Map[String, BT]
  requestFns: Map[String, String]
  requestTys: Map[String, BT]
  pointMethodNames: Map[String, List[String]]
  line: Int
}

func k(st: in St, code: in String, msg: in String, sp: in Span): Unit {
  st.diags.add(errorDiagnostic(code, msg, sp))
}

record TyPair {
  first: TypeExpr
  second: TypeExpr
}

func isResultTy(te: in TypeExpr): Option[TyPair] {
  match te.kind {
    case TGenericApp(head, args) -> {
      if lastSegOf(head.segments) == "Result" and args.count == 2 {
        match typeArgTy(args[0]) {
          case Some(o) -> match typeArgTy(args[1]) {
            case Some(e) -> return Some(value = TyPair(first = o, second = e))
            case None -> ()
          }
          case None -> ()
        }
      }
      None
    }
    case TParen(inner) -> isResultTy(inner)
    case _ -> None
  }
}

// A reference written in a `requires:` clause, for K0007.
record FreeRef {
  name: String
  span: Span
  inCall: Bool
  unsupported: Bool
}

func patBinds(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(n, inner) -> {
      acc.add(n)
      match inner {
        case Some(q) -> patBinds(q, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        patBinds(a, acc)
      }
    }
    case PRecord(_, fields, _) -> {
      for f in fields {
        match f {
          case RPFNamed(_, q, _) -> patBinds(q, acc)
          case RPFShort(n, _) -> acc.add(n)
        }
      }
    }
    case PTuple(ps) -> {
      for q in ps {
        patBinds(q, acc)
      }
    }
    case PParen(q) -> patBinds(q, acc)
    case PTypeTest(q, _) -> patBinds(q, acc)
    case POr(ps) -> {
      for q in ps {
        patBinds(q, acc)
      }
    }
    case _ -> ()
  }
}

func withNames(bound: in List[String], extra: in List[String]): List[String] {
  val acc: List[String] = newList()
  for b in bound {
    acc.add(b)
  }
  for x in extra {
    acc.add(x)
  }
  acc
}

func freeRefsEob(e: in ExprOrBlock, bound: in List[String], acc: in List[FreeRef]): Unit {
  match e {
    case EOBExpr(x) -> freeRefs(x, false, bound, acc)
    case EOBBlock(b) -> acc.add(FreeRef(name = "a block", span = b.span, inCall = false, unsupported = true))
  }
}

func freeRefs(e: in Expr, inCall: in Bool, bound: in List[String], acc: in List[FreeRef]): Unit {
  match e.kind {
    case ELiteral(_) -> ()
    case EInterpolated(segs) -> {
      for s in segs {
        match s {
          case ISExpr(x) -> freeRefs(x, false, bound, acc)
          case ISText(_, _) -> ()
        }
      }
    }
    case EPath(path) -> {
      if path.segments.count > 0 and not bound.contains(path.segments[0]) {
        acc.add(FreeRef(name = path.segments[0], span = e.span, inCall = inCall, unsupported = false))
      }
    }
    case EParen(x) -> freeRefs(x, inCall, bound, acc)
    case ETuple(xs) -> {
      for x in xs {
        freeRefs(x, false, bound, acc)
      }
    }
    case EList(xs) -> {
      for x in xs {
        freeRefs(x, false, bound, acc)
      }
    }
    case EIf(c, t, el, _) -> {
      freeRefs(c, false, bound, acc)
      freeRefsEob(t, bound, acc)
      match el {
        case Some(x) -> freeRefsEob(x, bound, acc)
        case None -> ()
      }
    }
    case EMatch(s, arms) -> {
      freeRefs(s, false, bound, acc)
      for arm in arms {
        val names: List[String] = newList()
        patBinds(arm.pattern, names)
        val inner = withNames(bound, names)
        match arm.guard {
          case Some(g) -> freeRefs(g, false, inner, acc)
          case None -> ()
        }
        freeRefsEob(arm.body, inner, acc)
      }
    }
    case ECall(fn, args) -> {
      freeRefs(fn, true, bound, acc)
      for a in args {
        match a {
          case CANamed(_, v, _) -> freeRefs(v, false, bound, acc)
          case CAPositional(x) -> freeRefs(x, false, bound, acc)
        }
      }
    }
    case ETypeApp(fn, _) -> freeRefs(fn, inCall, bound, acc)
    case EIndex(r, idx) -> {
      freeRefs(r, false, bound, acc)
      for x in idx {
        freeRefs(x, false, bound, acc)
      }
    }
    case EMember(r, _) -> freeRefs(r, inCall, bound, acc)
    case EPrefix(_, x) -> freeRefs(x, false, bound, acc)
    case EBinop(_, l, r) -> {
      freeRefs(l, false, bound, acc)
      freeRefs(r, false, bound, acc)
    }
    case ERange(rb) -> {
      match rangeLowerExpr(rb) {
        case Some(x) -> freeRefs(x, false, bound, acc)
        case None -> ()
      }
      match rangeUpperExpr(rb) {
        case Some(x) -> freeRefs(x, false, bound, acc)
        case None -> ()
      }
    }
    case EForall(binders, wh, body, _) -> freeRefsQuant(binders, wh, body, bound, acc)
    case EExists(binders, wh, body, _) -> freeRefsQuant(binders, wh, body, bound, acc)
    case ESelf -> acc.add(FreeRef(name = "self", span = e.span, inCall = false, unsupported = true))
    case _ -> acc.add(
      FreeRef(name = "a " + exprKindTag(e) + " expression", span = e.span, inCall = false, unsupported = true)
    )
  }
}

func freeRefsQuant(
  binders: in List[PropertyBinder],
  wh: in Option[Expr],
  body: in Expr,
  bound: in List[String],
  acc: in List[FreeRef],
): Unit {
  val names: List[String] = newList()
  for b in binders {
    names.add(b.name)
  }
  val inner = withNames(bound, names)
  match wh {
    case Some(w) -> freeRefs(w, false, inner, acc)
    case None -> ()
  }
  freeRefs(body, false, inner, acc)
}

func mentionsGrant(e: in Expr): Bool {
  val refs: List[FreeRef] = newList()
  val noBound: List[String] = newList()
  freeRefs(e, false, noBound, refs)
  for r in refs {
    if r.name == "grant" and not r.inCall {
      return true
    }
  }
  false
}

func methodsOf(
  decl: in InterfaceDecl, ifaceName: in String, isCap: in Bool, hasGrant: in Bool, ctx: in Ctx, st: in St
): List[MethodModel] {
  val acc: List[MethodModel] = newList()
  for m in decl.members {
    match m {
      case IMSig(sig) -> {
        match methodModel(ifaceName, sig.name, sig.generics, sig.params, sig.ret, sig.contracts, false, sig.span, isCap, hasGrant, ctx, st) {
          case Some(mm) -> acc.add(mm)
          case None -> ()
        }
      }
      case IMFunc(fn) -> {
        val hb = match fn.body { case Some(_) -> true; case None -> false }
        match methodModel(ifaceName, fn.name, fn.generics, fn.params, fn.ret, fn.contracts, hb, fn.span, isCap, hasGrant, ctx, st) {
          case Some(mm) -> acc.add(mm)
          case None -> ()
        }
      }
      case IMAssoc(a) -> k(
        st,
        "K0004",
        "plugin interface " + ifaceName + " declares the associated type " + a.name +
          "; a plugin point or capability cannot have associated types",
        a.span
      )
    }
  }
  acc
}

func methodModel(
  ifaceName: in String,
  name: in String,
  generics: in Option[GenericParams],
  params: in List[Param],
  ret: in Option[TypeExpr],
  contracts: in List[ContractClause],
  hasBody: in Bool,
  sp: in Span,
  isCap: in Bool,
  hasGrant: in Bool,
  ctx: in Ctx,
  st: in St,
): Option[MethodModel] {
  val whereText = ifaceName + "." + name
  match generics {
    case Some(_) -> {
      k(
        st,
        "K0004",
        "method " + whereText + " is generic; a plugin point or capability method cannot have type parameters",
        sp
      )
      return None
    }
    case None -> ()
  }
  val retTe = match ret {
    case Some(r) -> r
    case None -> {
      k(st, "K0004", "method " + whereText + " must return Result[T, E]", sp)
      return None
    }
  }
  val pair = match isResultTy(retTe) {
    case Some(p) -> p
    case None -> {
      k(st, "K0004", "method " + whereText + " must return Result[T, E], not " + Fmt.typeStr(retTe), retTe.span)
      return None
    }
  }
  var ok = true
  val ptys: List[BT] = newList()
  for p in params {
    match p.mode {
      case PMIn -> ()
      case _ -> {
        k(
          st,
          "K0001",
          "parameter '" + p.name + "' of " + whereText + " is out or inout; only in parameters cross a plugin boundary",
          p.span
        )
        ok = false
      }
    }
    val b = classify(p.ty, ctx, ctx.pkg, st, p.ty.span, "parameter '" + p.name + "' of " + whereText, 0)
    if isBad(b) {
      ok = false
    }
    ptys.add(b)
  }
  val okTe = pair.first
  val errTe = pair.second
  val okB = classify(okTe, ctx, ctx.pkg, st, okTe.span, "the result of " + whereText, 0)
  val errB = classify(errTe, ctx, ctx.pkg, st, errTe.span, "the error of " + whereText, 0)
  if isBad(okB) or isBad(errB) {
    ok = false
  }
  val guards: List[ContractClause] = newList()
  if isCap {
    val allowed: List[String] = newList()
    allowed.add("grant")
    for p in params {
      allowed.add(p.name)
    }
    for c in contracts {
      match c {
        case CCRequires(ex, csp) -> {
          if mentionsGrant(ex) {
            if not hasGrant {
              k(
                st,
                "K0007",
                "the requires: clause of " + whereText + " names grant, but capability " + ifaceName +
                  " declares no grant type (@capability(grant = ...))",
                csp
              )
              ok = false
            }
            val refs: List[FreeRef] = newList()
            val noBound: List[String] = newList()
            freeRefs(ex, false, noBound, refs)
            for r in refs {
              if r.unsupported {
                k(
                  st,
                  "K0007",
                  "the requires: clause of " + whereText + " uses " + r.name +
                    "; a capability guard may use only grant, the method's parameters and function calls",
                  r.span
                )
                ok = false
              } else if not r.inCall and not allowed.contains(r.name) {
                k(
                  st,
                  "K0007",
                  "the requires: clause of " + whereText + " names '" + r.name +
                    "'; a capability guard may use only grant, the method's parameters and function calls",
                  r.span
                )
                ok = false
              }
            }
            guards.add(c)
          }
        }
        case _ -> ()
      }
    }
  }
  if not ok {
    return None
  }
  Some(
    value = MethodModel(
      name = name,
      params = params,
      paramTys = ptys,
      okTy = okB,
      errTy = errB,
      guards = guards,
      hasBody = hasBody
    )
  )
}

func checkArgs(
  a: in Annotation,
  allowedNamed: in List[String],
  allowedCalls: in List[String],
  what: in String,
  st: in St,
): Unit {
  for arg in a.args {
    match arg {
      case AAName(n, _, s) -> {
        if not allowedNamed.contains(n) {
          k(st, "K0006", "@" + what + " has no argument '" + n + "'", s)
        }
      }
      case AACall(n, _, s) -> {
        if not allowedCalls.contains(n) {
          k(st, "K0006", "@" + what + " has no argument '" + n + "(...)'", s)
        }
      }
      case _ -> k(
        st,
        "K0006",
        "@" + what + " takes only named arguments; unexpected '" + argName(arg) + "'",
        argSpan(arg)
      )
    }
  }
}

func annStringValue(a: in Annotation, key: in String, st: in St): Option[String] {
  for arg in a.args {
    match arg {
      case AAName(n, v, s) -> {
        if n == key {
          match v {
            case AVString(x, _) -> return Some(value = x)
            case _ -> {
              k(st, "K0006", "@" + annName(a) + "(" + key + " = ...) must be a string", s)
              return None
            }
          }
        }
      }
      case _ -> ()
    }
  }
  None
}

func annIdentValueChecked(a: in Annotation, key: in String, st: in St): Option[String] {
  for arg in a.args {
    match arg {
      case AAName(n, v, s) -> {
        if n == key {
          match v {
            case AVIdent(x, _) -> return Some(value = x)
            case _ -> {
              k(st, "K0006", "@" + annName(a) + "(" + key + " = ...) must name a type", s)
              return None
            }
          }
        }
      }
      case _ -> ()
    }
  }
  None
}

func annCallNames(a: in Annotation, key: in String, st: in St): List[NameAt] {
  val acc: List[NameAt] = newList()
  for arg in a.args {
    match arg {
      case AACall(n, inner, _) -> {
        if n == key {
          for x in inner {
            match x {
              case ABare(nm, s) -> acc.add(NameAt(name = nm, span = s))
              case _ -> k(st, "K0006", "@" + annName(a) + "(" + key + "(...)) takes interface names", argSpan(x))
            }
          }
        }
      }
      case _ -> ()
    }
  }
  acc
}

func ifaceModel(
  it: in Item, decl: in InterfaceDecl, a: in Annotation, kind: in String, ctx: in Ctx, st: in St
): Option[IfaceModel] {
  val what = annName(a)
  if not isPub(it) {
    k(st, "K0005", "@" + what + " must be on a pub interface; " + decl.name + " is not pub", a.span)
    return None
  }
  match decl.generics {
    case Some(_) -> {
      k(
        st,
        "K0004",
        "interface " + decl.name + " is generic; a plugin point or capability cannot have type parameters",
        decl.span
      )
      return None
    }
    case None -> ()
  }
  val named: List[String] = newList()
  val calls: List[String] = newList()
  if kind == "capability" {
    named.add("grant")
  } else {
    named.add("version")
    named.add("contributions")
    calls.add("allows")
    if kind == "protocol" {
      named.add("protocol")
    }
  }
  val before = st.diags.count
  checkArgs(a, named, calls, what, st)
  var version = "1.0"
  var protocol = ""
  var hasProtocol = false
  if kind == "point" {
    match annStringValue(a, "version", st) {
      case Some(v) -> {
        if not isMajorMinor(v) {
          k(
            st,
            "K0006",
            "@plugin_point(version = \"" + v + "\") on " + decl.name + " must be major.minor, such as \"1.2\"",
            a.span
          )
        }
        version = v
      }
      case None -> k(st, "K0006", "@plugin_point on " + decl.name + " needs version = \"major.minor\"", a.span)
    }
  }
  if kind == "protocol" {
    match annStringValue(a, "version", st) {
      case Some(v) -> {
        if not isMajorMinor(v) {
          k(
            st,
            "K0006",
            "@protocol_point(version = \"" + v + "\") on " + decl.name + " must be major.minor, such as \"1.2\"",
            a.span
          )
        }
        version = v
      }
      case None -> ()
    }
    match annStringValue(a, "protocol", st) {
      case Some(p) -> {
        if p == "" {
          k(st, "K0006", "@protocol_point(protocol = ...) on " + decl.name + " must not be empty", a.span)
        }
        protocol = p
        hasProtocol = true
      }
      case None -> k(st, "K0006", "@protocol_point on " + decl.name + " needs protocol = \"<name>/<version>\"", a.span)
    }
    if decl.members.count > 0 {
      k(
        st,
        "K0011",
        "@protocol_point interface " + decl.name +
          " must have no members; its messages are the protocol's, not Lyric methods",
        decl.span
      )
    }
  }
  if st.diags.count > before {
    return None
  }
  var contributions: Option[BT] = None
  var grant: Option[BT] = None
  var allows: List[NameAt] = newList()
  if kind == "capability" {
    match annIdentValueChecked(a, "grant", st) {
      case Some(g) -> {
        val b = classify(identType(g, a.span), ctx, ctx.pkg, st, a.span, "the grant of capability " + decl.name, 0)
        if isBad(b) {
          return None
        }
        grant = Some(value = b)
      }
      case None -> ()
    }
  } else {
    match annIdentValueChecked(a, "contributions", st) {
      case Some(c) -> {
        val b = classify(identType(c, a.span), ctx, ctx.pkg, st, a.span, "the contributions of " + decl.name, 0)
        if isBad(b) {
          return None
        }
        contributions = Some(value = b)
      }
      case None -> ()
    }
    allows = annCallNames(a, "allows", st)
    for al in allows {
      val ref = resolveNamed(splitDotted(al.name), ctx, st)
      if ref.found {
        val isCapIface = match ref.item {
          case Some(x) -> match x.kind {
            case IInterface(_) -> match findAnn(x.annotations, annCapability) {
              case Some(_) -> true
              case None -> false
            }
            case _ -> false
          }
          case None -> false
        }
        if not isCapIface {
          k(
            st,
            "K0002",
            "allows(" + al.name + ") on " + decl.name + " names something that is not a @capability interface",
            al.span
          )
        }
      } else if ref.collected or ref.pkg == "" {
        k(st, "K0002", "allows(" + al.name + ") on " + decl.name + " names no known @capability interface", al.span)
      }
    }
  }
  val hasGrant = match grant { case Some(_) -> true; case None -> false }
  val methods = methodsOf(decl, decl.name, kind == "capability", hasGrant, ctx, st)
  if st.diags.count > before {
    return None
  }
  Some(
    value = IfaceModel(
      name = decl.name,
      kind = kind,
      version = version,
      protocol = protocol,
      hasProtocol = hasProtocol,
      contributions = contributions,
      grant = grant,
      allows = allows,
      methods = methods,
      line = it.span.startPos.line
    )
  )
}

func isAnnotatedIface(it: in Item, which: in String): Bool {
  match it.kind {
    case IInterface(_) -> match findAnn(it.annotations, which) { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

func isPointItem(it: in Item): Bool {
  isAnnotatedIface(it, annPoint) or isAnnotatedIface(it, annProtocol)
}

/// Point declaration facts read from its item (in its own package).
func pointContributionsTe(it: in Item): Option[TypeExpr] {
  for a in it.annotations {
    val n = annName(a)
    if n == annPoint or n == annProtocol {
      match annIdentValue(a, "contributions") {
        case Some(c) -> return Some(value = identType(c, a.span))
        case None -> ()
      }
    }
  }
  None
}

func capGrantTe(it: in Item): Option[TypeExpr] {
  match findAnn(it.annotations, annCapability) {
    case Some(a) -> match annIdentValue(a, "grant") {
      case Some(g) -> Some(value = identType(g, a.span))
      case None -> None
    }
    case None -> None
  }
}

func pointAllowNames(it: in Item): List[String] {
  val acc: List[String] = newList()
  for a in it.annotations {
    val n = annName(a)
    if n == annPoint or n == annProtocol {
      for arg in a.args {
        match arg {
          case AACall(cn, inner, _) -> {
            if cn == "allows" {
              for x in inner {
                match x {
                  case ABare(nm, _) -> acc.add(nm)
                  case _ -> ()
                }
              }
            }
          }
          case _ -> ()
        }
      }
    }
  }
  acc
}

/// "pkg.Name" of a resolved type expression, "" when unresolved.
func namedKey(te: in TypeExpr, ctx: in Ctx, st: in St): String {
  match te.kind {
    case TRef(path) -> {
      val ref = resolveNamed(path.segments, ctx, st)
      if ref.pkg == "" {
        ""
      } else {
        ref.pkg + "." + ref.declName
      }
    }
    case TParen(inner) -> namedKey(inner, ctx, st)
    case _ -> ""
  }
}

func refKey(ref: in NamedRef): String {
  if ref.pkg != "" {
    ref.pkg + "." + ref.declName
  } else {
    ref.qualifier + ref.declName
  }
}

func implTargetIs(d: in ImplDecl, recName: in String, pkg: in String): Bool {
  match d.target.kind {
    case TRef(path) -> {
      val segs = path.segments
      if segs.count == 1 {
        return segs[0] == recName
      }
      val qsegs: List[String] = newList()
      var i = 0
      while i < segs.count - 1 {
        qsegs.add(segs[i])
        i = i + 1
      }
      modulePathJoin(qsegs) == pkg and lastSegOf(segs) == recName
    }
    case _ -> false
  }
}

func clientCapName(te: in TypeExpr): Option[List[String]] {
  match te.kind {
    case TRef(path) -> {
      val last = lastSegOf(path.segments)
      if Str.endsWith(last, "Client") and last.length > 6 {
        val segs: List[String] = newList()
        var i = 0
        while i < path.segments.count - 1 {
          segs.add(path.segments[i])
          i = i + 1
        }
        segs.add(Str.substring(last, 0, last.length - 6))
        return Some(value = segs)
      }
      None
    }
    case TParen(inner) -> clientCapName(inner)
    case _ -> None
  }
}

func optionInner(te: in TypeExpr): Option[TypeExpr] {
  match te.kind {
    case TGenericApp(head, args) -> {
      if head.segments.count == 1 and head.segments[0] == "Option" and args.count == 1 {
        return typeArgTy(args[0])
      }
      None
    }
    case TNullable(inner) -> Some(value = inner)
    case TParen(inner) -> optionInner(inner)
    case _ -> None
  }
}

func singleNameArg(a: in Annotation, what: in String, st: in St): Option[NameAt] {
  if a.args.count != 1 {
    k(st, "K0009", "@" + what + " takes exactly one interface name", a.span)
    return None
  }
  match a.args[0] {
    case ABare(n, s) -> Some(value = NameAt(name = n, span = s))
    case _ -> {
      k(st, "K0009", "@" + what + " takes exactly one interface name", a.span)
      None
    }
  }
}

func pluginModel(
  it: in Item, decl: in RecordDecl, a: in Annotation, ctx: in Ctx, st: in St, file: in SourceFile
): Option[PluginModel] {
  if not isPub(it) {
    k(st, "K0005", "@plugin must be on a pub record; " + decl.name + " is not pub", a.span)
    return None
  }
  match decl.generics {
    case Some(_) -> {
      k(st, "K0005", "@plugin record " + decl.name + " must not be generic", decl.span)
      return None
    }
    case None -> ()
  }
  val before = st.diags.count
  val named: List[String] = newList()
  named.add("id")
  named.add("version")
  named.add("publisher")
  val calls: List[String] = newList()
  calls.add("implements")
  checkArgs(a, named, calls, "plugin", st)
  var id = ""
  match annStringValue(a, "id", st) {
    case Some(v) -> {
      if v == "" {
        k(st, "K0006", "@plugin(id = ...) on " + decl.name + " must not be empty", a.span)
      }
      id = v
    }
    case None -> k(st, "K0006", "@plugin on " + decl.name + " needs id = \"<publisher>.<name>\"", a.span)
  }
  var version = ""
  match annStringValue(a, "version", st) {
    case Some(v) -> {
      if not isReleaseVersion(v) {
        k(
          st,
          "K0006",
          "@plugin(version = \"" + v + "\") on " + decl.name + " must be major.minor or major.minor.patch, such as \"0.4.1\"",
          a.span
        )
      }
      version = v
    }
    case None -> k(st, "K0006", "@plugin on " + decl.name + " needs version = \"major.minor.patch\"", a.span)
  }
  val publisher = match annStringValue(a, "publisher", st) { case Some(p) -> p; case None -> "" }
  val implNames = annCallNames(a, "implements", st)
  if implNames.count == 0 {
    k(st, "K0006", "@plugin on " + decl.name + " needs implements(<point>, ...)", a.span)
  }
  if st.diags.count > before {
    return None
  }
  // The points it implements.
  val points: List[PointRef] = newList()
  for nm in implNames {
    val ref = resolveNamed(splitDotted(nm.name), ctx, st)
    if ref.found {
      val isPt = match ref.item { case Some(x) -> isPointItem(x); case None -> false }
      if not isPt {
        k(
          st,
          "K0008",
          "implements(" + nm.name + ") on " + decl.name + " names an interface that is not a @plugin_point or @protocol_point",
          nm.span
        )
      }
    } else if ref.collected or ref.pkg == "" {
      k(st, "K0008", "implements(" + nm.name + ") on " + decl.name + " names no known plugin point", nm.span)
    }
    points.add(
      PointRef(
        key = refKey(ref),
        declName = ref.declName,
        qualifier = qualifierIn(ref, ctx.pkg),
        pkg = ref.pkg,
        item = ref.item,
        span = nm.span
      )
    )
  }
  // Its impl blocks.
  val implKeys: List[String] = newList()
  val pointMethodNames: Map[String, List[String]] = newMap()
  for other in file.items {
    match other.kind {
      case IImpl(d) -> {
        if implTargetIs(d, decl.name, ctx.pkg) {
          val iref = resolveNamed(d.iface.head.segments, ctx, st)
          val key = refKey(iref)
          implKeys.add(key)
          var listed = false
          for p in points {
            if p.key == key {
              listed = true
            }
          }
          val isPt = match iref.item { case Some(x) -> isPointItem(x); case None -> false }
          if isPt and not listed {
            k(
              st,
              "K0008",
              "plugin record " + decl.name + " implements the plugin point " + modulePathJoin(d.iface.head.segments) +
                ", which its @plugin(implements(...)) does not list",
              d.span
            )
          }
          val names: List[String] = newList()
          for m in d.members {
            match m {
              case IMplFunc(fn) -> names.add(fn.name)
              case _ -> ()
            }
          }
          pointMethodNames[key] = names
        }
      }
      case _ -> ()
    }
  }
  for p in points {
    if not implKeys.contains(p.key) {
      k(
        st,
        "K0008",
        "plugin record " + decl.name + " lists " + p.declName + " in implements(...) but has no `impl " + p.declName +
          " for " +
          decl.name +
          "`",
        p.span
      )
    }
  }
  // Methods each point reports: implemented ones plus inherited defaults.
  for p in points {
    val have = match mapGet(pointMethodNames, p.key) { case Some(l) -> l; case None -> newList() }
    match p.item {
      case Some(x) -> match x.kind {
        case IInterface(idecl) -> {
          val names: List[String] = newList()
          for m in idecl.members {
            match m {
              case IMSig(sig) -> {
                if have.contains(sig.name) {
                  names.add(sig.name)
                }
              }
              case IMFunc(fn) -> {
                val hb = match fn.body { case Some(_) -> true; case None -> false }
                if hb or have.contains(fn.name) {
                  names.add(fn.name)
                }
              }
              case IMAssoc(_) -> ()
            }
          }
          pointMethodNames[p.key] = names
        }
        case _ -> ()
      }
      case None -> ()
    }
  }
  // Capability fields.
  val caps: List[CapField] = newList()
  for f in recordFields(decl) {
    match f.dflt {
      case Some(_) -> ()
      case None -> {
        var optional = false
        var clientTe = f.ty
        match optionInner(f.ty) {
          case Some(inner) -> {
            optional = true
            clientTe = inner
          }
          case None -> ()
        }
        var accepted = false
        match clientCapName(clientTe) {
          case Some(capSegs) -> {
            val ref = resolveNamed(capSegs, ctx, st)
            if ref.found {
              val isCapIface = match ref.item { case Some(x) -> isAnnotatedIface(x, annCapability); case None -> false }
              if isCapIface {
                accepted = true
              }
            } else if not ref.collected and ref.pkg != "" and not isStdPkg(ref.pkg) {
              accepted = true
            }
            if accepted {
              caps.add(
                CapField(
                  fieldName = f.name,
                  fieldTy = f.ty,
                  optional = optional,
                  capName = ref.declName,
                  qualifier = qualifierIn(ref, ctx.pkg),
                  pkg = ref.pkg,
                  item = ref.item,
                  key = refKey(ref),
                  span = f.span
                )
              )
            }
          }
          case None -> ()
        }
        if not accepted {
          k(
            st,
            "K0010",
            "field '" + f.name + "' of plugin record " + decl.name +
              " has no default and is not a capability client (<Capability>Client or Option[<Capability>Client]); plugin state needs a default",
            f.span
          )
        }
      }
    }
  }
  // K0003: every requested capability must be allowed by an implemented point.
  var allKnown = true
  val allowed: List[String] = newList()
  for p in points {
    match p.item {
      case Some(x) -> {
        match ctxOf(p.pkg, ctx, st) {
          case Some(pc) -> {
            for an in pointAllowNames(x) {
              allowed.add(refKey(resolveNamed(splitDotted(an), pc, st)))
            }
          }
          case None -> {
            allKnown = false
          }
        }
      }
      case None -> {
        allKnown = false
      }
    }
  }
  if allKnown {
    for c in caps {
      if c.pkg != "" and not allowed.contains(c.key) {
        k(
          st,
          "K0003",
          "plugin record " + decl.name + " requests capability " + c.capName + " (field '" + c.fieldName +
            "'), which none of the points it implements allows",
          c.span
        )
      }
    }
  }
  // K0009: contributions and request functions.
  val contribFns: Map[String, String] = newMap()
  val contribTys: Map[String, BT] = newMap()
  val requestFns: Map[String, String] = newMap()
  val requestTys: Map[String, BT] = newMap()
  for other in file.items {
    match other.kind {
      case IFunc(fn) -> {
        val anns = allAnns(other)
        for fa in anns {
          val an = annName(fa)
          if an == annContributions or an == annRequest {
            match singleNameArg(fa, an, st) {
              case Some(target) -> {
                val ref = resolveNamed(splitDotted(target.name), ctx, st)
                val key = refKey(ref)
                val fnOk = checkProviderFn(fn, an, st)
                if an == annContributions {
                  var pt: Option[PointRef] = None
                  for p in points {
                    if p.key == key {
                      pt = Some(value = p)
                    }
                  }
                  match pt {
                    case None -> k(
                      st,
                      "K0009",
                      "@plugin_contributions(" + target.name + ") on " + fn.name + " names a point plugin record " +
                        decl.name +
                        " does not implement",
                      target.span
                    )
                    case Some(p) -> {
                      if contribFns.containsKey(key) {
                        k(
                          st,
                          "K0009",
                          "a second @plugin_contributions(" + target.name + ") function (" + fn.name + "); a point has exactly one",
                          fn.span
                        )
                      } else if fnOk {
                        match checkProviderType(fn, p.item, p.pkg, true, target.name, ctx, st) {
                          case Some(b) -> {
                            contribFns[key] = fn.name
                            contribTys[key] = b
                          }
                          case None -> ()
                        }
                      }
                    }
                  }
                } else {
                  var cf: Option[CapField] = None
                  for c in caps {
                    if c.key == key {
                      cf = Some(value = c)
                    }
                  }
                  match cf {
                    case None -> k(
                      st,
                      "K0009",
                      "@plugin_request(" + target.name + ") on " + fn.name + " names a capability plugin record " +
                        decl.name +
                        " does not request",
                      target.span
                    )
                    case Some(c) -> {
                      if requestFns.containsKey(key) {
                        k(
                          st,
                          "K0009",
                          "a second @plugin_request(" + target.name + ") function (" + fn.name + "); a capability has exactly one",
                          fn.span
                        )
                      } else if fnOk {
                        match checkProviderType(fn, c.item, c.pkg, false, target.name, ctx, st) {
                          case Some(b) -> {
                            requestFns[key] = fn.name
                            requestTys[key] = b
                          }
                          case None -> ()
                        }
                      }
                    }
                  }
                }
              }
              case None -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  for p in points {
    match p.item {
      case Some(x) -> match pointContributionsTe(x) {
        case Some(_) -> {
          if not contribFns.containsKey(p.key) {
            k(
              st,
              "K0009",
              "plugin point " + p.declName + " declares contributions, so plugin record " + decl.name +
                " needs one @plugin_contributions(" +
                p.declName +
                ") function",
              p.span
            )
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  for c in caps {
    match c.item {
      case Some(x) -> match capGrantTe(x) {
        case Some(_) -> {
          if not requestFns.containsKey(c.key) {
            k(
              st,
              "K0009",
              "capability " + c.capName + " declares a grant, so plugin record " + decl.name + " needs one @plugin_request(" +
                c.capName +
                ") function",
              c.span
            )
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  if st.diags.count > before {
    return None
  }
  Some(
    value = PluginModel(
      name = decl.name,
      id = id,
      version = version,
      publisher = publisher,
      points = points,
      caps = caps,
      contribFns = contribFns,
      contribTys = contribTys,
      requestFns = requestFns,
      requestTys = requestTys,
      pointMethodNames = pointMethodNames,
      line = it.span.startPos.line
    )
  )
}

func checkProviderFn(fn: in FunctionDecl, what: in String, st: in St): Bool {
  var ok = true
  if fn.params.count > 0 {
    k(st, "K0009", "@" + what + " function " + fn.name + " must take no parameters", fn.span)
    ok = false
  }
  match fn.generics {
    case Some(_) -> {
      k(st, "K0009", "@" + what + " function " + fn.name + " must not be generic", fn.span)
      ok = false
    }
    case None -> ()
  }
  match fn.ret {
    case None -> {
      k(st, "K0009", "@" + what + " function " + fn.name + " must declare its return type", fn.span)
      ok = false
    }
    case Some(_) -> ()
  }
  ok
}

/// The return type of a contributions/request function, checked against
/// the point's contributions type or the capability's grant type when that
/// declaration is at hand.
func checkProviderType(
  fn: in FunctionDecl,
  declItem: in Option[Item],
  declPkg: in String,
  isContrib: in Bool,
  target: in String,
  ctx: in Ctx,
  st: in St,
): Option[BT] {
  val ret = match fn.ret { case Some(r) -> r; case None -> return None }
  match declItem {
    case Some(x) -> {
      val expectTe = if isContrib { pointContributionsTe(x) } else { capGrantTe(x) }
      match expectTe {
        case None -> {
          if isContrib {
            k(
              st,
              "K0009",
              "@plugin_contributions(" + target + ") on " + fn.name + ": the point declares no contributions type",
              fn.span
            )
          } else {
            k(st, "K0009", "@plugin_request(" + target + ") on " + fn.name + ": the capability declares no grant type", fn.span)
          }
          return None
        }
        case Some(ete) -> match ctxOf(declPkg, ctx, st) {
          case Some(dc) -> {
            val want = namedKey(ete, dc, st)
            val have = namedKey(ret, ctx, st)
            if want != "" and want != have {
              val wanted = if isContrib { "contributions type" } else { "grant type" }
              k(
                st,
                "K0009",
                fn.name + " returns " + Fmt.typeStr(ret) + ", but the " + wanted + " of " + target + " is " + want,
                ret.span
              )
              return None
            }
          }
          case None -> ()
        }
      }
    }
    case None -> ()
  }
  val b = classify(ret, ctx, ctx.pkg, st, ret.span, "the result of " + fn.name, 0)
  if isBad(b) {
    None
  } else {
    Some(value = b)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Code generation: encoders and decoders.
// ─────────────────────────────────────────────────────────────────────────────
record Gen {
  pkg: String
  helperNames: List[String]
  helperTexts: List[String]
  flags: Map[String, Bool]
}

func newGen(pkg: in String): Gen {
  Gen(pkg = pkg, helperNames = newList(), helperTexts = newList(), flags = newMap())
}

func addHelper(g: in Gen, name: in String, text: in String): Unit {
  if not g.helperNames.contains(name) {
    g.helperNames.add(name)
    g.helperTexts.add(text)
  }
}

func hasHelper(g: in Gen, name: in String): Bool {
  g.helperNames.contains(name)
}

func joinLines(lines: in List[String]): String {
  var s = ""
  for l in lines {
    s = s + l + "\n"
  }
  s
}

func mangle(b: in BT): String {
  match b.kind {
    case BPrim(n) -> n
    case BJson -> "Json"
    case BOption(i) -> "Opt_L" + mangle(i) + "_R"
    case BResult(o, e) -> "Res_L" + mangle(o) + "_C" + mangle(e) + "_R"
    case BList(e, sl) -> if sl { "Slice_L" + mangle(e) + "_R" } else { "List_L" + mangle(e) + "_R" }
    case BBytes(sl) -> if sl { "ByteSlice" } else { "ByteList" }
    case BMap(v) -> "Map_L" + mangle(v) + "_R"
    case BTuple(es) -> {
      var s = "Tup_L"
      var i = 0
      for e in es {
        if i > 0 {
          s = s + "_C"
        }
        s = s + mangle(e)
        i = i + 1
      }
      s + "_R"
    }
    case BNamed(n, q, _) -> Str.replace(q, ".", "_") + n
    case BBad -> "Bad"
  }
}

/// An expression encoding the value `v` (a simple expression) of type `b`.
func encExpr(b: in BT, v: in String, g: in Gen): String {
  match b.kind {
    case BPrim(n) -> {
      if n == "Bool" {
        "JsonValue.JBool(value = " + v + ")"
      } else if n == "Byte" or n == "Int" {
        "JsonValue.JInt(value = " + v + ".toLong())"
      } else if n == "Long" {
        "JsonValue.JInt(value = " + v + ")"
      } else if n == "UInt" {
        needPrimHelpers(g)
        needUnsignedHelpers(g)
        "__pluginEncULong(" + v + ".toULong())"
      } else if n == "ULong" {
        needPrimHelpers(g)
        needUnsignedHelpers(g)
        "__pluginEncULong(" + v + ")"
      } else if n == "Float" {
        "JsonValue.JFloat(value = " + v + ".toDouble())"
      } else if n == "Double" {
        "JsonValue.JFloat(value = " + v + ")"
      } else if n == "Char" {
        "JsonValue.JString(value = " + v + ".toString())"
      } else if n == "String" {
        "JsonValue.JString(value = " + v + ")"
      } else {
        "JsonValue.JNull"
      }
    }
    case BJson -> v
    case BBytes(sl) -> {
      g.flags["bytes"] = true
      if sl {
        "JsonValue.JString(value = encodeBase64(" + v + "))"
      } else {
        "JsonValue.JString(value = encodeBase64(" + v + ".toArray()))"
      }
    }
    case BNamed(n, q, _) -> q + "pluginEncode" + n + "(" + v + ")"
    case BBad -> "JsonValue.JNull"
    case _ -> {
      val name = "__pluginEnc_" + mangle(b)
      if not hasHelper(g, name) {
        addHelper(g, name, "")
        val text = encHelperText(b, name, g)
        replaceHelper(g, name, text)
      }
      name + "(" + v + ")"
    }
  }
}

func replaceHelper(g: in Gen, name: in String, text: in String): Unit {
  var i = 0
  while i < g.helperNames.count {
    if g.helperNames[i] == name {
      g.helperTexts[i] = text
    }
    i = i + 1
  }
}

func encHelperText(b: in BT, name: in String, g: in Gen): String {
  val l: List[String] = newList()
  l.add("func " + name + "(v: in " + b.text + "): JsonValue {")
  match b.kind {
    case BOption(i) -> {
      l.add("  match v {")
      l.add("    case Some(x) -> " + encExpr(i, "x", g))
      l.add("    case None -> JsonValue.JNull")
      l.add("  }")
    }
    case BResult(o, e) -> {
      needPrimHelpers(g)
      l.add("  match v {")
      l.add("    case Ok(x) -> __pluginObj1(\"ok\", " + encExpr(o, "x", g) + ")")
      l.add("    case Err(x) -> __pluginObj1(\"err\", " + encExpr(e, "x", g) + ")")
      l.add("  }")
    }
    case BList(e, _) -> {
      l.add("  val items: List[JsonValue] = newList()")
      l.add("  for x in v {")
      l.add("    items.add(" + encExpr(e, "x", g) + ")")
      l.add("  }")
      l.add("  JsonValue.JArray(items = items)")
    }
    case BMap(vt) -> {
      l.add("  val fs: List[JsonField] = newList()")
      l.add("  for key in mapKeys(v) {")
      l.add("    val x = v[key]")
      l.add("    fs.add(JsonField(name = key, value = " + encExpr(vt, "x", g) + "))")
      l.add("  }")
      l.add("  JsonValue.JObject(fields = fs)")
    }
    case BTuple(es) -> {
      var pat = "("
      var i = 0
      for e0 in es {
        if i > 0 {
          pat = pat + ", "
        }
        pat = pat + "x" + i.toString()
        i = i + 1
      }
      l.add("  val " + pat + ") = v")
      l.add("  val items: List[JsonValue] = newList()")
      var j = 0
      for e in es {
        l.add("  items.add(" + encExpr(e, "x" + j.toString(), g) + ")")
        j = j + 1
      }
      l.add("  JsonValue.JArray(items = items)")
    }
    case _ -> l.add("  JsonValue.JNull")
  }
  l.add("}")
  joinLines(l)
}

/// An expression of type `Result[T, String]` decoding the JSON value `j`.
func decExpr(b: in BT, j: in String, g: in Gen): String {
  match b.kind {
    case BNamed(n, q, _) -> q + "pluginDecode" + n + "(" + j + ")"
    case BPrim(n) -> {
      needPrimHelpers(g)
      if n == "UInt" or n == "ULong" {
        needUnsignedHelpers(g)
      }
      "__pluginDec" + n + "(" + j + ")"
    }
    case BJson -> "Ok(value = " + j + ")"
    case BBytes(sl) -> {
      needPrimHelpers(g)
      g.flags["bytes"] = true
      val name = if sl { "__pluginDecByteSlice" } else { "__pluginDecByteList" }
      if not hasHelper(g, name) {
        val l: List[String] = newList()
        l.add("func " + name + "(j: in JsonValue): Result[" + b.text + ", String] {")
        l.add("  match j {")
        l.add("    case JsonValue.JString(s) -> match tryDecodeBase64(s) {")
        if sl {
          l.add("      case Some(bs) -> Ok(value = bs)")
        } else {
          l.add("      case Some(bs) -> Ok(value = bs.toList())")
        }
        l.add("      case None -> Err(error = \"expected base64-encoded bytes, got a string that is not base64\")")
        l.add("    }")
        l.add("    case _ -> Err(error = \"expected base64-encoded bytes, got \" + __pluginKind(j))")
        l.add("  }")
        l.add("}")
        addHelper(g, name, joinLines(l))
      }
      name + "(" + j + ")"
    }
    case BBad -> "Err(error = \"\")"
    case _ -> {
      val name = "__pluginDec_" + mangle(b)
      if not hasHelper(g, name) {
        addHelper(g, name, "")
        val text = decHelperText(b, name, g)
        replaceHelper(g, name, text)
      }
      name + "(" + j + ")"
    }
  }
}

func decHelperText(b: in BT, name: in String, g: in Gen): String {
  needPrimHelpers(g)
  val l: List[String] = newList()
  l.add("func " + name + "(j: in JsonValue): Result[" + b.text + ", String] {")
  match b.kind {
    case BOption(i) -> {
      l.add("  match j {")
      l.add("    case JsonValue.JNull -> {")
      l.add("      val none: " + b.text + " = None")
      l.add("      Ok(value = none)")
      l.add("    }")
      l.add("    case _ -> match " + decExpr(i, "j", g) + " {")
      l.add("      case Ok(x) -> Ok(value = Some(value = x))")
      l.add("      case Err(m) -> Err(error = m)")
      l.add("    }")
      l.add("  }")
    }
    case BResult(o, e) -> {
      l.add("  match __pluginMember(j, \"ok\") {")
      l.add("    case Some(okj) -> match " + decExpr(o, "okj", g) + " {")
      l.add("      case Ok(x) -> {")
      l.add("        val r: " + b.text + " = Ok(value = x)")
      l.add("        Ok(value = r)")
      l.add("      }")
      l.add("      case Err(m) -> Err(error = \"ok: \" + m)")
      l.add("    }")
      l.add("    case None -> match __pluginMember(j, \"err\") {")
      l.add("      case Some(errj) -> match " + decExpr(e, "errj", g) + " {")
      l.add("        case Ok(x) -> {")
      l.add("          val r: " + b.text + " = Err(error = x)")
      l.add("          Ok(value = r)")
      l.add("        }")
      l.add("        case Err(m) -> Err(error = \"err: \" + m)")
      l.add("      }")
      l.add("      case None -> Err(error = \"expected an object with an ok or err member, got \" + __pluginKind(j))")
      l.add("    }")
      l.add("  }")
    }
    case BList(e, sl) -> {
      l.add("  val items: List[JsonValue] = match j {")
      l.add("    case JsonValue.JArray(xs) -> xs")
      l.add("    case _ -> return Err(error = \"expected an array, got \" + __pluginKind(j))")
      l.add("  }")
      l.add("  val acc: List[" + e.text + "] = newList()")
      l.add("  var i = 0")
      l.add("  while i < items.count {")
      l.add("    match " + decExpr(e, "items[i]", g) + " {")
      l.add("      case Ok(x) -> acc.add(x)")
      l.add("      case Err(m) -> return Err(error = \"[\" + i.toString() + \"]: \" + m)")
      l.add("    }")
      l.add("    i = i + 1")
      l.add("  }")
      if sl {
        l.add("  Ok(value = acc.toArray())")
      } else {
        l.add("  Ok(value = acc)")
      }
    }
    case BMap(vt) -> {
      l.add("  val fs: List[JsonField] = match j {")
      l.add("    case JsonValue.JObject(xs) -> xs")
      l.add("    case _ -> return Err(error = \"expected an object, got \" + __pluginKind(j))")
      l.add("  }")
      l.add("  val acc: " + b.text + " = newMap()")
      l.add("  for f in fs {")
      l.add("    match " + decExpr(vt, "f.value", g) + " {")
      l.add("      case Ok(x) -> {")
      l.add("        acc[f.name] = x")
      l.add("      }")
      l.add("      case Err(m) -> return Err(error = \"[\" + __pluginQuote(f.name) + \"]: \" + m)")
      l.add("    }")
      l.add("  }")
      l.add("  Ok(value = acc)")
    }
    case BTuple(es) -> {
      l.add("  val items: List[JsonValue] = match j {")
      l.add("    case JsonValue.JArray(xs) -> xs")
      l.add("    case _ -> return Err(error = \"expected an array, got \" + __pluginKind(j))")
      l.add("  }")
      l.add("  if items.count != " + es.count.toString() + " {")
      l.add(
        "    return Err(error = \"expected an array of " + es.count.toString() +
          " elements, got \" + items.count.toString())"
      )
      l.add("  }")
      var i = 0
      var tup = "("
      for e in es {
        val xi = "x" + i.toString()
        l.add("  val " + xi + ": " + e.text + " = match " + decExpr(e, "items[" + i.toString() + "]", g) + " {")
        l.add("    case Ok(x) -> x")
        l.add("    case Err(m) -> return Err(error = \"[" + i.toString() + "]: \" + m)")
        l.add("  }")
        if i > 0 {
          tup = tup + ", "
        }
        tup = tup + xi
        i = i + 1
      }
      l.add("  Ok(value = " + tup + "))")
    }
    case _ -> l.add("  Err(error = \"unsupported\")")
  }
  l.add("}")
  joinLines(l)
}

func needPrimHelpers(g: in Gen): Unit {
  if hasHelper(g, "__pluginKind") {
    return ()
  }
  val l: List[String] = newList()
  l.add("func __pluginKind(j: in JsonValue): String {")
  l.add("  match j {")
  l.add("    case JsonValue.JNull -> \"null\"")
  l.add("    case JsonValue.JBool(_) -> \"a boolean\"")
  l.add("    case JsonValue.JInt(_) -> \"an integer\"")
  l.add("    case JsonValue.JFloat(_) -> \"a number\"")
  l.add("    case JsonValue.JString(_) -> \"a string\"")
  l.add("    case JsonValue.JArray(_) -> \"an array\"")
  l.add("    case JsonValue.JObject(_) -> \"an object\"")
  l.add("  }")
  l.add("}")
  addHelper(g, "__pluginKind", joinLines(l))
  val f: List[String] = newList()
  f.add("func __pluginField(fs: in List[JsonField], name: in String): Option[JsonValue] {")
  f.add("  var found: Option[JsonValue] = None")
  f.add("  for f in fs {")
  f.add("    if f.name == name {")
  f.add("      found = Some(value = f.value)")
  f.add("    }")
  f.add("  }")
  f.add("  found")
  f.add("}")
  f.add("")
  f.add("func __pluginMember(j: in JsonValue, name: in String): Option[JsonValue] {")
  f.add("  match j {")
  f.add("    case JsonValue.JObject(fs) -> __pluginField(fs, name)")
  f.add("    case _ -> None")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginObj1(name: in String, value: in JsonValue): JsonValue {")
  f.add("  val fs: List[JsonField] = newList()")
  f.add("  fs.add(JsonField(name = name, value = value))")
  f.add("  JsonValue.JObject(fields = fs)")
  f.add("}")
  f.add("")
  f.add("func __pluginQuote(s: in String): String {")
  f.add("  writeValue(JsonValue.JString(value = s))")
  f.add("}")
  f.add("")
  f.add("func __pluginDecBool(j: in JsonValue): Result[Bool, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JBool(b) -> Ok(value = b)")
  f.add("    case _ -> Err(error = \"expected a boolean, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecByte(j: in JsonValue): Result[Byte, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JInt(n) -> {")
  f.add("      if n < 0i64 or n > 255i64 {")
  f.add("        Err(error = \"the integer \" + n.toString() + \" is out of range for Byte\")")
  f.add("      } else {")
  f.add("        Ok(value = n.toByte())")
  f.add("      }")
  f.add("    }")
  f.add("    case _ -> Err(error = \"expected an integer, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecInt(j: in JsonValue): Result[Int, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JInt(n) -> {")
  f.add("      if n < -2147483648i64 or n > 2147483647i64 {")
  f.add("        Err(error = \"the integer \" + n.toString() + \" is out of range for Int\")")
  f.add("      } else {")
  f.add("        Ok(value = n.toInt())")
  f.add("      }")
  f.add("    }")
  f.add("    case _ -> Err(error = \"expected an integer, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecLong(j: in JsonValue): Result[Long, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JInt(n) -> Ok(value = n)")
  f.add("    case _ -> Err(error = \"expected an integer, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecFloat(j: in JsonValue): Result[Float, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JFloat(d) -> Ok(value = d.toFloat())")
  f.add("    case JsonValue.JInt(n) -> Ok(value = n.toDouble().toFloat())")
  f.add("    case _ -> Err(error = \"expected a number, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecDouble(j: in JsonValue): Result[Double, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JFloat(d) -> Ok(value = d)")
  f.add("    case JsonValue.JInt(n) -> Ok(value = n.toDouble())")
  f.add("    case _ -> Err(error = \"expected a number, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecChar(j: in JsonValue): Result[Char, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JString(s) -> {")
  f.add("      if s.length == 1 {")
  f.add("        Ok(value = s[0])")
  f.add("      } else {")
  f.add("        Err(error = \"expected a one-character string, got a string of length \" + s.length.toString())")
  f.add("      }")
  f.add("    }")
  f.add("    case _ -> Err(error = \"expected a one-character string, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecString(j: in JsonValue): Result[String, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JString(s) -> Ok(value = s)")
  f.add("    case _ -> Err(error = \"expected a string, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecUnit(j: in JsonValue): Result[Unit, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JNull -> Ok(value = ())")
  f.add("    case _ -> Err(error = \"expected null, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  addHelper(g, "__pluginPrims", joinLines(f))
}

func needUnsignedHelpers(g: in Gen): Unit {
  if hasHelper(g, "__pluginUnsigned") {
    return ()
  }
  val f: List[String] = newList()
  f.add("func __pluginLongToULong(n: in Long): ULong {")
  f.add("  var u = 0u64")
  f.add("  var shift = 56")
  f.add("  while shift >= 0 {")
  f.add("    u = u * 256u64 + n.shr(shift).and(255i64).toByte().toULong()")
  f.add("    shift = shift - 8")
  f.add("  }")
  f.add("  u")
  f.add("}")
  f.add("")
  f.add("func __pluginLongToUInt(n: in Long): UInt {")
  f.add("  var u = 0u32")
  f.add("  var shift = 24")
  f.add("  while shift >= 0 {")
  f.add("    u = u * 256u32 + n.shr(shift).and(255i64).toByte().toUInt()")
  f.add("    shift = shift - 8")
  f.add("  }")
  f.add("  u")
  f.add("}")
  f.add("")
  f.add("func __pluginDecUInt(j: in JsonValue): Result[UInt, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JInt(n) -> {")
  f.add("      if n < 0i64 or n > 4294967295i64 {")
  f.add("        Err(error = \"the integer \" + n.toString() + \" is out of range for UInt\")")
  f.add("      } else {")
  f.add("        Ok(value = __pluginLongToUInt(n))")
  f.add("      }")
  f.add("    }")
  f.add("    case _ -> Err(error = \"expected an integer, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginDecULong(j: in JsonValue): Result[ULong, String] {")
  f.add("  match j {")
  f.add("    case JsonValue.JInt(n) -> {")
  f.add("      if n < 0i64 {")
  f.add("        Err(error = \"the integer \" + n.toString() + \" is out of range for ULong\")")
  f.add("      } else {")
  f.add("        Ok(value = __pluginLongToULong(n))")
  f.add("      }")
  f.add("    }")
  f.add("    case JsonValue.JFloat(d) -> {")
  f.add("      val rest = d - 9223372036854775808.0")
  f.add("      if rest >= 0.0 and rest < 9223372036854775808.0 and rest == rest.toLong().toDouble() {")
  f.add("        Ok(value = 9223372036854775808u64 + __pluginLongToULong(rest.toLong()))")
  f.add("      } else {")
  f.add("        Err(error = \"the number is not a ULong\")")
  f.add("      }")
  f.add("    }")
  f.add("    case _ -> Err(error = \"expected an integer, got \" + __pluginKind(j))")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginEncULong(u: in ULong): JsonValue {")
  f.add("  val s = u.toString()")
  f.add("  if u <= 9223372036854775807u64 {")
  f.add("    var n = 0i64")
  f.add("    var i = 0")
  f.add("    while i < s.length {")
  f.add("      n = n * 10i64 + (s[i].toInt() - 48).toLong()")
  f.add("      i = i + 1")
  f.add("    }")
  f.add("    JsonValue.JInt(value = n)")
  f.add("  } else {")
  f.add("    var d = 0.0")
  f.add("    var i = 0")
  f.add("    while i < s.length {")
  f.add("      d = d * 10.0 + (s[i].toInt() - 48).toDouble()")
  f.add("      i = i + 1")
  f.add("    }")
  f.add("    JsonValue.JFloat(value = d)")
  f.add("  }")
  f.add("}")
  addHelper(g, "__pluginUnsigned", joinLines(f))
}

// Decode a member of an object into a local, returning `errExpr(msg)` from
// the enclosing function on failure.  `optional` makes a missing member
// `None` (an `Option` field or parameter).
func decodeMemberLines(
  l: in List[String],
  indent: in String,
  local: in String,
  b: in BT,
  fieldsExpr: in String,
  member: in String,
  ctxText: in String,
  errWrap: in String,
  g: in Gen,
): Unit {
  val optional = match b.kind { case BOption(_) -> true; case _ -> false }
  l.add(indent + "val " + local + ": " + b.text + " = match __pluginField(" + fieldsExpr + ", " + lit(member) + ") {")
  l.add(indent + "  case Some(fj) -> match " + decExpr(b, "fj", g) + " {")
  l.add(indent + "    case Ok(x) -> x")
  l.add(indent + "    case Err(m) -> return " + Str.replace(errWrap, "MSG", lit(ctxText + ": ") + " + m"))
  l.add(indent + "  }")
  if optional {
    l.add(indent + "  case None -> None")
  } else {
    l.add(indent + "  case None -> return " + Str.replace(errWrap, "MSG", lit(ctxText + ": the member is missing")))
  }
  l.add(indent + "}")
}

func recordCodecText(name: in String, fields: in List[FieldDecl], bts: in List[BT], g: in Gen): String {
  needPrimHelpers(g)
  val l: List[String] = newList()
  l.add("pub func pluginEncode" + name + "(v: in " + name + "): JsonValue {")
  l.add("  val fs: List[JsonField] = newList()")
  var i = 0
  while i < fields.count {
    l.add(
      "  fs.add(JsonField(name = " + lit(fields[i].name) + ", value = " + encExpr(bts[i], "v." + fields[i].name, g) + "))"
    )
    i = i + 1
  }
  l.add("  JsonValue.JObject(fields = fs)")
  l.add("}")
  l.add("")
  l.add("pub func pluginDecode" + name + "(j: in JsonValue): Result[" + name + ", String] {")
  l.add("  val fs: List[JsonField] = match j {")
  l.add("    case JsonValue.JObject(xs) -> xs")
  l.add("    case _ -> return Err(error = " + lit(name + ": expected an object, got ") + " + __pluginKind(j))")
  l.add("  }")
  var args = ""
  var k2 = 0
  while k2 < fields.count {
    val fname = fields[k2].name
    decodeMemberLines(l, "  ", "__f_" + fname, bts[k2], "fs", fname, name + "." + fname, "Err(error = MSG)", g)
    if k2 > 0 {
      args = args + ", "
    }
    args = args + fname + " = __f_" + fname
    k2 = k2 + 1
  }
  l.add("  Ok(value = " + name + "(" + args + "))")
  l.add("}")
  joinLines(l)
}

func unionCodecText(name: in String, cases: in List[UnionCase], bts: in List[List[BT]], g: in Gen): String {
  needPrimHelpers(g)
  val l: List[String] = newList()
  l.add("pub func pluginEncode" + name + "(v: in " + name + "): JsonValue {")
  l.add("  match v {")
  var ci = 0
  for c in cases {
    val fnames: List[String] = newList()
    for f in c.fields {
      match f {
        case UFNamed(n, _, _) -> fnames.add(n)
        case UFPos(_, _) -> ()
      }
    }
    var pat = name + "." + c.name
    if fnames.count > 0 {
      pat = pat + "("
      var i = 0
      for n in fnames {
        if i > 0 {
          pat = pat + ", "
        }
        pat = pat + "__c_" + n
        i = i + 1
      }
      pat = pat + ")"
    }
    l.add("    case " + pat + " -> {")
    l.add("      val fs: List[JsonField] = newList()")
    l.add("      fs.add(JsonField(name = \"case\", value = JsonValue.JString(value = " + lit(c.name) + ")))")
    var i2 = 0
    for n in fnames {
      l.add("      fs.add(JsonField(name = " + lit(n) + ", value = " + encExpr(bts[ci][i2], "__c_" + n, g) + "))")
      i2 = i2 + 1
    }
    l.add("      JsonValue.JObject(fields = fs)")
    l.add("    }")
    ci = ci + 1
  }
  l.add("  }")
  l.add("}")
  l.add("")
  l.add("pub func pluginDecode" + name + "(j: in JsonValue): Result[" + name + ", String] {")
  l.add("  val fs: List[JsonField] = match j {")
  l.add("    case JsonValue.JObject(xs) -> xs")
  l.add("    case _ -> return Err(error = " + lit(name + ": expected an object, got ") + " + __pluginKind(j))")
  l.add("  }")
  l.add("  val tag: String = match __pluginField(fs, \"case\") {")
  l.add("    case Some(JsonValue.JString(s)) -> s")
  l.add("    case Some(_) -> return Err(error = " + lit(name + ": the case member must be a string") + ")")
  l.add("    case None -> return Err(error = " + lit(name + ": the case member is missing") + ")")
  l.add("  }")
  var cj = 0
  for c in cases {
    l.add("  if tag == " + lit(c.name) + " {")
    var args = ""
    var i3 = 0
    for f in c.fields {
      match f {
        case UFNamed(n, _, _) -> {
          decodeMemberLines(l, "    ", "__f_" + n, bts[cj][i3], "fs", n, name + "." + c.name + "." + n, "Err(error = MSG)", g)
          if i3 > 0 {
            args = args + ", "
          }
          args = args + n + " = __f_" + n
          i3 = i3 + 1
        }
        case UFPos(_, _) -> ()
      }
    }
    if c.fields.count > 0 {
      l.add("    return Ok(value = " + name + "." + c.name + "(" + args + "))")
    } else {
      l.add("    return Ok(value = " + name + "." + c.name + ")")
    }
    l.add("  }")
    cj = cj + 1
  }
  l.add("  Err(error = " + lit(name + ": unknown case ") + " + __pluginQuote(tag))")
  l.add("}")
  joinLines(l)
}

func enumCodecText(name: in String, cases: in List[EnumCase], g: in Gen): String {
  needPrimHelpers(g)
  val l: List[String] = newList()
  l.add("pub func pluginEncode" + name + "(v: in " + name + "): JsonValue {")
  l.add("  match v {")
  for c in cases {
    l.add("    case " + name + "." + c.name + " -> JsonValue.JString(value = " + lit(c.name) + ")")
  }
  l.add("  }")
  l.add("}")
  l.add("")
  l.add("pub func pluginDecode" + name + "(j: in JsonValue): Result[" + name + ", String] {")
  l.add("  val s: String = match j {")
  l.add("    case JsonValue.JString(x) -> x")
  l.add("    case _ -> return Err(error = " + lit(name + ": expected a string, got ") + " + __pluginKind(j))")
  l.add("  }")
  for c in cases {
    l.add("  if s == " + lit(c.name) + " {")
    l.add("    return Ok(value = " + name + "." + c.name + ")")
    l.add("  }")
  }
  l.add("  Err(error = " + lit(name + ": unknown case ") + " + __pluginQuote(s))")
  l.add("}")
  joinLines(l)
}

func handleCodecText(name: in String, g: in Gen): String {
  needPrimHelpers(g)
  val l: List[String] = newList()
  l.add("pub func pluginEncode" + name + "(v: in " + name + "): JsonValue {")
  l.add("  JsonValue.JInt(value = v.value)")
  l.add("}")
  l.add("")
  l.add("pub func pluginDecode" + name + "(j: in JsonValue): Result[" + name + ", String] {")
  l.add("  match j {")
  l.add("    case JsonValue.JInt(n) -> Ok(value = " + name + ".from(n))")
  l.add("    case _ -> Err(error = " + lit(name + ": expected an integer handle, got ") + " + __pluginKind(j))")
  l.add("  }")
  l.add("}")
  joinLines(l)
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Code generation: capabilities, points and plugins.
// ─────────────────────────────────────────────────────────────────────────────
func rpcHelpers(g: in Gen): Unit {
  if hasHelper(g, "__pluginRpc") {
    return ()
  }
  needPrimHelpers(g)
  val f: List[String] = newList()
  f.add("func __pluginRpcError(code: in Int, message: in String): RpcError {")
  f.add("  RpcError(code = code, message = message, data = None)")
  f.add("}")
  f.add("")
  f.add("func __pluginMethodName(m: in String): String {")
  f.add("  val i = m.lastIndexOf(\"/\")")
  f.add("  if i < 0 {")
  f.add("    m")
  f.add("  } else {")
  f.add("    m.substring(i + 1)")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginPointOf(m: in String): String {")
  f.add("  val i = m.lastIndexOf(\"/\")")
  f.add("  if i < 0 {")
  f.add("    \"\"")
  f.add("  } else {")
  f.add("    m.substring(0, i)")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginParams(params: in Option[JsonValue]): JsonValue {")
  f.add("  match params {")
  f.add("    case Some(p) -> p")
  f.add("    case None -> JsonValue.JObject(fields = newList())")
  f.add("  }")
  f.add("}")
  f.add("")
  f.add("func __pluginParamFields(p: in JsonValue): Option[List[JsonField]] {")
  f.add("  match p {")
  f.add("    case JsonValue.JObject(fs) -> Some(value = fs)")
  f.add("    case _ -> None")
  f.add("  }")
  f.add("}")
  addHelper(g, "__pluginRpc", joinLines(f))
}

func callErrorText(errTy: in BT): String {
  "CallError[" + errTy.text + "]"
}

/// `Result[JsonValue, BoundaryError]` from `callHost`/`callPlugin` split
/// into `Result[T, CallError[E]]`.
func callResultHelper(m: in MethodModel, g: in Gen): String {
  needPrimHelpers(g)
  val name = "__pluginCallResult_" + mangle(m.okTy) + "__" + mangle(m.errTy)
  if hasHelper(g, name) {
    return name
  }
  addHelper(g, name, "")
  val rt = "Result[" + m.okTy.text + ", " + callErrorText(m.errTy) + "]"
  val l: List[String] = newList()
  l.add("func " + name + "(r: in Result[JsonValue, BoundaryError]): " + rt + " {")
  l.add("  val j: JsonValue = match r {")
  l.add("    case Ok(x) -> x")
  l.add("    case Err(e) -> return Err(error = CallError.Boundary(error = e))")
  l.add("  }")
  l.add("  match __pluginMember(j, \"ok\") {")
  l.add("    case Some(okj) -> match " + decExpr(m.okTy, "okj", g) + " {")
  l.add("      case Ok(x) -> Ok(value = x)")
  l.add(
    "      case Err(msg) -> Err(error = CallError.Boundary(error = BoundaryError.Protocol(detail = \"result.ok: \" + msg)))"
  )
  l.add("    }")
  l.add("    case None -> match __pluginMember(j, \"err\") {")
  l.add("      case Some(errj) -> match " + decExpr(m.errTy, "errj", g) + " {")
  l.add("        case Ok(x) -> Err(error = CallError.App(error = x))")
  l.add(
    "        case Err(msg) -> Err(error = CallError.Boundary(error = BoundaryError.Protocol(detail = \"result.err: \" + msg)))"
  )
  l.add("      }")
  l.add(
    "      case None -> Err(error = CallError.Boundary(error = BoundaryError.Protocol(detail = \"the result has neither an ok nor an err member\")))"
  )
  l.add("    }")
  l.add("  }")
  l.add("}")
  replaceHelper(g, name, joinLines(l))
  name
}

func paramListText(m: in MethodModel): String {
  var s = ""
  var i = 0
  for p in m.params {
    s = s + ", " + p.name + ": in " + m.paramTys[i].text
    i = i + 1
  }
  s
}

/// A stub method (`<C>Client` or `<P>Remote`) calling `callFn`.
func stubMethodText(recName: in String, m: in MethodModel, callFn: in String, methodId: in String, g: in Gen): String {
  val helper = callResultHelper(m, g)
  val l: List[String] = newList()
  l.add(
    "pub func " + recName + "." + m.name + "(__stub: in " + recName + paramListText(m) + "): Result[" + m.okTy.text +
      ", " +
      callErrorText(m.errTy) +
      "] {"
  )
  l.add("  val __ps: List[JsonField] = newList()")
  var i = 0
  for p in m.params {
    l.add("  __ps.add(JsonField(name = " + lit(p.name) + ", value = " + encExpr(m.paramTys[i], p.name, g) + "))")
    i = i + 1
  }
  l.add("  " + helper + "(" + callFn + "(__stub.conn, " + lit(methodId) + ", JsonValue.JObject(fields = __ps)))")
  l.add("}")
  joinLines(l)
}

/// Decode the params, check the guards, call the method on `__target` and
/// encode `{"ok"}`/`{"err"}`.
func invokeHelperText(
  name: in String,
  ifaceName: in String,
  id: in String,
  m: in MethodModel,
  grant: in Option[BT],
  g: in Gen,
): String {
  rpcHelpers(g)
  val mid = id + "/" + m.name
  val l: List[String] = newList()
  var sig = "func " + name + "(__target: in " + ifaceName + ", __params: in Option[JsonValue]"
  match grant {
    case Some(_) -> {
      sig = sig + ", __grant: in Option[JsonValue]"
    }
    case None -> ()
  }
  l.add(sig + "): Result[JsonValue, RpcError] {")
  l.add("  val __fs: List[JsonField] = match __pluginParamFields(__pluginParams(__params)) {")
  l.add("    case Some(fs) -> fs")
  l.add(
    "    case None -> return Err(error = __pluginRpcError(-32046, " + lit(mid + ": params must be an object") + "))"
  )
  l.add("  }")
  match grant {
    case Some(gb) -> {
      l.add("  val grant: " + gb.text + " = match __grant {")
      l.add("    case Some(gj) -> match " + decExpr(gb, "gj", g) + " {")
      l.add("      case Ok(x) -> x")
      l.add(
        "      case Err(msg) -> return Err(error = __pluginRpcError(-32046, " + lit(id + ": malformed grant: ") + " + msg))"
      )
      l.add("    }")
      l.add("    case None -> return Err(error = __pluginRpcError(-32040, " + lit(id + " is not granted") + "))")
      l.add("  }")
    }
    case None -> ()
  }
  var i = 0
  var args = ""
  for p in m.params {
    decodeMemberLines(
      l,
      "  ",
      p.name,
      m.paramTys[i],
      "__fs",
      p.name,
      mid + ": parameter " + p.name,
      "Err(error = __pluginRpcError(-32046, MSG))",
      g
    )
    if i > 0 {
      args = args + ", "
    }
    args = args + p.name
    i = i + 1
  }
  for c in m.guards {
    match c {
      case CCRequires(ex, _) -> {
        val text = Fmt.exprInline(0, ex)
        l.add("  if not (" + text + ") {")
        l.add("    return Err(error = __pluginRpcError(-32040, " + lit(mid + ": denied by requires: " + text) + "))")
        l.add("  }")
      }
      case _ -> ()
    }
  }
  l.add("  match __target." + m.name + "(" + args + ") {")
  l.add("    case Ok(x) -> Ok(value = __pluginObj1(\"ok\", " + encExpr(m.okTy, "x", g) + "))")
  l.add("    case Err(x) -> Ok(value = __pluginObj1(\"err\", " + encExpr(m.errTy, "x", g) + "))")
  l.add("  }")
  l.add("}")
  joinLines(l)
}

func capabilityText(c: in IfaceModel, pkg: in String, g: in Gen): String {
  rpcHelpers(g)
  val id = pkg + "." + c.name
  val cl = lowerFirst(c.name)
  val l: List[String] = newList()
  // Plugin side.
  l.add("pub record " + c.name + "Client {")
  l.add("  conn: PluginConnection")
  l.add("}")
  l.add("")
  for m in c.methods {
    l.add(stubMethodText(c.name + "Client", m, "callHost", "cap/" + id + "/" + m.name, g))
  }
  // Host side.
  l.add("pub func " + cl + "CapabilityInfo(): CapabilityInfo {")
  val hasGrant = match c.grant { case Some(_) -> "true"; case None -> "false" }
  l.add("  CapabilityInfo(id = " + lit(id) + ", hasGrant = " + hasGrant + ")")
  l.add("}")
  l.add("")
  l.add("pub record " + c.name + "Server {")
  l.add("  target: " + c.name)
  l.add("}")
  l.add("")
  l.add("impl CapabilityProvider for " + c.name + "Server {")
  l.add("  func info(): CapabilityInfo {")
  l.add("    " + cl + "CapabilityInfo()")
  l.add("  }")
  l.add("")
  l.add(
    "  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {"
  )
  l.add("    val name = __pluginMethodName(method)")
  for m in c.methods {
    val hname = "__pluginServe_" + c.name + "_" + m.name
    l.add("    if name == " + lit(m.name) + " {")
    match c.grant {
      case Some(_) -> l.add("      return " + hname + "(self.target, params, grant)")
      case None -> l.add("      return " + hname + "(self.target, params)")
    }
    l.add("    }")
  }
  l.add("    Err(error = __pluginRpcError(-32043, " + lit(id + " has no method ") + " + __pluginQuote(name)))")
  l.add("  }")
  l.add("}")
  l.add("")
  for m in c.methods {
    l.add(invokeHelperText("__pluginServe_" + c.name + "_" + m.name, c.name, "cap/" + id, m, c.grant, g))
  }
  l.add("pub func " + cl + "Provider(target: in " + c.name + "): CapabilityProvider {")
  l.add("  " + c.name + "Server(target = target)")
  l.add("}")
  joinLines(l)
}

func allowsLines(p: in IfaceModel, ctx: in Ctx, st: in St): List[String] {
  val l: List[String] = newList()
  l.add("  val allows: List[String] = newList()")
  for al in p.allows {
    val ref = resolveNamed(splitDotted(al.name), ctx, st)
    val q = qualifierIn(ref, ctx.pkg)
    l.add("  allows.add(" + q + lowerFirst(ref.declName) + "CapabilityInfo().id)")
  }
  l
}

func pointText(p: in IfaceModel, pkg: in String, ctx: in Ctx, st: in St, g: in Gen): String {
  rpcHelpers(g)
  val id = pkg + "." + p.name
  val pl = lowerFirst(p.name)
  val l: List[String] = newList()
  l.add("pub func " + pl + "PointInfo(): PluginPointInfo {")
  for x in allowsLines(p, ctx, st) {
    l.add(x)
  }
  val proto = if p.hasProtocol { "Some(value = " + lit(p.protocol) + ")" } else { "None" }
  val hasC = match p.contributions { case Some(_) -> "true"; case None -> "false" }
  l.add(
    "  PluginPointInfo(id = " + lit(id) + ", version = " + lit(p.version) + ", allows = allows, hasContributions = " +
      hasC +
      ", protocol = " +
      proto +
      ")"
  )
  l.add("}")
  l.add("")
  match p.contributions {
    case Some(cb) -> {
      l.add("pub record " + p.name + "Contribution {")
      l.add("  pluginId: String")
      l.add("  value: " + cb.text)
      l.add("}")
      l.add("")
      l.add("pub func " + pl + "Contributions(host: in PluginHost): List[" + p.name + "Contribution] {")
      l.add("  val acc: List[" + p.name + "Contribution] = newList()")
      l.add("  for c in contributionsFor(host, " + lit(id) + ") {")
      l.add("    match " + decExpr(cb, "c.value", g) + " {")
      l.add("      case Ok(x) -> acc.add(" + p.name + "Contribution(pluginId = c.pluginId, value = x))")
      l.add("      case Err(_) -> ()")
      l.add("    }")
      l.add("  }")
      l.add("  acc")
      l.add("}")
      l.add("")
    }
    case None -> ()
  }
  if p.kind == "protocol" {
    return joinLines(l)
  }
  // Host side.
  l.add("pub record " + p.name + "Remote {")
  l.add("  conn: PluginConnection")
  l.add("}")
  l.add("")
  for m in p.methods {
    l.add(stubMethodText(p.name + "Remote", m, "callPlugin", id + "/" + m.name, g))
  }
  l.add("pub func " + pl + "Remotes(host: in PluginHost): List[" + p.name + "Remote] {")
  l.add("  val acc: List[" + p.name + "Remote] = newList()")
  l.add("  for c in connectionsFor(host, " + lit(id) + ") {")
  l.add("    acc.add(" + p.name + "Remote(conn = c))")
  l.add("  }")
  l.add("  acc")
  l.add("}")
  l.add("")
  // Plugin side.
  l.add(
    "pub func pluginDispatch" + p.name + "(target: in " + p.name +
      ", method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {"
  )
  l.add("  val name = __pluginMethodName(method)")
  for m in p.methods {
    l.add("  if name == " + lit(m.name) + " {")
    l.add("    return __pluginInvoke_" + p.name + "_" + m.name + "(target, params)")
    l.add("  }")
  }
  l.add("  Err(error = __pluginRpcError(-32043, " + lit(id + " has no method ") + " + __pluginQuote(name)))")
  l.add("}")
  l.add("")
  val noGrant: Option[BT] = None
  for m in p.methods {
    l.add(invokeHelperText("__pluginInvoke_" + p.name + "_" + m.name, p.name, id, m, noGrant, g))
  }
  joinLines(l)
}

func pluginText(pm: in PluginModel, g: in Gen): String {
  rpcHelpers(g)
  val srv = pm.name + "Server"
  val l: List[String] = newList()
  l.add("record " + srv + " {")
  l.add("  var held: Option[" + pm.name + "] = None")
  l.add("}")
  l.add("")
  l.add("impl PluginServer for " + srv + " {")
  // describe
  l.add("  func describe(): JsonValue {")
  l.add("    val points: List[JsonValue] = newList()")
  var i = 0
  for p in pm.points {
    val info = "__pi" + i.toString()
    l.add("    val " + info + " = " + p.qualifier + lowerFirst(p.declName) + "PointInfo()")
    l.add("    val __pf" + i.toString() + ": List[JsonField] = newList()")
    l.add(
      "    __pf" + i.toString() + ".add(JsonField(name = \"point\", value = JsonValue.JString(value = " + info + ".id)))"
    )
    l.add(
      "    __pf" + i.toString() + ".add(JsonField(name = \"version\", value = JsonValue.JString(value = " + info +
        ".version)))"
    )
    val contrib = match mapGet(pm.contribFns, p.key) {
      case Some(fnName) -> match mapGet(pm.contribTys, p.key) {
        case Some(b) -> encExpr(b, fnName + "()", g)
        case None -> "JsonValue.JNull"
      }
      case None -> "JsonValue.JNull"
    }
    l.add("    __pf" + i.toString() + ".add(JsonField(name = \"contributions\", value = " + contrib + "))")
    l.add("    points.add(JsonValue.JObject(fields = __pf" + i.toString() + "))")
    i = i + 1
  }
  l.add("    val required: List[JsonValue] = newList()")
  l.add("    val optional: List[JsonValue] = newList()")
  var ci = 0
  for c in pm.caps {
    val cf = "__cf" + ci.toString()
    l.add("    val " + cf + ": List[JsonField] = newList()")
    l.add(
      "    " + cf + ".add(JsonField(name = \"name\", value = JsonValue.JString(value = " + c.qualifier +
        lowerFirst(c.capName) +
        "CapabilityInfo().id)))"
    )
    val grantExpr = match mapGet(pm.requestFns, c.key) {
      case Some(fnName) -> match mapGet(pm.requestTys, c.key) {
        case Some(b) -> encExpr(b, fnName + "()", g)
        case None -> "JsonValue.JNull"
      }
      case None -> "JsonValue.JNull"
    }
    l.add("    " + cf + ".add(JsonField(name = \"grant\", value = " + grantExpr + "))")
    if c.optional {
      l.add("    optional.add(JsonValue.JObject(fields = " + cf + "))")
    } else {
      l.add("    required.add(JsonValue.JObject(fields = " + cf + "))")
    }
    ci = ci + 1
  }
  l.add("    val caps: List[JsonField] = newList()")
  l.add("    caps.add(JsonField(name = \"required\", value = JsonValue.JArray(items = required)))")
  l.add("    caps.add(JsonField(name = \"optional\", value = JsonValue.JArray(items = optional)))")
  l.add("    val top: List[JsonField] = newList()")
  l.add("    top.add(JsonField(name = \"schema\", value = JsonValue.JInt(value = 1i64)))")
  l.add("    top.add(JsonField(name = \"id\", value = JsonValue.JString(value = " + lit(pm.id) + ")))")
  l.add("    top.add(JsonField(name = \"version\", value = JsonValue.JString(value = " + lit(pm.version) + ")))")
  l.add("    top.add(JsonField(name = \"publisher\", value = JsonValue.JString(value = " + lit(pm.publisher) + ")))")
  l.add("    top.add(JsonField(name = \"points\", value = JsonValue.JArray(items = points)))")
  l.add("    top.add(JsonField(name = \"capabilities\", value = JsonValue.JObject(fields = caps)))")
  l.add("    JsonValue.JObject(fields = top)")
  l.add("  }")
  l.add("")
  // attach (D207's `bind`: `bind` is a reserved keyword)
  l.add("  func attach(conn: in PluginConnection, grants: in List[GrantedCapability]): Result[Unit, BoundaryError] {")
  var args = ""
  var ai = 0
  for c in pm.caps {
    val idv = "__cap" + ai.toString()
    l.add("    val " + idv + " = " + c.qualifier + lowerFirst(c.capName) + "CapabilityInfo().id")
    l.add("    var " + idv + "Granted = false")
    l.add("    for g in grants {")
    l.add("      if g.capability == " + idv + " {")
    l.add("        " + idv + "Granted = true")
    l.add("      }")
    l.add("    }")
    val client = c.qualifier + c.capName + "Client(conn = conn)"
    if c.optional {
      l.add("    val __f" + ai.toString() + ": " + Fmt.typeStr(c.fieldTy) + " = if " + idv + "Granted {")
      l.add("      Some(value = " + client + ")")
      l.add("    } else {")
      l.add("      None")
      l.add("    }")
    } else {
      l.add("    if not " + idv + "Granted {")
      l.add("      return Err(error = BoundaryError.NotGranted(capability = " + idv + "))")
      l.add("    }")
      l.add("    val __f" + ai.toString() + ": " + Fmt.typeStr(c.fieldTy) + " = " + client)
    }
    if ai > 0 {
      args = args + ", "
    }
    args = args + c.fieldName + " = __f" + ai.toString()
    ai = ai + 1
  }
  l.add("    self.held = Some(value = " + pm.name + "(" + args + "))")
  l.add("    Ok(value = ())")
  l.add("  }")
  l.add("")
  // pointMethods
  l.add("  func pointMethods(): List[PluginPointMethods] {")
  l.add("    val acc: List[PluginPointMethods] = newList()")
  var pi = 0
  for p in pm.points {
    val info = "__mi" + pi.toString()
    val ms = "__ms" + pi.toString()
    l.add("    val " + info + " = " + p.qualifier + lowerFirst(p.declName) + "PointInfo()")
    l.add("    val " + ms + ": List[String] = newList()")
    match mapGet(pm.pointMethodNames, p.key) {
      case Some(names) -> {
        for n in names {
          l.add("    " + ms + ".add(" + lit(n) + ")")
        }
      }
      case None -> ()
    }
    l.add(
      "    acc.add(PluginPointMethods(point = " + info + ".id, version = " + info + ".version, methods = " + ms + "))"
    )
    pi = pi + 1
  }
  l.add("    acc")
  l.add("  }")
  l.add("")
  // dispatch
  l.add("  func dispatch(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {")
  l.add("    val bound: " + pm.name + " = match self.held {")
  l.add("      case Some(p) -> p")
  l.add("      case None -> return Err(error = __pluginRpcError(-32046, \"plugin/hello has not completed\"))")
  l.add("    }")
  l.add("    val point = __pluginPointOf(method)")
  for p in pm.points {
    val isProto = match p.item { case Some(x) -> isAnnotatedIface(x, annProtocol); case None -> false }
    if not isProto {
      l.add("    if point == " + p.qualifier + lowerFirst(p.declName) + "PointInfo().id {")
      l.add("      return " + p.qualifier + "pluginDispatch" + p.declName + "(bound, method, params)")
      l.add("    }")
    }
  }
  l.add("    Err(error = __pluginRpcError(-32601, \"no such method: \" + method))")
  l.add("  }")
  l.add("}")
  l.add("")
  l.add("func main(): Int = runPlugin(" + srv + "())")
  joinLines(l)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. The pass.
// ─────────────────────────────────────────────────────────────────────────────
record Chunk {
  text: String
  line: Int
}

func parseChunk(pkg: in String, c: in Chunk, st: in St, sp: in Span, into: in List[Item]): Unit {
  var pad = ""
  if c.line > 2 {
    pad = Str.repeat("\n", c.line - 2)
  }
  val pr = parse("package " + pkg + "\n" + pad + c.text)
  if pr.diagnostics.count > 0 {
    val d = pr.diagnostics[0]
    k(
      st,
      "K0000",
      "internal error: Lyric.PluginExpand generated code that does not parse (" + d.code + " " + d.message +
        " at generated line " +
        d.span.startPos.line.toString() +
        "); please report it",
      sp
    )
    return ()
  }
  for it in pr.file.items {
    into.add(it)
  }
}

func hasWholeImport(imports: in List[ImportDecl], path: in String): Bool {
  for im in imports {
    val whole = match im.selector { case Some(_) -> false; case None -> true }
    val bare = match im.asAlias { case Some(_) -> false; case None -> true }
    if not im.isExtern and whole and bare and importPath(im) == path {
      return true
    }
  }
  false
}

func withImports(imports: in List[ImportDecl], paths: in List[String], sp: in Span): List[ImportDecl] {
  val acc: List[ImportDecl] = newList()
  for im in imports {
    acc.add(im)
  }
  for p in paths {
    if not hasWholeImport(acc, p) {
      val segs: List[String] = newList()
      for s in splitDotted(p) {
        segs.add(s)
      }
      acc.add(
        ImportDecl(
          path = ModulePath(segments = segs, span = sp),
          selector = None,
          asAlias = None,
          isPubUse = false,
          isExtern = false,
          span = sp
        )
      )
    }
  }
  acc
}

/// The interface with the `requires:` clauses that name `grant` removed from
/// its methods (they move to the generated `<C>Server`).
func stripGuards(d: in InterfaceDecl): InterfaceDecl {
  val members: List[InterfaceMember] = newList()
  for m in d.members {
    match m {
      case IMSig(sig) -> members.add(IMSig(sig = sig.copy(contracts = keepNonGrant(sig.contracts))))
      case IMFunc(fn) -> members.add(IMFunc(fn = fn.copy(contracts = keepNonGrant(fn.contracts))))
      case IMAssoc(a) -> members.add(IMAssoc(assoc = a))
    }
  }
  d.copy(members = members)
}

func keepNonGrant(cs: in List[ContractClause]): List[ContractClause] {
  val kept: List[ContractClause] = newList()
  for c in cs {
    match c {
      case CCRequires(ex, _) -> {
        if not mentionsGrant(ex) {
          kept.add(c)
        }
      }
      case _ -> kept.add(c)
    }
  }
  kept
}

func strippedItem(it: in Item): Item {
  val anns = withoutPluginAnns(it.annotations)
  match it.kind {
    case IInterface(d) -> {
      if isAnnotatedIface(it, annCapability) {
        return it.copy(annotations = anns, kind = IInterface(decl = stripGuards(d)))
      }
      it.copy(annotations = anns)
    }
    case IFunc(fn) -> it.copy(
      annotations = anns,
      kind = IFunc(decl = fn.copy(annotations = withoutPluginAnns(fn.annotations)))
    )
    case _ -> it.copy(annotations = anns)
  }
}

/// Expand `file`'s plugin annotations.  `packages` holds every source
/// package of the build (`collectPluginPackage`), this one included or not.
pub func expandFile(file: in SourceFile, packages: in Map[String, PluginPackage]): PluginExpandResult {
  val noDiags: List[Diagnostic] = newList()
  if not usesPluginAnnotations(file) {
    return PluginExpandResult(file = file, diagnostics = noDiags)
  }
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  val st = St(packages = packages, reachMemo = newMap(), diags = newList())
  val ctx = makeCtx(pkg, file.imports, file.items)
  val ifaces: List[IfaceModel] = newList()
  val plugins: List[PluginModel] = newList()
  var pluginCount = 0
  var firstLine = 0
  for it in file.items {
    val anns = allAnns(it)
    var anyPlugin = false
    for a in anns {
      val n = annName(a)
      if isPluginAnnName(n) {
        anyPlugin = true
        if countAnn(anns, n) > 1 and n != annContributions and n != annRequest {
          k(st, "K0006", "@" + n + " appears more than once on the same item", a.span)
        }
      }
    }
    if anyPlugin and firstLine == 0 {
      firstLine = it.span.startPos.line
    }
    for a in anns {
      val n = annName(a)
      if n == annPoint or n == annProtocol or n == annCapability {
        val kind = if n == annPoint { "point" } else if n == annProtocol { "protocol" } else { "capability" }
        var others = 0
        if hasAnn(anns, annPoint) {
          others = others + 1
        }
        if hasAnn(anns, annProtocol) {
          others = others + 1
        }
        if hasAnn(anns, annCapability) {
          others = others + 1
        }
        if others > 1 {
          k(
            st,
            "K0005",
            "an interface is a plugin point, a protocol point or a capability, not more than one; remove @" + n,
            a.span
          )
        } else {
          match it.kind {
            case IInterface(d) -> match ifaceModel(it, d, a, kind, ctx, st) { case Some(m) -> ifaces.add(m); case None -> () }
            case _ -> k(st, "K0005", "@" + n + " must be on a pub interface", a.span)
          }
        }
      } else if n == annHandle {
        match it.kind {
          case IDistinctType(d) -> {
            val isLong = match d.underlying.kind {
              case TRef(path) -> path.segments.count == 1 and path.segments[0] == "Long"
              case _ -> false
            }
            val isGenericTy = match d.generics { case Some(_) -> true; case None -> false }
            val ranged = match d.rangeClause { case Some(_) -> true; case None -> false }
            if not isPub(it) or not isLong or isGenericTy or ranged {
              k(
                st,
                "K0005",
                "@plugin_handle must be on `pub type " + d.name + " = Long` (a public distinct type over Long, without a range)",
                a.span
              )
            }
          }
          case _ -> k(st, "K0005", "@plugin_handle must be on a `pub type H = Long` declaration", a.span)
        }
      } else if n == annPlugin {
        match it.kind {
          case IRecord(d) -> {
            pluginCount = pluginCount + 1
            if pluginCount > 1 {
              k(st, "K0012", "a package declares at most one @plugin record; " + d.name + " is the second", a.span)
            } else {
              match pluginModel(it, d, a, ctx, st, file) {
                case Some(m) -> plugins.add(m)
                case None -> ()
              }
            }
          }
          case _ -> k(st, "K0005", "@plugin must be on a pub record", a.span)
        }
      } else if n == annContributions or n == annRequest {
        match it.kind {
          case IFunc(_) -> ()
          case _ -> k(st, "K0009", "@" + n + " must be on a function", a.span)
        }
      }
    }
  }
  // Contributions/request functions without a plugin record.
  if pluginCount == 0 {
    for it in file.items {
      match it.kind {
        case IFunc(fn) -> {
          for a in allAnns(it) {
            val n = annName(a)
            if n == annContributions or n == annRequest {
              k(st, "K0009", "@" + n + " on " + fn.name + ": the package declares no @plugin record", a.span)
            }
          }
        }
        case _ -> ()
      }
    }
  }
  if pluginCount > 0 {
    for it in file.items {
      match it.kind {
        case IFunc(fn) -> {
          if fn.name == "main" {
            k(
              st,
              "K0012",
              "a package with a @plugin record must not declare main; the plugin's entry point is generated",
              fn.span
            )
          }
        }
        case _ -> ()
      }
    }
  }
  // Boundary types of this package.
  val g = newGen(pkg)
  val chunks: List[Chunk] = newList()
  val reached: List[String] = newList()
  computeReach(ctx, reached)
  if hasErrorDiag(st.diags) {
    return PluginExpandResult(file = file, diagnostics = st.diags)
  }
  for it in file.items {
    val n = itemDeclName(it)
    if n != "" and reached.contains(n) {
      match it.kind {
        case IRecord(d) -> chunks.add(Chunk(text = codecForRecord(d, ctx, st, g), line = it.span.startPos.line))
        case IExposedRec(d) -> chunks.add(Chunk(text = codecForRecord(d, ctx, st, g), line = it.span.startPos.line))
        case IUnion(d) -> chunks.add(Chunk(text = codecForUnion(d, ctx, st, g), line = it.span.startPos.line))
        case IEnum(d) -> chunks.add(Chunk(text = enumCodecText(d.name, d.cases, g), line = it.span.startPos.line))
        case IDistinctType(d) -> chunks.add(Chunk(text = handleCodecText(d.name, g), line = it.span.startPos.line))
        case _ -> ()
      }
    }
  }
  for m in ifaces {
    if m.kind == "capability" {
      chunks.add(Chunk(text = capabilityText(m, pkg, g), line = m.line))
    } else {
      chunks.add(Chunk(text = pointText(m, pkg, ctx, st, g), line = m.line))
    }
  }
  for pm in plugins {
    chunks.add(Chunk(text = pluginText(pm, g), line = pm.line))
  }
  if hasErrorDiag(st.diags) {
    return PluginExpandResult(file = file, diagnostics = st.diags)
  }
  var helpers = ""
  for t in g.helperTexts {
    helpers = helpers + t + "\n"
  }
  if helpers != "" {
    chunks.add(Chunk(text = helpers, line = firstLine))
  }
  val items: List[Item] = newList()
  for it in file.items {
    items.add(strippedItem(it))
  }
  for c in chunks {
    parseChunk(pkg, c, st, file.packageDecl.span, items)
  }
  if hasErrorDiag(st.diags) {
    return PluginExpandResult(file = file, diagnostics = st.diags)
  }
  val paths: List[String] = newList()
  paths.add("Std.Core")
  paths.add("Std.Collections")
  paths.add("Std.JsonValue")
  paths.add("Std.JsonRpc")
  paths.add("Std.Plugin")
  if g.flags.containsKey("bytes") {
    paths.add("Std.Encoding")
  }
  val out2 = SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = withImports(file.imports, paths, file.packageDecl.span),
    items = items,
    span = file.span
  )
  PluginExpandResult(file = out2, diagnostics = st.diags)
}

func hasErrorDiag(ds: in List[Diagnostic]): Bool {
  for d in ds {
    if d.severity == DiagError {
      return true
    }
  }
  false
}

func codecForRecord(d: in RecordDecl, ctx: in Ctx, st: in St, g: in Gen): String {
  val fields = recordFields(d)
  val bts: List[BT] = newList()
  for f in fields {
    bts.add(classify(f.ty, ctx, ctx.pkg, st, f.ty.span, "field '" + f.name + "' of " + d.name, 0))
  }
  recordCodecText(d.name, fields, bts, g)
}

func codecForUnion(d: in UnionDecl, ctx: in Ctx, st: in St, g: in Gen): String {
  val bts: List[List[BT]] = newList()
  for c in d.cases {
    val row: List[BT] = newList()
    for f in c.fields {
      match f {
        case UFNamed(n, t, _) -> row.add(
          classify(t, ctx, ctx.pkg, st, t.span, "field '" + n + "' of " + d.name + "." + c.name, 0)
        )
        case UFPos(t, s) -> row.add(k0001(st, s, d.name + "." + c.name, "a boundary union needs named case fields"))
      }
    }
    bts.add(row)
  }
  unionCodecText(d.name, d.cases, bts, g)
}
