//! layers.l — `Lyric.Layers`: enforced package layering (docs/65 §5, D149).
//!
//! A manifest's `[layers]` table assigns project packages to named layers
//! and says which layers each layer may import.  Packages outside the
//! project are placed by their package-level classification: `@pure` or
//! `@io` on the `package` line of their source (the stdlib and ecosystem
//! libraries carry one), or recorded in a restored package's contract
//! metadata.  An `import extern` counts as an `io` import.
//!
//! `checkLayers` runs once per project build, before any backend, so the
//! rules are the same on every target.  It needs only the parsed files and
//! the manifest; the call-level rules (`@io` functions, protected-type
//! entries: Y0003, Y0007, Y0008) need resolved calls and run in the type
//! checker.
//!
//! Diagnostics:
//!   Y0001  a layered package imports a package its rule does not allow
//!   Y0002  a layered package imports a package with no layer and no class
//!   Y0004  `async func` in a layer whose rule sets `async = false`
//!   Y0005  a package's `@layer` annotation disagrees with the manifest
//!   Y0006  an unknown layer name or preset
//!   Y0009  a malformed `@pure` / `@io` / `@layer` annotation, or a
//!          `[layers.packages]` entry that matches no project package or
//!          ties with another entry naming a different layer
package Lyric.Layers

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Manifest
import Lyric.PackageMerge as PM

/// One project source file, parsed.  A package may span several files.
pub record LayerPackage {
  name: String
  path: String
  file: SourceFile
}

/// A diagnostic and the file it belongs to.  `path` is "" for a
/// manifest-level diagnostic.
pub record LayerDiagnostic {
  path: String
  diag: Diagnostic
}

/// A resolved rule: the layer names and classes it may import, the
/// package patterns it may and may not import, and whether it allows
/// `async func`.
pub record LayerRule {
  name: String
  layers: List[String]
  allowPackages: List[String]
  denyPackages: List[String]
  allowAsync: Bool
}

pub record LayerConfig {
  rules: List[LayerRule]
  assignments: List[LayerAssignment]
}

/// The preset names `[layers] preset` accepts.
pub func knownPresets(): List[String] {
  names1("ui")
}

func names1(a: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs
}

func names2(a: in String, b: in String): List[String] {
  val xs = names1(a)
  xs.add(b)
  xs
}

func names3(a: in String, b: in String, c: in String): List[String] {
  val xs = names2(a, b)
  xs.add(c)
  xs
}

func names4(a: in String, b: in String, c: in String, d: in String): List[String] {
  val xs = names3(a, b, c)
  xs.add(d)
  xs
}

func uiRule(name: in String, layers: in List[String], allow: in List[String], allowAsync: in Bool): LayerRule {
  LayerRule(
    name = name,
    layers = layers,
    allowPackages = allow,
    denyPackages = names2("Ui", "Ui.**"),
    allowAsync = allowAsync
  )
}

/// The `ui` preset (docs/65 §5.2).  Every layer is closed to the `Ui.*`
/// packages except the ones it names: logic and effects see only
/// `Ui.Core`'s data types, `Ui.Routing`'s URL helpers (which a
/// `@generate(Ui.Routes)` route union calls, D151) and `Ui.Grid`'s pure
/// data-grid state (D154), and only views build widgets.  A view may also import another view, which an embedded
/// component needs (§6.2).
pub func presetRules(preset: in String): List[LayerRule] {
  val rules: List[LayerRule] = newList()
  if preset != "ui" {
    return rules
  }
  rules.add(uiRule("domain", names2("domain", "pure"), newList(), true))
  rules.add(uiRule("ports", names2("domain", "pure"), newList(), true))
  rules.add(uiRule("logic", names3("domain", "logic", "pure"), names3("Ui.Core", "Ui.Routing", "Ui.Grid"), false))
  val effects = names4("domain", "logic", "ports", "pure")
  effects.add("io")
  rules.add(uiRule("effects", effects, names3("Ui.Core", "Ui.Routing", "Ui.Grid"), true))
  val viewUi = names4("Ui.Core", "Ui.Widgets", "Ui.Forms", "Ui.Routing")
  viewUi.add("Ui.Grid")
  rules.add(uiRule("view", names4("domain", "logic", "view", "pure"), viewUi, false))
  rules
}

func hasName(xs: in List[String], x: in String): Bool {
  for y in xs {
    if y == x {
      return true
    }
  }
  false
}

func joinNames(xs: in List[String]): String {
  var joined = ""
  for x in xs {
    joined = if joined == "" { x } else { joined + ", " + x }
  }
  joined
}

func isPackagePattern(entry: in String): Bool {
  if entry.length == 0 {
    return false
  }
  val first = Str.substring(entry, 0, 1)
  first != Str.toLower(first)
}

func manifestDiag(code: in String, msg: in String): LayerDiagnostic {
  LayerDiagnostic(path = "", diag = errorDiagnostic(code, msg, emptySpan()))
}

func emptySpan(): Span {
  val p = Position(line = 0, column = 0, offset = 0)
  Span(startPos = p, endPos = p)
}

/// Resolves a manifest `[layers]` table into rules: the preset's rules,
/// replaced or extended by the manifest's own.  Every name a rule or an
/// assignment uses must be a defined layer or the class `pure` / `io`
/// (Y0006).
pub func resolveLayerConfig(section: in LayersSection): Result[LayerConfig, List[LayerDiagnostic]] {
  val diags: List[LayerDiagnostic] = newList()
  if section.preset != "" and not hasName(knownPresets(), section.preset) {
    diags.add(
      manifestDiag(
        "Y0006",
        "unknown [layers] preset '" + section.preset + "' (known presets: " + joinNames(knownPresets()) + ")"
      )
    )
  }
  val rules: List[LayerRule] = newList()
  for r in presetRules(section.preset) {
    var overridden = false
    for c in section.rules {
      if c.name == r.name {
        overridden = true
      }
    }
    if not overridden {
      rules.add(r)
    }
  }
  for c in section.rules {
    if c.name == "pure" or c.name == "io" {
      diags.add(
        manifestDiag("Y0006", "'" + c.name + "' is a package class, not a layer name; rename the [layers.rules] entry")
      )
    }
    val layerNames: List[String] = newList()
    val allow: List[String] = newList()
    for m in c.mayImport {
      if isPackagePattern(m) {
        allow.add(m)
      } else {
        layerNames.add(m)
      }
    }
    for d in c.mayNotImport {
      if not isPackagePattern(d) {
        diags.add(
          manifestDiag(
            "Y0006",
            "[layers.rules] '" + c.name + "' may_not_import entry '" + d + "' must be a package name or pattern, not a layer"
          )
        )
      }
    }
    rules.add(
      LayerRule(
        name = c.name,
        layers = layerNames,
        allowPackages = allow,
        denyPackages = c.mayNotImport,
        allowAsync = c.allowAsync
      )
    )
  }
  val defined: List[String] = newList()
  for r in rules {
    defined.add(r.name)
  }
  for r in rules {
    for l in r.layers {
      if l != "pure" and l != "io" and not hasName(defined, l) {
        diags.add(
          manifestDiag(
            "Y0006",
            "[layers.rules] '" + r.name + "' may import unknown layer '" + l + "'" + knownLayersNote(defined)
          )
        )
      }
    }
  }
  for a in section.packages {
    if not hasName(defined, a.layer) {
      diags.add(
        manifestDiag(
          "Y0006",
          "[layers.packages] '" + a.pattern + "' names unknown layer '" + a.layer + "'" + knownLayersNote(defined)
        )
      )
    }
  }
  if diags.count > 0 {
    return Err(error = diags)
  }
  Ok(value = LayerConfig(rules = rules, assignments = section.packages))
}

func knownLayersNote(defined: in List[String]): String {
  if defined.count == 0 {
    " (no layers are defined: set [layers] preset or add [layers.rules])"
  } else {
    " (defined layers: " + joinNames(defined) + ")"
  }
}

/// Whether `name` matches `pattern`.  A `*` segment matches exactly one
/// dotted segment; a final `**` segment matches one or more.
pub func packageMatches(pattern: in String, name: in String): Bool {
  val ps = Str.split(pattern, ".")
  val ns = Str.split(name, ".")
  var i = 0
  while i < ps.length {
    val p = ps[i]
    if p == "**" {
      return i == ps.length - 1 and ns.length > i
    }
    if i >= ns.length {
      return false
    }
    if p != "*" and p != ns[i] {
      return false
    }
    i = i + 1
  }
  i == ns.length
}

// How specific a matching pattern is: literal segments count double, and
// a pattern with no wildcard at all beats any wildcard pattern.
func patternSpecificity(pattern: in String): Int {
  val ps = Str.split(pattern, ".")
  var literal = 0
  var wild = false
  for p in ps {
    if p == "*" or p == "**" {
      wild = true
    } else {
      literal = literal + 1
    }
  }
  if wild {
    literal * 2
  } else {
    literal * 2 + 1
  }
}

// The most specific pattern in `patterns` matching `name`, as its
// specificity; -1 when none matches.
func bestMatch(patterns: in List[String], name: in String): Int {
  var best = -1
  for p in patterns {
    if packageMatches(p, name) {
      val s = patternSpecificity(p)
      if s > best {
        best = s
      }
    }
  }
  best
}

func annotationName(a: in Annotation): String {
  modulePathJoin(a.name.segments)
}

/// A package-level classification annotation on one file.
pub record ClassAnnotation {
  value: String
  span: Span
}

/// The `@pure` / `@io` classification a file declares ("" for none), and
/// any malformed-annotation diagnostics (Y0009).
pub func fileClassOf(sf: in SourceFile, path: in String, diags: in List[LayerDiagnostic]): Option[ClassAnnotation] {
  var found: Option[ClassAnnotation] = None
  for a in sf.fileAnnotations {
    val n = annotationName(a)
    if n == "pure" or n == "io" {
      if a.args.count > 0 {
        diags.add(
          LayerDiagnostic(path = path, diag = errorDiagnostic("Y0009", "@" + n + " on a package takes no arguments", a.span))
        )
      }
      match found {
        case Some(prev) -> {
          if prev.value != n {
            diags.add(
              LayerDiagnostic(path = path, diag = errorDiagnostic("Y0009", "a package is either @pure or @io, not both", a.span))
            )
          }
        }
        case None -> {
          found = Some(value = ClassAnnotation(value = n, span = a.span))
        }
      }
    }
  }
  found
}

/// The layer a file's `@layer("name")` annotation declares, if any.
pub func fileLayerOf(sf: in SourceFile, path: in String, diags: in List[LayerDiagnostic]): Option[ClassAnnotation] {
  var found: Option[ClassAnnotation] = None
  for a in sf.fileAnnotations {
    if annotationName(a) == "layer" {
      var name = ""
      if a.args.count == 1 {
        match a.args[0] {
          case ALiteral(v, _) -> match v { case AVString(s, _) -> { name = s }; case _ -> () }
          case _ -> ()
        }
      }
      if name == "" {
        diags.add(
          LayerDiagnostic(
            path = path,
            diag = errorDiagnostic("Y0009", "@layer takes one string argument, the layer name: @layer(\"logic\")", a.span)
          )
        )
      } else {
        match found {
          case Some(prev) -> {
            if prev.value != name {
              diags.add(LayerDiagnostic(path = path, diag = errorDiagnostic("Y0009", "a package has one @layer", a.span)))
            }
          }
          case None -> {
            found = Some(value = ClassAnnotation(value = name, span = a.span))
          }
        }
      }
    }
  }
  found
}

/// The package-level classification of a set of source files for one
/// package: "pure", "io", or "" when none declares one.  Files that
/// disagree are reported (Y0009).  Used for project packages here and by
/// callers classifying stdlib and dependency sources.
pub func packageClassOfFiles(files: in List[LayerPackage], diags: in List[LayerDiagnostic]): String {
  var cls = ""
  var clsPath = ""
  for f in files {
    match fileClassOf(f.file, f.path, diags) {
      case Some(c) -> {
        if cls == "" {
          cls = c.value
          clsPath = f.path
        } else if cls != c.value {
          diags.add(
            LayerDiagnostic(
              path = f.path,
              diag = errorDiagnostic(
                "Y0009",
                "package " + f.name + " is @" + c.value + " here but @" + cls + " in " + clsPath,
                c.span
              )
            )
          )
        }
      }
      case None -> ()
    }
  }
  cls
}

func ruleNamed(cfg: in LayerConfig, name: in String): Option[LayerRule] {
  for r in cfg.rules {
    if r.name == name {
      return Some(value = r)
    }
  }
  None
}

// The layer the manifest assigns `name`, by its most specific matching
// entry; "" when none matches.  Equally specific entries naming different
// layers are reported (Y0009).
func assignedLayer(cfg: in LayerConfig, name: in String, diags: in List[LayerDiagnostic]): String {
  var best = -1
  var layer = ""
  var bestPattern = ""
  for a in cfg.assignments {
    if packageMatches(a.pattern, name) {
      val s = patternSpecificity(a.pattern)
      if s > best {
        best = s
        layer = a.layer
        bestPattern = a.pattern
      } else if s == best and a.layer != layer {
        diags.add(
          manifestDiag(
            "Y0009",
            "[layers.packages] entries '" + bestPattern + "' and '" + a.pattern + "' both match " + name +
              " and name different layers"
          )
        )
      }
    }
  }
  layer
}

// What an imported package is, for rule matching: its layer when it is a
// layered project package, else its class ("pure" / "io"), else "".
record Placement {
  layer: String
  cls: String
}

func describe(p: in Placement): String {
  if p.layer != "" {
    "layer '" + p.layer + "'"
  } else if p.cls != "" {
    "@" + p.cls
  } else {
    "unclassified"
  }
}

/// Checks every project package against the layer rules.  `pkgs` holds
/// every project source file; `external` maps each non-project package a
/// project file may import (stdlib, dependencies) to its class, "pure" or
/// "io".  A package absent from both is unclassified.
pub func checkLayers(
  cfg: in LayerConfig, pkgs: in List[LayerPackage], external: in Map[String, String]
): List[LayerDiagnostic] {
  val diags: List[LayerDiagnostic] = newList()
  // Group files by package, preserving first-seen order.
  val names: List[String] = newList()
  for p in pkgs {
    if not hasName(names, p.name) {
      names.add(p.name)
    }
  }
  val layerOf: Map[String, String] = newMap()
  val classOf: Map[String, String] = newMap()
  for name in names {
    val files: List[LayerPackage] = newList()
    for p in pkgs {
      if p.name == name {
        files.add(p)
      }
    }
    classOf[name] = packageClassOfFiles(files, diags)
    val manifestLayer = assignedLayer(cfg, name, diags)
    var layer = manifestLayer
    for f in files {
      match fileLayerOf(f.file, f.path, diags) {
        case Some(ann) -> {
          if manifestLayer != "" and ann.value != manifestLayer {
            diags.add(
              LayerDiagnostic(
                path = f.path,
                diag = errorDiagnostic(
                  "Y0005",
                  "package " + name + " is @layer(\"" + ann.value + "\") here but the manifest puts it in '" +
                    manifestLayer +
                    "'",
                  ann.span
                )
              )
            )
          } else if ruleNamed(cfg, ann.value).isNone {
            diags.add(
              LayerDiagnostic(path = f.path, diag = errorDiagnostic("Y0006", "unknown layer '" + ann.value + "'", ann.span))
            )
          } else if layer == "" {
            layer = ann.value
          }
        }
        case None -> ()
      }
    }
    layerOf[name] = layer
  }
  for a in cfg.assignments {
    var matched = false
    for name in names {
      if packageMatches(a.pattern, name) {
        matched = true
      }
    }
    if not matched {
      diags.add(manifestDiag("Y0009", "[layers.packages] '" + a.pattern + "' matches no package of this project"))
    }
  }
  for p in pkgs {
    val layer = unwrapOr(mapGet(layerOf, p.name), "")
    if layer != "" {
      match ruleNamed(cfg, layer) {
        case Some(rule) -> checkFile(rule, p, layerOf, classOf, external, diags)
        case None -> ()
      }
    }
  }
  diags
}

func checkFile(
  rule: in LayerRule,
  p: in LayerPackage,
  layerOf: in Map[String, String],
  classOf: in Map[String, String],
  external: in Map[String, String],
  diags: in List[LayerDiagnostic],
): Unit {
  for imp in p.file.imports {
    val target = modulePathJoin(imp.path.segments)
    if target != p.name {
      val placement = if imp.isExtern {
        Placement(layer = "", cls = "io")
      } else {
        placementOf(target, layerOf, classOf, external)
      }
      checkImport(rule, p, imp, target, placement, diags)
    }
  }
  if not rule.allowAsync {
    for item in p.file.items {
      checkAsyncItem(rule, p, item, diags)
    }
  }
}

func placementOf(
  target: in String,
  layerOf: in Map[String, String],
  classOf: in Map[String, String],
  external: in Map[String, String],
): Placement {
  match mapGet(layerOf, target) {
    case Some(l) -> {
      if l != "" {
        return Placement(layer = l, cls = "")
      } else {
        return Placement(layer = "", cls = unwrapOr(mapGet(classOf, target), ""))
      }
    }
    case None -> ()
  }
  Placement(layer = "", cls = unwrapOr(mapGet(external, target), ""))
}

func checkImport(
  rule: in LayerRule,
  p: in LayerPackage,
  imp: in ImportDecl,
  target: in String,
  placement: in Placement,
  diags: in List[LayerDiagnostic],
): Unit {
  val what = if imp.isExtern {
    "import extern " + target + " (an io import)"
  } else {
    target + " (" + describe(placement) + ")"
  }
  // A package pattern decides first; the more specific of an allow and a
  // deny pattern wins, and a tie denies.
  val allowScore = if imp.isExtern { -1 } else { bestMatch(rule.allowPackages, target) }
  val denyScore = if imp.isExtern { -1 } else { bestMatch(rule.denyPackages, target) }
  if allowScore >= 0 or denyScore >= 0 {
    if allowScore > denyScore {
      return
    }
    diags.add(
      LayerDiagnostic(
        path = p.path,
        diag = errorDiagnostic(
          "Y0001",
          "package " + p.name + " in layer '" + rule.name + "' may not import " + what,
          imp.span
        )
      )
    )
    return
  }
  if placement.layer == "" and placement.cls == "" {
    diags.add(
      LayerDiagnostic(
        path = p.path,
        diag = errorDiagnostic(
          "Y0002",
          "package " + p.name + " in layer '" + rule.name + "' imports " + target +
            ", which has no layer and is neither @pure nor @io; classify it or assign it a layer",
          imp.span
        )
      )
    )
    return
  }
  val key = if placement.layer != "" { placement.layer } else { placement.cls }
  if not hasName(rule.layers, key) {
    diags.add(
      LayerDiagnostic(
        path = p.path,
        diag = errorDiagnostic(
          "Y0001",
          "package " + p.name + " in layer '" + rule.name + "' may not import " + what,
          imp.span
        )
      )
    )
  }
}

func asyncDiag(rule: in LayerRule, p: in LayerPackage, fnName: in String, sp: in Span): LayerDiagnostic {
  LayerDiagnostic(
    path = p.path,
    diag = errorDiagnostic(
      "Y0004",
      "async func " + fnName + " in package " + p.name + ": layer '" + rule.name +
        "' does not allow async functions",
      sp
    )
  )
}

func checkAsyncFn(rule: in LayerRule, p: in LayerPackage, fn: in FunctionDecl, diags: in List[LayerDiagnostic]): Unit {
  if fn.isAsync {
    diags.add(asyncDiag(rule, p, fn.name, fn.span))
  }
}

func checkAsyncItem(rule: in LayerRule, p: in LayerPackage, item: in Item, diags: in List[LayerDiagnostic]): Unit {
  match item.kind {
    case IFunc(fn) -> checkAsyncFn(rule, p, fn, diags)
    case IRecord(decl) -> {
      for m in decl.members {
        match m {
          case RMFunc(fn) -> checkAsyncFn(rule, p, fn, diags)
          case _ -> ()
        }
      }
    }
    case IExposedRec(decl) -> {
      for m in decl.members {
        match m {
          case RMFunc(fn) -> checkAsyncFn(rule, p, fn, diags)
          case _ -> ()
        }
      }
    }
    case IImpl(decl) -> {
      for m in decl.members {
        match m {
          case IMplFunc(fn) -> checkAsyncFn(rule, p, fn, diags)
          case _ -> ()
        }
      }
    }
    case IInterface(decl) -> {
      for m in decl.members {
        match m {
          case IMFunc(fn) -> checkAsyncFn(rule, p, fn, diags)
          case IMSig(sig) -> if sig.isAsync { diags.add(asyncDiag(rule, p, sig.name, item.span)) }
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
}

// The text of `source` up to the end of its `package` declaration: module
// docs, comments, file annotations and the declaration, without the imports
// and items.  "" when no `package` declaration is found.  Read as the
// package merge reads a header, so a `package` line inside a comment is not
// the declaration.
func headerText(source: in String): String {
  PM.headerThroughPackage(source)
}

/// A package's name and class, "pure", "io" or "".
pub record PackageClassEntry {
  name: String
  cls: String
}

/// The package a source declares and its class, read from the header
/// alone, so classifying the whole stdlib does not parse every body.
/// None when the header does not parse.
pub func headerClassOf(source: in String): Option[PackageClassEntry] {
  val header = headerText(source)
  if header == "" {
    return None
  }
  val pr = parse(header)
  if pr.diagnostics.count > 0 {
    return None
  }
  val ignored: List[LayerDiagnostic] = newList()
  val cls = match fileClassOf(pr.file, "", ignored) { case Some(c) -> c.value; case None -> "" }
  Some(value = PackageClassEntry(name = modulePathJoin(pr.file.packageDecl.path.segments), cls = cls))
}

/// Records the class of every classified package among `sources` in
/// `into`.  A package already present keeps its first class.
pub func addSourceClasses(sources: in List[String], into: in Map[String, String]): Unit {
  for s in sources {
    match headerClassOf(s) {
      case Some(e) -> {
        if e.cls != "" and not into.containsKey(e.name) {
          into[e.name] = e.cls
        }
      }
      case None -> ()
    }
  }
}

/// Package name -> why the package may not do I/O ("layer 'logic'"), for
/// each project package whose layer's rule does not allow `io`.  The
/// backends pass it to `Lyric.Pipeline`, which reports calls to `@io`
/// functions (Y0003) and protected entries (Y0008) and mutable module
/// state (Y0007) there.
pub func ioForbiddenReasons(cfg: in LayerConfig, pkgs: in List[LayerPackage]): Map[String, String] {
  val ignored: List[LayerDiagnostic] = newList()
  val reasons: Map[String, String] = newMap()
  for p in pkgs {
    if not reasons.containsKey(p.name) {
      var layer = assignedLayer(cfg, p.name, ignored)
      if layer == "" {
        for q in pkgs {
          if q.name == p.name and layer == "" {
            match fileLayerOf(q.file, q.path, ignored) {
              case Some(ann) -> {
                layer = ann.value
              }
              case None -> ()
            }
          }
        }
      }
      if layer != "" {
        match ruleNamed(cfg, layer) {
          case Some(rule) -> {
            if not hasName(rule.layers, "io") {
              reasons[p.name] = "layer '" + layer + "'"
            }
          }
          case None -> ()
        }
      }
    }
  }
  reasons
}
