# Unknown members on imported types; the language server checks what the build checks (#7575, #7512)

**Imported records and interfaces are member-complete (#7575).** The
unknown-member check (T0113, docs/59 A5) covered only records, exposed
records and interfaces declared in the file being checked. Imported ones were
exempt because a restored package's contract repr dropped record-body
methods. It has carried them since #6440, and `impl` blocks travel in the
contract too, so the exemption no longer protected anything. It hid typos: a
read of a field that another package's record does not declare, such as
`decl.visibility` on `Lyric.Parser.EnumDecl`, typed as `TyError` with no
diagnostic. The MSIL emitter then lowered it to a bare `pop`, which only the
ilverify gate caught as a stack underflow. `symTableAdd` now records every
record, exposed record and interface as member-complete. Unions stay lenient,
as before. `typechecker_self_test.l` covers an unknown field and an unknown
method on an imported record, and an unknown method on an imported interface.
It also checks that a field, a body method, a dot-named function and an `impl`
method on an imported record still resolve.

**The language server runs the build's pre-check rewrites (#7512).** Every
build rewrites a file before type checking it: module `val` destructuring,
alias rewriting, `@stubbable` synthesis, inherited `impl` defaults and
invariant checkers. The language server type-checked the raw parse instead.
There, `PkgB.wantB(...)` is still a member chain on an unknown value rather
than a qualified call, so an argument that fails the parameter type (the
issue's interface case, or any other) was accepted in the editor and rejected
by `lyric build`. The rewrites are now one function,
`Lyric.Pipeline.pipePrepareForCheck`. `pipeExpandAndRewrite` and the server's
`analyzeAndStore` both call it. The server skips `@stubbable` synthesis,
because the stubs need `Std.Testing.Mocking`, which it does not load.
`lsp_self_test.l` opens a document that calls a workspace package with a
wrong argument and expects T0043. `typechecker_self_test.l` checks the
issue's two-package `Greeter` case through `pipePrepareForCheck`.
