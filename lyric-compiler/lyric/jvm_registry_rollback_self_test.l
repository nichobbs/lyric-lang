//! jvm_registry_rollback_self_test.l — regression test for `Jvm.Bridge`'s
//! bundle-wide registry rollback (review finding #6766, PR #6631):
//!
//! Inside `compileToJarBundled`'s bundling loop, a bundled package's
//! `collectAspectWovenSigs` / `collectBModeWovenSigs` /
//! `collectMonoSpecializedSigs` / `collectFileCasesExtern` /
//! `collectFileCtors` calls mutate the shared, bundle-wide, first-wins
//! `registry` / `caseReg` / `ctorReg` maps BEFORE `codegenPackageInto` runs.
//! When codegen then panics and the package is not call-reachable, the
//! catch arm records a J003 note and skips the package silently — but
//! nothing previously rolled back the registrations already made, leaving
//! stale entries in the shared maps that point at classes never written to
//! the JAR.  The fix: `snapshotKeySet(m)` before an unreached package's
//! registration runs, `rollbackNewKeys(m, before)` on a codegen panic.
//!
//! Investigation (documented here rather than dropping the finding
//! silently, per CLAUDE.md): a black-box JAR test that discriminates
//! before/after this fix could not be constructed. Every consultation path
//! for the three registries these five functions populate has its own
//! independent "check the consuming package's own registration first"
//! protection: `importAwareRegistry` (own-imports-last-wins) for `registry`,
//! and `ctorClassFor`'s owner-scoped-key-first lookup for `ctorReg`. Both
//! shield ANY other package that legitimately needs the identical
//! compiler-synthesised symbol shape, because such a package always
//! independently re-derives (and thus re-registers) its own copy before its
//! own codegen runs — the five functions register ONLY compiler-synthesised,
//! package-private names (aspect-woven renames, B'-mode shared types,
//! mono-specialised copies), never something another package could
//! reference without producing a matching entry of its own. Verified
//! empirically below: the same-shared-template B'-mode leak+victim JAR
//! builds and runs identically with the rollback temporarily disabled and
//! with the fix applied. The fix stands as defense-in-depth per CLAUDE.md's
//! no-shortcuts standard — a J003-skipped package's stale bundle-wide state
//! must never persist regardless of whether today's other protections mask
//! its consequences — and this test pins the real end-to-end interaction
//! between J003-skip and the rollback landing in the same PR, at the same
//! rigor this PR's other multi-package tests use.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_registry_rollback_self_test.l
@test_module
package Lyric.JvmRegistryRollbackSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-rollback-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// `LeakPkg` and `VictimPkg` both consume the SAME cross-package aspect
// template (`LibTpl.Tap`), which is B'-mode by default (no `@inline_template`
// — docs/27 §6.1) and synthesises a shared `__LyricBModeCallContext` record
// PLUS its constructor into EVERY weaving file's own registry entries
// (`collectFileCtors`/`collectFileCasesExtern`, one of the five #6766
// registration paths).  `LeakPkg.poison()` is matched by the template and
// deliberately panics in JVM codegen (`old(...)` is unsupported there); it
// is never called from anywhere, so it is genuinely, correctly unreachable
// and gets silently J003-skipped.  `VictimPkg.greet()` is ALSO matched by
// the same template, and IS reachable (called from `main`).
test "a J003-skipped B'-mode package does not break another package sharing the same template" {
  val stdlibSources: List[String] = newList()
  stdlibSources.add(
    "package LibTpl\n" + "\n" + "pub aspect Tap {\n" + "  around(call) -> ret {\n" + "    ret = call.proceed()\n" +
      "  }\n" +
      "}\n"
  )
  stdlibSources.add(
    "package LeakPkg\n" + "\n" + "import LibTpl\n" + "\n" + "aspect Guard from LibTpl.Tap {\n" +
      "  matches: name in { poison }\n" +
      "}\n" +
      "\n" +
      "pub func poison(): Int {\n" +
      "  old(1)\n" +
      "}\n"
  )
  stdlibSources.add(
    "package VictimPkg\n" + "\n" + "import LibTpl\n" + "\n" + "aspect Guard2 from LibTpl.Tap {\n" +
      "  matches: name in { greet }\n" +
      "}\n" +
      "\n" +
      "pub func greet(): String {\n" +
      "  \"hi\"\n" +
      "}\n"
  )
  val source = "package EntryPkg\n" + "\n" + "import VictimPkg\n" + "\n" + "func main(): Int {\n" +
    "  println(VictimPkg.greet())\n" +
    "  0\n" +
    "}\n"
  val dir = freshTempDir("bmode-rollback")
  val jarPath = Path.join(dir, "bmode-rollback.jar")
  val ok = compileToJarBundled(source, jarPath, "bmode-rollback", stdlibSources, "0.1.0")
  if not ok {
    cleanup(dir)
    panic("bmode-rollback: compileToJarBundled returned false")
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  assertEqualInt(result.exitCode, 0, "bmode_rollback: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "hi",
    "bmode_rollback: VictimPkg.greet() runs correctly despite LeakPkg's J003-skip"
  )
}

// #5932: a package assembled from TWO bundled stdlib source files (mirroring
// a top-level `lyric-stdlib/std/<pkg>.l` plus an additive
// `lyric-stdlib/std/_kernel_jvm/<other>.l` declaring the SAME `package`)
// must codegen as ONE class carrying every file's functions. Before the fix,
// `Jvm.Bridge`'s `stdlibByPkg` map kept only the FIRST-parsed file for a
// given package name; the second file's declarations still type-checked
// (registered via `importedPkgs`) but its bytecode was silently absent from
// the bundle, so calling into EITHER file's functions from a THIRD package
// could hit `NoSuchMethodError` depending on which file's class won the
// race. Both `first()` (from the first-listed source) and `second()` (from
// the second) must be callable from the entry package.
test "a package split across two bundled stdlib source files codegens both files' functions (#5932)" {
  val stdlibSources: List[String] = newList()
  stdlibSources.add("package SplitPkg\n" + "\n" + "pub func first(): Int {\n" + "  1\n" + "}\n")
  stdlibSources.add("package SplitPkg\n" + "\n" + "pub func second(): Int {\n" + "  2\n" + "}\n")
  val source = "package SplitEntryPkg\n" + "\n" + "import SplitPkg\n" + "\n" + "func main(): Int {\n" +
    "  println(SplitPkg.first().toString())\n" + "  println(SplitPkg.second().toString())\n" + "  0\n" + "}\n"
  val dir = freshTempDir("split-pkg")
  val jarPath = Path.join(dir, "split-pkg.jar")
  val ok = compileToJarBundled(source, jarPath, "split-pkg", stdlibSources, "0.1.0")
  if not ok {
    cleanup(dir)
    panic("split-pkg: compileToJarBundled returned false")
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  assertEqualInt(result.exitCode, 0, "split_pkg: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "1\n2",
    "split_pkg: both SplitPkg.first() and SplitPkg.second() are present in the bundled class"
  )
}
