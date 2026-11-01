# The `lyric` CLI runs the compiler on a large-stack thread (#8667)

The Windows `native-tests` job failed in `llvm_tls_self_test.l` with exit 127
and `Process is terminating due to StackOverflowException`, after
`5 test(s), 0 skipped` and before any TAP output. That point is the in-process
compile of the test module (`emitTestLinked`), not the generated program.

**Cause.** The compiler is recursive over the syntax tree, with one frame group
per nesting level in the type checker, the lowering passes and the emitters.
`llvm_tls_self_test.l` embeds the Lyric programs it compiles as string
literals built by a left-associative chain of 160 `+` operands, so the checker
and then the MSIL lowering descend 160 levels. The frame groups are large
(`inferExprCore` and `lowerBinopMsil` are single functions with an arm per
expression form, about 29 KB per level for the checker on a JIT build), so the
chain needs several MB. A process's main-thread stack is 1 MB on Windows and
`ulimit -s` (typically 8 MB) on Linux; the Linux jobs had room, the Windows job
did not. Reproduced on Linux with `ulimit -s 1024` (stack overflow in
`inferExprCore`) and `ulimit -s 3072` (in `lowerBinopMsil`); a 300-term chain
also overflowed an 8 MB stack.

**Fix.** `bootstrap/src/Lyric.Cli.Aot/Program.cs` runs `Lyric.Cli.Program.main`
on a thread with a 512 MB stack (address space reserved, pages committed as
touched), falling back to the main thread's stack if the reservation cannot be
made. Recursion depth in the compiler is proportional to the depth of the
user's expressions, so the right bound is a stack sized for the compiler, not a
tighter bound on programs; the Rust and Roslyn drivers take the same approach.

**Regression check.** `scripts/ci/small-stack-compile.sh` limits the main
thread to 1 MB (`ulimit -s 1024`) and compiles and runs a 400-term
concatenation chain and 400 nested parentheses; the `aot-smoke` job runs it
against the published CLI. It fails (SIGABRT) without the `Program.cs` change.
