# D305 - A protected type's fields are reached only through its members (T0221, #8672)

**Status:** shipped (type checker; dotnet, JVM and native share it)

Enforces the first bullet of docs/01 section 7.5: "There is no way to access the
state without going through an `entry` or `func`."

## Context

The checker accepted `c.total` and `c.total = 5` for a `Counter` anywhere, in
the declaring package and, since D295 (#8261), in a package that imports it.
Both bypass the instance lock: a read can see a state no `entry` produced and a
write skips the barrier re-evaluation and the invariant check. On dotnet,
`val c = Counter(); c.total = 5; println(c.total)` printed 5.

## Decision

1. A field of a protected type, named through a value of that type (`c.total`,
   as a read or as the target of `=`/`op=`), is **T0221** unless the access sits
   in one of the type's own members: an `entry`, a `func`, an invariant, or an
   `impl` method (D-progress-1009), whose scope names the type as its own.
2. Inside a member the fields stay available by bare name, through `self.`, and
   through another value of the same type.
3. A contract clause (`requires:`, `ensures:`, `invariant:`) may name a protected
   field of a value: it states a property (`ensures: result.tokens == capacity`
   in `examples/token_bucket_proof.l`), it is not a state access by program code.
4. Construction (`Counter(total = 40)`) is not a field access and is unchanged.
5. The check reads the receiver's checked type, so it covers a value reached
   through a parameter, a local, a field or a call result, and a protected type
   of an imported package.

## Audit

The standard library, every `lyric-*/lyric.toml` project, the examples and the
self-hosted compiler's packages were checked with the rule on. Existing accesses
found, and what changed:

- `examples/token_bucket_proof.l`: `ensures: result.tokens == capacity` is a
  contract clause, now exempt (point 3).
- `inout_aliasing_self_test.l` passed `c.total` from outside as an `inout` place,
  the very bypass this decision closes. Its two outside cases now pass a
  caller-owned local; the field-aliasing cases that matter run inside a member
  (`selfAlias`, `bumpField`) and are unchanged.
- `protected_iface_impl_self_type_self_test.l` read `f.n` on a protected result;
  it calls the `value()` member instead.

No library or compiler source needed a change.

## Tests

`testdata/reject/protected_field_outside_member` and
`testdata/reject/protected_field_imported` (dotnet and JVM through
`scripts/ci/reject-corpus.sh`); the protected types of the existing self-tests
keep compiling and running, which is the positive case.
