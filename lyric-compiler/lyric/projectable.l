//! Declaration expansion for `@projectable` opaque types (docs/01 section 2.9,
//! docs/70 section 7.1).
//!
//! An `opaque type User @projectable { ... }` gets, before the type check, the
//! declarations the backends used to synthesise for themselves:
//!
//!   exposed record UserView { <visible fields> }
//!   func User.toView(self: in User): UserView = UserView(<fields>)
//!   func UserView.tryInto(self: in UserView): Result[User, String] = Ok(User(<fields>))
//!
//! as ordinary AST, so the checker types them, the typed IR builder lowers them
//! and no backend carries a projection twin of its own.
//!
//! - The view holds the fields not marked `@hidden`, in declaration order.
//! - A `@projectionBoundary` field keeps its source type in the view.
//! - A field whose type is another `@projectable` opaque type of the same file
//!   (and is not a boundary) becomes `<FieldType>View`, and `toView` projects it
//!   with `.toView()`.
//! - `tryInto` is emitted only when no field is `@hidden` and no visible field is
//!   a nested projectable (the view then cannot rebuild the opaque).
//! - A generic opaque type is not projected.
//!
//! The declarations are written as source text and parsed, then given spans of
//! their own that map back to the opaque type (`Lyric.Expand.respanGenerated`),
//! the way `Lyric.PluginExpand` and `Lyric.Stubbable` do.
package Lyric.Projectable

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt
import Lyric.Expand as Expand
import Lyric.PluginExpand as PluginExpand

func hasAnnotation(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if a.name.segments.count > 0 and a.name.segments[0] == name {
      return true
    }
  }
  false
}

func isProjectableOpaque(it: in Item, d: in OpaqueTypeDecl): Bool {
  match d.generics {
    case Some(_) -> false
    case None -> hasAnnotation(d.annotations, "projectable") or hasAnnotation(it.annotations, "projectable")
  }
}

record ViewField {
  name: String
  hidden: Bool
  /// The view's type for this field, as written in source.
  viewType: String
  /// True when the view field is another type's view and `toView` recurses.
  nested: Bool
}

/// What the pass knows while it expands one file: the projectable names of the file, the
/// build's source packages (`PluginExpand.collectPluginPackage`, the index every bridge
/// already fills), and the view imports the expansion needs added to the file.
record Scope {
  file: SourceFile
  local: Map[String, Bool]
  packages: Map[String, PluginExpand.PluginPackage]
  /// Each `<package>.<Name>View` a field of an imported projectable type needs imported.
  viewImports: List[List[String]]
  /// The file (`Position.fileId`) each of `viewImports` is for: a file resolves its names through its own
  /// header's imports, so the import goes into that header too.
  viewImportFiles: List[Int]
  /// The file of the opaque type being expanded, in one cell.
  currentFile: List[Int]
  /// The files with a projectable opaque type: their headers import `Std.Core` for `Result` and `Ok`.
  projectableFiles: Map[Int, Bool]
}

/// How a field type names another projectable type: the view type to write, and the
/// import the view needs (empty when the type is written qualified or is the file's own).
record NestedRef {
  viewType: String
  importPath: List[String]
}

func joinPath(segs: in List[String]): String = joinWith(segs, ".")

/// Whether package `pkg` of the build declares a non-generic `@projectable` opaque type `name`.
func packageHasProjectable(sc: in Scope, pkg: in String, name: in String): Bool {
  match mapGet(sc.packages, pkg) {
    case Some(p) -> {
      for it in p.items {
        match it.kind {
          case IOpaque(d) -> if d.name == name and isProjectableOpaque(it, d) { return true }
          case _ -> ()
        }
      }
      false
    }
    case None -> false
  }
}

func prefixOf(segs: in List[String]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < segs.count - 1 {
    acc.add(segs[i])
    i = i + 1
  }
  acc
}

/// The projectable type a field type path names, in this file's package or one of the build's
/// other packages: by bare name (declared here, or imported as `import P.Name` or
/// `import P.{Name}`), or qualified by a package path or an import alias.
func resolveNested(sc: in Scope, path: in ModulePath): Option[NestedRef] {
  val segs = path.segments
  val noImport: List[String] = newList()
  if segs.count == 1 {
    val name = segs[0]
    val own = Fmt.pathStr(sc.file.packageDecl.path)
    if sc.local.containsKey(name) or packageHasProjectable(sc, own, name) {
      return Some(value = NestedRef(viewType = name + "View", importPath = noImport))
    }
    for im in sc.file.imports {
      if im.isExtern {
        continue
      }
      match im.selector {
        case Some(sel) -> {
          val items: List[ImportItem] = match sel { case ISSingle(item) -> [item]; case ISGroup(xs) -> xs }
          for item in items {
            val aliased = match item.asAlias { case Some(_) -> true; case None -> false }
            if item.name == name and not aliased and packageHasProjectable(sc, joinPath(im.path.segments), name) {
              return Some(value = NestedRef(viewType = name + "View", importPath = im.path.segments))
            }
          }
        }
        case None -> {
          val imSegs = im.path.segments
          val aliased = match im.asAlias { case Some(_) -> true; case None -> false }
          if not aliased and imSegs.count >= 2 and imSegs[imSegs.count - 1] == name and packageHasProjectable(sc, joinPath(prefixOf(imSegs)), name) {
            return Some(value = NestedRef(viewType = name + "View", importPath = prefixOf(imSegs)))
          }
        }
      }
    }
    return None
  }
  val name = segs[segs.count - 1]
  val prefix = prefixOf(segs)
  var pkg = joinPath(prefix)
  if not sc.packages.containsKey(pkg) {
    for im in sc.file.imports {
      match im.asAlias {
        case Some(a) -> if not im.isExtern and prefix.count == 1 and a == prefix[0] { pkg = joinPath(im.path.segments) }
        case None -> ()
      }
    }
  }
  if packageHasProjectable(sc, pkg, name) {
    return Some(value = NestedRef(viewType = joinPath(prefix) + "." + name + "View", importPath = noImport))
  }
  None
}

func fieldsOf(d: in OpaqueTypeDecl, sc: in Scope): List[ViewField] {
  val acc: List[ViewField] = newList()
  for m in d.members {
    match m {
      case OMField(f) -> {
        val hidden = hasAnnotation(f.annotations, "hidden")
        val boundary = hasAnnotation(f.annotations, "projectionBoundary")
        val written = Fmt.typeStr(f.ty)
        var viewType = written
        var nested = false
        if not hidden and not boundary {
          match f.ty.kind {
            case TRef(p) -> match resolveNested(sc, p) {
              case Some(r) -> {
                viewType = r.viewType
                nested = true
                if r.importPath.count > 0 {
                  val full: List[String] = newList()
                  for seg in r.importPath {
                    full.add(seg)
                  }
                  full.add(r.viewType)
                  sc.viewImports.add(full)
                  sc.viewImportFiles.add(sc.currentFile[0])
                }
              }
              case None -> ()
            }
            case _ -> ()
          }
        }
        acc.add(ViewField(name = f.name, hidden = hidden, viewType = viewType, nested = nested))
      }
      case OMInvariant(_) -> ()
    }
  }
  acc
}

func visibilityPrefix(it: in Item): String {
  match it.visibility {
    case Some(_) -> "pub "
    case None -> ""
  }
}

func joinWith(parts: in List[String], sep: in String): String {
  var joined = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      joined = joined + sep
    }
    joined = joined + parts[i]
    i = i + 1
  }
  joined
}

/// The source text of the view record and its two functions for `d`.
func expansionText(it: in Item, d: in OpaqueTypeDecl, sc: in Scope): String {
  val fields = fieldsOf(d, sc)
  val vis = visibilityPrefix(it)
  val view = d.name + "View"
  val decls: List[String] = newList()
  val viewFields: List[String] = newList()
  val toViewArgs: List[String] = newList()
  val tryArgs: List[String] = newList()
  var eligible = true
  for f in fields {
    if f.hidden {
      eligible = false
    } else {
      tryArgs.add(f.name + " = self." + f.name)
      viewFields.add("  " + vis + f.name + ": " + f.viewType)
      if f.nested {
        toViewArgs.add(f.name + " = self." + f.name + ".toView()")
        eligible = false
      } else {
        toViewArgs.add(f.name + " = self." + f.name)
      }
    }
  }
  var rec = vis + "exposed record " + view + " {\n"
  if viewFields.count > 0 {
    rec = rec + joinWith(viewFields, "\n") + "\n"
  }
  rec = rec + "}\n"
  decls.add(rec)
  decls.add(
    vis + "func " + d.name + ".toView(self: in " + d.name + "): " + view + " = " + view + "(" +
      joinWith(toViewArgs, ", ") +
      ")\n"
  )
  if eligible {
    decls.add(
      vis + "func " + view + ".tryInto(self: in " + view + "): Result[" + d.name + ", String] = Ok(" + d.name + "(" +
        joinWith(tryArgs, ", ") +
        "))\n"
    )
  }
  joinWith(decls, "\n")
}

/// Whether `imports` has `import first.second` as a whole, unaliased import (a selector or an alias does not
/// bring every name into scope).
func hasWholeImport(imports: in List[ImportDecl], first: in String, second: in String): Bool {
  for im in imports {
    val whole = match im.selector { case Some(_) -> false; case None -> true }
    val bare = match im.asAlias { case Some(_) -> false; case None -> true }
    if whole and bare and not im.isExtern and im.path.segments.count == 2 and im.path.segments[0] == first and im.path.segments[1] == second {
      return true
    }
  }
  false
}

func withStdCore(imports: in List[ImportDecl], span: in Span): List[ImportDecl] {
  val acc: List[ImportDecl] = newList()
  for im in imports {
    acc.add(im)
  }
  val segs: List[String] = newList()
  segs.add("Std")
  segs.add("Core")
  acc.add(
    ImportDecl(
      path = ModulePath(segments = segs, span = span),
      selector = None,
      asAlias = None,
      isPubUse = false,
      isExtern = false,
      span = span
    )
  )
  acc
}

pub record ProjectableResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// `imports` with each of `paths` (a package path then a name) imported by selector
/// (`import P.{NameView}`), the ones already imported left out.
func withViewImports(imports: in List[ImportDecl], paths: in List[List[String]], span: in Span): List[ImportDecl] {
  val acc: List[ImportDecl] = newList()
  val seen: Map[String, Bool] = newMap()
  for im in imports {
    acc.add(im)
    match im.selector {
      case Some(sel) -> {
        val items: List[ImportItem] = match sel { case ISSingle(item) -> [item]; case ISGroup(xs) -> xs }
        for item in items {
          seen.add(joinPath(im.path.segments) + "." + item.name, true)
        }
      }
      case None -> seen.add(joinPath(im.path.segments), true)
    }
  }
  for segs in paths {
    val key = joinPath(segs)
    if not seen.containsKey(key) {
      seen.add(key, true)
      acc.add(
        ImportDecl(
          path = ModulePath(segments = prefixOf(segs), span = span),
          selector = Some(value = ISSingle(item = ImportItem(name = segs[segs.count - 1], asAlias = None, span = span))),
          asAlias = None,
          isPubUse = false,
          isExtern = false,
          span = span
        )
      )
    }
  }
  acc
}

/// `headers` with each file's own header importing the views its own opaque types need.
func withHeaderViewImports(headers: in List[FileHeader], sc: in Scope): List[FileHeader] {
  val acc: List[FileHeader] = newList()
  var fileId = 0
  for h in headers {
    val paths: List[List[String]] = newList()
    var i = 0
    while i < sc.viewImports.count {
      if sc.viewImportFiles[i] == fileId {
        paths.add(sc.viewImports[i])
      }
      i = i + 1
    }
    var imps = withViewImports(h.imports, paths, h.span)
    if sc.projectableFiles.containsKey(fileId) and not hasWholeImport(imps, "Std", "Core") {
      imps = withStdCore(imps, h.span)
    }
    acc.add(h.copy(imports = imps))
    fileId = fileId + 1
  }
  acc
}

/// `file` with the view record and `toView`/`tryInto` of every `@projectable`
/// opaque type appended.  A file that declares none is returned unchanged.
/// Source the pass generated that does not parse is I0006 at the opaque type.
pub func projectableRewriteFile(file: in SourceFile): ProjectableResult {
  val none: Map[String, PluginExpand.PluginPackage] = newMap()
  projectableRewriteFileIn(file, none)
}

/// `projectableRewriteFile` with the build's source packages (`PluginExpand.collectPluginPackage`),
/// so a field typed as a `@projectable` opaque type of another package of the build projects to that
/// package's `<Name>View` as it does for one of the file's own, the view type imported from its package.
pub func projectableRewriteFileIn(
  file: in SourceFile, packages: in Map[String, PluginExpand.PluginPackage]
): ProjectableResult {
  val projectable: Map[String, Bool] = newMap()
  for it in file.items {
    match it.kind {
      case IOpaque(d) -> if isProjectableOpaque(it, d) { projectable.add(d.name, true) }
      case _ -> ()
    }
  }
  val diags: List[Diagnostic] = newList()
  if projectable.count == 0 {
    return ProjectableResult(file = file, diagnostics = diags)
  }
  val pkg = Fmt.pathStr(file.packageDecl.path)
  val items: List[Item] = newList()
  for it in file.items {
    items.add(it)
  }
  val origins: Map[String, Span] = newMap()
  val base = Expand.generatedSpanBase(file)
  val sc = Scope(
    file = file,
    local = projectable,
    packages = packages,
    viewImports = newList(),
    viewImportFiles = newList(),
    currentFile = [0],
    projectableFiles = newMap()
  )
  for it in file.items {
    match it.kind {
      case IOpaque(d) -> if isProjectableOpaque(it, d) {
        sc.currentFile[0] = it.span.startPos.fileId
        sc.projectableFiles[it.span.startPos.fileId] = true
        val pr = parse("package " + pkg + "\n" + expansionText(it, d, sc))
        if pr.diagnostics.count > 0 {
          diags.add(
            errorDiagnostic(
              "I0006",
              "internal error: the @projectable expansion of '" + d.name + "' does not parse (" + pr.diagnostics[0].code + " " +
                pr.diagnostics[0].message +
                "); please report it",
              it.span
            )
          )
        } else {
          for g in Expand.respanGenerated(file, pr.file.items, base, it.span, origins) {
            items.add(g)
          }
        }
      }
      case _ -> ()
    }
  }
  var imports = file.imports
  if not hasWholeImport(imports, "Std", "Core") {
    imports = withStdCore(imports, file.span)
  }
  imports = withViewImports(imports, sc.viewImports, file.span)
  ProjectableResult(
    file = SourceFile(
      moduleDoc = file.moduleDoc,
      files = withHeaderViewImports(file.files, sc),
      fileAnnotations = file.fileAnnotations,
      packageDecl = file.packageDecl,
      imports = imports,
      items = items,
      span = file.span
    ),
    diagnostics = diags
  )
}
