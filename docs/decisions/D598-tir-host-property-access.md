# D598 - A host property read or write is a call of its getter or setter (docs/70 phase 3a, #8613)

**Status:** shipped; extends D387 and D597.

## Context

The compiler's own sources read and write properties of host types (`Process.ExitCode`, `Task.IsCompleted`,
`DirectoryInfo.FullName`, `ProcessStartInfo.RedirectStandardOutput = true`, `HttpClientHandler.AllowAutoRedirect = ...`).
The builder counted each as "a member access that is not a record field" or "an assignment to a member that is not a
record field": the largest member-access groups of the compiler census (37 and 15 bodies).

## Decision

- A read of `recv.name` where the checker typed `recv` as a host value is `XCall(Extern(member), [recv])`: `member.kind`
  is `HMPropertyGet` (a getter) or `HMFieldGet` (a public field), `params` is the receiver alone and `ret` the host's
  result, converted like a method's (a possibly null string is `CvLiftNullable`, an array, host enum or host task
  `CvFromHost`). The getter is resolved by the metadata reader's property lookup (`resolveMemberSigs(.., isProperty = true)`,
  getter or public field, supertypes included); `ExternMemberSig.isField` says which.
- A write of `recv.name = value` is `XCall(Extern(member), [recv, value])` of type `Unit`, with `member.kind = HMPropertySet`,
  `params` the receiver then the setter's parameter, and the value converted to it as a method argument is (`hostArgConv`:
  widening, boxing, narrowing, the language's own conversions). The setter is the host's `set_<name>` method.
- Not built, and counted with the site in the message: a compound assignment to a host property (a read-modify-write
  that would evaluate the receiver once), a write to a public field (no setter method), a static property, and a result the
  checker's type does not fit.
- The getter, setter and argument conversions are the same nodes a method call has, so every backend that lowers host
  calls lowers properties without a new case.
