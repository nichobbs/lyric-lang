/// Tests for multi-file built-in packages (Phase 5 §M5.1 stage-2,
/// per `docs/19-multi-file-packages.md`).
///
/// We point the `LYRIC_TESTPKG_PATH` env var at a temp directory that
/// holds a synthetic two-file package `Testpkg.MultiFile`.  Building
/// a user program that `import Testpkg.MultiFile.{...}` exercises
/// the multi-file resolver (`locateBuiltinFiles`) + merge helper
/// (`parseAndMergeBuiltinFiles`) end-to-end without depending on the
/// stdlib's source layout.
///
/// `Testpkg` is wired as a built-in head so the existing emitter
/// resolution path applies.  The single-file legacy form is exercised
/// by every other emitter test in the suite, so the assertions here
/// focus on the multi-file specifics: declarations from different
/// files merging into one symbol table, imports from different files
/// composing, and a built-in package found in a directory rather than
/// at a top-level `.l` file.
module Lyric.Emitter.Tests.MultiFilePackageTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private writeTempPackage
        (rootName: string)
        (packageBaseName: string)
        (files: (string * string) list)
        : string =
    let root = Path.Combine(Path.GetTempPath(), rootName + "-" + Guid.NewGuid().ToString("N"))
    let pkgDir = Path.Combine(root, packageBaseName)
    Directory.CreateDirectory(pkgDir) |> ignore
    for (name, content) in files do
        File.WriteAllText(Path.Combine(pkgDir, name), content)
    root

// Sequenced because each test races on the `LYRIC_TESTPKG_PATH`
// env var — Expecto's default parallel scheduler would interleave
// the env-var save/set/restore cycles and corrupt test isolation.
let tests =
    testSequenced
    <| testList "multi-file packages" [

        // Two files declare `package Testpkg.MultiFile`; one defines
        // `pub func twice`, the other defines `pub func square`.  A
        // user program imports both and prints the sum, asserting
        // both declarations participated in the merged symbol table.
        testCase "[two_files_merge_into_one_package]" <| fun () ->
            let twiceL =
                "package Testpkg.MultiFile\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func twice(x: in Int): Int { x + x }\n"
            let squareL =
                "package Testpkg.MultiFile\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func square(x: in Int): Int { x * x }\n"
            let root =
                writeTempPackage
                    "lyric-multifile-merge"
                    "multi_file"
                    [ "twice.l",  twiceL
                      "square.l", squareL ]
            // The resolver reads Testpkg.MultiFile from
            // <root>/multi_file/*.l per `segmentToFileBase`.
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package MultiFileUser\n" +
                    "import Testpkg.MultiFile.{twice, square}\n" +
                    "func main(): Unit {\n" +
                    "  println(twice(5) + square(3))\n" +
                    "}\n"
                let _, stdout, stderr, exitCode =
                    compileAndRun "multi_file_merge" userSrc
                Expect.equal exitCode 0
                    (sprintf "exit 0 expected (stderr=%s)" stderr)
                // 2*5 + 3*3 = 19.
                Expect.stringContains stdout "19"
                    (sprintf "stdout should contain '19' (got: '%s')" stdout)
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)

        // A multi-file package whose two files declare conflicting
        // imports (one `import Std.Core`, one `import Std.Math`) is
        // legal — the merge unions imports.
        testCase "[two_files_with_distinct_imports]" <| fun () ->
            let aL =
                "package Testpkg.Imports\n" +
                "import Std.Core\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func wrapInt(n: in Int): Option[Int] { Some(value = n) }\n"
            let bL =
                "package Testpkg.Imports\n" +
                "import Std.Math.{absInt}\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func absoluteValue(n: in Int): Int { absInt(n) }\n"
            let root =
                writeTempPackage
                    "lyric-multifile-imports"
                    "imports"
                    [ "a.l", aL
                      "b.l", bL ]
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package MultiFileImportsUser\n" +
                    "import Testpkg.Imports.{absoluteValue}\n" +
                    "func main(): Unit {\n" +
                    "  println(absoluteValue(-7))\n" +
                    "}\n"
                let _, stdout, stderr, exitCode =
                    compileAndRun "multi_file_imports" userSrc
                Expect.equal exitCode 0
                    (sprintf "exit 0 expected (stderr=%s)" stderr)
                Expect.stringContains stdout "7"
                    (sprintf "stdout should contain '7' (got: '%s')" stdout)
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)

        // B0010: package matches BOTH single-file `<base>.l` AND a
        // multi-file `<base>/` directory in the same root.  Refused
        // outright so the user picks one.
        testCase "[B0010_layout_conflict]" <| fun () ->
            let root =
                Path.Combine(
                    Path.GetTempPath(),
                    "lyric-multifile-b0010-" + Guid.NewGuid().ToString("N"))
            Directory.CreateDirectory(root) |> ignore
            // Write both forms: a single-file `b0010.l` AND a
            // `b0010/` directory containing one `.l`.
            File.WriteAllText(
                Path.Combine(root, "b0010.l"),
                "package Testpkg.B0010\npub func one(): Int { 1 }\n")
            let dir = Path.Combine(root, "b0010")
            Directory.CreateDirectory(dir) |> ignore
            File.WriteAllText(
                Path.Combine(dir, "two.l"),
                "package Testpkg.B0010\npub func two(): Int { 2 }\n")
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package B0010User\n" +
                    "import Testpkg.B0010.{one}\n" +
                    "func main(): Unit { println(one()) }\n"
                let result, _, _, _ = compileAndRun "b0010_layout" userSrc
                let layoutErrs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Code = "B0010")
                Expect.isNonEmpty layoutErrs "expected B0010 layout-conflict diagnostic"
                let msg = (List.head layoutErrs).Message
                Expect.stringContains msg "single-file and multi-file"
                    "B0010 message mentions both layouts"
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)

        // B0011: duplicate `pub func twice/1` across two files of the
        // same package.  The duplicate is dropped; the diagnostic
        // surfaces with both file names.  Function arity participates
        // in the key so `pub func twice(x: Int)` and `pub func twice(x: Int, y: Int)`
        // co-exist as legitimate overloads.
        testCase "[B0011_duplicate_decl_across_files]" <| fun () ->
            let aL =
                "package Testpkg.Dup\n" +
                "pub func twice(x: in Int): Int { x + x }\n"
            let bL =
                "package Testpkg.Dup\n" +
                "pub func twice(x: in Int): Int { x * 2 }\n"  // dup
            let root =
                writeTempPackage
                    "lyric-multifile-b0011"
                    "dup"
                    [ "a.l", aL
                      "b.l", bL ]
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package B0011User\n" +
                    "import Testpkg.Dup.{twice}\n" +
                    "func main(): Unit { println(twice(5)) }\n"
                let result, _, _, _ = compileAndRun "b0011_dup" userSrc
                let dupErrs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Code = "B0011")
                Expect.isNonEmpty dupErrs "expected B0011 duplicate-decl diagnostic"
                let msg = (List.head dupErrs).Message
                Expect.stringContains msg "duplicate declaration"
                    "B0011 message says 'duplicate declaration'"
                Expect.stringContains msg "twice"
                    "B0011 message names the duplicated symbol"
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)

        // B0012: same alias mapped to different targets across files.
        testCase "[B0012_conflicting_import_alias]" <| fun () ->
            let aL =
                "package Testpkg.AliasConflict\n" +
                "import Std.Core as A\n" +
                "pub func one(): Int { 1 }\n"
            let bL =
                "package Testpkg.AliasConflict\n" +
                "import Std.Math as A\n" +    // same alias, different target
                "pub func two(): Int { 2 }\n"
            let root =
                writeTempPackage
                    "lyric-multifile-b0012"
                    "alias_conflict"
                    [ "a.l", aL
                      "b.l", bL ]
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package B0012User\n" +
                    "import Testpkg.AliasConflict.{one}\n" +
                    "func main(): Unit { println(one()) }\n"
                let result, _, _, _ = compileAndRun "b0012_alias" userSrc
                let aliasErrs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Code = "B0012")
                Expect.isNonEmpty aliasErrs "expected B0012 alias-conflict diagnostic"
                let msg = (List.head aliasErrs).Message
                Expect.stringContains msg "conflicting import alias"
                    "B0012 message says 'conflicting import alias'"
                Expect.stringContains msg "'A'"
                    "B0012 message names the conflicting alias"
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)

        // Function overloading by arity is preserved across files —
        // not flagged as B0011.  Two files contribute different-arity
        // versions of `add`; the user can call either.
        testCase "[overload_by_arity_across_files]" <| fun () ->
            let aL =
                "package Testpkg.Overload\n" +
                "pub func add(x: in Int): Int { x }\n"  // arity 1
            let bL =
                "package Testpkg.Overload\n" +
                "pub func add(x: in Int, y: in Int): Int { x + y }\n"  // arity 2
            let root =
                writeTempPackage
                    "lyric-multifile-overload"
                    "overload"
                    [ "a.l", aL
                      "b.l", bL ]
            let prevEnv = Environment.GetEnvironmentVariable "LYRIC_TESTPKG_PATH"
            try
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", root)
                let userSrc =
                    "package OverloadUser\n" +
                    "import Testpkg.Overload.{add}\n" +
                    "func main(): Unit { println(add(3, 4)) }\n"
                let result, stdout, stderr, exitCode =
                    compileAndRun "overload_arity" userSrc
                let dupErrs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Code = "B0011")
                Expect.isEmpty dupErrs
                    "B0011 must NOT fire for overloads-by-arity"
                Expect.equal exitCode 0
                    (sprintf "exit 0 expected (stderr=%s)" stderr)
                Expect.stringContains stdout "7"
                    (sprintf "stdout should print 7 (got: '%s')" stdout)
            finally
                Environment.SetEnvironmentVariable("LYRIC_TESTPKG_PATH", prevEnv)
    ]
