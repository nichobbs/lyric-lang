package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Errors
import Std.ProcessCapture as ProcessCapture
import Lyric.Manifest as Mf
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// `lyric restore --generate-npm-shims` (docs/35 section 9.3, D-progress-1042):
// write `_extern_npm/<package>.l` from the TypeScript declarations an installed
// NPM package ships.  Only plain function declarations whose parameters and
// result are `string`, `number`, `boolean` or `bigint` become host imports;
// everything else is listed in the shim as skipped, to be declared by hand.
// ─────────────────────────────────────────────────────────────────────────────
/// A parameter of a TypeScript function declaration.
pub record DtsParam {
  name: String
  tsType: String
  optional: Bool
}

/// A function declaration found in a `.d.ts`: `declName` is how the file names it,
/// `exportName` the name the package exports it under (`default` for a default or
/// `export =` export), `skip` why it cannot be a host import ("" when it can).
pub record DtsFunc {
  declName: String
  exportName: String
  params: List[DtsParam]
  ret: String
  skip: String
}

/// `text` without `//` and `/* */` comments; string literals are left alone.
pub func stripTsComments(text: in String): String {
  var acc = ""
  var i = 0
  val n = text.length
  while i < n {
    val c = Str.charAtOrReplacement(text, i)
    val d = if i + 1 < n { Str.charAtOrReplacement(text, i + 1) } else { ' ' }
    if c == '/' and d == '/' {
      while i < n and Str.charAtOrReplacement(text, i) != '\n' {
        i += 1
      }
    } else if c == '/' and d == '*' {
      i += 2
      while i + 1 < n and not (Str.charAtOrReplacement(text, i) == '*' and Str.charAtOrReplacement(text, i + 1) == '/') {
        i += 1
      }
      i += 2
      acc = acc + " "
    } else if c == '"' or c == '\'' or c == '`' {
      acc = acc + c.toString()
      i += 1
      while i < n and Str.charAtOrReplacement(text, i) != c {
        if Str.charAtOrReplacement(text, i) == '\\' and i + 1 < n {
          acc = acc + Str.charAtOrReplacement(text, i).toString()
          i += 1
        }
        acc = acc + Str.charAtOrReplacement(text, i).toString()
        i += 1
      }
      if i < n {
        acc = acc + c.toString()
      }
      i += 1
    } else {
      acc = acc + c.toString()
      i += 1
    }
  }
  acc
}

/// The top-level statements of a declaration file: split at a `;` outside any
/// bracket and where a top-level `{ ... }` closes, trimmed and non-empty.
pub func tsStatements(text: in String): List[String] {
  val stmts: List[String] = newList()
  var cur = ""
  var depth = 0
  var i = 0
  val n = text.length
  while i < n {
    val c = Str.charAtOrReplacement(text, i)
    if c == '"' or c == '\'' or c == '`' {
      cur = cur + c.toString()
      i += 1
      while i < n and Str.charAtOrReplacement(text, i) != c {
        if Str.charAtOrReplacement(text, i) == '\\' and i + 1 < n {
          cur = cur + Str.charAtOrReplacement(text, i).toString()
          i += 1
        }
        cur = cur + Str.charAtOrReplacement(text, i).toString()
        i += 1
      }
      if i < n {
        cur = cur + c.toString()
      }
      i += 1
    } else {
      if c == '(' or c == '[' or c == '{' {
        depth += 1
      } else if c == ')' or c == ']' or c == '}' {
        depth -= 1
      }
      cur = cur + c.toString()
      i += 1
      val endsBlock = c == '}' and depth == 0
      if (c == ';' and depth == 0) or endsBlock {
        val t = Str.trim(cur)
        if t.length > 0 and t != ";" {
          stmts.add(if Str.endsWith(t, ";") { Str.trim(Str.substring(t, 0, t.length - 1)) } else { t })
        }
        cur = ""
      }
    }
  }
  val tail = Str.trim(cur)
  if tail.length > 0 {
    stmts.add(tail)
  }
  stmts
}

/// `s` split at commas that are not inside `()`, `[]`, `{}` or `<>`.
pub func splitTopLevelCommas(s: in String): List[String] {
  val parts: List[String] = newList()
  var cur = ""
  var depth = 0
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '(' or c == '[' or c == '{' or c == '<' {
      depth += 1
    } else if c == ')' or c == ']' or c == '}' or c == '>' {
      depth -= 1
    }
    if c == ',' and depth == 0 {
      parts.add(Str.trim(cur))
      cur = ""
    } else {
      cur = cur + c.toString()
    }
    i += 1
  }
  val tail = Str.trim(cur)
  if tail.length > 0 {
    parts.add(tail)
  }
  parts
}

/// The index of the `)` matching the `(` at `open`, or -1.
func matchingParen(s: in String, open: in Int): Int {
  var depth = 0
  var i = open
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '(' {
      depth += 1
    } else if c == ')' {
      depth -= 1
      if depth == 0 {
        return i
      }
    }
    i += 1
  }
  -1
}

func stripWord(s: in String, word: in String): Option[String] {
  if Str.startsWith(s, word + " ") {
    Some(value = Str.trim(Str.substring(s, word.length)))
  } else {
    None
  }
}

func tsIdentEnd(s: in String, from: in Int): Int {
  var i = from
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$'
    if not ok {
      return i
    }
    i += 1
  }
  i
}

/// The TypeScript type as a Lyric type name, or "" when it is not one of the four
/// plain ones.
pub func tsToLyricType(t: in String): String {
  match Str.trim(t) {
    case "string" -> "String"
    case "number" -> "Double"
    case "boolean" -> "Bool"
    case "bigint" -> "Long"
    case _ -> ""
  }
}

/// One function declaration statement, or None when the statement is not one.
/// `exported` and `isDefault` report the `export` and `export default` prefixes.
func parseFunctionStatement(stmt: in String): Option[(DtsFunc, Bool, Bool)] {
  var rest = stmt
  var exported = false
  var isDefault = false
  match stripWord(rest, "export") {
    case Some(r) -> {
      rest = r
      exported = true
    }
    case None -> ()
  }
  match stripWord(rest, "declare") {
    case Some(r) -> {
      rest = r
    }
    case None -> ()
  }
  if exported {
    match stripWord(rest, "default") {
      case Some(r) -> {
        rest = r
        isDefault = true
      }
      case None -> ()
    }
  }
  match stripWord(rest, "function") {
    case None -> return None
    case Some(r) -> {
      rest = r
    }
  }
  var skip = ""
  if Str.startsWith(rest, "*") {
    skip = "a generator"
    rest = Str.trim(Str.substring(rest, 1))
  }
  val nameEnd = tsIdentEnd(rest, 0)
  val name = Str.substring(rest, 0, nameEnd)
  val afterName = Str.trim(Str.substring(rest, nameEnd))
  if Str.startsWith(afterName, "<") {
    skip = "generic"
  }
  val open = Str.indexOfRaw(afterName, "(")
  if open < 0 {
    return None
  }
  val close = matchingParen(afterName, open)
  if close < 0 {
    return None
  }
  val params: List[DtsParam] = newList()
  for p in splitTopLevelCommas(Str.substring(afterName, open + 1, close - open - 1)) {
    if Str.startsWith(p, "...") {
      skip = "a rest parameter"
    } else if Str.startsWith(p, "{") or Str.startsWith(p, "[") {
      skip = "a destructured parameter"
    } else {
      val colon = Str.indexOfRaw(p, ":")
      if colon < 0 {
        skip = "a parameter without a type"
      } else {
        var pn = Str.trim(Str.substring(p, 0, colon))
        var opt = false
        if Str.endsWith(pn, "?") {
          opt = true
          pn = Str.trim(Str.substring(pn, 0, pn.length - 1))
        }
        params.add(DtsParam(name = pn, tsType = Str.trim(Str.substring(p, colon + 1)), optional = opt))
      }
    }
  }
  val tail = Str.trim(Str.substring(afterName, close + 1))
  val ret = if Str.startsWith(tail, ":") { Str.trim(Str.substring(tail, 1)) } else { "" }
  val exportName = if isDefault { "default" } else { name }
  Some(
    value = (
      DtsFunc(declName = name, exportName = exportName, params = params, ret = ret, skip = skip),
      exported,
      isDefault
    )
  )
}

/// The names `export { a, b as c }` makes visible, as (declared, exported) pairs.
func parseExportList(stmt: in String): List[(String, String)] {
  val pairs: List[(String, String)] = newList()
  val open = Str.indexOfRaw(stmt, "{")
  val close = Str.lastIndexOfRaw(stmt, "}")
  if open < 0 or close <= open or Str.contains(stmt, " from ") {
    return pairs
  }
  for item in splitTopLevelCommas(Str.substring(stmt, open + 1, close - open - 1)) {
    val parts = Str.split(item, " as ")
    if parts.length == 2 {
      pairs.add((Str.trim(parts[0]), Str.trim(parts[1])))
    } else if parts.length == 1 and Str.trim(parts[0]).length > 0 {
      pairs.add((Str.trim(parts[0]), Str.trim(parts[0])))
    }
  }
  pairs
}

/// The functions a declaration file exports, with the reason any of them cannot
/// be a host import.  Overloads (one export name declared more than once) are
/// reported once, as skipped.
pub func parseDtsFunctions(text: in String): List[DtsFunc] {
  val declared: List[DtsFunc] = newList()
  val inlineExported: List[Bool] = newList()
  val aliases: List[(String, String)] = newList()
  var exportEquals = ""
  for stmt in tsStatements(stripTsComments(text)) {
    match parseFunctionStatement(stmt) {
      case Some((f, exported, _)) -> {
        declared.add(f)
        inlineExported.add(exported)
      }
      case None -> {
        match stripWord(stmt, "export =") {
          case Some(r) -> {
            exportEquals = Str.trim(r)
          }
          case None -> {
            if Str.startsWith(stmt, "export {") or Str.startsWith(stmt, "export{") {
              for pair in parseExportList(stmt) {
                aliases.add(pair)
              }
            } else {
              match stripWord(stmt, "export default") {
                case Some(r) -> {
                  val ident = Str.trim(r)
                  if tsIdentEnd(ident, 0) == ident.length and ident.length > 0 {
                    aliases.add((ident, "default"))
                  }
                }
                case None -> ()
              }
            }
          }
        }
      }
    }
  }
  val result: List[DtsFunc] = newList()
  var i = 0
  while i < declared.count {
    val f = declared[i]
    val names: List[String] = newList()
    if inlineExported[i] {
      names.add(f.exportName)
    }
    if exportEquals.length > 0 and exportEquals == f.declName {
      names.add("default")
    }
    for pair in aliases {
      val (decl, exp) = pair
      if decl == f.declName {
        names.add(exp)
      }
    }
    for nm in names {
      result.add(DtsFunc(declName = f.declName, exportName = nm, params = f.params, ret = f.ret, skip = f.skip))
    }
    i += 1
  }
  val unique: List[DtsFunc] = newList()
  for f in result {
    var count = 0
    for g in result {
      if g.exportName == f.exportName {
        count += 1
      }
    }
    var seen = false
    for u in unique {
      if u.exportName == f.exportName {
        seen = true
      }
    }
    if not seen {
      if count > 1 {
        unique.add(
          DtsFunc(declName = f.declName, exportName = f.exportName, params = f.params, ret = f.ret, skip = "overloaded")
        )
      } else {
        unique.add(f)
      }
    }
  }
  unique
}

/// A Lyric identifier for a JavaScript name: other characters become `_`, a
/// leading digit gets a `_` prefix and a keyword a `_` suffix.
pub func lyricIdent(js: in String): String {
  var acc = ""
  var i = 0
  while i < js.length {
    val c = Str.charAtOrReplacement(js, i)
    val ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
    acc = acc + (if ok { c.toString() } else { "_" })
    i += 1
  }
  if acc.length == 0 {
    return "_"
  }
  val first = Str.charAtOrReplacement(acc, 0)
  if first >= '0' and first <= '9' {
    acc = "_" + acc
  }
  match tryKeywordFromString(acc) {
    case Some(_) -> acc + "_"
    case None -> acc
  }
}

func lowerFirst(s: in String): String {
  if s.length == 0 {
    return s
  }
  val first = Str.charAtOrReplacement(s, 0)
  if first >= 'A' and first <= 'Z' {
    Str.toLower(Str.substring(s, 0, 1)) + Str.substring(s, 1)
  } else {
    s
  }
}

/// The skip reason of `f` for use as a host import, or "" when its signature is
/// plain enough: only `string`, `number`, `boolean` and `bigint` parameters, no
/// optional ones, and one of those or `void` as the result.
func importSkipReason(f: in DtsFunc): String {
  if f.skip.length > 0 {
    return f.skip
  }
  for p in f.params {
    if p.optional {
      return "optional parameter " + p.name
    }
    if tsToLyricType(p.tsType).length == 0 {
      return "parameter " + p.name + ": " + p.tsType
    }
  }
  val r = Str.trim(f.ret)
  if r != "void" and r != "undefined" and tsToLyricType(r).length == 0 {
    return "returns " + (if r.length == 0 { "an unknown type" } else { r })
  }
  ""
}

/// The marker the generated header opens with, so a later run can tell a
/// generated file from a hand-authored one.
pub func npmShimGeneratedMarker(): String {
  "// Generated by `lyric restore --generate-npm-shims`"
}

/// The shim text for `e` from the functions of its declaration file `typesFile`.
pub func renderGeneratedShim(e: in Mf.NpmEntry, typesFile: in String, funcs: in List[DtsFunc]): String {
  val lines: List[String] = newList()
  lines.add("@axiom(\"from npm " + e.name + " " + e.version + "\")")
  lines.add("package " + e.ident)
  lines.add("")
  lines.add(npmShimGeneratedMarker() + " from " + typesFile + ".")
  lines.add("// Only plain string/number/boolean/bigint functions are declared (a number is a Double);")
  lines.add("// anything else is listed as skipped: declare it by hand below. A restore never overwrites this file.")
  val used: Map[String, Bool] = newMap()
  for f in funcs {
    val reason = importSkipReason(f)
    if reason.length > 0 {
      lines.add("// skipped " + f.exportName + ": " + reason)
    } else {
      val base = if f.exportName == "default" { lowerFirst(Mf.npmPackageIdent(e.name)) } else { lyricIdent(f.exportName) }
      var fname = lyricIdent(base)
      while used.containsKey(fname) {
        fname = fname + "_"
      }
      used.add(fname, true)
      val ps: List[String] = newList()
      for p in f.params {
        ps.add(lyricIdent(p.name) + ": " + tsToLyricType(p.tsType))
      }
      val r = Str.trim(f.ret)
      val retText = if r == "void" or r == "undefined" { "" } else { ": " + tsToLyricType(r) }
      lines.add("")
      lines.add("@wasmImport(\"npm:" + e.name + "\")")
      lines.add("pub extern func " + fname + "(" + Str.joinList(", ", ps) + ")" + retText + " = \"" + f.exportName + "\"")
    }
  }
  Str.joinList("\n", lines) + "\n"
}

/// The script that finds a package's declaration file: `types`/`typings` of its
/// `package.json`, else its `main` with a `.d.ts` extension, else `index.d.ts`,
/// else `@types/<name>`.  Run beside `node_modules` with the install directory
/// and the package name.
pub func npmTypesScript(): String {
  r"import fs from 'node:fs';
import path from 'node:path';
const [, , root, name] = process.argv;
const dir = path.join(root, 'node_modules', name);
let rel = '';
try {
  const pj = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  rel = pj.types || pj.typings || '';
  if (!rel && typeof pj.main === 'string') {
    const cand = pj.main.replace(/\.[cm]?js$/, '.d.ts');
    if (fs.existsSync(path.join(dir, cand))) rel = cand;
  }
} catch (e) {}
if (!rel && fs.existsSync(path.join(dir, 'index.d.ts'))) rel = 'index.d.ts';
if (rel) {
  console.log(path.join(dir, rel));
} else {
  const alt = path.join(root, 'node_modules', '@types', name.startsWith('@') ? name.slice(1).replace('/', '__') : name, 'index.d.ts');
  if (fs.existsSync(alt)) console.log(alt);
}
"
}

/// The declaration file of the installed package `name`, or "".
func findTypesFile(installDir: in String, name: in String): String {
  val scriptPath = Path.join(installDir, "lyric-npm-types.mjs")
  match File.writeText(scriptPath, npmTypesScript()) {
    case Err(_) -> return ""
    case Ok(_) -> ()
  }
  val args: List[String] = newList()
  args.add(scriptPath)
  args.add(installDir)
  args.add(name)
  val r = ProcessCapture.runCaptureWithDiagnosticsTimeout("node", args, "", 60000)
  if r.exitCode != 0 {
    return ""
  }
  Str.trim(r.stdout)
}

/// Whether the existing shim `text` may be replaced without `--force`: it is
/// the plain scaffold, or an earlier generated file.
pub func npmShimReplaceable(text: in String, e: in Mf.NpmEntry): Bool {
  text == npmShimStub(e) or Str.contains(text, npmShimGeneratedMarker())
}

/// `lyric restore --generate-npm-shims`: for each `[npm]` package write its shim
/// from the installed package's declarations.  A shim that is neither the
/// scaffold nor generated is left alone unless `force`.  Returns 0, or 1 when a
/// shim could not be written.
pub func generateNpmShims(manifest: in Mf.Manifest, mfDir: in String, force: in Bool): Int {
  val npm = match manifest.npm { case Some(n) -> n; case None -> return 0 }
  val installDir = Path.join(Path.join(mfDir, "target"), "npm")
  val shimDir = Path.join(mfDir, "_extern_npm")
  match File.createDir(shimDir) {
    case Err(err) -> {
      printErr("restore: cannot create " + shimDir + ": " + IOError.message(err))
      return 1
    }
    case Ok(_) -> ()
  }
  for e in npm.entries {
    val typesFile = findTypesFile(installDir, e.name)
    if typesFile.length == 0 {
      Console.println("restore: " + e.name + ": no type declarations found; the shim stays as it is")
      continue
    }
    val dts = match File.readText(typesFile) {
      case Ok(t) -> t
      case Err(err) -> {
        printErr("restore: cannot read " + typesFile + ": " + IOError.message(err))
        return 1
      }
    }
    val text = renderGeneratedShim(e, Path.basename(typesFile), parseDtsFunctions(dts))
    val shimPath = Path.join(shimDir, Mf.npmShimFileName(e.name))
    if File.fileExists(shimPath) {
      val existing = match File.readText(shimPath) { case Ok(t) -> t; case Err(_) -> "" }
      if not force and not npmShimReplaceable(existing, e) {
        Console.println("restore: " + e.name + ": " + shimPath + " is hand-edited; pass --force to regenerate it")
        continue
      }
    }
    match File.writeText(shimPath, text) {
      case Err(err) -> {
        printErr("restore: cannot write " + shimPath + ": " + IOError.message(err))
        return 1
      }
      case Ok(_) -> Console.println("restore: wrote " + shimPath + " from " + Path.basename(typesFile))
    }
  }
  0
}
