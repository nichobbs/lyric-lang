# Child processes on the Windows native target (D208, #8433)

`Std.Process` and `Std.ProcessCapture` now work on `--target native --triple x86_64-pc-windows-msvc`.

- `lyric-rt/src/lyric_process_win32.c` replaces `lyric_process_unsupported.c` in the Windows build (Makefile
  and CMake). It covers captured runs with stdin and deadlines, inherited runs, the nonblocking capture op, and
  piped children, using `CreateProcessW` over overlapped named pipes with a handle list, and a Job Object per
  captured or piped child. A killed child reports status 137, as on POSIX.
- The runtime resolves the program itself (`PATH` only, `.exe` first) and refuses batch files with `ENOEXEC`
  (D208 explains why).
- `lyric_win32_errno` is shared between the Win32 files, and gains `ENOEXEC`, `ENAMETOOLONG`, `EPIPE` and
  `EINVAL` mappings.
- New `lyric-rt/test/lyric_process_win32_test.c`, run by `make -C lyric-rt test-windows` and by CTest on the
  Windows CI job. `scripts/ci/windows-native-e2e.sh` gains a `Std.Process` program that runs itself as the child.
- `make -C lyric-rt windows` now recreates `lyric_rt.lib` from scratch, so an object dropped from the source list
  cannot linger in the archive.
- `lyric-rt/test/lyric_win32_test.c` builds again after `lyric_dir_list_typed` took an `int64_t*` (#8443).
- Book chapter 13 no longer says by-value records are N0010 on Windows (stale since D205).

Verified locally with clang 18, an xwin MSVC sysroot and wine: `make -C lyric-rt test-windows` (all four
programs) and `scripts/ci/windows-native-e2e.sh`.
