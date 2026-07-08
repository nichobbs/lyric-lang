//! jvm/auto_ffi.l — JDK metadata-based auto-FFI resolution for the JVM backend.
//!
//! Resolves `extern type Math = "java.lang.Math"` call sites at compile time by
//! reading the actual method signatures from JDK reference assemblies (.jmod
//! files).  The resolved signature drives correct `invokestatic` / `invokevirtual`
//! emission instead of the legacy `([Object...])Object` guess.
//!
//! JDK discovery: JAVA_HOME → /usr/lib/jvm/* → /Library/Java/JavaVirtualMachines/*
//! → C:/Program Files/Java/*.  The first directory containing java.base.jmod wins.
//!
//! Class loading: classes are loaded lazily on first request and cached.
//! java.base.jmod is tried first (contains the vast majority of JDK classes);
//! other JMODs are tried in listing order when the class is not found there.
//!
//! Overload resolution: argument types from the Lyric call site (expressed as
//! JVM descriptor strings: "I", "J", "D", "F", "Z", "Ljava/lang/String;", etc.)
//! are scored against each candidate overload.  Widening numeric conversions are
//! accepted at a lower score than exact matches.
package Jvm.AutoFfi

import Std.Core
import Std.Collections
import Std.Environment as Env
import Std.File as File
import Std.String as Str
import Jvm.ZipReader
import Jvm.ClassReader

// ── Auto-FFI context ──────────────────────────────────────────────────────────
pub record AutoFfiCtx {
  jmodsDir: String
  // Colon-separated list of additional JAR paths for Maven/non-JDK classes.
  // Populated from the LYRIC_FFI_JARS environment variable at context creation.
  jarPaths: List[String]
  // Resolved-class cache as two parallel lists (binaryName → ClassInfo) rather
  // than a `Map`: the stage-0 bootstrap emitter miscompiles `Map`/`Option`
  // value threading for cross-package record element types (e.g.
  // `Map[String, ClassInfo]` lookups silently drop the hit), so the loading
  // chain uses plain `List` accumulators it compiles correctly.
  cacheKeys: List[String]
  cacheVals: List[ClassInfo]
  // Negative-lookup cache: binary names (e.g. "Pkg/MyRecord") that were not
  // found in any JMOD or JAR.  Prevents repeated JMOD central-directory scans
  // for Lyric-native record types whose JVM binary name will never match a
  // class entry (#2181).  Same parallel-list pattern, keyed by binary name.
  missKeys: List[String]
  // ── JDK discovery ─────────────────────────────────────────────────────────────
}

func probeJmodsDir(dir: in String, found: in List[String]): Unit {
  if found.count == 0 and File.fileExists(dir + "/java.base.jmod") {
    found.add(dir)
  }
}

func findJmodsDir(): String {
  val found: List[String] = newList()

  val javaHome = Env.getVarOrDefault("JAVA_HOME", "")
  if javaHome.length > 0 {
    probeJmodsDir(javaHome + "/jmods", found)
  }

  // Linux: /usr/lib/jvm/<jdk-dir>/jmods
  if found.count == 0 {
    match File.listDirs("/usr/lib/jvm") {
      case Ok(dirs) -> {
        var i = 0
        while i < dirs.count and found.count == 0 {
          probeJmodsDir(dirs[i] + "/jmods", found)
          i = i + 1
        }
      }
      case Err(_) -> ()
    }
  }

  // macOS: /Library/Java/JavaVirtualMachines/<dir>/Contents/Home/jmods
  if found.count == 0 {
    match File.listDirs("/Library/Java/JavaVirtualMachines") {
      case Ok(dirs) -> {
        var i = 0
        while i < dirs.count and found.count == 0 {
          probeJmodsDir(dirs[i] + "/Contents/Home/jmods", found)
          i = i + 1
        }
      }
      case Err(_) -> ()
    }
  }

  // Windows: C:/Program Files/Java/<dir>/jmods
  if found.count == 0 {
    match File.listDirs("C:/Program Files/Java") {
      case Ok(dirs) -> {
        var i = 0
        while i < dirs.count and found.count == 0 {
          probeJmodsDir(dirs[i] + "/jmods", found)
          i = i + 1
        }
      }
      case Err(_) -> ()
    }
  }

  if found.count > 0 {
    found[0]
  } else {
    ""
  }
}

// True when the running Lyric CLI process's own host platform is Windows.
// Mirrors the `Str.startsWith(rid, "win")` check against
// `Std.Environment.runtimeIdentifier()` (e.g. "win-x64", "linux-x64",
// "osx-arm64") already used in `app_host.l` / `release.l`.  This is the host
// platform the CLI itself runs on — `LYRIC_FFI_JARS` is set by the shell
// that invokes the CLI, so its separator convention follows that host, not
// the JVM target being compiled for.
func isWindowsHost(): Bool {
  Str.startsWith(Env.runtimeIdentifier(), "win")
}

// Split a path-list string into individual paths on a single caller-chosen
// separator character, using the platform-correct separator only: `;` on
// Windows, `:` everywhere else (#2214).  Splitting on BOTH characters
// unconditionally (the previous behaviour) misparsed a Windows absolute
// path's drive-letter colon (e.g. `C:\foo.jar;D:\bar.jar` split into four
// bogus parts instead of two).
//
// Takes `isWin` explicitly (rather than calling `isWindowsHost()` directly)
// so tests can exercise the Windows-separator behaviour deterministically
// regardless of the actual host the test suite runs on — the same
// explicit-platform-parameter pattern `AppHost.launcherName` /
// `AppHost.preferHostRid` use for testability.
pub func splitPathListOn(s: in String, isWin: in Bool): List[String] {
  val sep = if isWin { ';' } else { ':' }
  val parts: List[String] = newList()
  var start = 0
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == sep {
      if i > start {
        parts.add(s.substring(start, i - start))
      }
      start = i + 1
    }
    i = i + 1
  }
  if s.length > start {
    parts.add(s.substring(start, s.length - start))
  }
  parts
}

func splitPathList(s: in String): List[String] {
  splitPathListOn(s, isWindowsHost())
}

// Discover additional JAR paths from the LYRIC_FFI_JARS environment variable.
// LYRIC_FFI_JARS is a colon-separated (Unix) or semicolon-separated (Windows)
// list of absolute paths to JAR files to include in auto-FFI class resolution.
// Set it to the classpath of resolved Maven dependencies, e.g.:
//   export LYRIC_FFI_JARS=$(mvn -q dependency:build-classpath \
//     -DincludeTypes=jar -Dmdep.outputFile=/dev/stdout 2>/dev/null)
func findJarPaths(): List[String] {
  val raw = Env.getVarOrDefault("LYRIC_FFI_JARS", "")
  if raw.length == 0 {
    return newList()
  }
  splitPathList(raw)
}

/// Build the auto-FFI context.  Discovers the JDK jmods directory via
/// $JAVA_HOME and common system paths, and reads additional JAR paths from
/// the LYRIC_FFI_JARS environment variable.  The class cache starts empty.
pub func buildAutoFfiCtx(): AutoFfiCtx {
  AutoFfiCtx(
    jmodsDir = findJmodsDir(),
    jarPaths = findJarPaths(),
    cacheKeys = newList(),
    cacheVals = newList(),
    missKeys = newList()
  )
}

// ── Class loading ─────────────────────────────────────────────────────────────
//
// The whole chain reads each JMOD directly (no byte / entry caches) and
// threads results through plain `var` accumulators rather than returning
// `Option`/`Map` values out of `match`-arm or `try`-expression positions.
// This is deliberate: the stage-0 bootstrap emitter that compiles this
// self-hosted compiler package miscompiles those patterns for cross-package
// record types (it drops the value, yielding a spurious `None`), so the
// loading chain sticks to assign-into-`var` control flow it lowers correctly.
// Convert "java.lang.Math" → "classes/java/lang/Math.class"  (JMOD layout)
func javaFqnToJmodEntry(javaFqn: in String): String {
  "classes/" + javaFqn.replace(".", "/") + ".class"
}

// Convert "java.lang.Math" → "java/lang/Math.class"  (JAR layout — no classes/ prefix)
func javaFqnToJarEntry(javaFqn: in String): String {
  javaFqn.replace(".", "/") + ".class"
}

// True when `opt` carries a value.  Used in place of an `Option`-returning
// `match` arm so the stage-0 emitter keeps the wrapped record intact.
func classFound(opt: in Option[ClassInfo]): Bool {
  var found = false
  match opt {
    case Some(_) -> {
      found = true
    }
    case None -> ()
  }
  found
}

// Try to load and parse a class entry from a specific JMOD or JAR archive.
// Returns the parsed `ClassInfo` or `None` when the entry is absent or
// the archive is unreadable.  Both JMODs (ZIP + 4-byte magic header) and
// plain JARs (standard ZIP) are handled by `readZipEntries`.
func tryLoadFromArchive(archivePath: in String, entryPath: in String): Option[ClassInfo] {
  var result: Option[ClassInfo] = None
  if File.fileExists(archivePath) {
    try {
      val bytes = File.readBytesOrPanic(archivePath)
      val entries = readZipEntries(bytes)
      match extractByName(bytes, entries, entryPath) {
        case Some(classBytes) -> {
          result = parseClass(classBytes)
        }
        case None -> ()
      }
    } catch Bug as _ {
      result = None
    }
  }
  result
}

// Convenience wrapper: try to load a class from a JMOD using the JMOD entry
// path convention ("classes/...").
func tryLoadFromJmod(jmodPath: in String, entryPath: in String): Option[ClassInfo] {
  tryLoadFromArchive(jmodPath, entryPath)
}

func loadClassInfo(ctx: in AutoFfiCtx, javaFqn: in String): Option[ClassInfo] {
  val jmodEntryPath = javaFqnToJmodEntry(javaFqn)
  val jarEntryPath = javaFqnToJarEntry(javaFqn)

  // ── JDK jmods ─────────────────────────────────────────────────────────────
  var result: Option[ClassInfo] = None
  if ctx.jmodsDir.length > 0 {
    val baseJmod = ctx.jmodsDir + "/java.base.jmod"
    // java.base.jmod holds the vast majority of JDK classes; try it first.
    result = tryLoadFromJmod(baseJmod, jmodEntryPath)

    // Otherwise scan the remaining JMODs in listing order.
    if not classFound(result) {
      match File.listFiles(ctx.jmodsDir) {
        case Ok(jmodFiles) -> {
          var ji = 0
          while ji < jmodFiles.count and not classFound(result) {
            val jmod = jmodFiles[ji]
            if jmod != baseJmod and jmod.endsWith(".jmod") {
              result = tryLoadFromJmod(jmod, jmodEntryPath)
            }
            ji = ji + 1
          }
        }
        case Err(_) -> ()
      }
    }
  }

  // ── Maven / additional JARs (LYRIC_FFI_JARS) ──────────────────────────────
  // Scan each JAR path if the class was not found in the JDK jmods.  JAR
  // entries use the flat "com/example/Foo.class" path (no "classes/" prefix).
  if not classFound(result) {
    var ji = 0
    while ji < ctx.jarPaths.count and not classFound(result) {
      result = tryLoadFromArchive(ctx.jarPaths[ji], jarEntryPath)
      ji = ji + 1
    }
  }

  result
}

// Adds a freshly loaded ClassInfo to the parallel-list cache.  Called with
// `ci` as a direct function-argument from the loadClass match arm — the
// known-safe pattern under stage-0, which drops cross-package record bindings
// when they are accessed inside a block body (`case Some(ci) -> { ci.field }`).
func addClassToCache(ctx: in AutoFfiCtx, binaryName: in String, ci: in ClassInfo): Unit {
  ctx.cacheKeys.add(binaryName)
  ctx.cacheVals.add(ci)
}

/// Load (and cache) the public-method surface for a Java class.
/// `javaFqn` is the dotted name e.g. "java.lang.Math".
/// Negative lookups are cached in `ctx.missKeys` so that Lyric-native record
/// types (whose JVM binary names never match a JMOD entry) don't trigger a
/// repeated JMOD central-directory scan on every method call (#2181).
pub func loadClass(ctx: in AutoFfiCtx, javaFqn: in String): Option[ClassInfo] {
  val binaryName = javaFqn.replace(".", "/")

  // Linear scan of the positive cache (see `AutoFfiCtx`).
  var i = 0
  while i < ctx.cacheKeys.count {
    if ctx.cacheKeys[i] == binaryName {
      return Some(value = ctx.cacheVals[i])
    }
    i = i + 1
  }

  // Linear scan of the negative (miss) cache: skip the JMOD scan entirely for
  // binary names already known to be absent.
  var mi = 0
  while mi < ctx.missKeys.count {
    if ctx.missKeys[mi] == binaryName {
      return None
    }
    mi = mi + 1
  }

  var currentFqn = javaFqn
  var loaded: Option[ClassInfo] = None
  var done = false

  while not done {
    loaded = loadClassInfo(ctx, currentFqn)
    match loaded {
      case Some(_) -> {
        done = true
      }
      case None -> {
        // Try replacing the last dot with '$'
        var lastDotIdx = -1
        var idx = 0
        while idx < currentFqn.length {
          if currentFqn.substring(idx, 1) == "." {
            lastDotIdx = idx
          }
          idx = idx + 1
        }
        if lastDotIdx >= 0 {
          currentFqn = currentFqn.substring(0, lastDotIdx) + "$" +
            currentFqn.substring(lastDotIdx + 1, currentFqn.length - lastDotIdx - 1)
        } else {
          done = true
        }
      }
    }
  }

  // Pass `ci` as a direct function argument from the match arm expression
  // (not inside a block body) so stage-0 lowers the binding correctly.
  match loaded {
    case Some(ci) -> addClassToCache(ctx, binaryName, ci)
    case None -> ctx.missKeys.add(binaryName)
  }
  loaded
}

// ── Overload resolution ───────────────────────────────────────────────────────
// Parse parameter descriptor list from a JVM method descriptor "(params)ret".
// Each element is a raw descriptor string: "I", "J", "Ljava/lang/String;", etc.
pub func parseDescriptorParams(descriptor: in String): List[String] {
  val params: List[String] = newList()
  val len = descriptor.length
  if len < 2 or descriptor[0] != '(' {
    return params
  }
  var i = 1
  while i < len and descriptor[i] != ')' {
    val ch = descriptor[i]
    if ch == 'L' {
      var j = i + 1
      while j < len and descriptor[j] != ';' {
        j = j + 1
      }
      // Include the full "L...;" form: start=i, count=j-i+1
      params.add(descriptor.substring(i, j - i + 1))
      i = j + 1
    } else if ch == '[' {
      // Array: capture the bracket + element
      val start = i
      i = i + 1
      if i < len and descriptor[i] == 'L' {
        while i < len and descriptor[i] != ';' {
          i = i + 1
        }
        i = i + 1
      } else {
        i = i + 1
      }
      params.add(descriptor.substring(start, i - start))
    } else {
      params.add("" + ch)
      i = i + 1
    }
  }
  params
}

// True when `desc` is one of the 8 JVM primitive array descriptors
// (`boolean[]`/`char[]`/`float[]`/`double[]`/`byte[]`/`short[]`/`int[]`/
// `long[]`).  Self-contained (no dependency on `Jvm.Codegen`'s `JvmType`) so
// `scoreParamMatch` can recognize any primitive array as a valid — if
// low-priority — target for a Lyric slice argument.
func isPrimitiveArrayDesc(desc: in String): Bool {
  desc == "[Z" or desc == "[C" or desc == "[F" or desc == "[D" or desc == "[B" or desc == "[S" or desc == "[I" or
    desc == "[J"
}

// Context-free descriptor scoring (numeric widening, exact match, any-ref→Object,
// slice→primitive-array).  Returns -1 for incompatible AND for reference/reference
// pairs — those need the class hierarchy, which `scoreParam` resolves via
// `isAssignableRef`.  Module-private: external callers must use `scoreParam` (which
// layers the IS-A check on top), so a bare reference/reference pair here never
// means "definitively incompatible".
func scoreParamMatch(argDesc: in String, paramDesc: in String): Int {
  if argDesc == paramDesc {
    return 10
  }
  // exact match
  // Primitive → java/lang/Object: valid via boxing (`emitFfiCoerce` boxes),
  // low priority so an exact-primitive overload always wins.  Lets JDK
  // collection methods take raw primitives (`ArrayList.add(7)`,
  // `bytes.add(0xFF)` on a List[Byte]).
  if paramDesc == "Ljava/lang/Object;" {
    if argDesc == "I" or argDesc == "J" or argDesc == "D" or argDesc == "F" or argDesc == "Z" or argDesc == "B" or argDesc == "C" or argDesc == "S" {
      return 2
    }
  }
  // Numeric widening
  if argDesc == "I" {
    if paramDesc == "J" {
      return 7
    }
    if paramDesc == "D" {
      return 5
    }
    if paramDesc == "F" {
      return 5
    }
    return -1
  }
  if argDesc == "J" {
    if paramDesc == "D" {
      return 5
    }
    if paramDesc == "F" {
      return 3
    }
    return -1
  }
  if argDesc == "F" {
    if paramDesc == "D" {
      return 5
    }
    return -1
  }
  // Any reference type → java/lang/Object
  if paramDesc == "Ljava/lang/Object;" and argDesc.startsWith("L") {
    return 3
  }
  if argDesc == "" and paramDesc.startsWith("L") {
    return 3
  }
  // Lyric slice (`[Ljava/lang/Object;`, the erased slice[T] representation)
  // → any JDK primitive array.  `emitFfiCoerce` materialises a real
  // primitive array by unboxing each element (generalized from a
  // byte[]-only special case), so this is a valid (if low-priority) match
  // for any of the 8 JVM primitive array element types.  Enables
  // `_kernel_jvm` hosts to hand slices to JDK APIs such as
  // `java.security.MessageDigest.digest(byte[])` or `String(char[])`.
  if argDesc == "[Ljava/lang/Object;" and isPrimitiveArrayDesc(paramDesc) {
    return 2
  }
  // Reference/reference pairs are not classified here: the descriptor strings
  // alone do not carry the class hierarchy.  `scoreParam` (which has the auto-FFI
  // context) resolves these via `isAssignableRef`, scoring a verified IS-A match
  // above the blind fallback.  Returning -1 keeps this function pure.
  return -1
}

// `Lxxx;` reference descriptor → JVM binary name (`Ljava/util/List;` ->
// `java/util/List`); "" for any non-object descriptor (primitive, array, …).
func refDescToBinary(desc: in String): String {
  if desc.length >= 3 and desc.startsWith("L") and desc.endsWith(";") {
    desc.substring(1, desc.length - 2)
  } else {
    ""
  }
}

// True when reference type `fromBin` IS-A `toBin` per loaded class metadata:
// walks `fromBin`'s superclass chain, matching each class and its directly-declared
// interfaces.  Interface→super-interface chains are not followed (the reader skips
// ACC_INTERFACE files), so an unprovable assignability returns `false` and the
// caller falls back to the permissive blind match — never a rejection.  Uses the
// load → `findCacheIdx` → `cacheVals[idx]` walk to dodge the stage-0 Option binding bug.
func isAssignableRef(ctx: in AutoFfiCtx, fromBin: in String, toBin: in String): Bool {
  if fromBin == toBin {
    return true
  }
  if toBin == "java/lang/Object" {
    return true
  }
  var cur = fromBin
  var guard = 0
  while cur.length > 0 and guard < 64 {
    if cur == toBin {
      return true
    }
    val fqn = cur.replace("/", ".")
    loadClass(ctx, fqn)
    val idx = findCacheIdx(ctx, cur)
    if idx < 0 {
      return false
    }
    val ci = ctx.cacheVals[idx]
    var i = 0
    while i < ci.interfaces.count {
      if ci.interfaces[i] == toBin {
        return true
      }
      i = i + 1
    }
    cur = ci.superName
    guard = guard + 1
  }
  false
}

// Score one argument descriptor against one parameter descriptor with auto-FFI
// context.  Delegates the context-free cases to `scoreParamMatch`; for an
// otherwise-unmatched reference/reference pair, a verified IS-A match scores 4
// (ranking above the blind fallback, below an exact match at 10) and an
// unverifiable pair scores 1 (permissive — the JVM verifier enforces the true
// constraint at class-load).
func scoreParam(ctx: in AutoFfiCtx, argDesc: in String, paramDesc: in String): Int {
  val base = scoreParamMatch(argDesc, paramDesc)
  if base >= 0 {
    return base
  }
  if argDesc.startsWith("L") and paramDesc.startsWith("L") {
    val fromBin = refDescToBinary(argDesc)
    val toBin = refDescToBinary(paramDesc)
    if fromBin.length > 0 and toBin.length > 0 and isAssignableRef(ctx, fromBin, toBin) {
      return 4
    }
    return 1
  }
  return -1
}

// Score a method against a list of argument descriptor strings.
// Returns -1 for incompatible, else the sum of per-parameter scores.
func scoreMethod(ctx: in AutoFfiCtx, method: in ClassMethod, argDescs: in List[String], wantStatic: in Bool): Int {
  if wantStatic and not method.isStatic {
    return -1
  }
  val params = parseDescriptorParams(method.descriptor)
  if params.count != argDescs.count {
    return -1
  }
  var total = 0
  var i = 0
  while i < params.count {
    val s = scoreParam(ctx, argDescs[i], params[i])
    if s < 0 {
      return -1
    }
    total = total + s
    i = i + 1
  }
  total
}

// True when `desc` is the erased Lyric slice representation used for a
// `slice[T]` argument (`Object[]`, per `typeExprToJvm`'s `TSlice` erasure in
// `jvm/codegen/01_types.l`).
func isErasedSliceDesc(desc: in String): Bool {
  desc == "[Ljava/lang/Object;"
}

// Panics with a compile-time diagnostic when 2+ candidates tied at the
// winning score bind the SAME `slice[T]` argument position to DIFFERENT
// primitive array parameter types.  `scoreParamMatch`'s generalization (any
// of the 8 JVM primitive-array descriptors scores equally against an erased
// `slice[T]` argument) means a JDK overload family differing only by
// primitive element type — `String(byte[])` vs `String(char[])`,
// `Arrays.hashCode(int[])` vs `Arrays.hashCode(long[])`, and dozens of
// similar `java.util.Arrays` families — would otherwise tie and silently
// resolve to whichever overload happens to appear first in the parsed class
// metadata, not the caller's actual intent.  A Lyric `slice[T]` erases to
// `Object[]` before this resolver ever sees it, with no element-type
// information surviving to disambiguate correctly here, so refusing with a
// diagnostic is the honest alternative to silently guessing.
func checkPrimitiveArraySliceAmbiguity(
  what: in String,
  argDescs: in List[String],
  candidates: in List[ClassMethod],
  scores: in List[Int],
  bestScore: in Int,
): Unit {
  var argIdx = 0
  while argIdx < argDescs.count {
    if isErasedSliceDesc(argDescs[argIdx]) {
      val seenTypes: List[String] = newList()
      var j = 0
      while j < candidates.count {
        if scores[j] == bestScore {
          val params = parseDescriptorParams(candidates[j].descriptor)
          if argIdx < params.count {
            val pd = params[argIdx]
            if isPrimitiveArrayDesc(pd) and not seenTypes.contains(pd) {
              seenTypes.add(pd)
            }
          }
        }
        j = j + 1
      }
      if seenTypes.count > 1 {
        panic(
          "JVM auto-FFI: ambiguous overload for '" + what +
            "' — a Lyric slice[T] argument matches more than one primitive array parameter type with equal score, and the erased slice[T] representation carries no element-type information to disambiguate. Use a differently-shaped call, or bind the target member explicitly (e.g. @externTarget), to select an unambiguous overload."
        )
      }
    }
    argIdx = argIdx + 1
  }
}

/// Find the best-matching method in `ci` for the given name and argument
/// descriptor strings.  Each element of `argDescs` is a JVM type descriptor
/// produced by `jvmTypeToDescStr` in Jvm.Codegen.
pub func findBestMethod(
  ctx: in AutoFfiCtx,
  ci: in ClassInfo,
  methodName: in String,
  argDescs: in List[String],
  wantStatic: in Bool,
): Option[ClassMethod] {
  val candidates: List[ClassMethod] = newList()
  val scores: List[Int] = newList()
  var best: Option[ClassMethod] = None
  var bestScore: Int = -1
  var i = 0
  while i < ci.methods.count {
    val m = ci.methods[i]
    if m.name == methodName {
      val s = scoreMethod(ctx, m, argDescs, wantStatic)
      if s >= 0 {
        candidates.add(m)
        scores.add(s)
        if s > bestScore {
          bestScore = s
          best = Some(value = m)
        }
      }
    }
    i = i + 1
  }
  if bestScore >= 0 {
    checkPrimitiveArraySliceAmbiguity(ci.binaryName + "." + methodName, argDescs, candidates, scores, bestScore)
  }
  best
}

/// Find the best-matching constructor in `ci` for the given argument descriptor
/// strings.  Searches the `constructors` list (public `<init>` entries).
pub func findBestConstructor(ctx: in AutoFfiCtx, ci: in ClassInfo, argDescs: in List[String]): Option[ClassMethod] {
  val candidates: List[ClassMethod] = newList()
  val scores: List[Int] = newList()
  var best: Option[ClassMethod] = None
  var bestScore: Int = -1
  var i = 0
  while i < ci.constructors.count {
    val m = ci.constructors[i]
    val s = scoreMethod(ctx, m, argDescs, false)
    // Explicit `s >= 0` mirrors `scoreAndGetSuper` / `findBestInstanceMethod`:
    // negative means "no match" per the `scoreMethod` convention.  The
    // initialisation of `bestScore = -1` provides an equivalent implicit guard
    // today, but the explicit form is more robust if the sentinel ever shifts
    // (e.g. scoreMethod returning 0 for no-match in a future refactor) (#2226).
    if s >= 0 {
      candidates.add(m)
      scores.add(s)
      if s > bestScore {
        bestScore = s
        best = Some(value = m)
      }
    }
    i = i + 1
  }
  if bestScore >= 0 {
    checkPrimitiveArraySliceAmbiguity(ci.binaryName + ".<init>", argDescs, candidates, scores, bestScore)
  }
  best
}

// Returns the cache index for `binaryName` (e.g. "java/lang/Math"), or -1.
func findCacheIdx(autoFfi: in AutoFfiCtx, binaryName: in String): Int {
  var i = 0
  while i < autoFfi.cacheKeys.count {
    if autoFfi.cacheKeys[i] == binaryName {
      return i
    }
    i = i + 1
  }
  -1
}

// Score instance methods of `sci` for the given name and args, appending each
// compatible (method, score) pair to the accumulator lists.  Returns
// `sci.superName` for the next chain iteration.
// `sci` is received as a function parameter — the only stage-0-safe way to
// access fields of a cross-package record type that arrived via an Option match.
func scoreAndGetSuper(
  ctx: in AutoFfiCtx,
  sci: in ClassInfo,
  methodName: in String,
  argDescs: in List[String],
  allMethods: in List[ClassMethod],
  allScores: in List[Int],
): String {
  var j = 0
  while j < sci.methods.count {
    val m = sci.methods[j]
    if m.name == methodName {
      val s = scoreMethod(ctx, m, argDescs, false)
      if s >= 0 {
        allMethods.add(m)
        allScores.add(s)
      }
    }
    j = j + 1
  }
  sci.superName
}

// True when `needle` already appears in `haystack`.  Used by
// `scoreInterfacesRec` to guard against re-scoring the same interface twice
// under diamond inheritance (e.g. two sibling interfaces that both extend a
// common ancestor) — real-world APIs like Lettuce's `RedisCommands` extend
// 15+ sibling command interfaces, so without this guard a shared ancestor
// would otherwise produce duplicate candidates and a false-positive
// ambiguity warning from `checkPrimitiveArraySliceAmbiguity`.
func binNameSeen(haystack: in List[String], needle: in String): Bool {
  var i = 0
  while i < haystack.count {
    if haystack[i] == needle {
      return true
    }
    i = i + 1
  }
  false
}

// Recursively score `methodName` against `ifaceBin` and every interface it
// (transitively) extends.  A class's own `superName` chain only follows
// single inheritance (JVMS `super_class`); an interface's *extends* list is
// `ClassInfo.interfaces` instead, and Java interfaces support extending
// several parents at once, so this needs its own walk rather than reusing
// `scoreAndGetSuper`'s single-parent loop.  Needed because a method is often
// declared on a narrower sibling interface rather than the one an extern
// type is actually bound to — e.g. `io.lettuce.core.api.sync.RedisCommands`
// (the umbrella interface `Session.Kernel.Jvm`'s `RedisStoreHandle` stores)
// declares no `get`/`set`/`setex`/`del`/`expire` methods of its own; they
// live one level down on `RedisStringCommands`/`RedisKeyCommands`.  The
// *emitted* `invokeinterface` still names the original receiver's interface
// as the constant-pool owner (see `lowerAutoFfiInstanceCall`) — that is
// intentional and correct: JVMS 5.4.3.4's interface-method-resolution
// algorithm itself searches superinterfaces at link time, so only the
// compile-time *lookup* (finding the descriptor to type-check and encode
// the call against) needs this extra walk, not the bytecode's owner field.
func scoreInterfacesRec(
  autoFfi: in AutoFfiCtx,
  ifaceBin: in String,
  methodName: in String,
  argDescs: in List[String],
  allMethods: in List[ClassMethod],
  allScores: in List[Int],
  visited: in List[String],
): Unit {
  if binNameSeen(visited, ifaceBin) {
    return
  }
  visited.add(ifaceBin)
  loadClass(autoFfi, ifaceBin.replace("/", "."))
  val idx = findCacheIdx(autoFfi, ifaceBin)
  if idx < 0 {
    return
  }
  val ici = autoFfi.cacheVals[idx]
  var j = 0
  while j < ici.methods.count {
    val m = ici.methods[j]
    if m.name == methodName {
      val s = scoreMethod(autoFfi, m, argDescs, false)
      if s >= 0 {
        allMethods.add(m)
        allScores.add(s)
      }
    }
    j = j + 1
  }
  var k = 0
  while k < ici.interfaces.count {
    scoreInterfacesRec(autoFfi, ici.interfaces[k], methodName, argDescs, allMethods, allScores, visited)
    k = k + 1
  }
}

/// Find the best-matching instance method in `ci`, walking up the superclass
/// chain when the method is declared in a superclass (e.g. `length()` on
/// `StringBuilder` is declared in `AbstractStringBuilder`), and recursively
/// through every (transitively) extended interface — both `ci`'s own
/// `interfaces` list and each superclass's — since interface method lookup
/// doesn't follow the single-parent `superName` chain (see
/// `scoreInterfacesRec`).
///
/// Uses the parallel-list cache to avoid the stage-0 Option[ClassInfo]
/// match-arm binding bug: each superclass is loaded into the cache via
/// `loadClass`, then accessed directly via `cacheVals[idx]` and passed to
/// `scoreAndGetSuper` as a function parameter — the known-safe pattern.
pub func findBestInstanceMethod(
  autoFfi: in AutoFfiCtx,
  ci: in ClassInfo,
  methodName: in String,
  argDescs: in List[String],
): Option[ClassMethod] {
  val allMethods: List[ClassMethod] = newList()
  val allScores: List[Int] = newList()
  val visitedIfaces: List[String] = newList()
  visitedIfaces.add(ci.binaryName)

  // Score the declared class directly (ci is a function parameter — safe).
  var i = 0
  while i < ci.methods.count {
    val m = ci.methods[i]
    if m.name == methodName {
      val s = scoreMethod(autoFfi, m, argDescs, false)
      if s >= 0 {
        allMethods.add(m)
        allScores.add(s)
      }
    }
    i = i + 1
  }

  // `ci` may itself be an interface (e.g. `io.lettuce.core.api.sync.
  // RedisCommands`) whose own class file declares none of the methods
  // reachable through it — those live on the (possibly several) interfaces
  // it extends.  Walk `ci.interfaces` transitively before the superclass
  // chain below (see `scoreInterfacesRec`).
  var ifI = 0
  while ifI < ci.interfaces.count {
    scoreInterfacesRec(autoFfi, ci.interfaces[ifI], methodName, argDescs, allMethods, allScores, visitedIfaces)
    ifI = ifI + 1
  }

  // Walk the superclass chain.  Each iteration:
  //   1. Calls loadClass to populate the parallel-list cache.
  //   2. Locates the entry by key scan (avoids Option[ClassInfo] binding).
  //   3. Passes cacheVals[idx] directly to scoreAndGetSuper as a function
  //      argument — the known-safe pattern for cross-package record types
  //      under stage-0 (which drops bindings accessed in block bodies).
  //   4. Also walks that superclass's own directly-implemented interfaces
  //      transitively (a concrete class can implement interfaces the
  //      auto-FFI receiver's own declared type never mentions).
  //
  // The walk continues all the way up to (and including) `java/lang/Object`
  // (#2219): `ClassInfo.superName` is "" for Object itself (see
  // `class_reader.l`), so the loop terminates naturally once Object has been
  // scored — no explicit `java/lang/Object` cutoff is needed.  Before this
  // fix, methods declared *only* on Object and never overridden anywhere in
  // the chain (`getClass()`, `notify()`, `notifyAll()`, `wait()`) were
  // invisible to the resolver.
  var superBin = ci.superName
  while superBin.length > 0 {
    val superFqn = superBin.replace("/", ".")
    loadClass(autoFfi, superFqn)
    // populate cache; return value intentionally unused
    val superIdx = findCacheIdx(autoFfi, superBin)
    var nextSuper = ""
    if superIdx >= 0 {
      val sci = autoFfi.cacheVals[superIdx]
      nextSuper = scoreAndGetSuper(autoFfi, sci, methodName, argDescs, allMethods, allScores)
      var siI = 0
      while siI < sci.interfaces.count {
        scoreInterfacesRec(autoFfi, sci.interfaces[siI], methodName, argDescs, allMethods, allScores, visitedIfaces)
        siI = siI + 1
      }
    }
    superBin = nextSuper
  }

  // Pick the best candidate from all collected methods.
  var best: Option[ClassMethod] = None
  var bestScore: Int = -1
  var k = 0
  while k < allMethods.count {
    if allScores[k] > bestScore {
      bestScore = allScores[k]
      best = Some(value = allMethods[k])
    }
    k = k + 1
  }
  if bestScore >= 0 {
    checkPrimitiveArraySliceAmbiguity(ci.binaryName + "." + methodName, argDescs, allMethods, allScores, bestScore)
  }
  best
}

// Locate a public STATIC field named `fieldName` on `ci` or a superclass.
// Exact-name match, no overloads (JVMS forbids same-name fields in one class);
// the declared class wins over inherited fields.  Lets the codegen resolve JDK
// constants (`System.out`, `Duration.ZERO`, `System.in`) as `getstatic` where
// method resolution finds nothing.
pub func findStaticField(autoFfi: in AutoFfiCtx, ci: in ClassInfo, fieldName: in String): Option[ClassMethod] {
  match fieldInClass(ci, fieldName) {
    case Some(f) -> {
      return Some(value = f)
    }
    case None -> ()
  }
  // Walk the superclass chain through the cache (same shape as
  // findBestInstanceMethod; fields on java/lang/Object don't exist, so the
  // Object cutoff loses nothing here).
  var superBin = ci.superName
  while superBin.length > 0 and superBin != "java/lang/Object" {
    val superFqn = superBin.replace("/", ".")
    loadClass(autoFfi, superFqn)
    val superIdx = findCacheIdx(autoFfi, superBin)
    if superIdx < 0 {
      return None
    }
    match fieldInClass(autoFfi.cacheVals[superIdx], fieldName) {
      case Some(f) -> {
        return Some(value = f)
      }
      case None -> ()
    }
    superBin = superNameOf(autoFfi.cacheVals[superIdx])
  }
  None
}

// The declared static field named `fieldName` on exactly this class, if any.
func fieldInClass(ci: in ClassInfo, fieldName: in String): Option[ClassMethod] {
  var i = 0
  while i < ci.fields.count {
    val f = ci.fields[i]
    if f.name == fieldName and f.isStatic {
      return Some(value = f)
    }
    i = i + 1
  }
  None
}

// Superclass accessor kept as a function so the record field is read off a
// direct argument (the stage-0-safe pattern for cross-package record types).
func superNameOf(ci: in ClassInfo): String {
  ci.superName
}

// Verify that a declared @externTarget signature has a matching overload in JDK
// class metadata.  Returns true when the match succeeds or when the class is not
// found in the JDK index (non-JDK types, or JDK not present — no false positive).
// Returns false when the class IS found but no overload matches the declared arg
// descriptors.
//
// Extracted as a top-level function so callers (lowerExternTargetBody in
// jvm/codegen/04_calls.l) avoid the stage-0 `case Some(ci) -> { block }` binding
// bug for cross-package record types: the Option[ClassInfo] match is kept inside
// this function, which stage-0 compiles correctly when the bound value is passed
// directly as a function argument rather than used in an outer block body.
pub func verifyExternTargetJvm(
  ctx: in AutoFfiCtx,
  javaFqn: in String,
  methodName: in String,
  argDescs: in List[String],
  wantStatic: in Bool,
): Bool {
  match loadClass(ctx, javaFqn) {
    case None -> true
    case Some(ci) -> {
      val resolved = if methodName == "new" {
        findBestConstructor(ctx, ci, argDescs)
      } else {
        findBestMethod(ctx, ci, methodName, argDescs, wantStatic)
      }
      match resolved {
        case Some(_) -> true
        case None -> false
      }
    }
  }
}
