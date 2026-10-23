# Windows x86-64 native target (docs/67 G9, #7948, D204)

- `--triple x86_64-pc-windows-msvc` (the default on a Windows host): `lld-link` on every host, a Linux host
  cross-compiles with `INCLUDE`/`LIB` naming an MSVC CRT and Windows SDK; COFF datalayout; `bcrypt` and
  `shell32` on the link line, no `-lm`/`-lpthread`/`-ldl`; `@library("c")`/`@library("m")` add nothing; the
  output is `<stem>.exe` (the CLI default name, `lyric run`, `lyric test` and an `-o` without `.exe`). Any other
  Windows triple is `N0025`; clang's versioned host spelling (`x86_64-pc-windows-msvc19.xx`) normalises to the
  canonical triple. `[native.libs]` `dir` libraries are `<link>.lib` plus a bundled `<link>.dll`, no run path.
- Microsoft x64 C ABI for by-value records (`cAbiArch` "win64"): 1/2/4/8 bytes in a register, others by
  reference and through sret; `llvm_c_abi_self_test.l` checks the declarations against clang 18.
- lyric-rt: `lyric_win32.c` and `lyric_fs_win32.c` (Win32 twins of `lyric_posix.c` and `lyric_fs.c`), Win32
  branches in `lyric_parallel.c`, `lyric_sleep_nanos`, wrappers for `close`/`unlink`/`mkdir`/`rmdir` and
  `lyric_sock_shutdown` (the kernels no longer bind those POSIX names), `make windows`/`test-windows`, CMake for
  Windows hosts. Processes and sockets/TLS use the unsupported twins (#8433, #8434).
- Float formatting rounds decimal ties itself instead of relying on `printf` (glibc and the Windows CRT
  differ): identical output on 402,098 cases, 35% faster.
- Tests: `lyric_rt_test.c` builds for Windows (thread cases now use `lyric_thread_create`),
  `lyric_win32_test.c`; `windows-build.yml` gains a `native-tests` job running
  `scripts/ci/windows-native-tests.sh` (lyric-rt C tests, the cross-target and stdlib `--target native` suites,
  `scripts/ci/windows-native-e2e.sh`).
- Docs: D204, docs/01 (native target), docs/67, docs/12, book chapter 1 and appendix B (`N0025`), CLAUDE.md.
  Follow-ups: #8433 (processes), #8434 (sockets, TLS), #8435 (graphics prebuilts, G4-G7 examples), #8436
  (compiler-hosted self-tests, ASan, long paths).
