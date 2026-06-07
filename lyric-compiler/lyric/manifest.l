//! lyric/manifest.l — TOML manifest parser for lyric.toml (Phase 5 §M5.3).
//!
//! Parses the lyric.toml subset used by the Lyric package system.
//! The grammar covers:
//!   [package]           — package identity (name, version, description, authors, license)
//!   [project]           — project-mode bundling (name, output, output_assembly)
//!   [project.packages]  — map of package-name -> source-path
//!   [dependencies]      — map of package-name -> dep-source (string, inline-table)
//!   [nuget]             — map of NuGet-id -> version string
//!   [nuget.options]     — target TFM and allow_native flag
//!   [workspace]         — workspace root declaration (exclude list, overrides)
//!   [workspace.overrides] — per-package path overrides for fork/patch workflows
//!   [registry]          — custom registry feed URLs
//!
//! Supported dependency source forms in [dependencies]:
//!   "1.0.0"                             — registry form (version string)
//!   { workspace = true }                — workspace-local source
//!   { workspace = true, version = "x" } — workspace-local with version check
//!   { path = "../relative/dir" }        — local path
//!   { git = "https://...", tag = "v1" } — git tag (immutable)
//!   { git = "https://...", rev = "sha"} — git commit (immutable)
//!   { git = "https://...", branch = "main" } — git branch (mutable, warns)
//!   { git = "...", tag = "v1", subdir = "lyric-foo" } — monorepo subdir
//!   Any form may include:  registry = "https://..."
//!
//! Mirrors the F# Manifest.fs parser in compiler/src/Lyric.Cli/Manifest.fs.
//! Values in unsupported sections are silently ignored; unrecognised keys in
//! known sections produce ManifestError.UnknownKey (not a hard error, reported
//! after a successful parse as a warning in the CLI).
package Lyric.Manifest

import Std.Core
import Std.Char
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
    case ParseError(fp, ln, col, msg) -> fp + ":" + toString(ln) + ":" + toString(col) + ": " + msg
    // `toString`, not `Str.fromInt`: this file imports Std.String and Std.Char,
    // and the F# emitter mis-resolves `Str.fromInt` to `Std.Char.fromInt`,
    // rendering line/column as garbled characters (same root as #2082).
    case MissingField(section, field) -> "[" + section + "] missing required field '" + field + "'"
    case InvalidField(section, field, msg) -> "[" + section + "] invalid value for '" + field + "': " + msg
  }
}

pub record PackageSection {
  name: String
  version: String
  description: String
  authors: List[String]
  license: String
  repository: Option[String]
  /// Package kind — `Some("source-generator")` for generator packages,
  /// `None` for normal library or application packages.
  kind: Option[String]
}

pub record PackageEntry {
  name: String
  path: String
}

pub record ProjectSection {
  name: String
  output: String
  outputAssembly: Option[String]
  packages: List[PackageEntry]
  // `[project.tests]` entries.  Mapping from synthetic-package-name
  // (e.g. "Auth.AuthSecurityTests") to test file path.  Consumed by
  // `lyric test --manifest <toml>` (#465).
  tests: List[PackageEntry]
}

// ── Dependency source forms ──────────────────────────────────────────────────
pub union DepSource {
  /// Plain version string resolved from the configured registry.
  case Registry(version: String)
  /// Workspace-local source. `version` is an optional constraint against the
  /// member's declared version.
  case Workspace(version: Option[String])
  /// Local filesystem path (relative to the manifest directory).
  case Path(dir: String)
  /// Git repository source.  The ref is stored as two primitive fields
  /// (`refKind` in {"tag","rev","branch"}, `refValue` the name/SHA) rather than
  /// a nested `GitRef` union: the F# stage-0 emitter reads a union-typed field
  /// of a union case back as null (#2126), so the typed `ref: GitRef` arrived
  /// null at consumers.  The flat encoding round-trips correctly on both
  /// emitters; callers use the `refKind` and `refValue` fields directly.
  case Git(url: String, refKind: String, refValue: String, subdir: Option[String])
}

pub record DependencyEntry {
  name: String
  source: DepSource
  /// Per-dependency registry override URL (overrides `[registry].dotnet`).
  registry: Option[String]
}

pub record NugetEntry {
  name: String
  version: String
}

pub record NugetSection {
  entries: List[NugetEntry]
  target: Option[String]
  allowNative: Bool
}

/// A single `[maven]` coordinate entry per `docs/31-maven-linking.md` (D053).
/// `group`/`artifact` are the two halves of the `groupId:artifactId` key
/// (split on the single `:`); `version` is the resolved version string
/// (passed opaquely to the resolver).
pub record MavenEntry {
  group: String
  artifact: String
  version: String
}

/// `[maven]` section per `docs/31-maven-linking.md` (D053).  Parallels
/// `NugetSection`.  `repositories` defaults to `["central"]` (Maven Central);
/// `javaVersion` is `None` when the `[maven.options]` `java_version` key is
/// absent (the resolver then substitutes the project's `jvm_target`).
pub record MavenSection {
  entries: List[MavenEntry]
  repositories: List[String]
  javaVersion: Option[String]
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

// ── Workspace types ──────────────────────────────────────────────────────────
/// A single `[workspace.overrides]` entry.
pub record WorkspaceOverride {
  /// Lyric package name (e.g. `"Lyric.Cache"`).
  name: String
  /// Directory to use instead of the workspace-discovered or registry-resolved
  /// source.  Relative to the workspace root; the resolver makes it absolute.
  dir: String
}

/// `[workspace]` table in the root `lyric.toml`.
pub record WorkspaceSection {
  /// Root-relative path prefixes to exclude from member discovery.
  exclude: List[String]
  /// Per-package path overrides for fork/patch workflows.
  overrides: List[WorkspaceOverride]
}

/// Per-target custom registry feed URLs from `[registry]`.
pub record RegistryConfig {
  dotnet: Option[String]
  jvm: Option[String]
}

/// Parsed form of a virtual workspace root (`lyric.toml` with `[workspace]`
/// but no `[package]`).
pub record WorkspaceRoot {
  filePath: String
  workspace: WorkspaceSection
  registry: Option[RegistryConfig]
}

pub record Manifest {
  filePath: String
  packageSection: PackageSection
  project: Option[ProjectSection]
  deps: List[DependencyEntry]
  nuget: Option[NugetSection]
  maven: Option[MavenSection]
  features: Option[FeaturesSection]
  /// Non-None when this manifest also declares a `[workspace]` table.
  workspace: Option[WorkspaceSection]
  registry: Option[RegistryConfig]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Internal parser types
// ─────────────────────────────────────────────────────────────────────────────
// Typed value inside an inline table `{ key = val, ... }`.
union TVal {
  case TVStr(s: String)
  case TVBool(b: Bool)
}

// A single key–value pair inside an inline table.
record InlinePair {
  key: String
  tval: TVal
}

// Intermediate values before typed assembly.
union Value {
  case VStr(s: String)
  case VStrList(items: List[String])
  case VBool(b: Bool)
  case VInt(n: Int)
  case VTable(pairs: List[InlinePair])
}

// A single parsed key-value binding with its TOML section context.
record Entry {
  section: String
  key: String
  value: Value
}

// Parsing cursor; pos/line/col are mutated via inout parameter passing.
record Cursor {
  text: String
  pos: Int
  line: Int
  col: Int
}

func charToString(c: in Char): String {
  "" + c
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
  if idx < c.text.length {
    c.text[idx]
  } else {
    '\u{0000}'
  }
}

func skipOne(c: inout Cursor): Unit {
  if not isAtEnd(c) {
    val ch = c.text[c.pos]
    c.pos = c.pos + 1
    if ch == '\n' {
      c.line = c.line + 1
      c.col = 1
    } else {
      c.col = c.col + 1
    }
  }
}

func skipWhitespace(c: inout Cursor): Unit {
  while not isAtEnd(c) and (peek(c) == ' ' or peek(c) == '\t') {
    skipOne(c)
  }
}

func skipToEndOfLine(c: inout Cursor): Unit {
  while not isAtEnd(c) and peek(c) != '\n' {
    skipOne(c)
  }
  if not isAtEnd(c) {
    skipOne(c)
  }
}

func skipBlankAndCommentLines(c: inout Cursor): Unit {
  var keepGoing = true
  while keepGoing and not isAtEnd(c) {
    skipWhitespace(c)
    if isAtEnd(c) {
      keepGoing = false
    } else if peek(c) == '#' or peek(c) == '\n' {
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
  (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or
    ch == '.'
}

// Collect a bare key (alphanumeric, underscores, hyphens).
func parseBareKey(c: inout Cursor): String {
  var key = ""
  while not isAtEnd(c) and isIdentChar(peek(c)) {
    key = key + charToString(peek(c))
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
  while not isAtEnd(c) and peek(c) != '"' and peek(c) != '\n' {
    val ch = peek(c)
    if ch == '\\' {
      skipOne(c)
      if isAtEnd(c) {
        return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated escape"))
      }
      val esc = peek(c)
      skipOne(c)
      if esc == 'n' {
        s = s + "\n"
      } else if esc == 't' {
        s = s + "\t"
      } else if esc == 'r' {
        s = s + "\r"
      } else if esc == '"' {
        s = s + "\""
      } else if esc == '\\' {
        s = s + "\\"
      } else {
        s = s + "\\" + charToString(esc)
      }
    } else {
      s = s + charToString(ch)
      skipOne(c)
    }
  }
  if isAtEnd(c) or peek(c) == '\n' {
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
    Err(
      error = ParseError(
        filePath = filePath,
        line = c.line,
        column = c.col,
        message = "unexpected character '" + charToString(peek(c)) + "' in key"
      )
    )
  }
}

// Parse a TOML array of strings: `["item1", "item2"]`.
func parseStringArray(c: inout Cursor, filePath: in String): Result[List[String], ManifestError] {
  skipOne(c)  // consume `[`
  val items: List[String] = newList()
  var keepGoing = true
  while keepGoing and not isAtEnd(c) {
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
        case Ok(s) -> {
          items.add(s)
          skipWhitespace(c)
          if not isAtEnd(c) and peek(c) == ',' {
            skipOne(c)
          }
        }
      }
    } else if ch == '#' or ch == '\n' {
      skipToEndOfLine(c)
    } else {
      return Err(
        error = ParseError(
          filePath = filePath,
          line = c.line,
          column = c.col,
          message = "expected string or ']' in array"
        )
      )
    }
  }
  Ok(value = items)
}

// Parse a TOML inline table: `{ key = value, ... }`.
// Values may be quoted strings or booleans (true/false).
func parseInlineTable(c: inout Cursor, filePath: in String): Result[List[InlinePair], ManifestError] {
  skipOne(c)  // consume `{`
  val pairs: List[InlinePair] = newList()
  var keepGoing = true
  while keepGoing and not isAtEnd(c) {
    skipWhitespace(c)
    if isAtEnd(c) {
      return Err(
        error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "unterminated inline table")
      )
    }
    val ch = peek(c)
    if ch == '}' {
      skipOne(c)
      keepGoing = false
    } else if ch == '#' or ch == '\n' {
      skipToEndOfLine(c)
    } else {
      match parseKey(c, filePath) {
        case Err(e) -> return Err(error = e)
        case Ok(key) -> {
          skipWhitespace(c)
          if isAtEnd(c) or peek(c) != '=' {
            return Err(
              error = ParseError(
                filePath = filePath,
                line = c.line,
                column = c.col,
                message = "expected '=' in inline table after '" + key + "'"
              )
            )
          }
          skipOne(c)  // consume `=`
          skipWhitespace(c)
          if isAtEnd(c) {
            return Err(
              error = ParseError(
                filePath = filePath,
                line = c.line,
                column = c.col,
                message = "expected value in inline table"
              )
            )
          }
          val vc = peek(c)
          if vc == '"' {
            match parseQuotedString(c, filePath) {
              case Err(e) -> return Err(error = e)
              case Ok(s) -> pairs.add(InlinePair(key = key, tval = TVStr(s = s)))
            }
          } else if vc == 't' and peekAt(c, 1) == 'r' and peekAt(c, 2) == 'u' and peekAt(c, 3) == 'e' {
            skipOne(c)
            skipOne(c)
            skipOne(c)
            skipOne(c)
            pairs.add(InlinePair(key = key, tval = TVBool(b = true)))
          } else if vc == 'f' and peekAt(c, 1) == 'a' and peekAt(c, 2) == 'l' and peekAt(c, 3) == 's' and peekAt(c, 4) == 'e' {
            skipOne(c)
            skipOne(c)
            skipOne(c)
            skipOne(c)
            skipOne(c)
            pairs.add(InlinePair(key = key, tval = TVBool(b = false)))
          } else if vc == '[' {
            // Array value (e.g. features = ["aws"]) — consume and skip;
            // InlinePair only tracks strings and bools so arrays are discarded.
            match parseStringArray(c, filePath) {
              case Err(e) -> return Err(error = e)
              case Ok(_) -> ()  // intentionally dropped
            }
          } else {
            return Err(
              error = ParseError(
                filePath = filePath,
                line = c.line,
                column = c.col,
                message = "expected string or bool value in inline table"
              )
            )
          }
          skipWhitespace(c)
          if not isAtEnd(c) and peek(c) == ',' {
            skipOne(c)
          }
        }
      }
    }
  }
  Ok(value = pairs)
}

// Parse a single TOML value (string, array, bool, integer, or inline table).
func parseValue(c: inout Cursor, filePath: in String): Result[Value, ManifestError] {
  skipWhitespace(c)
  if isAtEnd(c) {
    return Err(error = ParseError(filePath = filePath, line = c.line, column = c.col, message = "expected value"))
  }
  val ch = peek(c)
  if ch == '"' {
    match parseQuotedString(c, filePath) {
      case Err(e) -> Err(error = e)
      case Ok(s) -> Ok(value = VStr(s = s))
    }
  } else if ch == '[' {
    match parseStringArray(c, filePath) {
      case Err(e) -> Err(error = e)
      case Ok(items) -> Ok(value = VStrList(items = items))
    }
  } else if ch == '{' {
    match parseInlineTable(c, filePath) {
      case Err(e) -> Err(error = e)
      case Ok(pairs) -> Ok(value = VTable(pairs = pairs))
    }
  } else if ch == 't' and peekAt(c, 1) == 'r' and peekAt(c, 2) == 'u' and peekAt(c, 3) == 'e' {
    skipOne(c)
    skipOne(c)
    skipOne(c)
    skipOne(c)
    Ok(value = VBool(b = true))
  } else if ch == 'f' and peekAt(c, 1) == 'a' and peekAt(c, 2) == 'l' and peekAt(c, 3) == 's' and peekAt(c, 4) == 'e' {
    skipOne(c)
    skipOne(c)
    skipOne(c)
    skipOne(c)
    skipOne(c)
    Ok(value = VBool(b = false))
  } else if ch >= '0' and ch <= '9' {
    var n = 0
    while not isAtEnd(c) and peek(c) >= '0' and peek(c) <= '9' {
      n = n * 10 + (toInt(peek(c)) - toInt('0'))
      skipOne(c)
    }
    Ok(value = VInt(n = n))
  } else {
    Err(
      error = ParseError(
        filePath = filePath,
        line = c.line,
        column = c.col,
        message = "unexpected character '" + charToString(ch) + "' in value"
      )
    )
  }
}

// Parse a section header `[section]` or `[section.sub]`.
// Returns the full dotted section name (e.g. "project.packages").
// Cursor must be positioned at `[`.
func parseSectionHeader(c: inout Cursor, filePath: in String): Result[String, ManifestError] {
  skipOne(c)  // consume `[`
  var section = ""
  while not isAtEnd(c) and peek(c) != ']' and peek(c) != '\n' {
    section = section + charToString(peek(c))
    skipOne(c)
  }
  if isAtEnd(c) or peek(c) == '\n' {
    return Err(
      error = ParseError(
        filePath = filePath,
        line = c.line,
        column = c.col,
        message = "unterminated section header"
      )
    )
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
  val entries: List[Entry] = newList()
  var currentSection = ""

  while not isAtEnd(c) {
    skipBlankAndCommentLines(c)
    if isAtEnd(c) {
      // done
    } else if peek(c) == '[' {
      match parseSectionHeader(c, filePath) {
        case Err(e) -> return Err(error = e)
        case Ok(sec) -> {
          currentSection = sec
        }
      }
      skipToEndOfLine(c)
    } else if isIdentChar(peek(c)) or peek(c) == '"' {
      match parseKey(c, filePath) {
        case Err(e) -> return Err(error = e)
        case Ok(key) -> {
          skipWhitespace(c)
          if isAtEnd(c) or peek(c) != '=' {
            return Err(
              error = ParseError(
                filePath = filePath,
                line = c.line,
                column = c.col,
                message = "expected '=' after key '" + key + "'"
              )
            )
          }
          skipOne(c)  // consume `=`
          match parseValue(c, filePath) {
            case Err(e) -> return Err(error = e)
            case Ok(v) -> {
              entries.add(Entry(section = currentSection, key = key, value = v))
              skipToEndOfLine(c)
            }
          }
        }
      }
    } else {
      return Err(
        error = ParseError(
          filePath = filePath,
          line = c.line,
          column = c.col,
          message = "unexpected character '" + charToString(peek(c)) + "'"
        )
      )
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
    if e.section == section and e.key == key {
      match e.value {
        case VStr(s) -> return Some(value = s)
        case _ -> return None
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
    if e.section == section and e.key == key {
      match e.value {
        case VStrList(items) -> return Some(value = items)
        case _ -> return None
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
    if e.section == section and e.key == key {
      match e.value {
        case VBool(b) -> return b
        case _ -> return default
      }
    }
    i += 1
  }
  default
}

func requireString(entries: in List[Entry], section: in String, key: in String): Result[String, ManifestError] {
  match findString(entries, section, key) {
    case Some(s) -> Ok(value = s)
    case None -> Err(error = MissingField(section = section, field = key))
  }
}

// Collect all entries in a given section as (key, string-value) pairs.
func collectSectionPairs(entries: in List[Entry], section: in String): List[PackageEntry] {
  val pairs: List[PackageEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section {
      match e.value {
        case VStr(s) -> pairs.add(PackageEntry(name = e.key, path = s))
        case _ -> ()  // non-string values in pair sections are silently ignored
      }
    }
    i += 1
  }
  pairs
}

func assemblePackage(entries: in List[Entry]): Result[PackageSection, ManifestError] {
  match requireString(entries, "package", "name") {
    case Err(e) -> Err(error = e)
    case Ok(name) -> match requireString(entries, "package", "version") { case Err(e) -> Err(error = e); case Ok(version) -> { val description = unwrapOr(findString(entries, "package", "description"), ""); val authors: List[String] = unwrapOr(findStringList(entries, "package", "authors"), newList()); val license = unwrapOr(findString(entries, "package", "license"), ""); val repository = findString(entries, "package", "repository"); val kind = findString(entries, "package", "kind"); Ok(value = PackageSection(name = name, version = version, description = description, authors = authors, license = license, repository = repository, kind = kind)) } }
  }
}

func hasSection(entries: in List[Entry], section: in String): Bool {
  var i = 0
  while i < entries.count {
    if entries[i].section == section {
      return true
    }
    i += 1
  }
  false
}

func assembleProject(entries: in List[Entry]): Option[ProjectSection] {
  if not hasSection(entries, "project") {
    return None
  }
  val name = unwrapOr(findString(entries, "project", "name"), "")
  val output = unwrapOr(findString(entries, "project", "output"), "single")
  val outputAssembly = findString(entries, "project", "output_assembly")
  val packages = collectSectionPairs(entries, "project.packages")
  val tests = collectSectionPairs(entries, "project.tests")
  Some(
    value = ProjectSection(
      name = name,
      output = output,
      outputAssembly = outputAssembly,
      packages = packages,
      tests = tests
    )
  )
}

// ── Inline table helpers ─────────────────────────────────────────────────────
func findInlineStr(pairs: in List[InlinePair], key: in String): Option[String] {
  var i = 0
  while i < pairs.count {
    val p = pairs[i]
    if p.key == key {
      match p.tval {
        case TVStr(s) -> return Some(value = s)
        case _ -> return None
      }
    }
    i += 1
  }
  None
}

func findInlineBool(pairs: in List[InlinePair], key: in String, default: in Bool): Bool {
  var i = 0
  while i < pairs.count {
    val p = pairs[i]
    if p.key == key {
      match p.tval {
        case TVBool(b) -> return b
        case _ -> return default
      }
    }
    i += 1
  }
  default
}

// Build a DepSource from an inline table.
func buildDepSource(
  depName: in String, pairs: in List[InlinePair], section: in String
): Result[DepSource, ManifestError] {
  // Check for workspace = true
  if findInlineBool(pairs, "workspace", false) {
    val versionOpt = findInlineStr(pairs, "version")
    return Ok(value = Workspace(version = versionOpt))
  }
  // Check for path = "..."
  match findInlineStr(pairs, "path") {
    case Some(dir) -> return Ok(value = Path(dir = dir))
    case None -> ()
  }
  // Check for git = "..."
  match findInlineStr(pairs, "git") {
    case Some(url) -> {
      val subdir = findInlineStr(pairs, "subdir")
      // Construct the GitRef inline in each branch and return immediately,
      // rather than binding `val ref: GitRef = match ...` and storing it in the
      // record afterwards.  The F# stage-0 emitter reads a union value produced
      // by a nested `match` expression back as null when it lands in a record
      // field, so `Git.ref` arrived null at the consumer (#2126); the
      // early-return form sidesteps that.
      match findInlineStr(pairs, "tag") {
        case Some(t) -> return Ok(value = Git(url = url, refKind = "tag", refValue = t, subdir = subdir))
        case None -> ()
      }
      match findInlineStr(pairs, "rev") {
        case Some(r) -> return Ok(value = Git(url = url, refKind = "rev", refValue = r, subdir = subdir))
        case None -> ()
      }
      match findInlineStr(pairs, "branch") {
        case Some(b) -> return Ok(value = Git(url = url, refKind = "branch", refValue = b, subdir = subdir))
        case None -> ()
      }
      return Err(
        error = InvalidField(
          section = section,
          field = depName,
          message = "git dep requires one of: tag, rev, branch"
        )
      )
    }
    case None -> ()
  }
  // Explicit version key in inline table: { version = "1.0.0" }
  match findInlineStr(pairs, "version") {
    case Some(v) -> Ok(value = Registry(version = v))
    case None -> Err(error = InvalidField(section = section, field = depName, message = "dep must have one of: version, workspace = true, path, git"))
  }
}

func assembleDeps(entries: in List[Entry]): Result[List[DependencyEntry], ManifestError] {
  val depList: List[DependencyEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "dependencies" {
      match e.value {
        case VStr(v) -> depList.add(DependencyEntry(name = e.key, source = Registry(version = v), registry = None))
        case VTable(pairs) -> {
          match buildDepSource(e.key, pairs, "dependencies") {
            case Err(me) -> return Err(error = me)
            case Ok(src) -> depList.add(DependencyEntry(name = e.key, source = src, registry = findInlineStr(pairs, "registry")))
          }
        }
        case _ -> ()
      }
    }
    i += 1
  }
  Ok(value = depList)
}

// Local helpers used by the [features] assembly below.
func listContains(xs: in List[String], target: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == target {
      return true
    }
    i += 1
  }
  false
}

func sortStringList(xs: in List[String]): List[String] {
  // Insertion sort — O(n^2) but list is small (one entry per declared
  // feature) and the sort runs once per build.
  val sorted: List[String] = newList()
  var i = 0
  while i < xs.count {
    sorted.add(xs[i])
    i += 1
  }
  var k = 1
  while k < sorted.count {
    val cur = sorted[k]
    var j = k
    while j > 0 and sorted[j - 1] > cur {
      sorted[j] = sorted[j - 1]
      j -= 1
    }
    sorted[j] = cur
    k += 1
  }
  sorted
}

/// `[features]` per `docs/24-build-features.md` (D045).  v1 accepts
/// only empty implication arrays; a non-empty array on any non-`default`
/// key produces `Err(InvalidField)`.  Returns `Ok(None)` when the
/// section is absent.
func assembleFeatures(entries: in List[Entry]): Result[Option[FeaturesSection], ManifestError] {
  if not hasSection(entries, "features") {
    return Ok(value = None)
  }
  val declared: List[String] = newList()
  var defaults: Option[List[String]] = None
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "features" {
      match e.value {
        case VStrList(items) -> if e.key == "default" { defaults = Some(value = items) } else if items.count > 0 { return Err(error = InvalidField(section = "features", field = e.key, message = "v1 requires an empty array (feature implications are deferred to v1.1)")) } else { declared.add(e.key) }
        case _ -> return Err(error = InvalidField(section = "features", field = e.key, message = "expected an array (use [] for v1)"))
      }
    }
    i += 1
  }
  // Validate every default names a declared feature.
  val defaultList: List[String] = unwrapOr(defaults, newList())
  var di = 0
  while di < defaultList.count {
    val name = defaultList[di]
    if not listContains(declared, name) {
      return Err(
        error = InvalidField(
          section = "features",
          field = "default",
          message = "references undeclared feature '" + name + "'"
        )
      )
    }
    di += 1
  }
  Ok(value = Some(value = FeaturesSection(declared = sortStringList(declared), defaults = defaultList)))
}

func assembleNuget(entries: in List[Entry]): Option[NugetSection] {
  if not hasSection(entries, "nuget") {
    return None
  }
  val nugetEntries: List[NugetEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "nuget" {
      match e.value {
        case VStr(v) -> nugetEntries.add(NugetEntry(name = e.key, version = v))
        case VTable(pairs) -> {
          // Support { version = "1.0.0", features = [...] } form in [nuget].
          match findInlineStr(pairs, "version") {
            case Some(v) -> nugetEntries.add(NugetEntry(name = e.key, version = v))
            case None -> ()
          }
        }
        case _ -> ()
      }
    }
    i += 1
  }
  val target = findString(entries, "nuget.options", "target")
  val allowNative = findBool(entries, "nuget.options", "allow_native", false)
  Some(value = NugetSection(entries = nugetEntries, target = target, allowNative = allowNative))
}

/// Validate a `[maven]` coordinate key + version and, on success, append the
/// resulting `MavenEntry` to `acc`.  The key must be exactly `groupId:artifactId`
/// (a single `:` separating two non-empty halves), and the version must not be a
/// `-SNAPSHOT` build (B0054, `docs/31-maven-linking.md` §11).  Returns
/// `Some(ManifestError)` on a validation failure (entry not appended), `None`
/// otherwise.  Mirrors the F# reference in `bootstrap/src/Lyric.Cli/Manifest.fs`.
func collectMavenEntry(acc: in List[MavenEntry], key: in String, version: in String): Option[ManifestError] {
  val parts = Str.split(key, ":")
  if parts.length != 2 or parts[0] == "" or parts[1] == "" {
    return Some(
      value = InvalidField(
        section = "maven",
        field = key,
        message = "expected a Maven coordinate in \"groupId:artifactId\" format"
      )
    )
  }
  if Str.endsWith(Str.toUpper(version), "-SNAPSHOT") {
    return Some(
      value = InvalidField(
        section = "maven",
        field = key,
        message = "SNAPSHOT versions are not allowed; pin a release version (B0054)"
      )
    )
  }
  acc.add(MavenEntry(group = parts[0], artifact = parts[1], version = version))
  None
}

/// Assemble the `[maven]` / `[maven.options]` tables per
/// `docs/31-maven-linking.md` (D053).  Mirrors `assembleNuget`/`assembleFeatures`:
/// each `groupId:artifactId = "version"` entry becomes a `MavenEntry`, and the
/// extended `{ version = "...", ... }` inline-table form is also accepted.
/// Coordinate keys must be exactly `groupId:artifactId` and versions must not
/// be `-SNAPSHOT` builds (B0054) — either produces `Err(InvalidField)`.
/// `[maven.options].repositories` defaults to `["central"]`; `java_version`
/// is optional.  Returns `Ok(None)` when no `[maven]` table is present.
func assembleMaven(entries: in List[Entry]): Result[Option[MavenSection], ManifestError] {
  if not hasSection(entries, "maven") {
    return Ok(value = None)
  }
  val mavenEntries: List[MavenEntry] = newList()
  var firstErr: Option[ManifestError] = None
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "maven" {
      val versionOpt: Option[String] = match e.value {
        case VStr(v) -> Some(value = v)
        // Support { version = "2.17.0", ... } form in [maven].
        case VTable(pairs) -> findInlineStr(pairs, "version")
        case _ -> None
      }
      match versionOpt {
        case None -> ()
        case Some(v) -> {
          val entryErr = collectMavenEntry(mavenEntries, e.key, v)
          if isNone(firstErr) {
            firstErr = entryErr
          }
        }
      }
    }
    i += 1
  }
  match firstErr {
    case Some(err) -> return Err(error = err)
    case None -> ()
  }
  val repositories: List[String] = match findStringList(entries, "maven.options", "repositories") {
    case Some(repos) -> repos
    case None -> {
      val def: List[String] = newList()
      def.add("central")
      def
    }
  }
  val javaVersion = findString(entries, "maven.options", "java_version")
  Ok(value = Some(value = MavenSection(entries = mavenEntries, repositories = repositories, javaVersion = javaVersion)))
}

func assembleWorkspace(entries: in List[Entry]): Option[WorkspaceSection] {
  if not hasSection(entries, "workspace") {
    return None
  }
  val exclude: List[String] = unwrapOr(findStringList(entries, "workspace", "exclude"), newList())
  val overrides: List[WorkspaceOverride] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "workspace.overrides" {
      match e.value {
        case VTable(pairs) -> match findInlineStr(pairs, "path") { case Some(dir) -> overrides.add(WorkspaceOverride(name = e.key, dir = dir)); case None -> () }
        case VStr(dir) -> overrides.add(WorkspaceOverride(name = e.key, dir = dir))
        case _ -> ()
      }
    }
    i += 1
  }
  Some(value = WorkspaceSection(exclude = exclude, overrides = overrides))
}

func assembleRegistry(entries: in List[Entry]): Option[RegistryConfig] {
  if not hasSection(entries, "registry") {
    return None
  }
  Some(
    value = RegistryConfig(
      dotnet = findString(entries, "registry", "dotnet"),
      jvm = findString(entries, "registry", "jvm")
    )
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry points
// ─────────────────────────────────────────────────────────────────────────────
/// Parse the contents of a `lyric.toml` member manifest (must have `[package]`).
///
/// `text` is the raw UTF-8 source; `filePath` is used only for error messages.
///
/// Returns `Ok(manifest)` on success or `Err(ManifestError)` on the first
/// fatal parse or validation error.  Unknown keys in recognised sections are
/// silently ignored in this bootstrap-grade parser.
pub func parseManifest(text: in String, filePath: in String): Result[Manifest, ManifestError] {
  match collectEntries(text, filePath) {
    case Err(e) -> Err(error = e)
    case Ok(entries) -> match assemblePackage(entries) { case Err(e) -> Err(error = e); case Ok(pkg) -> { val project = assembleProject(entries); val nuget = assembleNuget(entries); val ws = assembleWorkspace(entries); val reg = assembleRegistry(entries); match assembleDeps(entries) { case Err(e) -> Err(error = e); case Ok(deps) -> match assembleFeatures(entries) { case Err(e) -> Err(error = e); case Ok(featuresOpt) -> match assembleMaven(entries) { case Err(e) -> Err(error = e); case Ok(mavenOpt) -> Ok(value = Manifest(filePath = filePath, packageSection = pkg, project = project, deps = deps, nuget = nuget, maven = mavenOpt, features = featuresOpt, workspace = ws, registry = reg)) } } } } }
  }
}

/// Parse a virtual workspace root `lyric.toml` (no `[package]` required).
///
/// Returns `Ok(None)` if the file has no `[workspace]` table (not a workspace
/// root). Returns `Ok(Some(wr))` when `[workspace]` is present. TOML parse
/// errors are forwarded as `Err(ManifestError)`.
pub func parseWorkspaceRoot(text: in String, filePath: in String): Result[Option[WorkspaceRoot], ManifestError] {
  match collectEntries(text, filePath) {
    case Err(e) -> Err(error = e)
    case Ok(entries) -> match assembleWorkspace(entries) { case None -> Ok(value = None); case Some(ws) -> Ok(value = Some(value = WorkspaceRoot(filePath = filePath, workspace = ws, registry = assembleRegistry(entries)))) }
  }
}

/// Helper: return the version string from a Registry dep source, or "" for
/// all other source forms.  Used by pack.l and cli.l where only registry
/// deps produce NuGet package references.
pub func depRegistryVersion(source: in DepSource): Option[String] {
  match source {
    case Registry(v) -> Some(value = v)
    case _ -> None
  }
}

/// Return the `FeaturesSection` from the manifest, or a synthetic empty one
/// if the `[features]` section is absent.
pub func getManifestFeaturesOrEmpty(m: in Manifest): FeaturesSection {
  match m.features {
    case Some(f) -> return f
    case None -> return FeaturesSection(declared = newList(), defaults = newList())
  }
}

/// Return the `defaults` field of a FeaturesSection (intra-package accessor).
pub func featureSectionDefaults(s: in FeaturesSection): List[String] {
  s.defaults
}

/// Return the `declared` field of a FeaturesSection (intra-package accessor).
pub func featureSectionDeclared(s: in FeaturesSection): List[String] {
  s.declared
}

/// Return the `default` feature list from the manifest's `[features]` section,
/// or an empty list if the section is absent.
pub func getManifestFeatureDefaults(m: in Manifest): List[String] {
  featureSectionDefaults(getManifestFeaturesOrEmpty(m))
}

/// Return the `declared` feature list from the manifest's `[features]` section,
/// or an empty list if the section is absent.
pub func getManifestFeatureDeclared(m: in Manifest): List[String] {
  featureSectionDeclared(getManifestFeaturesOrEmpty(m))
}

/// Read the `default` feature list directly from raw TOML text, bypassing the
/// Manifest.features field entirely.  This avoids a bootstrap-emitter
/// code-gen issue where matching Option[FeaturesSection] and accessing the
/// resulting record's fields can return null in certain call-chain shapes.
///
/// Re-parses only the [features] entries — O(n) scan of the TOML token
/// stream, acceptable for the bootstrap phase.
pub func readFeatureDefaultsFromToml(text: in String, filePath: in String): List[String] {
  val result: List[String] = newList()
  match collectEntries(text, filePath) {
    case Err(_) -> ()
    case Ok(entries) -> {
      var i = 0
      while i < entries.count {
        val e = entries[i]
        if e.section == "features" and e.key == "default" {
          match e.value {
            case VStrList(items) -> {
              var j = 0
              while j < items.count {
                result.add(items[j])
                j += 1
              }
            }
            case _ -> ()
          }
        }
        i += 1
      }
    }
  }
  result
}

/// Read all declared feature names directly from raw TOML text, bypassing
/// Manifest.features.  See `readFeatureDefaultsFromToml` for rationale.
pub func readFeatureDeclaredFromToml(text: in String, filePath: in String): List[String] {
  val result: List[String] = newList()
  match collectEntries(text, filePath) {
    case Err(_) -> ()
    case Ok(entries) -> {
      var i = 0
      while i < entries.count {
        val e = entries[i]
        if e.section == "features" and e.key != "default" {
          result.add(e.key)
        }
        i += 1
      }
    }
  }
  result
}
