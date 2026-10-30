# Native backend: config blocks, SIGPIPE, stdlib lookup, nested buffer writes and smaller fixes (#7435, #7923, #7968, #8455, #8460, #8478, #8521)

A group of `--target native` fixes, each with a regression test.

**`config { }` blocks lower on native (#7435).** Each field of a config block
becomes a module-level `val` named `Block.field` whose initializer calls a
`Std.ConfigHost` reader (`_kernel_native/config_host.l`, over the audited
`lyric_config.c` in lyric-rt). The existing static-global machinery for
module-level `val`s fills them in before `main`, so a field is read once, from
`LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>`, with the dotnet and JVM behaviour: an
unset or empty var takes the default; a required field with none, a value that
does not parse (`G0003`) and a value outside a range field's bounds (`G0004`,
NaN included) print the same stderr message and exit 78 before `main`. The
lowering is `Lyric.LlvmBridge.lowerConfigBlocksNative`, after the type check
(which still reports `G0009`/`G0010`/`G0013`). `N0025` no longer means "config
block"; it is the Windows-triple diagnostic only. `Std.ConfigOverride` still
reports `Unsupported` on native, now because fields are read before `main` and
no registration could be seen (docs/25 §6.0). Test: `llvm_config_self_test.l`.

**Missing standard library (#8455).** A native build whose stdlib search finds no
sources fails before codegen with `N0029`, naming `$LYRIC_STD_PATH`, the
binary's directory and parents, and the working directory and parents. An import
of a `Std.*` package the found stdlib does not declare is `N0030`. Both replace
the unrelated `N0007` unresolved-call error. Test:
`native_missing_stdlib_self_test.l`.

**SIGPIPE (#8460).** A write to a socket or TLS connection whose peer has gone
no longer kills the process: `lyric_sock_write` sends with `MSG_NOSIGNAL` on
Linux, `SO_NOSIGPIPE` is set on every socket the runtime creates or adopts on
macOS, and the `SSL_*` calls run with SIGPIPE blocked on the calling thread (a
SIGPIPE they raised is consumed before unblocking), as `lyric_process.c` does
for stdin writes. The process disposition is left alone, so `prog | head` still
ends the program. Tests: `lyric_tls_test.c` (`test_plain_write_after_peer_close`,
`test_tls_write_after_peer_close`; the workaround comment in `test_alpn_string`
is gone).

**`Std.Directory` and `Std.Console.readLine` on native (#7968).** `Std.Directory`
now goes through the exception-free `Std.FileHost` Result seams on every target
(a new `hostDeleteDirEmptyResult` beside the existing ones) instead of catching a
host `Bug`, so it type-checks and runs on native. `directory_tests.l` runs in the
native lane; `console_readline_tests.l` (run by `scripts/ci/console-readline-test.sh`
on dotnet, JVM and native) covers `readLine`. The `readLine` Result seam and the
`-1` spawn failure of the captured process runs had already landed (#4752, the
2026-10-23 batch).

**Nullary union case as a receiver (#8478).** `Empty.tagged("n=")` resolves
`Empty` as the case value, not a package qualifier, when it names a nullary
case and no function is registered under that dotted name. Test:
`dot_named_receivers_self_test.l` (all targets).

**Ambiguous function value (#7923).** The type checker reports `T0123` for a
bare function value whose name the package declares at several arities, or
declares and an import declares at an arity the package does not (#7527). The
native test asserts the diagnostic instead of a codegen panic. Tests:
`typechecker_self_test.l`, `llvm_project_self_test.l`.

**Nested buffer writes (#8521).** `rows[0][1] = v` on a `buffer[array[N, T]]` and
`xs[0][0] = v` on an `array[N, buffer[T]]` lower through the same ensure-unique
step as `b[i] = v`. The cases moved from `buffer_nested_self_test.l` (deleted) to
`buffer_self_test.l`, which every target runs.
