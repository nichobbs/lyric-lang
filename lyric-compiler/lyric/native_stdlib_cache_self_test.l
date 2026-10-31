//! native_stdlib_cache_self_test.l - the bundled-stdlib check cache of
//! `--target native` (#7971, `Lyric.NativeStdlibCache`): hit, invalidation of
//! every key input, fallback on a corrupt entry, the compiler fingerprint, and
//! the predicate that decides which packages may be cached.
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/native_stdlib_cache_self_test.l
@test_module
package Lyric.NativeStdlibCacheSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Time
import Std.Environment as Environment
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Pipeline
import Lyric.NativeStdlibCache as C

func scratch(label: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  val dir = Path.join(base, "lyric-nsc-" + label + "-" + toString(nowEpochMillis()))
  val _ = File.createDir(dir)
  dir
}

func parts(own: in String, dep: in String): List[C.KeyPart] {
  val ps: List[C.KeyPart] = newList()
  ps.add(C.KeyPart(name = "Std.A", sourceHash = own))
  ps.add(C.KeyPart(name = "Std.B", sourceHash = dep))
  ps
}

func keyOf(own: in String, dep: in String): String {
  C.entryKey("compiler1", "native:linux", "Std.A", parts(own, dep))
}

test "a stored entry is a hit for the same key" {
  val dir = Path.join(scratch("hit"), "cache")
  val key = keyOf("h1", "h2")
  assertFalse(C.lookup(dir, key), "nothing stored yet")
  assertTrue(C.store(dir, key), "store creates the directory and the entry")
  assertTrue(C.lookup(dir, key), "the same key hits")
  assertEqual(keyOf("h1", "h2"), key, "keys are deterministic")
}

test "a source edit of the package, or of its import closure, changes the key" {
  val base = keyOf("h1", "h2")
  assertTrue(keyOf("h1x", "h2") != base, "own source edit invalidates")
  assertTrue(keyOf("h1", "h2x") != base, "closure source edit invalidates")
  val dir = Path.join(scratch("inv"), "cache")
  val _ = C.store(dir, base)
  assertFalse(C.lookup(dir, keyOf("h1x", "h2")), "an edited package misses")
  assertFalse(C.lookup(dir, keyOf("h1", "h2x")), "an edited dependency misses")
  assertTrue(C.lookup(dir, base), "the unedited key still hits")
}

test "compiler, target, package and closure membership each change the key" {
  val base = keyOf("h1", "h2")
  assertTrue(C.entryKey("compiler2", "native:linux", "Std.A", parts("h1", "h2")) != base, "compiler fingerprint")
  assertTrue(C.entryKey("compiler1", "native:windows", "Std.A", parts("h1", "h2")) != base, "target os")
  assertTrue(C.entryKey("compiler1", "native:linux", "Std.Z", parts("h1", "h2")) != base, "package name")
  val fewer: List[C.KeyPart] = newList()
  fewer.add(C.KeyPart(name = "Std.A", sourceHash = "h1"))
  assertTrue(C.entryKey("compiler1", "native:linux", "Std.A", fewer) != base, "a dropped import")
  val swapped: List[C.KeyPart] = newList()
  swapped.add(C.KeyPart(name = "Std.A", sourceHash = "h1"))
  swapped.add(C.KeyPart(name = "Std.B", sourceHash = "h2"))
  swapped.add(C.KeyPart(name = "Std.C", sourceHash = "h3"))
  assertTrue(C.entryKey("compiler1", "native:linux", "Std.A", swapped) != base, "an added import")
}

test "an unknown compiler disables the cache" {
  assertEqual(C.entryKey("", "native:linux", "Std.A", parts("h1", "h2")), "", "no compiler id, no key")
  val dir = Path.join(scratch("off"), "cache")
  assertFalse(C.store(dir, ""), "an empty key is never stored")
  assertFalse(C.lookup(dir, ""), "an empty key never hits")
  assertFalse(C.store("", keyOf("h1", "h2")), "an empty directory is never written")
  assertFalse(C.lookup("", keyOf("h1", "h2")), "an empty directory never hits")
}

test "a corrupt, truncated, edited, foreign or unreadable entry is a miss" {
  val dir = Path.join(scratch("corrupt"), "cache")
  val key = keyOf("h1", "h2")
  val other = keyOf("h9", "h9")
  val _ = C.store(dir, key)
  val _ = C.store(dir, other)
  val path = Path.join(dir, key + ".ok")
  val good = File.readTextOrPanic(path)
  assertTrue(C.lookup(dir, key), "starts valid")

  val _ = File.writeText(path, "")
  assertFalse(C.lookup(dir, key), "empty file")
  val _ = File.writeText(path, Str.substring(good, 0, good.length - 5))
  assertFalse(C.lookup(dir, key), "truncated file")
  val _ = File.writeText(path, good + "extra\n")
  assertFalse(C.lookup(dir, key), "trailing garbage")
  val _ = File.writeText(path, "not a cache entry")
  assertFalse(C.lookup(dir, key), "foreign contents")
  val _ = File.writeText(path, File.readTextOrPanic(Path.join(dir, other + ".ok")))
  assertFalse(C.lookup(dir, key), "another key's entry copied over this one")
  val _ = File.deleteFile(path)
  val _ = File.createDir(path)
  assertFalse(C.lookup(dir, key), "a directory where the entry should be")

  val _ = File.deleteDirRecursive(path)
  assertTrue(C.store(dir, key), "a damaged entry is replaced by the next store")
  assertTrue(C.lookup(dir, key), "and hits again")
  assertEqual(File.readTextOrPanic(path), good, "byte-identical to the original entry")
}

test "store fails soft when the directory cannot be created" {
  val blocker = Path.join(scratch("blocked"), "file")
  val _ = File.writeText(blocker, "x")
  assertFalse(
    C.store(Path.join(blocker, "cache"), keyOf("h1", "h2")),
    "a file in the way costs the entry, not the build"
  )
}

test "the compiler fingerprint follows the compiler files and nothing else" {
  val dir = scratch("fp")
  assertEqual(C.compilerFingerprint(""), "", "no directory")
  assertEqual(C.compilerFingerprint(Path.join(dir, "missing")), "", "unreadable directory")
  val _ = File.writeText(Path.join(dir, "unrelated.txt"), "a")
  assertEqual(C.compilerFingerprint(dir), "", "no compiler file")
  val _ = File.writeText(Path.join(dir, "Lyric.Lyric.TypeChecker.dll"), "one")
  val _ = File.writeText(Path.join(dir, "lyric"), "exe")
  val f1 = C.compilerFingerprint(dir)
  assertTrue(f1.length > 0, "found")
  assertEqual(C.compilerFingerprint(dir), f1, "stable")
  val _ = File.writeText(Path.join(dir, "unrelated.txt"), "b")
  assertEqual(C.compilerFingerprint(dir), f1, "unrelated files are ignored")
  val _ = File.writeText(Path.join(dir, "Lyric.Lyric.TypeChecker.dll"), "two")
  assertTrue(C.compilerFingerprint(dir) != f1, "a rebuilt compiler DLL changes it")
  val _ = File.writeText(Path.join(dir, "Lyric.Lyric.TypeChecker.dll"), "one")
  assertEqual(C.compilerFingerprint(dir), f1, "and restoring it restores it")
  val _ = File.writeText(Path.join(dir, "lyric"), "exe2")
  assertTrue(C.compilerFingerprint(dir) != f1, "a changed executable changes it")
}

func sitesFor(src: in String): Bool {
  val pr = parse(src)
  val noPkgs: List[ImportedPackage] = newList()
  val res = checkWithImportedPackagesForNative(pr.file, noPkgs)
  stdlibLoweringIsIdentity(res.symbols)
}

test "only a package the lowering passes leave unchanged is cacheable" {
  assertTrue(sitesFor("package P\npub func f(x: in Int): Int { x + 1 }\n"), "plain code has no sites")
  assertFalse(
    sitesFor("package P\npub func f(a: in array[4, Int], i: in Int): Int { a[i] }\n"),
    "array indexing is lowered, so the package is checked in full"
  )
}
