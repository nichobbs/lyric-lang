# A closure-captured `var` passed as an `out`/`inout` argument (#8189, #8199, #8182, #8204)

A `var` that a closure captures is hoisted to a one-element heap cell that
the closure and the enclosing scope share (docs/01 §5.4), so its slot holds
the cell, not the value. The by-reference argument lowering did not know
this. On `--target dotnet` it passed the address of the slot holding the
cell reference as the `T&`, so the callee's write corrupted memory
(`AccessViolationException`). On `--target jvm` it stored the callee's
result into the slot holding the cell (`VerifyError`).

- **dotnet** (`Msil.Codegen.emitCellByrefArgMsil`): the argument is the
  cell's element, passed with `ldelema`, so the closure sees each write the
  callee makes during the call, and the callee sees each write the closure
  makes. The lookup follows an `EPath` read: a cell hoisted in this
  function, then a plain slot, then a cell captured into the lambda's
  closure class. That covers a by-reference argument inside a lambda and a
  nested lambda. The cell's element type and the parameter's pointee are
  compared as CLR types (`sameClrTypeMsil`), because one closed generic can
  be tracked as `MGenericInst` or `MGenericInstByName`.
- **Typed cells** (#8199): a captured record, union, closed generic
  (`Option`, `Result`, an in-bundle generic record), concrete `List`/`Map`,
  value type or primitive-element slice used to live in an `object[]` cell,
  which no `T&` can point into. That made the argument a copy-in/copy-out
  temp, and a closure's write during the call was lost. Such a cell is now
  an `MCellArray`, a genuine `T[]`. Its signature is SZARRAY of the element
  type in every position. It is created with `newarr`, read with `ldelem`,
  and written with `ldelema` + `stobj` (new `MNewarrCell`/`MLdelemCell`/
  `MLdelemaCell`/`MStobjCell`), with the element's TypeDef, TypeRef or
  TypeSpec resolved at lowering. Every cell site (declaration, reads,
  writes, closure-class fields, async state-machine promotion) takes its
  shape from `cellArrayTyMsil`.
- **Erased `inout Self`** (#8204): an `out`/`inout Self` parameter keeps the
  interface slot's `object&` ABI (#7783), and only an `object[]` cell's
  element can be an `object&`. The closure-capture pre-pass, one entry point
  for plain functions, async state machines and generators
  (`runClosureCapturePrePassMsil`), finds the captured variables passed to
  such a parameter and keeps their cells `object[]`
  (`FuncCtx.objectCellNames`, carried into each lambda through
  `lambdaObjectCells`). The callee is the method of the receiver's static
  type, `<owner>/<method>#<position>` against the parameters
  `registerMethodParamModes` records; an interface-typed receiver counts
  when the interface method erases `Self`, a concrete type with a typed
  `inout` of the same name does not. The pre-pass runs before the body is
  lowered and has no type-checked expression types, so it names a
  receiver's type only from a parameter, `self`, an annotated local, or a
  local initialised by a constructor call (`collectRecvTypesMsil`). A
  receiver it cannot name (a factory call's result, a field, a lambda
  parameter, a call expression) is matched by method name and position
  alone, the conservative rule: the erased call always aliases, and the
  cost falls only on a same-named typed `inout` call with such a receiver,
  which then copies in and out through a temp, so a closure write made
  during it is lost. The typed `Self&` ABI was not
  taken: an interface slot cannot name the implementing type, so it would
  need an `object&` bridge per impl method, which has the same aliasing
  problem in reverse. A variable passed both to an erased `inout Self` and
  to a typed `inout` parameter goes through a temp at the typed call.
- **Generic receiver** (#8182, dotnet): the call-site MemberRef of a method
  on a generic record now declares an `out`/`inout` parameter as `!0&`. The
  argument is passed at the receiver's instantiation (`Holder[Int].put(x,
  ...)` passes an `int32&`), so no local of the open `!0` is allocated in a
  non-generic caller.
- **JVM** (`Jvm.Codegen.prepareCellHolderArg`): a cell and an `out`/`inout`
  holder are both single-element arrays. The cell itself is passed as the
  holder when the element types agree, or when the holder is an erased
  `Object[]` and the cell holds a reference type (JVM arrays are
  covariant). The callee's write-through then lands in the shared storage.

Two shapes keep a copy-in/copy-out temp, because no managed pointer or
holder can alias the cell. In both, the value is right after the call, but
a closure that reads or writes the variable during the call sees the
caller's copy:

- dotnet: a variable whose type names a type parameter, inside a generic
  record or union method. A closure class is never generic, so the cell is
  `object[]`. The same applies to a variable passed to both an erased
  `inout Self` and a typed `inout` parameter, at the typed call.
- JVM: a primitive variable passed to a parameter the JVM erases to
  `Object[]`: an `inout T` method of a generic record at a primitive
  instantiation (`Holder[Int].put`).

Tests: `closure_captured_var_byref_self_test.l` (33 cases, dotnet and JVM,
in `compiler-self-tests-batch.sh`, `jvm-generics-self-tests-batch.sh` and
the ilverify consumer list). It covers `inout` and `out`; `Int`, `Long`,
`String`, `Bool`, a record, a union, `Option`, `Result`, a generic record,
`List` and a slice, each with a closure write during the call and a
closure read of the callee's write; two closures over one variable; a
by-reference argument inside a lambda, a nested lambda, and on a
lambda-local `var`; generic callees; a generic record's `inout T` method;
an erased `inout Self` parameter, alone, inside an `async func`, on a
factory-call, field, lambda-parameter and call-expression receiver, and
next to a typed `inout`; a same-named method with a typed `inout`; and an
argument after a `?`. The `f(x, g()?)` form is left to #8171.

Not covered:

- **Native** still captures `var`s by value (#7891 item 1), and the
  generic-receiver call still crashes there (#8182 stays open for native).
- **Callee side:** a lambda capturing its own function's `inout` parameter
  (#8197), and the JVM's entry copy of an `inout` parameter (#8198).
