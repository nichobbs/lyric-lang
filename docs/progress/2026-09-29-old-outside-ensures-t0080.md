# `old(...)` outside `ensures:` is T0080 again (#7731)

`old(e)` names the value `e` had at function entry. The contract semantics
(`docs/08-contract-semantics.md` §3, §4.4) admit it only in an `ensures:`
clause. Nothing enforced that. An `old` written in a function body, a
`requires:` clause, a loop `invariant:`, a type invariant or a `when:` barrier
passed the type checker. The contract elaborator snapshots only the `old`
operands of `ensures:` clauses, so every other `old` reached codegen, which
has no lowering for it. The MSIL build then failed with the internal-error
fallback `error[T0120]: MSIL codegen failed: Msil.Codegen: EOld reached
codegen`. The JVM and native backends panicked in the same way.

History: D035 (M1.4) first introduced `T0080` as an interim rejection of
`old` in any position, before the snapshot machinery existed. Once the
contract elaborator gained `old` snapshots, the book's T-code table listed the
code with its lasting meaning, "`old(…)` used outside an `ensures` clause", but
no self-hosted checker ever emitted it. The F# bootstrap only mentioned it in a `failwith` in its codegen, and
that went away with the F# compiler (#3834). #7738 then removed the book row
because nothing emitted the code. The code was never retired or reassigned,
so this change restores it with its documented meaning.

The fix is a new syntactic pass in `Lyric.TypeChecker`
(`type_checker/typechecker_old.l`, `checkOldPlacement`). It runs over every
item of the checked file and reports `T0080`, naming the position, for an
`old` in any of these places:

- a function, method, entry, lambda, test, property or aspect `around` body
- a `requires:` clause, a `when:` barrier or a `decreases:` measure
- a loop `invariant:`
- a record, opaque or protected type `invariant:`
- a module `val`/`const` initializer, a field, parameter, protected-field or
  config-field default, a fixture, a wire binding or a range-subtype bound

`old` stays legal in the `ensures:` clause of a function or method, an
interface or extern signature, a protected `entry` or `func`, and an aspect,
including inside a quantifier or lambda in that clause. Two misuses inside
`ensures:` are also `T0080`: a nested `old(old(x))`, and an `old` operand that
mentions `result`. The first has no meaning, and `result` does not exist at
function entry. Either one used to reach codegen through the elaborator's
snapshot binding.

On native, the type check is advisory, because the checker lacks builtin
coverage there. `Lyric.Pipeline.pipeCheckAndMono` still gates on `T0080`,
since a syntactic check cannot be a coverage false positive. JVM bundled
stdlib packages keep their silent advisory check. The stdlib itself is
checked fatally in its own build. The backend `EOld` panics stay as
unreachable guards.

Verified: 15 new `typechecker_self_test.l` cases cover each rejected position,
nesting, `old(result)` and each legal `ensures:` form, including a lambda
inside `ensures:`. The positive sources are asserted to parse cleanly, so
they cannot pass vacuously. The full
self-test is 629/629. A program using `old` in function, method,
interface-impl, protected-entry and aspect `ensures:` clauses builds and runs
on `--target dotnet` and `--target jvm`. A violated `old` postcondition raises
`PostconditionViolated` on dotnet, JVM and native. The misuse program is
rejected with `T0080` on all three targets.
