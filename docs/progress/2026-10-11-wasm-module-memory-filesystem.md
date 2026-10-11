# wasm32 module: in-memory filesystem for Std.File (docs/35 Q-JS-008)

The module shape's JS glue now implements the WASI preview1 file calls over an in-memory tree
behind one preopened directory, `/` (fd 3), so `Std.File` and `Std.Directory` run unchanged on the
native file kernel (wasi-libc over `path_open`, `fd_read`, `fd_readdir`, ...). Before this, the
glue had no preopen and every file call failed.

Covered: `path_open` (create, exclusive, truncate, directory, rights, append), `fd_read`/`fd_write`/
`fd_pread`/`fd_pwrite`/`fd_seek`/`fd_tell`/`fd_close`/`fd_renumber`, `fd_readdir` (with `.` and `..`
and resumable cookies), `fd_filestat_get`/`path_filestat_get`/`*_set_size`/`*_set_times`,
`path_create_directory`/`path_remove_directory`/`path_unlink_file`/`path_rename`, `fd_fdstat_*`,
`fd_prestat_*`. `..` cannot leave the root, there are no symlinks, and a file is capped at 1 GiB.

Host side: `options.files` (object or `Map`; a trailing `/` makes a directory) seeds it, and the
instance's `files` member (`read`, `readText`, `write`, `mkdir`, `list`, `exists`, `snapshot`) reads
and writes it. `files` joins the reserved export names (`W0040`), and the `.d.ts` types both.
The `component` shape is unchanged (it uses the host's WASI filesystem).

Tests: `lyric-compiler/lyric/wasm/memfs_test.mjs` (23 node tests; it assembles a wasm module that
re-exports the WASI imports, so it needs no wasi-sdk) runs in `wasm32-wasi-rt-tests.sh`, plus two
module self-test cases (`Std.File` end to end through the glue, and the `.d.ts`).
