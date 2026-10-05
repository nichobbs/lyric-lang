# A closure-captured `var` passed as an `out`/`inout` argument (#8189)

A `var` that a closure captures is hoisted to a one-element heap cell that
the closure and the enclosing scope share (docs/01 §5.4), so its slot holds
the cell, not the value. The by-reference argument lowering did not know
this. On `--target dotnet` it passed the address of the slot holding the
cell reference as the `T&`, so the callee's write corrupted memory
(`AccessViolationException`). On `--target jvm` it stored the callee's
result into the slot holding the cell (`VerifyError`).

- **dotnet** (`Msil.Codegen.emitCellByrefArgMsil`): the argument is the
  cell's element. When the cell's storage type is the parameter's pointee
  (`Int`, `Long`, `Double`, `Float`, `Bool`, `Char`, `Byte`, `String`), the
  call passes `ldelema` on element 0, so the closure sees each write while
  the callee is still running. A cell stored as `object` (a record, union,
  collection or generic instantiation, per `cellStorageElemTyMsil`) cannot
  be aliased by a `T&`, because managed pointers are invariant. Its value
  goes through a temp that is stored back into the cell after the call,
  the copy-in/copy-out `emitByrefArgCheckedMsil` already uses for an
  erased `Self` pointer. The lookup follows an `EPath` read: a cell hoisted
  in this function, then a plain slot, then a cell captured into the
  lambda's closure class. That covers a captured `var` passed by reference
  from inside a lambda and from a nested one. New `MLdelema` instruction.
- **JVM** (`Jvm.Codegen.prepareCellHolderArg`): a cell and an `out`/`inout`
  holder are both single-element arrays. When their element types agree,
  the cell itself is passed as the holder, and the callee's write-through
  (`emitStoreLocalWriteThrough`) lands in the shared storage. Otherwise (an
  erased generic parameter's `Object` holder), the holder is filled from the
  cell, and `writeBackHolderArg` copies its element back into the cell.

Tests: `closure_captured_var_byref_self_test.l` (15 cases, dotnet and JVM,
in `compiler-self-tests-batch.sh`, `jvm-generics-self-tests-batch.sh` and
the ilverify consumer list). Cases: `inout` and `out`, `Int`, `Long`,
`String`, `Bool` and a record; two closures over one variable; a mutation
through the closure before and after the call; the callee calling the
closure mid-call; a by-reference argument inside a lambda, a nested lambda,
and on a lambda-local `var`; a generic callee; and an argument after a `?`.
The `f(x, g()?)` form is left to #8171, which spills the `inout` argument.

Not covered:

- **Native** still captures `var`s by value, so the closure keeps a stale
  copy. Boxing captured `var`s there is #7891 item 1.
- **Callee-side reads on the JVM.** A holder parameter is copied into a
  local on entry. A callee that calls a closure which writes the caller's
  variable, then reads its own parameter, sees the entry value on the JVM
  and the new value on dotnet.
- **A lambda inside the callee that captures an `inout` parameter** captures
  the value, on both targets.
