//! resolve_lookup.l - the §4.3 lookup (docs/70, D313).
//!
//! The functions here are the resolver's only reads of the declaration table.
//! Each takes the scope of the file the name is written in.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

func useAccepts(use: in NameUse, kind: in SymKind): Bool {
  match use {
    case UseType -> symKindIsType(kind)
    case _ -> true
  }
}

// The newest registration of each declaration named `name`, in registration
// order: a package registered twice (as a source and as a dependency) is one
// DefPath, so one candidate.
func namedDecls(tbl: in DeclTable, name: in String, use: in NameUse): List[Decl] {
  val out: List[Decl] = newList()
  match mapGet(tbl.byName, name) {
    case None -> ()
    case Some(ixs) -> {
      for ix in ixs {
        val d = tbl.decls[ix]
        match mapGet(tbl.byId, toString(d.id.id)) {
          case Some(last) -> {
            if last == ix and useAccepts(use, d.kind) {
              out.add(d)
            }
          }
          case None -> ()
        }
      }
    }
  }
  out
}

func declsOfPackageNamed(tbl: in DeclTable, pkg: in String, name: in String): List[Decl] {
  val out: List[Decl] = newList()
  for d in namedDecls(tbl, name, UseValue) {
    if d.pkg == pkg {
      out.add(d)
    }
  }
  out
}

// The cases of the union or enum with id `owner`.
func casesOf(tbl: in DeclTable, owner: in SymbolId): List[Decl] {
  val out: List[Decl] = newList()
  for d in tbl.decls {
    match d.parent {
      case Some(pid) -> {
        if pid.id == owner.id and symKindIsCase(d.kind) {
          match mapGet(tbl.byId, toString(d.id.id)) {
            case Some(_) -> out.add(d)
            case None -> ()
          }
        }
      }
      case None -> ()
    }
  }
  out
}

func isPreludeName(name: in String): Bool {
  name == "Option" or name == "Result"
}

func inPrelude(tbl: in DeclTable, d: in Decl): Bool {
  if d.pkg != "Std.Core" {
    return false
  }
  if isPreludeName(d.name) {
    return true
  }
  match d.parent {
    case Some(pid) -> match declOfId(tbl, pid) {
      case Some(p) -> isPreludeName(p.name)
      case None -> false
    }
    case None -> false
  }
}

func bindingCovers(tbl: in DeclTable, b: in NameBinding, d: in Decl): Bool {
  if b.origName != d.name {
    return false
  }
  if d.pkg == b.pkg {
    return true
  }
  reexportClosure(tbl, b.pkg).contains(d.pkg)
}

// A candidate and how the file reaches it.
record Candidate {
  decl: Decl
  direct: Bool
  via: String
}

func addCandidate(out: in List[Candidate], seen: in Map[String, Int], d: in Decl, direct: in Bool, via: in String): Unit {
  val key = toString(d.id.id)
  match mapGet(seen, key) {
    case Some(ix) -> {
      // A direct reach beats a re-export reach of the same declaration.
      if direct and not out[ix].direct {
        out[ix] = Candidate(decl = d, direct = true, via = via)
      }
    }
    case None -> {
      seen.add(key, out.count)
      out.add(Candidate(decl = d, direct = direct, via = via))
    }
  }
}

func joinQuoted(names: in List[String]): String {
  var s = ""
  var i = 0
  while i < names.count {
    if i > 0 {
      s = s + ", "
    }
    s = s + "'" + names[i] + "'"
    i = i + 1
  }
  s
}

func packagesOf(cands: in List[Candidate]): List[String] {
  val pkgs: List[String] = newList()
  for c in cands {
    if not pkgs.contains(c.decl.pkg) {
      pkgs.add(c.decl.pkg)
    }
  }
  pkgs
}

func unknownNameCode(use: in NameUse): String {
  match use {
    case UseType -> "T0010"
    case _ -> "T0020"
  }
}

func unknownNameMessage(use: in NameUse, name: in String): String {
  match use {
    case UseType -> "unknown type name '" + name + "'"
    case _ -> "unknown name '" + name + "'"
  }
}

// The declarations at one step, as a resolution: one package's overload set,
// one declaration, or T0123 when packages collide.
func resolveCandidates(cands: in List[Candidate], name: in String, how: in String): Resolution {
  val pkgs = packagesOf(cands)
  if pkgs.count > 1 {
    return RUnresolved(
      code = "T0123",
      message = "'" + name + "' is ambiguous: it is declared by " + joinQuoted(pkgs) + ", all " + how +
        " - qualify the reference (e.g. '" + pkgs[0] + "." + name + "')"
    )
  }
  val ids: List[SymbolId] = newList()
  var allFuncs = true
  for c in cands {
    ids.add(c.decl.id)
    if not symKindIsFunc(c.decl.kind) {
      allFuncs = false
    }
  }
  if allFuncs and ids.count > 1 {
    return ROverloads(ids = ids)
  }
  // One declaration, or a type and a function of one name in one package: the
  // newest registration (the checker's rule, kept until the differential
  // phase says otherwise).
  RSymbol(id = ids[ids.count - 1])
}

// The hint that says how to import a name a loaded package declares: the
// newest declaration of `name` in another package, `pub` or `internal` ones
// first.
func hiddenImportHint(tbl: in DeclTable, scope: in FileScope, name: in String, use: in NameUse): String {
  var pass = 0
  while pass < 2 {
    for d in reverseOf(namedDecls(tbl, name, use)) {
      if d.pkg != scope.pkg and d.pkg.length > 0 and (pass == 1 or declCrossPackageVisible(d)) {
        return importHintFor(tbl, scope, d, name)
      }
    }
    pass = pass + 1
  }
  ""
}

func reverseOf(ds: in List[Decl]): List[Decl] {
  val out: List[Decl] = newList()
  var i = ds.count - 1
  while i >= 0 {
    out.add(ds[i])
    i = i - 1
  }
  out
}

func parentNameOf(tbl: in DeclTable, d: in Decl): String {
  match d.parent {
    case Some(pid) -> match declOfId(tbl, pid) {
      case Some(p) -> p.name
      case None -> ""
    }
    case None -> ""
  }
}

// The package a file imports to reach a kernel host package (`Std.XHost`
// behind `Std.X`): the public package when it is loaded and re-exports it.
func publicPackageOf(tbl: in DeclTable, pkg: in String): String {
  if not pkg.endsWith("Host") {
    return pkg
  }
  val home = pkg.substring(0, pkg.length - 4)
  match mapGet(tbl.packages, home) {
    case Some(info) -> if info.reexports.contains(pkg) { home } else { pkg }
    case None -> pkg
  }
}

func importHintFor(tbl: in DeclTable, scope: in FileScope, d: in Decl, name: in String): String {
  val origin = d.pkg
  for alias in mapKeys(scope.aliases) {
    if scope.aliases[alias] == origin {
      return " (declared in " + origin + ", imported as " + alias + "; write " + alias + "." + name + ")"
    }
  }
  val parent = parentNameOf(tbl, d)
  val shown = if parent.length > 0 { parent } else { name }
  val home = publicPackageOf(tbl, origin)
  if home != origin {
    return " (declared in " + origin + "; add import " + home + ")"
  }
  " (declared in " + origin + "; add import " + origin + " or import " + origin + ".{" + shown + "})"
}

/// Resolve the bare name `name`, written in the file `scope` belongs to, at
/// steps 2-4 of §4.3.  The caller answers step 1 (locals) first.
pub func resolveBare(tbl: in DeclTable, scope: in FileScope, name: in String, use: in NameUse): Resolution {
  // Step 2: the file's own package, any file.
  val own: List[Candidate] = newList()
  val ownSeen: Map[String, Int] = newMap()
  for d in namedDecls(tbl, name, use) {
    if d.pkg == scope.pkg {
      addCandidate(own, ownSeen, d, true, "")
    }
  }
  if own.count > 0 {
    return resolveCandidates(own, name, "declared by this package")
  }
  // Step 3: what the file imports.
  val reached: List[Candidate] = newList()
  val seen: Map[String, Int] = newMap()
  val hidden: List[Decl] = newList()
  for d in namedDecls(tbl, name, use) {
    if d.pkg != scope.pkg and scope.whole.containsKey(d.pkg) {
      val r = scope.whole[d.pkg]
      val direct = match r {
        case ReachDirect(_) -> true
        case ReachReexport(_) -> false
      }
      val via = match r {
        case ReachDirect(v) -> v
        case ReachReexport(v) -> v
      }
      if declCrossPackageVisible(d) {
        addCandidate(reached, seen, d, direct, via)
      } else {
        hidden.add(d)
      }
    }
  }
  match mapGet(scope.names, name) {
    case Some(bindings) -> {
      for b in bindings {
        if b.pkg == "extern" {
          val extId = internDefPath(tbl.interner, externTypeDefPath(b.origName))
          match declOfId(tbl, extId) {
            case Some(d) -> {
              if useAccepts(use, d.kind) {
                addCandidate(reached, seen, d, true, b.via)
              }
            }
            case None -> ()
          }
        } else {
          for d in namedDecls(tbl, b.origName, use) {
            if bindingCovers(tbl, b, d) {
              if declCrossPackageVisible(d) {
                addCandidate(reached, seen, d, true, b.via)
              } else {
                hidden.add(d)
              }
            }
          }
        }
      }
    }
    case None -> ()
  }
  val direct: List[Candidate] = newList()
  val reexported: List[Candidate] = newList()
  for c in reached {
    if c.direct {
      direct.add(c)
    } else {
      reexported.add(c)
    }
  }
  if direct.count > 0 {
    return resolveCandidates(direct, name, "imported by this file")
  }
  if reexported.count > 0 {
    return resolveCandidates(reexported, name, "reached through this file's imports")
  }
  // Step 4: the prelude.
  val prelude: List[Candidate] = newList()
  val preludeSeen: Map[String, Int] = newMap()
  for d in namedDecls(tbl, name, use) {
    if inPrelude(tbl, d) {
      addCandidate(prelude, preludeSeen, d, true, "")
    }
  }
  if prelude.count > 0 {
    return resolveCandidates(prelude, name, "in the prelude")
  }
  if hidden.count > 0 {
    return RUnresolved(
      code = "T0097",
      message = "'" + name + "' is package-private and cannot be referenced from another package " +
        "(mark it `pub` or `internal`)"
    )
  }
  RUnresolved(
    code = unknownNameCode(use),
    message = unknownNameMessage(use, name) + hiddenImportHint(tbl, scope, name, use)
  )
}

/// What a path resolved to and how many of its segments that used.  The rest
/// are members, left to the checker (§4.5).
pub record PathResolution {
  res: Resolution
  consumed: Int
}

// `name` as package `pkg` declares it, or re-exports it; a declaration of the
// package itself wins over a re-exported one (docs/01 §9.3).
func resolveInPackage(
  tbl: in DeclTable, scope: in FileScope, pkg: in String, name: in String, use: in NameUse
): Resolution {
  val pkgs: List[String] = newList()
  pkgs.add(pkg)
  for q in reexportClosure(tbl, pkg) {
    pkgs.add(q)
  }
  for p in pkgs {
    val cands: List[Candidate] = newList()
    val seen: Map[String, Int] = newMap()
    var sawPrivate = false
    for d in namedDecls(tbl, name, use) {
      if d.pkg == p {
        if p == scope.pkg or declCrossPackageVisible(d) {
          addCandidate(cands, seen, d, true, "")
        } else {
          sawPrivate = true
        }
      }
    }
    if cands.count > 0 {
      return resolveCandidates(cands, name, "declared by " + p)
    }
    if sawPrivate {
      return RUnresolved(
        code = "T0097",
        message = "'" + name + "' is package-private and cannot be referenced from another package " +
          "(mark it `pub` or `internal`)"
      )
    }
  }
  RUnresolved(
    code = unknownNameCode(use),
    message = unknownNameMessage(use, pkg + "." + name)
  )
}

func joinSegments(segs: in List[String], count: in Int): String {
  var s = ""
  var i = 0
  while i < count {
    if i > 0 {
      s = s + "."
    }
    s = s + segs[i]
    i = i + 1
  }
  s
}

// The package a leading run of `segs` names in this file: an alias, the file's
// own package, or the full path of a package the file imports in any form.
// Returns the segment count it used, or 0.
func leadingPackage(scope: in FileScope, segs: in List[String]): Option[PackagePrefix] {
  var k = segs.count
  while k >= 1 {
    val text = joinSegments(segs, k)
    if k == 1 and scope.aliases.containsKey(text) {
      return Some(value = PackagePrefix(pkg = scope.aliases[text], count = k))
    }
    if text == scope.pkg or scope.directPkgs.containsKey(text) {
      return Some(value = PackagePrefix(pkg = text, count = k))
    }
    k = k - 1
  }
  None
}

record PackagePrefix {
  pkg: String
  count: Int
}

// The longest leading run of `segs` that names a loaded package the file does
// not import, for the "not imported" diagnostic.
func unimportedPackagePrefix(tbl: in DeclTable, segs: in List[String]): String {
  var k = segs.count
  while k >= 1 {
    val text = joinSegments(segs, k)
    if tbl.packages.containsKey(text) {
      return text
    }
    k = k - 1
  }
  ""
}

/// Resolve a dotted path `segs` written in the file `scope` belongs to: a
/// qualified reference through a package the file names (an alias, the full
/// path of a package it imports, or its own package), or a bare name followed
/// by members.  A package the file does not import cannot be named, even when
/// an imported package imports it (§4.3).
pub func resolvePath(tbl: in DeclTable, scope: in FileScope, segs: in List[String], use: in NameUse): PathResolution {
  if segs.count == 0 {
    return PathResolution(res = RUnresolved(code = "T0020", message = "empty path"), consumed = 0)
  }
  match leadingPackage(scope, segs) {
    case Some(prefix) -> {
      if prefix.count == segs.count {
        return PathResolution(res = RPackage(pkg = prefix.pkg), consumed = prefix.count)
      }
      val res = resolveInPackage(tbl, scope, prefix.pkg, segs[prefix.count], use)
      return PathResolution(res = res, consumed = prefix.count + 1)
    }
    case None -> ()
  }
  val first = resolveBare(tbl, scope, segs[0], if segs.count == 1 { use } else { UseValue })
  match first {
    case RUnresolved(_, _) -> {
      if segs.count > 1 {
        val unimported = unimportedPackagePrefix(tbl, segs)
        if unimported.length > 0 {
          return PathResolution(
            res = RUnresolved(
              code = unknownNameCode(use),
              message = "unknown name '" + joinSegments(segs, segs.count) + "' (package " + unimported +
                " is not imported; add import " + unimported + ")"
            ),
            consumed = 0
          )
        }
      }
      PathResolution(res = first, consumed = 0)
    }
    case _ -> PathResolution(res = first, consumed = 1)
  }
}
