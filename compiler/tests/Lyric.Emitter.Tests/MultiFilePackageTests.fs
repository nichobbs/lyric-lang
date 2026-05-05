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
    ]
