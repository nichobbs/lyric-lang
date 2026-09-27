# D-progress-1009 — An `impl` for a protected type contributes locked members (#7457)

**Status:** shipped

`impl Iface for P`, where `P` is a `protected type`, type-checked and built on
both targets and then failed at run time. On dotnet the class carried the
interface's InterfaceImpl row but none of the impl's methods
(`TypeLoadException`); when one of `P`'s own members happened to share a
method's name, the CLR bound the interface slot to that member and the impl
body was silently dropped. On the JVM the class never declared the interface
(`ClassCastException` at the upcast). The type checker also gave impl bodies
no access to `P`'s fields (T0020 on `n` / `self.n`).

## Decision

The construct is legal, and an impl method on a protected type is one of the
type's own locked members. §7.5 says a protected type's state is reachable only
through its members, which hold the instance lock; an interface method that
reads or writes that state must obey the same rule. So each impl method:

- holds the instance lock for its whole body (reentrant, so it may call `P`'s
  other members);
- sees `P`'s fields by bare name and through `self.`;
- wakes barrier waiters on exit when `P` has a `when:` barrier;
- re-checks `P`'s invariant, and keeps the interface's own
  `requires:`/`ensures:` (#7223).

Rather than add a second locked-method path to every backend, the contract
elaborator (`Lyric.ContractElaborator.mergeProtectedImpls`,
`contract_elaborator/protected_impls.l`) moves the impl's methods into `P` as
`entry` members before elaboration. The barrier protocol, invariant asserts
and the backends' existing entry lowering then apply unchanged. The impl block
stays behind with no methods, and each backend still emits the interface
relation for it: an InterfaceImpl row on MSIL (the CLR binds the slot to the
moved member by name and signature), an `implements` entry on the JVM
(`buildProtected` now takes the target's interfaces), and a vtable on native
whose slots point at the entries' lock wrappers. Methods become entries rather
than `func`s because only entries re-check the invariant, and an impl method
may mutate state.

## Native: reentrant protected lock

Native protected members lock a default `pthread` mutex, so a member calling
a sibling member (which §7.5 allows, and which an impl method delegating to
one of `P`'s members does routinely) deadlocked. `lyric_mutex_init` now
creates a `PTHREAD_MUTEX_RECURSIVE` mutex, matching the reentrant CLR
`Monitor` and JVM monitors. Its only other user, the native HTTP server
kernel's queue lock, never re-locks, so it is unaffected.

## Restrictions (type checker)

- **T0136** — the impl is declared in another package than `P` (its methods
  must land in `P`'s own class); `P` or the impl is generic (generic protected
  types do not lower on either managed target yet, independently of this
  change); or an impl method has the same name as one of `P`'s own
  `entry`/`func` members, since both would be the same method. The issue's
  delegating shape (`impl Store for Locked { func get(...) { self.get(key) } }`
  with a member `get`) is therefore rejected with a message that says to move
  the body into the impl or rename the member.
- **T0135** — an `async` or method-generic impl method, as for a protected
  `func`.

## Tests

`protected_iface_impl_self_test.l` (3 cases on dotnet, JVM and native:
interface dispatch, concrete-receiver call, two interfaces with a sibling
call under the lock); `protected_iface_impl_contracts_self_test.l` (2 cases,
dotnet and JVM: the interface's `requires:`, the invariant re-check);
a reentrant-lock check in `lyric-rt/test/lyric_rt_test.c`; two new cases in each of
`protected_exclusion_{dotnet,jvm}_self_test.l` (4 x 2000 increments through
the interface on real threads; an impl method opening a barrier wakes the
waiter); five `typechecker_self_test.l` cases (field access, T0136 clash,
T0136 generic, T0135 async, records unaffected).
