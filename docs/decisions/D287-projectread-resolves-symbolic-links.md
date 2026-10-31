# D287 - `Std.File.realPath`, and `ProjectRead` refuses a symbolic link that leaves a granted root (#8468)

**Status:** shipped

## Context

`Lyric.Generator.serveProjectRead` checked a requested path lexically
(`projectPathWithin`) and then read `Path.join(root, path)`. A symbolic link
inside a granted root that points outside the project passed the check and the
read followed it. D207 noted the limit; it matters once generators run as wasm
payloads (docs/40 Q-SG-005), where `ProjectRead` is the only file access.

## Decision

1. `Std.File.realPath(path): Result[String, IOError]` returns the canonical
   absolute path with every link resolved. `Err(InvalidPath)` for an empty
   path, `Err(FileNotFound)` for a missing path or a dangling link,
   `Err(IoError)` for a link cycle or another failure. Each kernel twin
   implements it with its host call:
   - native: `lyric_path_real_ok` (`realpath(3)`, `GetFinalPathNameByHandleW`),
     already in the runtime;
   - JVM: `File.getCanonicalPath` after an existence check;
   - dotnet: a segment-by-segment walk using `lstat` kinds and
     `FileSystemInfo.LinkTarget` (at most 40 links), so a `..` after a link
     steps up from the link's target, as `realpath(3)` does.
2. `serveProjectRead` resolves the requested file and every granted root that
   lexically covers it, and serves the read only when the resolved file is at or
   under a resolved root (whole segments). The read goes to the resolved path,
   so a link retargeted between check and read is not followed. A missing file
   falls through to the ordinary read error; any other resolution failure is
   refused with -32040 Denied.
3. Tests: `lyric-stdlib/tests/file_tests.l` (dots, file and directory links,
   dangling link, cycle, `..` after a link) and
   `lyric-compiler/lyric/generator/generator_self_test.l` (links to a file, an
   absolute target, a linked parent directory, a sibling directory that is not
   granted, a cycle, `..` after a link, the whole-project grant).

## Limits

Resolving then reading is not atomic: a path component swapped for a link
between the two calls could still escape, which closing needs `openat`-style
no-follow reads. Generators remain unsandboxed dotnet processes (D207), so this
closes the capability's own gap and not the process's.
