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

func fieldsOf(d: in OpaqueTypeDecl, projectable: in Map[String, Bool]): List[ViewField] {
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
            case TRef(p) -> if p.segments.count == 1 and projectable.containsKey(p.segments[0]) {
              viewType = p.segments[0] + "View"
              nested = true
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
func expansionText(it: in Item, d: in OpaqueTypeDecl, projectable: in Map[String, Bool]): String {
  val fields = fieldsOf(d, projectable)
  val vis = visibilityPrefix(it)
  val view = d.name + "View"
  val decls: List[String] = newList()
  val viewFields: List[String] = newList()
  val toViewArgs: List[String] = newList()
  val tryArgs: List[String] = newList()
  var eligible = true
  for f in fields {
    tryArgs.add(f.name + " = self." + f.name)
    if f.hidden {
      eligible = false
    } else {
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

/// `file` with the view record and `toView`/`tryInto` of every `@projectable`
/// opaque type appended.  A file that declares none is returned unchanged.
/// Source the pass generated that does not parse is I0006 at the opaque type.
pub func projectableRewriteFile(file: in SourceFile): ProjectableResult {
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
  for it in file.items {
    match it.kind {
      case IOpaque(d) -> if isProjectableOpaque(it, d) {
        val pr = parse("package " + pkg + "\n" + expansionText(it, d, projectable))
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
  ProjectableResult(
    file = SourceFile(
      moduleDoc = file.moduleDoc,
      files = file.files,
      fileAnnotations = file.fileAnnotations,
      packageDecl = file.packageDecl,
      imports = imports,
      items = items,
      span = file.span
    ),
    diagnostics = diags
  )
}
