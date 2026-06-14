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

// Split a colon/semicolon-delimited path string into individual paths.
// Handles both `:` (Unix) and `;` (Windows) separators, treating each as a
// delimiter.  NOTE: on Windows, absolute paths contain a drive-letter colon
// (e.g. `C:\foo.jar`).  Because `:` is also treated as a delimiter here,
// `C:\foo.jar;D:\bar.jar` is incorrectly split into four parts.  Windows
// users must use `;` exclusively as the separator AND ensure no drive-letter
// colons appear in the value — or, better, use a semicolon-only list (#2214).
func splitPathList(s: in String): List[String] {
  val parts: List[String] = newList()
  var start = 0
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == ':' or c == ';' {
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

  val loaded = loadClassInfo(ctx, javaFqn)
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

// Score how well a Lyric JVM-type-descriptor string matches a JVM param descriptor.
// Returns -1 for incompatible; 0+ for compatible (higher = better match).
// Lyric type descriptor strings come from `jvmTypeToDescStr` in codegen.l:
//   "I"=int, "J"=long, "D"=double, "F"=float, "Z"=boolean,
//   "B"=byte, "C"=char, "S"=short,
//   "Ljava/lang/String;" or other "L...;" for references, "" for unknown.
pub func scoreParamMatch(argDesc: in String, paramDesc: in String): Int {
  if argDesc == paramDesc {
    return 10
  }
  // exact match
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
  // Lyric byte slice (`[Ljava/lang/Object;`, the erased slice[Byte]
  // representation) → JDK primitive `byte[]`.  `emitFfiCoerce` materialises
  // a real `byte[]` by unboxing each element, so this is a valid (if low-
  // priority) match.  Enables `_kernel_jvm` hosts to hand byte slices to
  // JDK APIs such as `java.security.MessageDigest.digest(byte[])`.
  if argDesc == "[Ljava/lang/Object;" and paramDesc == "[B" {
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

// True when a value of reference type `fromBin` is assignable to a parameter of
// reference type `toBin` (IS-A), per the loaded class metadata: `toBin` is
// `Object`, or one of `fromBin`'s (transitive) superclasses, or a directly-
// declared interface of `fromBin` or any of its superclasses.
//
// Interface→super-interface chains are NOT followed: the class reader skips
// ACC_INTERFACE class files, so an interface's own super-interfaces are
// unavailable.  Such a (rarer) assignability therefore reports `false` here, and
// `scoreParam` falls back to the low-priority blind match — never to a rejection,
// so an assignability we cannot prove never blocks a real call.  Walks the
// superclass chain with the load → `findCacheIdx` → `cacheVals[idx]` pattern that
// avoids the stage-0 `Option[ClassInfo]` match-arm binding bug.
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
  var best: Option[ClassMethod] = None
  var bestScore: Int = -1
  var i = 0
  while i < ci.methods.count {
    val m = ci.methods[i]
    if m.name == methodName {
      val s = scoreMethod(ctx, m, argDescs, wantStatic)
      if s > bestScore {
        bestScore = s
        best = Some(value = m)
      }
    }
    i = i + 1
  }
  best
}

/// Find the best-matching constructor in `ci` for the given argument descriptor
/// strings.  Searches the `constructors` list (public `<init>` entries).
pub func findBestConstructor(ctx: in AutoFfiCtx, ci: in ClassInfo, argDescs: in List[String]): Option[ClassMethod] {
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
    if s >= 0 and s > bestScore {
      bestScore = s
      best = Some(value = m)
    }
    i = i + 1
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

/// Find the best-matching instance method in `ci`, walking up the superclass
/// chain when the method is declared in a superclass (e.g. `length()` on
/// `StringBuilder` is declared in `AbstractStringBuilder`).
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

  // Walk the superclass chain.  Each iteration:
  //   1. Calls loadClass to populate the parallel-list cache.
  //   2. Locates the entry by key scan (avoids Option[ClassInfo] binding).
  //   3. Passes cacheVals[idx] directly to scoreAndGetSuper as a function
  //      argument — the known-safe pattern for cross-package record types
  //      under stage-0 (which drops bindings accessed in block bodies).
  //
  // NOTE (#2219): the loop terminates before reaching `java/lang/Object`, so
  // methods declared *only* in Object and not overridden in any non-Object
  // superclass are invisible to the resolver.  Affected methods include
  // `getClass()`, `notify()`, `notifyAll()`, `wait()`, and unoverridden
  // `hashCode()`/`equals()`/`toString()`.  A follow-up must extend the loop
  // to include Object itself to support those calls via auto-FFI.
  var superBin = ci.superName
  while superBin.length > 0 and superBin != "java/lang/Object" {
    val superFqn = superBin.replace("/", ".")
    loadClass(autoFfi, superFqn)
    // populate cache; return value intentionally unused
    val superIdx = findCacheIdx(autoFfi, superBin)
    var nextSuper = ""
    if superIdx >= 0 {
      nextSuper = scoreAndGetSuper(autoFfi, autoFfi.cacheVals[superIdx], methodName, argDescs, allMethods, allScores)
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
  best
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
