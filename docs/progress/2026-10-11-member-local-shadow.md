# A local that shadows a field in a member body is the local, on every target (#8264)

Inside a protected type's `entry` or `func`, a local named like one of the
type's fields was ignored on `--target dotnet` and `--target native`: every
bare use of the name resolved to the field.

```
protected type C {
  var total: Int = 0
  entry f(): Int {
    var total = 100
    total = total + 5
    total
  }
}
```

`c.f()` returned 5 and wrote the field instead of returning 105 and leaving
the field at 0; `var total = 100; addTo(total, 5)` passed the field by
reference.  The same held for a lambda parameter, a `match`-arm or `for`
binding, and a binding inside an inner block named like a field.  The JVM was
right for the body.

Root cause: both backends rewrote a protected member's body before lowering
it, replacing EVERY bare path naming a field with `self.<name>`
(`desugarProtectedExpr` in `msil/codegen.l`, and a copy of it in
`llvm_codegen.l`).  The rewrite tracked no scopes, so it could not see that a
binding of the same name, a parameter included, hid the field.

The audit of the other member forms found more defects:

- Record-body and `impl` methods: on dotnet a bare field resolved through a
  fallback tried after module-level `val`s, so a module `val total` beat the
  record's own field `total` (the type checker resolves the field).  Native
  had no bare-field resolution in a record or `impl` method at all: such a
  method failed with N0007 ("unknown name"), or, when a module `val` of the
  name existed, read the `val`.
- A bare field inside a lambda in a non-generic record-body or `impl` method
  failed on dotnet with T0115 and on native with N0007.  On the JVM a lambda
  read the field's value when the lambda was made, where dotnet (in a
  protected member) read it when the lambda ran.
- On every target, an `ensures:` clause or a protected type's invariant that
  names a field was inserted at the return site, where a body local of the
  same name shadows it, so the clause checked the local; an invariant checked
  a parameter that shares a field's name.
- On the JVM, an interface default method that an `impl` inherits read a
  field of the implementing type where the interface meant a module-level
  name of the same spelling (the type checker resolved the name to the field
  as well).

Dot-named methods reach no field by bare name (a dot-named method uses
`self.<field>`), so a local there is an ordinary local on every target, as
before.

Fix: a new package, `Lyric.SelfFields` (`lyric-compiler/lyric/self_fields.l`),
resolves bare names in member bodies under the type checker's scoping.  The
type's fields are the outermost scope, then the member's parameters; a
`val`/`var`/`let` (after its initializer), a pattern binding (a `match` arm,
a `for` loop, a destructuring `val`), a lambda parameter, a `catch` binding,
a `scope` binding or a quantifier binder hides the field for the rest of its
own scope.  A bare `match`-arm pattern the type checker resolved as a union
or enum case (recorded per pattern in `SymbolTable.casePatternSites`) binds
nothing; a `val`, `for` or destructuring pattern always binds its names.  Each bare reference that still resolves to a field becomes
`self.<name>`.

- `Lyric.Pipeline.pipeCheckAndMono` runs it over the whole file after the
  mode check and before the contract elaborator, on every target, for
  protected members, record-body methods and `impl` methods (the target's
  fields come from the file, or from the caller's cross-file record list).
  Each member it resolves carries the reserved `__lyric_self_resolved`
  annotation, and codegen's own bare-field fallback (the MSIL
  `fctx.className` lookup, the JVM `selfFieldType`) is off in such a member:
  every bare name left there is a binding or a module-level name.
- `Lyric.ImplDefaults` marks the copy of an inherited interface default
  (`__lyric_inherited_default`).  The type checker checks the copy without
  the target's fields in scope by bare name, `Lyric.SelfFields` leaves it
  as written, and codegen's fallback is off in it, so a bare name there means
  what it meant in the interface.
- Source cannot spell these markers: an annotation name beginning with
  `__lyric_`, on a declaration or in an aspect's `annotated:` matcher, is the
  new parse error **P0346**, so a user annotation can never switch a member's
  name resolution off behind the type checker's back, and no aspect can
  select members by a compiler marker.
- `Lyric.ContractElaborator` resolves each member's own `requires:`/
  `ensures:`/`when:` clauses against its parameters and the fields, and its
  protected type's invariants against the fields alone, before inserting
  them into the body, so a clause names the field wherever it lands.  An
  interface's clauses an `impl` method inherits (including one moved into a
  protected type, whose count `mergeProtectedImpls` records) are left as
  written.  The violation message quotes the clause as written
  (`ensures total == old(total)`).  `Lyric.Mono` types a protected field read
  through `self` as it types the bare field, so a generic call in such a
  clause (`ensures: isNone(held)`) still specialises from the field's type.
- The `self` written in place of a bare name has an empty span
  (`Lyric.Parser.isImplicitSelf`), which keeps it apart from a `self` the
  author wrote.  On dotnet a record or `impl` method reads such a field as it
  always read a bare one (`ldarg.0; ldfld`, with no `castclass`), so a body
  with no shadowing compiles to the same IL as before; the field-lock audit
  (#6596) treats a write through it as the bare write V0015 never checked;
  and no side table the type checker keyed by the field reference's span
  mistakes it for that reference.  A lambda now reads a field when it runs on
  every target: on the JVM it captures the receiver rather than the field's
  value.
- The MSIL protected-type lowering and its lambda-lifting pre-pass, and
  native's `unitOfFile`/`unitOf`, resolve a member the middle end did not
  mark the same way, in place of the deleted scope-blind rewrites.  Native's
  rewrite of a bare sibling-member call (`helper()` -> `self.helper()`) moved
  into the same package and is now scope-aware as well.

- A `for` or destructuring-`val` binding named like a nullary union or enum
  case in scope lost its binding on dotnet (and a destructuring `val` on the
  JVM), in any function, member or not: the pattern binder took the name for
  a case, allocated no slot, and a later use read the case.  The type checker
  binds every name in such a pattern, so the MSIL and JVM binders now do too
  (`FuncCtx.bindingPattern`, set by `lowerBindingPatternMsil` /
  `lowerBindingPattern` for `val` and `for` patterns only); a `match` arm is
  unchanged.  Native was already right for these, but rejected a destructuring
  `val` with a union-case constructor pattern (`val Only(n, c) = p`)
  altogether (N0007); it now binds one, so all three targets agree.  The type
  checker bound every name in such a constructor (or record) pattern as an
  error type, which silenced any diagnostic involving it
  (`val Only(n, red) = p; val s: String = red` was accepted); its `val`
  binder now types those names from the case's or record's fields, through
  `bindPatternTyped` in a binding-only mode where no bare name is read as a
  case.

Not covered: on dotnet, a lambda in a member of a type with type parameters
cannot read the receiver (`self.n`, or a bare field, which is the same).  The
lifted lambda is a static method of the non-generic package class, where the
type's parameters have no `!n` form, so neither the receiver's class nor a
field read through it can be named there.  Before this change the explicit
spelling compiled and the CLR rejected the method at run time
(`TypeLoadException`), and a bare field failed in codegen with T0115.  Both
are now **F0048**, reported once at the lambda by a `Lyric.Pipeline` check the
dotnet bridge enables (`MiddleEndOptions.genericReceiverLambdasUnsupported`),
with the workaround: read the field into a local before the lambda.  #8284
tracks the fix, a closure class generic over the enclosing type's parameters
that hosts the lambda body.  A captured local whose type mentions the
parameters (`val me = self`) still compiles and fails the same way at run
time, as before.

Verified by `member_local_shadow_self_test.l` (new, 23 cases) on dotnet, the
JVM and native: a shadowing `var`/`val`/`let` read, assigned, compound-
assigned and passed by `inout`/`out` in an `entry`, a `func`, a `when:` entry
and a generic protected type; an inner-block shadow that ends with its block;
an initializer that reads the field it shadows; `match`-arm, `for` and lambda
bindings named like a field; a captured local; `self.total` beside a local
`total`; a parameter; `ensures:`/invariant clauses next to a shadowing local
or parameter; record-body, `impl` and dot-named methods; a module `val` of a
field's name; inherited interface defaults and contract clauses on a record
and a protected type, directly and through the interface; an enum-case
pattern named like a field; `val`, `for`, tuple and constructor destructuring
bindings named like a case, inside a member and outside one; and a lambda reading a field written
after it was made.  `member_local_shadow_panics_self_test.l` (dotnet and the JVM; it needs
`try`) checks that an invariant still catches a breach of its field where a
parameter shares the name.  Both run in `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh` and `ilverify-selfhosted.sh`, and the first
in `native-backend-self-tests.sh`.  `self_fields_self_test.l` (new, in
`compiler-self-tests-batch.sh`) checks that F0048 is reported once per lambda,
at the lambda, for each generic receiver form and not for a non-generic one,
and that resolving a marked member again changes nothing; two new
`parser_self_test.l` cases check P0346 for each reserved marker and for an
`annotated:` matcher; a new `typechecker_self_test.l` case checks that a
constructor destructure's names take the case's field types (T0060 on a
misuse, including a name spelled like a case).
