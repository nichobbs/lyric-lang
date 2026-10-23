# D207 - Child processes on the Windows native target

**Status:** accepted, implemented (docs/67 phase G9, #8433; extends D205)

## Decision

`lyric_process_win32.c` replaces `lyric_process_unsupported.c` in the `x86_64-pc-windows-msvc` build of
lyric-rt. It implements the whole `lyric_process_*` surface with the POSIX twin's contracts: captured runs with
stdin content and a deadline, inherited-stdio runs, the nonblocking capture op the async process leaf drives,
and long-lived piped children with bounded line reads.

1. **The runtime resolves the program, and the OS does no search.** A path with a separator (`\`, `/` or `:`) is
   used as given; a bare name is looked up in the `PATH` directories, in order. For a name without an
   extension `<name>.exe` is tried first, then the name itself. The resolved path is passed to `CreateProcessW`
   as `lpApplicationName`, so the current directory and the application directory are never searched (the
   lookup `CreateProcessW` would otherwise do, and a well-known way to run a planted program). Nothing found is
   `ENOENT`.
2. **No shell, so batch files are refused.** Windows runs a `.bat` or `.cmd` file through `cmd.exe`, which parses
   the command line again with its own rules; no quoting makes every argument safe there. The runtime refuses a
   resolved batch file with `ENOEXEC`. A program that wants `cmd.exe` names it and passes `/c` itself.
3. **Arguments are quoted for `CommandLineToArgvW`.** An argument with no space, tab, newline, vertical tab or
   quote is copied as is; any other is wrapped in quotes, each quote is preceded by a backslash, and the
   backslashes before a quote or the closing quote are doubled. `argv[0]` is the program as the caller gave it,
   quoted. A NUL byte, which a command line cannot carry, is `EINVAL`; a line past 32,767 characters is `E2BIG`.
4. **Overlapped named pipes, and handle lists.** Anonymous pipes cannot be waited on or read without blocking,
   so each pipe is a uniquely named, single-instance, local-only pipe whose parent end is overlapped and whose
   child end is a synchronous handle. The child's ends are inherited through
   `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, so a child started at the same time on another thread inherits none of
   them (the POSIX twin's `O_CLOEXEC`). The capture loop waits on the pipes' events with the POSIX twin's
   deadlines and its post-kill drain budget; the op and the piped reads keep one read in flight, so a bounded
   read that times out loses nothing.
5. **A Job Object per captured or piped child.** The child starts suspended, joins a new job, and then resumes,
   so nothing it starts can leave the job before it is in place. A deadline or kill terminates the job: the
   child's whole tree ends, as with the POSIX twin's process group (D-N-025). Where the parent's own job forbids
   nesting, the child runs unconfined and a kill ends it alone. Captured and piped children also start in a new
   process group, so a Ctrl+C in the parent's console does not reach them; an inherited-stdio child shares the
   console and its Ctrl+C, as on POSIX. The job is not set to kill on close, so a grandchild that outlives a
   normally finished child survives, as on POSIX.
6. **Exit statuses.** A killed tree exits with status 137, the 128 + SIGKILL the POSIX twin reports, so the
   kernels' timeout handling is unchanged. A child's own status is reported as is, and a crash as its NTSTATUS
   (`0xC0000005` becomes a negative 32-bit value). A kill after the child has already exited leaves its status
   alone and is not reported as a timeout (#5107).
7. **`lyric_process_piped_close` releases the process handle,** as `Std.Process.pipedClose` documents. Later
   calls on the handle report the child as gone.

## Rationale

Resolving the program in the runtime gives the same lookup on every target (`PATH` only, as `execvp` does) and
keeps the current directory out of it. Refusing batch files rather than escaping for `cmd.exe` keeps the
"no shell is ever invoked" property of the POSIX twin: the escaping that `cmd.exe` would need differs from the
`CommandLineToArgvW` rules and has been a source of argument injection in other runtimes. Overlapped named pipes
are the only Win32 pipes that can be waited on with a deadline, and the handle list is the only race-free way to
limit what a child inherits. Exit status 137 for a kill keeps the Lyric kernels' platform-independent handling
of timeouts.

## Test

`lyric-rt/test/lyric_process_win32_test.c` runs itself as the child (`--child <mode>`) and covers the POSIX
twin's `test_process_*` cases (captured output, exit codes, stdin round trips of 256 KiB, deadlines with and
without stdin in flight, a grandchild holding stdout, the op's pump and kill, piped line reads with CRLF, bursts,
bounded reads and late lines, kill, inherited stderr, double close), plus argument quoting edge cases, program
resolution (a non-ASCII directory, a name without `.exe`, `PATH` order, no current-directory lookup, a refused
`.cmd`, a directory), and concurrent spawns from four threads. `scripts/ci/windows-native-e2e.sh` adds a Lyric
program that drives `Std.Process` against itself: capture with quoted and non-ASCII arguments, exit codes,
stdin, a timeout, a missing program, an inherited run, and a piped child.
