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
//!   [maven]             — map of Maven coordinate -> version string (JVM target)
//!   [maven.options]     — repositories list and java_version
//!   [features]          — declared feature flags ([] values in v1)
//!   [native]            — --target native defaults (triple, opt_level, extra_libs)
//!   [build]             — artifact kind ("lib"/"exe"/"bundle"), packaging shape
//!                         ("portable"/"standalone"/"aot"), and compile profile
//!                         ("debug"/"release") — three independent axes, docs/63
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
  /// Non-empty when the entry is a single file or a directory.
  path: String
  /// Non-empty when the entry is an explicit list of source files
  /// (TOML array form: `"Pkg" = ["src/a.l", "src/b.l"]`).
  /// Mutually exclusive with `path`: exactly one of the two is non-empty.
  paths: List[String]
  /// True for a `[project.packages]` entry declared with the inline-table
  /// form `{ path = "...", test_only = true }` (#6579): the package is still
  /// resolvable by `lyric test`/single-file manifest-local import resolution
  /// (`collectImportedOwnPackages` in `cli_build.l`, `cli_test.l`'s `libPkgs`
  /// construction — both scan `[project.packages]` unconditionally), but
  /// `buildProjectFromManifest` skips it when assembling the production
  /// whole-project bundle. Lets a shared test-only fixture (e.g. a TLS
  /// private-key module, D-progress-806) be imported by multiple test files
  /// without shipping in the production output, closing the gap that used to
  /// force a choice between duplicating the fixture per consumer or leaking
  /// it into the shipped assembly. Always `false` for the bare-string/array
  /// forms, and meaningless (never read) on a `[project.tests]` entry, which
  /// is already test-only by construction and never reaches
  /// `buildProjectFromManifest`'s bundling step at all.
  testOnly: Bool
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

/// A single `[npm]` entry (docs/35 section 9).  `name` is the NPM package
/// name (`node-fetch`, `@aws-sdk/client-s3`), `version` the semver range
/// passed opaquely to the package manager, and `ident` the Lyric package
/// identifier the generated shim declares (`NodeFetch`, `AwsSdk.ClientS3`).
pub record NpmEntry {
  name: String
  version: String
  ident: String
}

/// `[npm]` / `[npm.options]` (docs/35 section 9.1).  `registry` is "" when
/// `[npm.options]` names none (the package manager's default,
/// `https://registry.npmjs.org/`).
pub record NpmSection {
  entries: List[NpmEntry]
  registry: String
}

/// `[native]` section (N6.4): defaults for `--target native` builds.
/// `triple` is the LLVM target triple (empty = auto-detect the host);
/// `optLevel` is the clang `-O` level (empty = the built-in default "2");
/// `extraLibs` are additional `-l<name>` link flags for clang.  The CLI
/// `--triple` / `--opt` flags override the manifest triple / optLevel;
/// `extraLibs` has no CLI counterpart and is applied unconditionally.
pub record NativeConfig {
  triple: String
  optLevel: String
  extraLibs: List[String]
  /// `[wasm] version`: the WIT package version of a `--shape component` build
  /// ("" = the project's `[package]` version, else `0.1.0`).
  wasmVersion: String = ""
  /// `[wasm] world`: the WIT world name ("" = `<package>-world`).
  wasmWorld: String = ""
  /// `[wasm] stack`: the shadow-stack size in bytes of a wasm32 module or
  /// component (0 = the 1 MiB default).
  wasmStack: Int = 0
}

/// `[layers]` section (docs/65 §5, D149): assigns project packages to
/// layers and optionally names a preset (`preset = "ui"`) and custom
/// rules.  `preset` is "" when absent.  Names are validated later, by
/// `Lyric.Layers`, which reports Y0006 for an unknown layer or preset.
pub record LayersSection {
  preset: String
  packages: List[LayerAssignment]
  rules: List[LayerRuleSpec]
}

/// One `[layers.packages]` entry: a package name or glob (`*` matches one
/// dotted segment) and the layer it belongs to.
pub record LayerAssignment {
  pattern: String
  layer: String
}

/// One custom rule, from `[layers.rules]` (`logic = { may_import = [...] }`)
/// or a `[layers.rules.<name>]` sub-table.  `mayImport` holds layer names,
/// the classes `pure` and `io`, and package patterns; `mayNotImport` holds
/// package patterns only.  `allowAsync` defaults to true.
pub record LayerRuleSpec {
  name: String
  mayImport: List[String]
  mayNotImport: List[String]
  allowAsync: Bool
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

/// `[build]` section. Carries three independent axes (docs/63 §3): what the
/// artifact *is* (`kind`), how it is *packaged* (`shape`), and how it is
/// *compiled* (`profile`).
///
/// `kind` selects the produced artifact for the Dotnet target:
///   - `"lib"`    — managed `.dll` (default), run via `dotnet exec`.
///   - `"exe"`    — managed `.dll` plus a native apphost launcher and
///                  `.runtimeconfig.json`; runs directly (`./<name>`) but still
///                  needs a .NET runtime installed (framework-dependent).
///   - `"bundle"` — self-contained: launcher with the runtime bundled
///                  (planned; not yet emitted).
/// For the Jvm target, `kind` is currently a no-op.
///
/// `"aot"` was removed from `kind` in docs/63 band B0: it described a
/// *packaging* mode, not an artifact kind, and now lives on `shape`. It is a
/// hard error (`F0042`) rather than a silent remap so a manifest cannot be
/// quietly downgraded to a portable DLL.
///
/// `shape` selects packaging (docs/63 §3.2):
///   - `"portable"`   — framework-dependent (default); needs a runtime installed.
///   - `"standalone"` — bundles a runtime, still JIT/interpreted.
///   - `"aot"`        — ahead-of-time compiled to native machine code.
///
/// `profile` selects optimization and debug symbols (docs/63 §3.1):
///   - `"debug"`   — unoptimized, debug info retained (default).
///   - `"release"` — optimized, debug info stripped.
///
/// `defines` carries the `[build.define]` sub-table (docs/60 §3.1) as a
/// `List[String]` of `"KEY=VALUE"` entries — the same cross-package-safe
/// representation the CLI `--define` list uses. Empty when the manifest has no
/// `[build.define]` table. Values are TOML strings only (§4); a non-string
/// value is a manifest error.
pub record BuildSection {
  kind: String
  shape: String
  profile: String
  defines: List[String]
  /// True when this manifest's `[build]` table declared `shape` explicitly
  /// (as opposed to `shape` carrying its `"portable"` default because the
  /// key was absent). `shape`/`profile` alone cannot distinguish "the
  /// manifest said portable" from "the manifest said nothing" — both parse
  /// to the same default string — so `resolveBuildAxes` (`cli_build.l`)
  /// needs this bit to decide whether `--target native`'s implicit `aot`
  /// default may apply, or whether a declared non-`aot` shape must instead
  /// raise `F0043` (#6268).
  shapeDeclared: Bool
  /// Same as `shapeDeclared`, for `profile` (kept for axis symmetry; no
  /// target currently forces a profile default the way native forces
  /// `shape`).
  profileDeclared: Bool
}

/// `[contracts]` table (docs/63 Q-BP-009): whether runtime contract checks
/// (`requires:`, `ensures:`, `invariant:`) are emitted in compiled output.
/// Default is true (checks enabled). All fields are optional; missing keys
/// use their defaults.
pub record ContractsSection {
  /// Whether runtime contract checks are enabled. Default true.
  enabled: Bool
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
  /// Non-None when this manifest declares an `[npm]` table (docs/35 section 9).
  npm: Option[NpmSection]
  features: Option[FeaturesSection]
  /// Non-None when this manifest declares a `[build]` table **or** a
  /// `[build.define]` table (a `[build.define]`-only manifest yields a
  /// `BuildSection` with the default `kind = "lib"` and the parsed defines).
  build: Option[BuildSection]
  /// Non-None when this manifest also declares a `[workspace]` table.
  workspace: Option[WorkspaceSection]
  registry: Option[RegistryConfig]
  /// Non-None when this manifest also declares a `[native]` table (N6.4).
  native: Option[NativeConfig]
  /// Non-None when this manifest also declares a `[contracts]` table.
  contracts: Option[ContractsSection]
  /// Non-None when this manifest declares a `[layers]` table or any
  /// `[layers.*]` sub-table (docs/65 §5, D149).
  layers: Option[LayersSection]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Internal parser types
// ─────────────────────────────────────────────────────────────────────────────
// Typed value inside an inline table `{ key = val, ... }`.
union TVal {
  case TVStr(s: String)
  case TVBool(b: Bool)
  case TVStrList(items: List[String])
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
  var pos: Int
  var line: Int
  var col: Int
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

// The cursor reads `Char`s through `Str.charAtOrReplacement`: manifest text
// may hold supplementary-plane characters (a `description` with an emoji),
// whose surrogate halves are not `Char`s and read as U+FFFD here.  Text that
// is copied into a value goes through `peekRaw`, which keeps the raw units.
func peek(c: in Cursor): Char {
  Str.charAtOrReplacement(c.text, c.pos)
}

// The code unit at the cursor, verbatim, as a one-unit String.
func peekRaw(c: in Cursor): String {
  Str.substring(c.text, c.pos, 1)
}

func peekAt(c: in Cursor, offset: in Int): Char {
  val idx = c.pos + offset
  if idx < c.text.length {
    Str.charAtOrReplacement(c.text, idx)
  } else {
    '\u{0000}'
  }
}

func skipOne(c: inout Cursor): Unit {
  if not isAtEnd(c) {
    val ch = peek(c)
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
  // `\r` is treated as horizontal whitespace so CRLF (`\r\n`) manifests parse on
  // any platform: the `\r` is skipped and the `\n` remains the line terminator.
  // Without this a Windows (CRLF) checkout fails with "unexpected character '\r'".
  while not isAtEnd(c) and (peek(c) == ' ' or peek(c) == '\t' or peek(c) == '\r') {
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
      val escRaw = peekRaw(c)
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
        s = s + "\\" + escRaw
      }
    } else {
      s = s + peekRaw(c)
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
// Values may be quoted strings, booleans (true/false) or string arrays.
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
            match parseStringArray(c, filePath) {
              case Err(e) -> return Err(error = e)
              case Ok(items) -> pairs.add(InlinePair(key = key, tval = TVStrList(items = items)))
            }
          } else {
            return Err(
              error = ParseError(
                filePath = filePath,
                line = c.line,
                column = c.col,
                message = "expected a string, bool or string array value in inline table"
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
      val digit = toInt(peek(c)) - toInt('0')
      // Guard the accumulator: an integer literal >= 2^31 in a manifest value
      // position would overflow the checked Int and panic, bypassing the
      // Result[..., ManifestError] contract (a dependency's lyric.toml is
      // untrusted input during resolution).  Surface a clean ParseError instead.
      if n > (2147483647 - digit) / 10 {
        return Err(
          error = ParseError(
            filePath = filePath,
            line = c.line,
            column = c.col,
            message = "integer literal out of range (max 2147483647)"
          )
        )
      }
      n = n * 10 + digit
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
    section = section + peekRaw(c)
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
// `[project.packages]`'s `{ path = "...", test_only = true }` inline-table
// form (#6579) is accepted here too — `[project.tests]` entries ignore the
// resulting `testOnly` bit (it's simply never read for that section).
func collectSectionPairs(entries: in List[Entry], section: in String): List[PackageEntry] {
  val pairs: List[PackageEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section {
      val noPaths: List[String] = newList()
      match e.value {
        case VStr(s) -> pairs.add(PackageEntry(name = e.key, path = s, paths = noPaths, testOnly = false))
        case VStrList(items) -> {
          val emptyPath = ""
          pairs.add(PackageEntry(name = e.key, path = emptyPath, paths = items, testOnly = false))
        }
        case VTable(tpairs) -> {
          // A table entry with no `path` key has nothing to compile; silently
          // ignored, matching the non-string/non-list default just below.
          match findInlineStr(tpairs, "path") {
            case Some(p) -> pairs.add(
              PackageEntry(
                name = e.key,
                path = p,
                paths = noPaths,
                testOnly = findInlineBool(tpairs, "test_only", false)
              )
            )
            case None -> ()
          }
        }
        case _ -> ()  // non-string, non-list, non-table values are silently ignored
      }
    }
    i += 1
  }
  pairs
}

func assemblePackage(entries: in List[Entry]): Result[PackageSection, ManifestError] {
  match requireString(entries, "package", "name") {
    case Err(e) -> Err(error = e)
    case Ok(name) -> match requireString(entries, "package", "version") {
      case Err(e) -> Err(error = e)
      case Ok(version) -> {
        val description = unwrapOr(findString(entries, "package", "description"), "")
        val authors: List[String] = unwrapOr(findStringList(entries, "package", "authors"), newList())
        val license = unwrapOr(findString(entries, "package", "license"), "")
        val repository = findString(entries, "package", "repository")
        val kind = findString(entries, "package", "kind")
        Ok(
          value = PackageSection(
            name = name,
            version = version,
            description = description,
            authors = authors,
            license = license,
            repository = repository,
            kind = kind
          )
        )
      }
    }
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

// Collect the `[build.define]` sub-table (docs/60 §3.1) into `"KEY=VALUE"`
// strings — the cross-package-safe representation the define pipeline consumes.
// Values must be TOML strings (§4: String-only defines); a non-string value is
// an InvalidField error rather than a silent skip.
func collectBuildDefines(entries: in List[Entry]): Result[List[String], ManifestError] {
  val defs: List[String] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "build.define" {
      match e.value {
        case VStr(s) -> defs.add(e.key + "=" + s)
        case _ -> return Err(
          error = InvalidField(
            section = "build.define",
            field = e.key,
            message = "build define values must be strings (docs/60 §4)"
          )
        )
      }
    }
    i += 1
  }
  Ok(value = defs)
}

func assembleBuild(entries: in List[Entry]): Result[Option[BuildSection], ManifestError] {
  val hasBuild = hasSection(entries, "build")
  val hasDefine = hasSection(entries, "build.define")
  if (not hasBuild) and (not hasDefine) {
    return Ok(value = None)
  }
  match collectBuildDefines(entries) {
    case Err(e) -> Err(error = e)
    case Ok(defines) -> {
      // Each axis defaults independently when its key (or `[build]` itself) is
      // absent — a `[build.define]`-only manifest gets all three defaults.
      val shapeDeclared = match findString(entries, "build", "shape") { case Some(_) -> true; case None -> false }
      val profileDeclared = match findString(entries, "build", "profile") { case Some(_) -> true; case None -> false }
      match resolveBuildKind(entries) {
        case Err(e) -> Err(error = e)
        case Ok(kind) -> match resolveBuildShape(entries) {
          case Err(e) -> Err(error = e)
          case Ok(shape) -> match resolveBuildProfile(entries) {
            case Err(e) -> Err(error = e)
            case Ok(profile) -> Ok(
              value = Some(
                value = BuildSection(
                  kind = kind,
                  shape = shape,
                  profile = profile,
                  defines = defines,
                  shapeDeclared = shapeDeclared,
                  profileDeclared = profileDeclared
                )
              )
            )
          }
        }
      }
    }
  }
}

/// Assemble the `[contracts]` table.
/// Per docs/01-language-reference.md §3.7, a `[contracts]` table with no keys
/// is treated as absent (equivalent to the default).
/// Only return `Some` if at least one key-value pair exists in the section.
/// An empty `[contracts]` header with no entries returns `None`.
func assembleContracts(entries: in List[Entry]): Result[Option[ContractsSection], ManifestError] {
  // Per docs/01-language-reference.md §3.7: a [contracts] table with no keys
  // is treated as absent. Only return Some if at least one key-value pair exists.
  if not hasSection(entries, "contracts") {
    return Ok(value = None)
  }
  val enabled = findBool(entries, "contracts", "enabled", true)
  Ok(value = Some(value = ContractsSection(enabled = enabled)))
}

/// `[build] kind` — what the artifact *is*. `"aot"` is rejected outright
/// (`F0042`, docs/63 §6): it was a packaging mode misfiled as an artifact
/// kind, and silently remapping it to `shape = "aot"` would let a manifest
/// mean something it does not say.
///
/// The code is written bare (`F0042: ...`) rather than in the CLI's
/// `error[F0042]: ...` bracket form on purpose: this string is rendered
/// through `ManifestError.message`, which already prefixes
/// `[build] invalid value for 'kind': `, so the bracket form would read
/// `... invalid value for 'kind': error[F0042]: ...` and double up the
/// "error" prefix.
func resolveBuildKind(entries: in List[Entry]): Result[String, ManifestError] {
  match findString(entries, "build", "kind") {
    case None -> Ok(value = "lib")
    case Some(kind) -> {
      if kind == "lib" or kind == "exe" or kind == "bundle" {
        Ok(value = kind)
      } else if kind == "aot" {
        Err(
          error = InvalidField(
            section = "build",
            field = "kind",
            message = "F0042: kind = \"aot\" is no longer supported — \"aot\" is a packaging shape, not an " +
              "artifact kind. Use `shape = \"aot\"` (and `profile = \"release\"` for an optimized binary). " +
              "See docs/63 §6."
          )
        )
      } else {
        Err(
          error = InvalidField(
            section = "build",
            field = "kind",
            message = "must be \"lib\", \"exe\", or \"bundle\", got \"" + kind + "\""
          )
        )
      }
    }
  }
}

/// `[build] shape` — how the artifact is packaged (docs/63 §3.2).
func resolveBuildShape(entries: in List[Entry]): Result[String, ManifestError] {
  match findString(entries, "build", "shape") {
    case None -> Ok(value = "portable")
    case Some(shape) -> {
      if shape == "portable" or shape == "standalone" or shape == "aot" or shape == "module" or shape == "component" {
        Ok(value = shape)
      } else {
        Err(
          error = InvalidField(
            section = "build",
            field = "shape",
            message = "must be \"portable\", \"standalone\", \"aot\", \"module\", or \"component\", got \"" + shape +
              "\""
          )
        )
      }
    }
  }
}

/// `[build] profile` — optimization and debug symbols (docs/63 §3.1).
func resolveBuildProfile(entries: in List[Entry]): Result[String, ManifestError] {
  match findString(entries, "build", "profile") {
    case None -> Ok(value = "debug")
    case Some(profile) -> {
      if profile == "debug" or profile == "release" {
        Ok(value = profile)
      } else {
        Err(
          error = InvalidField(
            section = "build",
            field = "profile",
            message = "must be \"debug\" or \"release\", got \"" + profile + "\""
          )
        )
      }
    }
  }
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
    case None -> Err(
      error = InvalidField(
        section = section,
        field = depName,
        message = "dep must have one of: version, workspace = true, path, git"
      )
    )
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
            case Ok(src) -> depList.add(
              DependencyEntry(name = e.key, source = src, registry = findInlineStr(pairs, "registry"))
            )
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
        case VStrList(items) -> {
          if e.key == "default" {
            defaults = Some(value = items)
          } else if items.count > 0 {
            return Err(
              error = InvalidField(
                section = "features",
                field = e.key,
                message = "v1 requires an empty array (feature implications are deferred to v1.1)"
              )
            )
          } else {
            declared.add(e.key)
          }
        }
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

/// Assemble the `[nuget]` / `[nuget.options]` tables.  Each
/// `Package.Name = "version"` entry becomes a `NugetEntry`; the extended
/// `{ version = "...", ... }` inline-table form is also accepted.  An entry
/// whose value is neither a string nor an inline table carrying a `version`
/// key produces `Err(InvalidField)` (#2744).  Returns `Ok(None)` when no
/// `[nuget]` table is present.
func assembleNuget(entries: in List[Entry]): Result[Option[NugetSection], ManifestError] {
  if not hasSection(entries, "nuget") {
    return Ok(value = None)
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
            case None -> return Err(
              error = InvalidField(
                section = "nuget",
                field = e.key,
                message = "expected a version string or an inline table with a 'version' key"
              )
            )
          }
        }
        case _ -> return Err(
          error = InvalidField(
            section = "nuget",
            field = e.key,
            message = "expected a version string or an inline table with a 'version' key"
          )
        )
      }
    }
    i += 1
  }
  val target = findString(entries, "nuget.options", "target")
  val allowNative = findBool(entries, "nuget.options", "allow_native", false)
  Ok(value = Some(value = NugetSection(entries = nugetEntries, target = target, allowNative = allowNative)))
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
  if Str.endsWith(version, "-SNAPSHOT") {
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
/// An entry whose value is neither a string nor an inline table carrying a
/// `version` key also produces `Err(InvalidField)` (#2744).
/// `[maven.options].repositories` defaults to `["central"]`; `java_version`
/// is optional.  Returns `Ok(None)` when no `[maven]` table is present.
func assembleMaven(entries: in List[Entry]): Result[Option[MavenSection], ManifestError] {
  if not hasSection(entries, "maven") {
    return Ok(value = None)
  }
  val mavenEntries: List[MavenEntry] = newList()
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
      // Return on the first invalid entry, mirroring assembleNuget's
      // early-return control flow.
      match versionOpt {
        case None -> return Err(
          error = InvalidField(
            section = "maven",
            field = e.key,
            message = "expected a version string or an inline table with a 'version' key"
          )
        )
        case Some(v) -> match collectMavenEntry(mavenEntries, e.key, v) {
          case Some(err) -> return Err(error = err)
          case None -> ()
        }
      }
    }
    i += 1
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

func isNpmNameChar(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~'
}

/// Whether `part` is one NPM name segment: non-empty, lowercase letters,
/// digits and `-._~`, not starting with `.` or `_`.
func isNpmNamePart(part: in String): Bool {
  if part.length == 0 {
    return false
  }
  val first = Str.charAtOrReplacement(part, 0)
  if first == '.' or first == '_' {
    return false
  }
  var i = 0
  while i < part.length {
    if not isNpmNameChar(Str.charAtOrReplacement(part, i)) {
      return false
    }
    i += 1
  }
  true
}

/// Whether `name` is a valid NPM package name: `pkg` or `@scope/pkg`, at most
/// 214 characters.
pub func isValidNpmName(name: in String): Bool {
  if name.length == 0 or name.length > 214 {
    return false
  }
  if Str.startsWith(name, "@") {
    val parts = Str.split(Str.substring(name, 1), "/")
    return parts.length == 2 and isNpmNamePart(parts[0]) and isNpmNamePart(parts[1])
  }
  isNpmNamePart(name)
}

/// The shim file name for an NPM package (docs/35 section 9.3): the package
/// name with `@` dropped and `/` written `__` (`@aws-sdk/client-s3` ->
/// `aws-sdk__client-s3.l`).
pub func npmShimFileName(name: in String): String {
  val bare = if Str.startsWith(name, "@") { Str.substring(name, 1) } else { name }
  Str.replace(bare, "/", "__") + ".l"
}

/// A range is written into the generated shim's `@axiom("...")` string and
/// the install `package.json`, so it must hold no quote, backslash, `$`
/// (interpolation) or control character.
func isShimSafeRange(range: in String): Bool {
  var i = 0
  while i < range.length {
    val c = Str.charAtOrReplacement(range, i)
    if c == '"' or c == '\\' or c == '$' or c < ' ' {
      return false
    }
    i += 1
  }
  true
}

/// ASCII-uppercase a one-character string.  Spelled with a table rather than
/// `Str.toUpper`, which the stage-0 emitter mis-resolves to `Std.Char` in a
/// file importing both modules (#2125).
func npmUpperAscii(one: in String): String {
  val at = Str.indexOfRaw("abcdefghijklmnopqrstuvwxyz", one)
  if at < 0 {
    one
  } else {
    Str.substring("ABCDEFGHIJKLMNOPQRSTUVWXYZ", at, 1)
  }
}

/// The Lyric package identifier for an NPM package name (docs/35 section 9.3):
/// strip `@`, map `/` to `.`, and PascalCase each `-`/`_`/`.`-separated
/// segment (`node-fetch` -> `NodeFetch`, `@aws-sdk/client-s3` ->
/// `AwsSdk.ClientS3`).  A segment starting with a digit is prefixed `N` so
/// the identifier stays a valid Lyric name (`7zip` -> `N7zip`).
pub func npmPackageIdent(name: in String): String {
  val bare = if Str.startsWith(name, "@") { Str.substring(name, 1) } else { name }
  val scopes = Str.split(bare, "/")
  var result = ""
  var si = 0
  while si < scopes.length {
    var ident = ""
    var upperNext = true
    var ci = 0
    val seg = scopes[si]
    while ci < seg.length {
      val c = Str.charAtOrReplacement(seg, ci)
      if c == '-' or c == '_' or c == '.' or c == '~' {
        upperNext = true
      } else {
        val one = Str.substring(seg, ci, 1)
        ident = ident + (if upperNext { npmUpperAscii(one) } else { one })
        upperNext = false
      }
      ci += 1
    }
    if ident.length > 0 and Str.charAtOrReplacement(ident, 0) >= '0' and Str.charAtOrReplacement(ident, 0) <= '9' {
      ident = "N" + ident
    }
    result = if si == 0 { ident } else { result + "." + ident }
    si += 1
  }
  result
}

/// Assemble `[npm]` / `[npm.options]` (docs/35 section 9.1).  Mirrors
/// `assembleNuget`: a `"name" = "range"` entry, or the inline-table form with
/// a `version` key.  Names must be valid NPM names, ranges non-empty, and two
/// names that map to the same Lyric package identifier (Q-JS-004:
/// `foo-bar` and `foo_bar`) are rejected so a shim can never silently shadow
/// another.  `[npm.options].registry` must be an `http(s)://` URL.
func assembleNpm(entries: in List[Entry]): Result[Option[NpmSection], ManifestError] {
  val none: Option[NpmSection] = None
  if not hasSection(entries, "npm") and not hasSection(entries, "npm.options") {
    return Ok(value = none)
  }
  val npmEntries: List[NpmEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == "npm" {
      if not isValidNpmName(e.key) {
        return Err(
          error = InvalidField(
            section = "npm",
            field = e.key,
            message = "not a valid NPM package name (lowercase letters, digits and '-._~', optionally scoped as '@scope/name')"
          )
        )
      }
      val versionOpt: Option[String] = match e.value {
        case VStr(v) -> Some(value = v)
        case VTable(pairs) -> findInlineStr(pairs, "version")
        case _ -> None
      }
      val range = match versionOpt { case Some(v) -> Str.trim(v); case None -> "" }
      if range == "" {
        return Err(
          error = InvalidField(
            section = "npm",
            field = e.key,
            message = "expected a non-empty version range string or an inline table with a 'version' key"
          )
        )
      }
      if not isShimSafeRange(range) {
        return Err(
          error = InvalidField(
            section = "npm",
            field = e.key,
            message = "the version range must not contain a quote, backslash, '$' or control character"
          )
        )
      }
      val ident = npmPackageIdent(e.key)
      if ident.length == 0 {
        return Err(
          error = InvalidField(
            section = "npm",
            field = e.key,
            message = "has no letters or digits to build a Lyric package identifier from"
          )
        )
      }
      var j = 0
      while j < npmEntries.count {
        if npmShimFileName(npmEntries[j].name) == npmShimFileName(e.key) {
          return Err(
            error = InvalidField(
              section = "npm",
              field = e.key,
              message = "its shim file \"" + npmShimFileName(e.key) + "\" is already taken by \"" +
                npmEntries[j].name +
                "\""
            )
          )
        }
        if npmEntries[j].ident == ident {
          return Err(
            error = InvalidField(
              section = "npm",
              field = e.key,
              message = "maps to the Lyric package \"" + ident + "\", already taken by \"" + npmEntries[j].name +
                "\""
            )
          )
        }
        j += 1
      }
      npmEntries.add(NpmEntry(name = e.key, version = range, ident = ident))
    }
    i += 1
  }
  if hasKey(entries, "npm.options", "registry") and not hasString(entries, "npm.options", "registry") {
    return Err(error = InvalidField(section = "npm.options", field = "registry", message = "must be a quoted URL string"))
  }
  val registry = unwrapOr(findString(entries, "npm.options", "registry"), "")
  if registry != "" and not Str.startsWith(registry, "https://") and not Str.startsWith(registry, "http://") {
    return Err(
      error = InvalidField(
        section = "npm.options",
        field = "registry",
        message = "must be an http:// or https:// URL, got \"" + registry + "\""
      )
    )
  }
  Ok(value = Some(value = NpmSection(entries = npmEntries, registry = registry)))
}

// An `extra_libs` entry becomes a `-l<name>` clang flag; reject an empty
// name, one containing whitespace (any of space/tab/CR/LF — a stray CR can
// survive a CRLF-edited manifest, #4874), or one starting with `-` (the
// `["-lssl"]`-instead-of-`["ssl"]` mistake would yield `-l-lssl`, #4875) so a
// typo surfaces as a clear Lyric diagnostic instead of a cryptic clang/ld
// error (#4865).
func invalidLibName(name: in String): Bool {
  name.length == 0 or Str.startsWith(name, "-") or Str.contains(name, " ") or Str.contains(name, "\t") or
    Str.contains(name, "\n") or
    Str.contains(name, "\r")
}

/// `[native]` (N6.4): `triple` (LLVM target triple, default host),
/// `opt_level` (clang `-O` level, default "2"), and `extra_libs` (a
/// string array of additional `-l<name>` link flags).  `opt_level` is
/// validated against the same set the `--opt` CLI flag accepts
/// (0/1/2/3/s); each `extra_libs` entry must be a non-empty,
/// whitespace-free bare library name that does not start with `-`; any
/// violation is `Err(InvalidField)`.  Returns `Ok(None)` when no
/// `[native]` table is present.
func hasKey(entries: in List[Entry], section: in String, key: in String): Bool {
  var i = 0
  while i < entries.count {
    if entries[i].section == section and entries[i].key == key {
      return true
    }
    i += 1
  }
  false
}

func hasString(entries: in List[Entry], section: in String, key: in String): Bool {
  match findString(entries, section, key) {
    case Some(_) -> true
    case None -> false
  }
}

func hasInt(entries: in List[Entry], section: in String, key: in String): Bool {
  match findInt(entries, section, key) {
    case Some(_) -> true
    case None -> false
  }
}

func findInt(entries: in List[Entry], section: in String, key: in String): Option[Int] {
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.section == section and e.key == key {
      match e.value {
        case VInt(n) -> return Some(value = n)
        case _ -> return None
      }
    }
    i += 1
  }
  None
}

func isDigitText(s: in String): Bool {
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c < '0' or c > '9' {
      return false
    }
    i += 1
  }
  s.length > 0
}

/// `[wasm]` (docs/35 section 8): `version` (a `major.minor.patch` WIT package
/// version), `world` (a WIT world name: lowercase letters, digits and `-`,
/// starting with a letter) and `stack` (the shadow-stack size in bytes, a multiple
/// of 16 between 64 KiB and 64 MiB).
record WasmCfg {
  version: String
  world: String
  stack: Int
}

func assembleWasm(entries: in List[Entry]): Result[Option[WasmCfg], ManifestError] {
  val none: Option[WasmCfg] = None
  if not hasSection(entries, "wasm") {
    return Ok(value = none)
  }
  for key in ["version", "world"] {
    if hasKey(entries, "wasm", key) and not hasString(entries, "wasm", key) {
      return Err(error = InvalidField(section = "wasm", field = key, message = "must be a quoted string"))
    }
  }
  val version = unwrapOr(findString(entries, "wasm", "version"), "")
  if version != "" {
    val parts = Str.split(version, ".")
    if parts.length != 3 or not (isDigitText(parts[0]) and isDigitText(parts[1]) and isDigitText(parts[2])) {
      return Err(
        error = InvalidField(
          section = "wasm",
          field = "version",
          message = "must be major.minor.patch (for example \"1.2.0\"), got \"" + version + "\""
        )
      )
    }
  }
  val world = unwrapOr(findString(entries, "wasm", "world"), "")
  if world != "" {
    var wi = 0
    var bad = false
    while wi < world.length {
      val c = Str.charAtOrReplacement(world, wi)
      val isLower = c >= 'a' and c <= 'z'
      val isDigit = c >= '0' and c <= '9'
      if not (isLower or (wi > 0 and (isDigit or c == '-'))) {
        bad = true
      }
      wi += 1
    }
    if bad {
      return Err(
        error = InvalidField(
          section = "wasm",
          field = "world",
          message = "must be a WIT name (lowercase letters, digits and '-', starting with a letter), got \"" +
            world +
            "\""
        )
      )
    }
  }
  if hasKey(entries, "wasm", "stack") and not hasInt(entries, "wasm", "stack") {
    return Err(
      error = InvalidField(
        section = "wasm",
        field = "stack",
        message = "must be an integer number of bytes (a bare number, not a quoted string)"
      )
    )
  }
  val stackOpt = findInt(entries, "wasm", "stack")
  val stack = unwrapOr(stackOpt, 0)
  val stackDeclared = match stackOpt { case Some(_) -> true; case None -> false }
  if stackDeclared and (stack < 65536 or stack > 67108864 or stack % 16 != 0) {
    return Err(
      error = InvalidField(
        section = "wasm",
        field = "stack",
        message = "must be a multiple of 16 between 65536 and 67108864 bytes, got " + stack.toString()
      )
    )
  }
  Ok(value = Some(value = WasmCfg(version = version, world = world, stack = stack)))
}

func assembleNative(entries: in List[Entry]): Result[Option[NativeConfig], ManifestError] {
  match assembleWasm(entries) {
    case Err(e) -> return Err(error = e)
    case Ok(wasm) -> return assembleNativeWith(entries, wasm)
  }
}

func assembleNativeWith(entries: in List[Entry], wasm: in Option[WasmCfg]): Result[Option[NativeConfig], ManifestError] {
  val wasmVersion = match wasm { case Some(w) -> w.version; case None -> "" }
  val wasmWorld = match wasm { case Some(w) -> w.world; case None -> "" }
  val wasmStack = match wasm { case Some(w) -> w.stack; case None -> 0 }
  if not hasSection(entries, "native") {
    return match wasm {
      case None -> Ok(value = None)
      case Some(_) -> Ok(
        value = Some(
          value = NativeConfig(
            triple = "",
            optLevel = "",
            extraLibs = newList(),
            wasmVersion = wasmVersion,
            wasmWorld = wasmWorld,
            wasmStack = wasmStack
          )
        )
      )
    }
  }
  val triple = unwrapOr(findString(entries, "native", "triple"), "")
  val opt = unwrapOr(findString(entries, "native", "opt_level"), "")
  if opt != "" and opt != "0" and opt != "1" and opt != "2" and opt != "3" and opt != "s" {
    return Err(
      error = InvalidField(
        section = "native",
        field = "opt_level",
        message = "must be \"0\", \"1\", \"2\", \"3\", or \"s\", got \"" + opt + "\""
      )
    )
  }
  val libs: List[String] = unwrapOr(findStringList(entries, "native", "extra_libs"), newList())
  var li = 0
  while li < libs.count {
    if invalidLibName(libs[li]) {
      return Err(
        error = InvalidField(
          section = "native",
          field = "extra_libs",
          message = "library name must be a non-empty, whitespace-free bare name (not a \"-l\" flag), got \"" +
            libs[li] +
            "\""
        )
      )
    }
    li = li + 1
  }
  Ok(
    value = Some(
      value = NativeConfig(
        triple = triple,
        optLevel = opt,
        extraLibs = libs,
        wasmVersion = wasmVersion,
        wasmWorld = wasmWorld,
        wasmStack = wasmStack
      )
    )
  )
}

func isLayersSection(section: in String): Bool {
  section == "layers" or Str.startsWith(section, "layers.")
}

func layersInvalid(section: in String, field: in String, message: in String): ManifestError {
  InvalidField(section = section, field = field, message = message)
}

// A `may_import` / `may_not_import` value: a string array.
func layerNameList(section: in String, field: in String, v: in Value): Result[List[String], ManifestError] {
  match v {
    case VStrList(items) -> Ok(value = items)
    case _ -> Err(error = layersInvalid(section, field, "expected an array of strings"))
  }
}

// Adds or merges a rule, so `[layers.rules] x = {...}` and
// `[layers.rules.x]` cannot silently disagree: naming a rule twice is an
// error.
func addLayerRule(
  rules: in List[LayerRuleSpec], rule: in LayerRuleSpec, section: in String
): Result[Unit, ManifestError] {
  for r in rules {
    if r.name == rule.name {
      return Err(error = layersInvalid(section, rule.name, "rule '" + rule.name + "' is defined more than once"))
    }
  }
  rules.add(rule)
  Ok(value = ())
}

/// `[layers]` per docs/65 §5 (D149).  Accepts `preset` in `[layers]`,
/// package assignments in `[layers.packages]`, and rules either inline in
/// `[layers.rules]` or as `[layers.rules.<name>]` sub-tables.  Unknown keys
/// are errors rather than ignored, so a misspelt rule cannot silently
/// weaken the layering.  Returns `Ok(None)` when no layers table exists.
func assembleLayers(entries: in List[Entry]): Result[Option[LayersSection], ManifestError] {
  var present = false
  for e in entries {
    if isLayersSection(e.section) {
      present = true
    }
  }
  if not present {
    return Ok(value = None)
  }
  var preset = ""
  val packages: List[LayerAssignment] = newList()
  val rules: List[LayerRuleSpec] = newList()
  // Sub-table rules, keyed by name, in first-seen order.
  val subNames: List[String] = newList()
  for e in entries {
    if e.section == "layers" {
      if e.key == "preset" {
        match e.value {
          case VStr(v) -> {
            preset = v
          }
          case _ -> return Err(error = layersInvalid("layers", "preset", "expected a string"))
        }
      } else {
        return Err(error = layersInvalid("layers", e.key, "unknown key (expected 'preset')"))
      }
    } else if e.section == "layers.packages" {
      match e.value {
        case VStr(layer) -> packages.add(LayerAssignment(pattern = e.key, layer = layer))
        case _ -> return Err(error = layersInvalid("layers.packages", e.key, "expected a layer name string"))
      }
    } else if e.section == "layers.rules" {
      match e.value {
        case VTable(pairs) -> {
          var mayImport: List[String] = newList()
          var mayNot: List[String] = newList()
          var allowAsync = true
          for p in pairs {
            if p.key == "may_import" {
              match p.tval {
                case TVStrList(items) -> {
                  mayImport = items
                }
                case _ -> return Err(error = layersInvalid("layers.rules", e.key + ".may_import", "expected an array of strings"))
              }
            } else if p.key == "may_not_import" {
              match p.tval {
                case TVStrList(items) -> {
                  mayNot = items
                }
                case _ -> return Err(error = layersInvalid("layers.rules", e.key + ".may_not_import", "expected an array of strings"))
              }
            } else if p.key == "async" {
              match p.tval {
                case TVBool(b) -> {
                  allowAsync = b
                }
                case _ -> return Err(error = layersInvalid("layers.rules", e.key + ".async", "expected true or false"))
              }
            } else {
              return Err(
                error = layersInvalid(
                  "layers.rules",
                  e.key + "." + p.key,
                  "unknown key (expected 'may_import', 'may_not_import' or 'async')"
                )
              )
            }
          }
          match addLayerRule(rules, LayerRuleSpec(name = e.key, mayImport = mayImport, mayNotImport = mayNot, allowAsync = allowAsync), "layers.rules") {
            case Err(err) -> return Err(error = err)
            case Ok(_) -> ()
          }
        }
        case _ -> return Err(error = layersInvalid("layers.rules", e.key, "expected an inline table { may_import = [...], ... }"))
      }
    } else if Str.startsWith(e.section, "layers.rules.") {
      val name = Str.substring(e.section, 13, e.section.length - 13)
      if e.key != "may_import" and e.key != "may_not_import" and e.key != "async" {
        return Err(
          error = layersInvalid(e.section, e.key, "unknown key (expected 'may_import', 'may_not_import' or 'async')")
        )
      }
      if not listContains(subNames, name) {
        subNames.add(name)
      }
    } else if isLayersSection(e.section) {
      return Err(
        error = layersInvalid(
          e.section,
          e.key,
          "unknown table (expected [layers], [layers.packages] or [layers.rules])"
        )
      )
    }
  }
  for name in subNames {
    val section = "layers.rules." + name
    var mayImport: List[String] = newList()
    var mayNot: List[String] = newList()
    var allowAsync = true
    for e in entries {
      if e.section == section {
        if e.key == "may_import" {
          match layerNameList(section, e.key, e.value) {
            case Err(err) -> return Err(error = err)
            case Ok(items) -> {
              mayImport = items
            }
          }
        } else if e.key == "may_not_import" {
          match layerNameList(section, e.key, e.value) {
            case Err(err) -> return Err(error = err)
            case Ok(items) -> {
              mayNot = items
            }
          }
        } else {
          match e.value {
            case VBool(b) -> {
              allowAsync = b
            }
            case _ -> return Err(error = layersInvalid(section, e.key, "expected true or false"))
          }
        }
      }
    }
    match addLayerRule(rules, LayerRuleSpec(name = name, mayImport = mayImport, mayNotImport = mayNot, allowAsync = allowAsync), section) {
      case Err(err) -> return Err(error = err)
      case Ok(_) -> ()
    }
  }
  Ok(value = Some(value = LayersSection(preset = preset, packages = packages, rules = rules)))
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
        case VTable(pairs) -> match findInlineStr(pairs, "path") {
          case Some(dir) -> overrides.add(WorkspaceOverride(name = e.key, dir = dir))
          case None -> ()
        }
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
/// True when the TOML text contains a `[package]` section header, regardless
/// of whether the section's required fields are complete — or even present
/// at all (#5862, #5865).  Used by `Lyric.Discovery`'s upward walk to
/// distinguish "not a package manifest at all" (e.g. a virtual `[workspace]`
/// root — keep walking) from "a package manifest that is present but
/// incomplete" (stop and report): `assemblePackage` emits the identical
/// `MissingField("package", "name")` for both shapes, so the error alone
/// cannot make that distinction.  Implemented as a textual header-line scan
/// rather than `collectEntries` + `hasSection`: a bare `[package]` header
/// with zero key/value lines under it produces no `Entry` rows at all
/// (#5865), so the entries view cannot see it.  This parser's TOML subset
/// has no multi-line strings, so a section header is always a whole line of
/// its own and the scan is exact.
pub func textHasPackageSection(text: in String): Bool {
  val lines = Str.split(text, "\n")
  var i = 0
  while i < lines.count {
    if Str.trim(lines[i]) == "[package]" {
      return true
    }
    i += 1
  }
  false
}

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
    case Ok(entries) -> match assemblePackage(entries) {
      case Err(e) -> Err(error = e)
      case Ok(pkg) -> {
        val project = assembleProject(entries)
        val ws = assembleWorkspace(entries)
        val reg = assembleRegistry(entries)
        match assembleNpm(entries) {
          case Err(e) -> Err(error = e)
          case Ok(npmOpt) -> match assembleNuget(entries) {
            case Err(e) -> Err(error = e)
            case Ok(nuget) -> match assembleDeps(entries) {
              case Err(e) -> Err(error = e)
              case Ok(deps) -> match assembleFeatures(entries) {
                case Err(e) -> Err(error = e)
                case Ok(featuresOpt) -> match assembleMaven(entries) {
                  case Err(e) -> Err(error = e)
                  case Ok(mavenOpt) -> match assembleBuild(entries) {
                    case Err(e) -> Err(
                      error = e
                    )
                    case Ok(buildOpt) -> match assembleNative(entries) {
                      case Err(e) -> Err(
                        error = e
                      )
                      case Ok(nativeOpt) -> match assembleContracts(entries) {
                        case Err(e) -> Err(
                          error = e
                        )
                        case Ok(contractsOpt) -> match assembleLayers(entries) {
                          case Err(e) -> Err(
                            error = e
                          )
                          case Ok(layersOpt) -> Ok(
                            value = Manifest(
                              filePath = filePath,
                              packageSection = pkg,
                              project = project,
                              deps = deps,
                              nuget = nuget,
                              maven = mavenOpt,
                              npm = npmOpt,
                              features = featuresOpt,
                              build = buildOpt,
                              workspace = ws,
                              registry = reg,
                              native = nativeOpt,
                              contracts = contractsOpt,
                              layers = layersOpt
                            )
                          )
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
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
    case Ok(entries) -> match assembleWorkspace(entries) {
      case None -> Ok(value = None)
      case Some(ws) -> Ok(
        value = Some(
          value = WorkspaceRoot(
            filePath = filePath,
            workspace = ws,
            registry = assembleRegistry(entries)
          )
        )
      )
    }
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

/// Return the `[build.define]` entries (as `"KEY=VALUE"` strings, docs/60 §3.1)
/// from the manifest, or an empty list when no `[build]`/`[build.define]` table
/// is present. The build pipeline layers these beneath CLI `--define`s (CLI
/// wins) and above the auto-injected well-known `version` fallback.
pub func getManifestBuildDefines(m: in Manifest): List[String] {
  match m.build {
    case Some(b) -> return b.defines
    case None -> return newList()
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
