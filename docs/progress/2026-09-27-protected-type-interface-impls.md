# Protected types can implement interfaces (#7457)

`impl Iface for P`, where `P` is a protected type, now works on
`--target dotnet` and `--target jvm` (and dispatches through the vtable on
`--target native`). It used to build and then fail at run time:
`TypeLoadException` on dotnet (or, when a member of `P` shared the method's
name, the impl body was silently skipped), `ClassCastException` on the JVM.

Each impl method becomes one of `P`'s locked entries: it holds the instance
lock, sees `P`'s fields, wakes barrier waiters and re-checks `P`'s invariant,
and the interface's `requires:`/`ensures:` still apply (D-progress-1009). The
contract elaborator moves the methods into `P`; the backends only needed to
emit the interface relation for the now-empty impl (JVM `implements`, native
vtable slots pointing at the entry wrappers, MSIL extern-interface validation
against `P`'s members).

The native protected lock is now a recursive `pthread` mutex: a member that
called a sibling member (allowed by §7.5, reentrant on the CLR and JVM)
deadlocked on native.

New diagnostic **T0136**: an impl for a protected type declared in another
package, an impl whose target names `P` through an `alias`, an impl for a
generic protected type, or an impl method named like one of `P`'s own members
or like a method of another impl for `P` (#7547). An `async` or
method-generic impl method is T0135. An impl method whose signature mentions
`Self` anywhere is also T0136: both backends erase `Self` to `Object` in the
interface slot, and a moved entry has no path yet to keep that erased
signature while typing its body concretely (#7550).

Tests: `lyric-compiler/lyric/protected_iface_impl_self_test.l` (dotnet batch,
JVM generics batch, native batch) and
`protected_iface_impl_contracts_self_test.l` (dotnet and JVM batches), a
reentrant-lock check in the lyric-rt C tests, new interface cases in
`protected_exclusion_{dotnet,jvm}_self_test.l`, and typechecker self-test
cases for T0135/T0136. Language reference §7.5 and §2.12, book chapter 10
and appendix B updated.

Follow-up: generic protected types themselves do not run on either managed
target (`InvalidProgramException` on dotnet, `NoClassDefFoundError: T` on the
JVM), which is why T0136 rejects an impl for one.
