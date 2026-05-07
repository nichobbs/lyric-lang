// lyric/manifest.l — TOML manifest parser for lyric.toml (Phase 5 §M5.3).
//
// Parses the lyric.toml subset used by the Lyric package system.
// The grammar covers:
//   [package]      — package identity (name, version, description, authors, license)
//   [project]      — project-mode bundling (name, output, output_assembly)
//   [project.packages]  — map of package-name -> source-path
//   [dependencies] — map of package-name -> version constraint
//   [nuget]        — map of NuGet-id -> version string
//   [nuget.options] — target TFM and allow_native flag
//
// Mirrors the F# Manifest.fs parser in compiler/src/Lyric.Cli/Manifest.fs.
// Values in unsupported sections are silently ignored; unrecognised keys in
// known sections produce ManifestError.UnknownKey (not a hard error, reported
// after a successful parse as a warning in the CLI).

package Lyric.Manifest

import Std.Core
import Std.Collections
import Std.Errors
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────

pub union ManifestError {
  /// Syntax error in the TOML source.
  case ParseError(filePath: String, line: Int, column: Int, message: String)
  /// A required field was absent from the manifest.
  case MissingField(section: String, field: String)
  /// A field had a type or value that is not accepted.
  case InvalidField(section: String, field: String, message: String)
}

pub func ManifestError.message(e: in ManifestError): String {
  match e {
    case ParseError(fp, ln, col, msg) ->
      fp + ":" + Str.fromInt(ln) + ":" + Str.fromInt(col) + ": " + msg
    case MissingField(section, field) ->
      "[" + section + "] missing required field '" + field + "'"
    case InvalidField(section, field, msg) ->
      "[" + section + "] invalid value for '" + field + "': " + msg
  }
}

pub record PackageSection {
  name:        String
  version:     String
  description: String
  authors:     List[String]
  license:     String
}

pub record PackageEntry {
  name: String
  path: String
}

pub record ProjectSection {
  name:           String
  output:         String
  outputAssembly: Option[String]
  packages:       List[PackageEntry]
}

pub record DependencyEntry {
  name:    String
  version: String
}

pub record NugetEntry {
  name:    String
  version: String
}

pub record NugetSection {
  entries:     List[NugetEntry]
  target:      Option[String]
  allowNative: Bool
}

/// `[features]` section per `docs/24-build-features.md` (D045).  v1
/// implementation accepts only empty implication arrays per declared
/// feature; non-empty implications are deferred to v1.1.
pub record FeaturesSection {
  /// Declared feature names, sorted alphabetically (excluding the
  /// synthetic `default` key).
  declared: List[String]
  /// Features active when the user passes neither `--features` nor
  /// `--no-default-features`.  Subset of `declared`.
  defaults: List[String]
}

pub record Manifest {
  filePath: String
  package:  PackageSection
  project:  Option[ProjectSection]
  deps:     List[DependencyEntry]
  nuget:    Option[NugetSection]
  features: Option[FeaturesSection]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Internal parser types
// ─────────────────────────────────────────────────────────────────────────────

// Intermediate values before typed assembly.
union Value {
  case VStr(s: String)
  case VStrList(items: List[String])
  case VBool(b: Bool)
  case VInt(n: Int)
}

// A single parsed key-value binding with its TOML section context.
record Entry {
  section: String
  key:     String
  value:   Value
}

// Mutable parsing cursor.
record Cursor {
  text:          String
  mutable pos:   Int
  mutable line:  Int
  mutable col:   Int
}

func makeCursor(text: in String): Cursor {
  Cursor(text = text, pos = 0, line = 1, col = 1)
}

func isAtEnd(c: in Cursor): Bool {
  c.pos >= c.text.length
}

func peek(c: in Cursor): Char {
  c.text[c.pos]
}

func peekAt(c: in Cursor, offset: in Int): Char {
  val idx = c.pos + offset
  if idx < c.text.length { c.text[idx] } else { '\x00' }
}

func skipOne(c: inout Cursor): Unit {
  if not isAtEnd(c) {
    val ch = c.text[c.pos]
    c.pos += 1
    if ch == '\n' { c.line += 1; c.col = 1 } else { c.col += 1 }
  }
}

func skipWhitespace(c: inout Cursor): Unit {
  while not isAtEnd(c) && (peek(c) == ' ' || peek(c) == '\t') {
    skipOne(c)
  }
}

func skipToEndOfLine(c: inout Cursor): Unit {
  while not isAtEnd(c) && peek(c) != '\n' {
    skipOne(c)
  }
  if not isAtEnd(c) { skipOne(c) }
}

func skipBlankAndCommentLines(c: inout Cursor): Unit {
  var keepGoing = true
  while keepGoing && not isAtEnd(c) {
    skipWhitespace(c)
    if isAtEnd(c) {
      keepGoing = false
    } else if peek(c) == '#' || peek(c) == '\n' {
      skipToEndOfLine(c)
    } else {
      keepGoing = false
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Lexing helpers
// ─────────────────────────────────────────────────────────────────────────────

func isIdentChar(ch: in Char): Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
}

// Collect a bare key (alphanumeric, underscores, hyphens).
func parseBareKey(c: inout Cursor): String {
  var key = ""
  while not isAtEnd(c) && isIdentChar(peek(c)) {
    key = key + Str.fromChar(peek(c))
    skipOne(c)
  }
  key
}

// Collect a quoted key or string value (simple double-quoted, no multiline).
// Advances past the closing `"`.  Returns the string content without quotes.
func parseQuotedString(c: inout Cursor, filePath: in String): Result[String, ManifestError] {
  // Caller ensures we're positioned at `"`.
  skipOne(c)  // consume opening `"`
  var s = ""
  while not isAtEnd(c) && peek(c) != '"' && peek(c) != '\n' {
    val ch = peek(c)
    if ch == '\\' {
      skipOne(c)
      if isAtEnd(c) {
        return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated escape"))
      }
      val esc = peek(c)
      skipOne(c)
      if esc == 'n'  { s = s + "\n" }
      else if esc == 't'  { s = s + "\t" }
      else if esc == 'r'  { s = s + "\r" }
      else if esc == '"'  { s = s + "\"" }
      else if esc == '\\' { s = s + "\\" }
      else { s = s + "\\" + Str.fromChar(esc) }
    } else {
      s = s + Str.fromChar(ch)
      skipOne(c)
    }
  }
  if isAtEnd(c) || peek(c) == '\n' {
    return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated string"))
  }
  skipOne(c)  // consume closing `"`
  Ok(value = s)
}

// Parse a TOML key: either bare or quoted.
func parseKey(c: inout Cursor, filePath: in String): Result[String, ManifestError] {
  skipWhitespace(c)
  if isAtEnd(c) {
    Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "expected key"))
  } else if peek(c) == '"' {
    parseQuotedString(c, filePath)
  } else if isIdentChar(peek(c)) {
    Ok(value = parseBareKey(c))
  } else {
    Err(error = ParseError(filePath = filePath, line = c.line, column = c.col,
                           message = "unexpected character '" + Str.fromChar(peek(c)) + "' in key"))
  }
}

// Parse a TOML array of strings: `["item1", "item2"]`.
func parseStringArray(c: inout Cursor, filePath: in String): Result[List[String], ManifestError] {
  skipOne(c)  // consume `[`
  val items = newList[String]()
  var keepGoing = true
  while keepGoing && not isAtEnd(c) {
    skipWhitespace(c)
    if isAtEnd(c) {
      return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated array"))
    }
    val ch = peek(c)
    if ch == ']' {
      skipOne(c)
      keepGoing = false
    } else if ch == '"' {
      match parseQuotedString(c, filePath) {
        case Err(e) -> return Err(error = e)
        case Ok(s)  ->
          items.add(s)
          skipWhitespace(c)
          if not isAtEnd(c) && peek(c) == ',' { skipOne(c) }
      }
    } else if ch == '#' || ch == '\n' {
      skipToEndOfLine(c)
    } else {
      return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col,
                                    message = "expected string or ']' in array"))
    }
  }
  Ok(value = items)
}

// Parse a single TOML value (string, array, bool, integer).
func parseValue(c: inout Cursor, filePath: in String): Result[Value, ManifestError] {
  skipWhitespace(c)
  if isAtEnd(c) {
    return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "expected value"))
  }
  val ch = peek(c)
  if ch == '"' {
    match parseQuotedString(c, filePath) {
      case Err(e) -> Err(error = e)
      case Ok(s)  -> Ok(value = VStr(s = s))
    }
  } else if ch == '[' {
    match parseStringArray(c, filePath) {
      case Err(e)    -> Err(error = e)
      case Ok(items) -> Ok(value = VStrList(items = items))
    }
  } else if ch == 't' && peekAt(c, 1) == 'r' && peekAt(c, 2) == 'u' && peekAt(c, 3) == 'e' {
    skipOne(c); skipOne(c); skipOne(c); skipOne(c)
    Ok(value = VBool(b = true))
  } else if ch == 'f' && peekAt(c, 1) == 'a' && peekAt(c, 2) == 'l' && peekAt(c, 3) == 's' && peekAt(c, 4) == 'e' {
    skipOne(c); skipOne(c); skipOne(c); skipOne(c); skipOne(c)
    Ok(value = VBool(b = false))
  } else if ch >= '0' && ch <= '9' {
    var n = 0
    while not isAtEnd(c) && peek(c) >= '0' && peek(c) <= '9' {
      n = n * 10 + (Char.toInt(peek(c)) - Char.toInt('0'))
      skipOne(c)
    }
    Ok(value = VInt(n = n))
  } else {
    Err(error = ParseError(filePath = filePath, line = c.line, column = c.col,
                           message = "unexpected character '" + Str.fromChar(ch) + "' in value"))
  }
}

// Parse a section header `[section]` or `[section.sub]`.
// Returns the full dotted section name (e.g. "project.packages").
// Cursor must be positioned at `[`.
func parseSectionHeader(c: inout Cursor, filePath: in String): Result[String, ManifestError] {
  skipOne(c)  // consume `[`
  var section = ""
  while not isAtEnd(c) && peek(c) != ']' && peek(c) != '\n' {
    section = section + Str.fromChar(peek(c))
    skipOne(c)
  }
  if isAtEnd(c) || peek(c) == '\n' {
    return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated section header"))
  }
  skipOne(c)  // consume `]`
  Ok(value = Str.trim(section))
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Entry collection pass
// ─────────────────────────────────────────────────────────────────────────────

// Scan the entire source text and produce a flat list of (section, key, value)
// entries.  The list is then assembled into a typed Manifest.
func collectEntries(text: in String, filePath: in String): Result[List[Entry], ManifestError] {
  var c = makeCursor(text)
  val entries = newList[Entry]()
  var currentSection = ""

  while not isAtEnd(c) {
    skipBlankAndCommentLines(c)
    if isAtEnd(c) {
      // done
    } else if peek(c) == '[' {
      match parseSectionHeader(c, filePath) {
        case Err(e)  -> return Err(error = e)
        case Ok(sec) -> currentSection = sec
      }
      skipToEndOfLine(c)
    } else if isIdentChar(peek(c)) || peek(c) == '"' {
      match parseKey(c, filePath) {
        case Err(e)   -> return Err(error = e)
        case Ok(key)  ->
          skipWhitespace(c)
          if isAtEnd(c) || peek(c) != '=' {
            return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col,
                                          message = "expected '=' after key '" + key + "'"))
          }
          skipOne(c)  // consume `=`
          match parseValue(c, filePath) {
            case Err(e) -> return Err(error = e)
            case Ok(v)  ->
              entries.add(Entry(section = currentSection, key = key, value = v))
              skipToEndOfLine(c)
          }
      }
    } else {
      return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col,
                                    message = "unexpected character '" + Str.fromChar(peek(c)) + "'"))
    }
  }
  Ok(value = entries)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Typed assembly
// ─────────────────────────────────────────────────────────────────────────────

// Look up a string entry in the flat list for a given section + key.
func findString(entries: in List[Entry], section: in String, key: in String): Option[String] {
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section && e.key == key {
      match e.value {
        case VStr(s) -> return Some(value = s)
        case _       -> return None
      }
    }
    i += 1
  }
  None
}

func findStringList(entries: in List[Entry], section: in String, key: in String): Option[List[String]] {
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section && e.key == key {
      match e.value {
        case VStrList(items) -> return Some(value = items)
        case _               -> return None
      }
    }
    i += 1
  }
  None
}

func findBool(entries: in List[Entry], section: in String, key: in String, default: in Bool): Bool {
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section && e.key == key {
      match e.value {
        case VBool(b) -> return b
        case _        -> return default
      }
    }
    i += 1
  }
  default
}

func requireString(entries: in List[Entry], section: in String, key: in String): Result[String, ManifestError] {
  match findString(entries, section, key) {
    case Some(s) -> Ok(value = s)
    case None    -> Err(error = MissingField(section = section, field = key))
  }
}

// Collect all entries in a given section as (key, string-value) pairs.
func collectSectionPairs(entries: in List[Entry], section: in String): List[PackageEntry] {
  val result = newList[PackageEntry]()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section {
      match e.value {
        case VStr(s) -> result.add(PackageEntry(name = e.key, path = s))
        case _       -> ()  // non-string values in pair sections are silently ignored
      }
    }
    i += 1
  }
  result
}

func assemblePackage(entries: in List[Entry]): Result[PackageSection, ManifestError] {
  match requireString(entries, "package", "name") {
    case Err(e) -> Err(error = e)
    case Ok(name) ->
      match requireString(entries, "package", "version") {
        case Err(e) -> Err(error = e)
        case Ok(version) ->
          val description = unwrapOr(findString(entries, "package", "description"), "")
          val authors     = unwrapOr(findStringList(entries, "package", "authors"), newList[String]())
          val license     = unwrapOr(findString(entries, "package", "license"), "")
          Ok(value = PackageSection(
            name        = name,
            version     = version,
            description = description,
            authors     = authors,
            license     = license))
      }
  }
}

func hasSection(entries: in List[Entry], section: in String): Bool {
  var i = 0
  while i < entries.count {
    if entries[i].section == section { return true }
    i += 1
  }
  false
}

func assembleProject(entries: in List[Entry]): Option[ProjectSection] {
  if not hasSection(entries, "project") { return None }
  val name           = unwrapOr(findString(entries, "project", "name"), "")
  val output         = unwrapOr(findString(entries, "project", "output"), "single")
  val outputAssembly = findString(entries, "project", "output_assembly")
  val packages       = collectSectionPairs(entries, "project.packages")
  Some(value = ProjectSection(
    name           = name,
    output         = output,
    outputAssembly = outputAssembly,
    packages       = packages))
}

func assembleDeps(entries: in List[Entry]): List[DependencyEntry] {
  val result = newList[DependencyEntry]()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "dependencies" {
      match e.value {
        case VStr(v) -> result.add(DependencyEntry(name = e.key, version = v))
        case _       -> ()
      }
    }
    i += 1
  }
  result
}

// Local helpers used by the [features] assembly below.
func listContains(xs: in List[String], target: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == target { return true }
    i += 1
  }
  false
}

func sortStringList(xs: in List[String]): List[String] {
  // Insertion sort — O(n^2) but list is small (one entry per declared
  // feature) and the sort runs once per build.
  val out = newList[String]()
  var i = 0
  while i < xs.count { out.add(xs[i]); i += 1 }
  var k = 1
  while k < out.count {
    val cur = out[k]
    var j = k
    while j > 0 && out[j - 1] > cur {
      out[j] = out[j - 1]
      j -= 1
    }
    out[j] = cur
    k += 1
  }
  out
}

/// `[features]` per `docs/24-build-features.md` (D045).  v1 accepts
/// only empty implication arrays; a non-empty array on any non-`default`
/// key produces `Err(InvalidField)`.  Returns `Ok(None)` when the
/// section is absent.
func assembleFeatures(entries: in List[Entry]): Result[Option[FeaturesSection], ManifestError] {
  if not hasSection(entries, "features") { return Ok(value = None) }
  val declared = newList[String]()
  var defaults: Option[List[String]] = None
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "features" {
      match e.value {
        case VStrList(items) ->
          if e.key == "default" {
            defaults = Some(value = items)
          } else if items.count > 0 {
            return Err(error = InvalidField(
              section = "features",
              field   = e.key,
              message = "v1 requires an empty array (feature implications are deferred to v1.1)"))
          } else {
            declared.add(e.key)
          }
        case _ ->
          return Err(error = InvalidField(
            section = "features",
            field   = e.key,
            message = "expected an array (use [] for v1)"))
      }
    }
    i += 1
  }
  // Validate every default names a declared feature.
  val defaultList = unwrapOr(defaults, newList[String]())
  var di = 0
  while di < defaultList.count {
    val name = defaultList[di]
    if not listContains(declared, name) {
      return Err(error = InvalidField(
        section = "features",
        field   = "default",
        message = "references undeclared feature '" + name + "'"))
    }
    di += 1
  }
  Ok(value = Some(value = FeaturesSection(
    declared = sortStringList(declared),
    defaults = defaultList)))
}

func assembleNuget(entries: in List[Entry]): Option[NugetSection] {
  if not hasSection(entries, "nuget") { return None }
  val nugetEntries = newList[NugetEntry]()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "nuget" {
      match e.value {
        case VStr(v) -> nugetEntries.add(NugetEntry(name = e.key, version = v))
        case _       -> ()
      }
    }
    i += 1
  }
  val target      = findString(entries, "nuget.options", "target")
  val allowNative = findBool(entries, "nuget.options", "allow_native", false)
  Some(value = NugetSection(
    entries     = nugetEntries,
    target      = target,
    allowNative = allowNative))
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Parse the contents of a `lyric.toml` file.
///
/// `text` is the raw UTF-8 source; `filePath` is used only for error messages.
///
/// Returns `Ok(manifest)` on success or `Err(ManifestError)` on the first
/// fatal parse or validation error.  Unknown keys in recognised sections are
/// silently ignored in this bootstrap-grade parser.
pub func parse(text: in String, filePath: in String): Result[Manifest, ManifestError] {
  match collectEntries(text, filePath) {
    case Err(e)      -> Err(error = e)
    case Ok(entries) ->
      match assemblePackage(entries) {
        case Err(e)   -> Err(error = e)
        case Ok(pkg)  ->
          val project = assembleProject(entries)
          val deps    = assembleDeps(entries)
          val nuget   = assembleNuget(entries)
          match assembleFeatures(entries) {
            case Err(e)         -> Err(error = e)
            case Ok(featuresOpt) ->
              Ok(value = Manifest(
                filePath = filePath,
                package  = pkg,
                project  = project,
                deps     = deps,
                nuget    = nuget,
                features = featuresOpt))
          }
      }
  }
}
