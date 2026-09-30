# MSIL: verifiable `inout Self` interface parameters (#7783)

An interface method's `inout Self` parameter is `object&` in every
implementation's signature, because the implementation must match the
interface slot. `registerParamsMsil` tracks the parameter as the target class
so that field accesses resolve (#6421/#6425). That produced two unverifiable
shapes, both reported by ilverify in `impl_method_self_test`:
- A write through the pointer (`other.base = ...`) loaded the pointer's
  `object` and used it as the class without a cast.
- A caller passed `ldloca` of its `Bumped6421` local where `object&` is
  declared. Managed pointers are invariant, so that is not assignable.

The fix has a callee half and a caller half:
- **Callee.** `FuncCtx.erasedByrefSlots` marks such parameters, and
  `emitLoadVarMsil` narrows every load through them with `castclass`.
- **Caller.** `emitByrefArgCheckedMsil` compares the argument's storage type
  with the callee's physical parameter type. It does this for every
  in-bundle call form: static functions (only for MethodDef callees, whose
  recorded types are the real signature), sibling methods, class and
  interface dispatch, and generic-receiver dispatch. When one side is
  `object` and the other a reference type, it copies the value into a temp of
  the parameter's type, passes the temp's address, and stores it back (with a
  cast) after the call. That covers a local, a forwarded `inout` parameter,
  and a record field (through a saved receiver).

This is the copy-in/copy-out the JVM backend uses for every `out`/`inout`
argument (`writeBackHolderArg`), so both targets observe the argument
identically. Every other byref argument still passes its own address.

The new dual-target `inout_self_param_self_test.l` covers a field write, a
reassignment forwarded to a typed `inout` helper, and a record-field
argument. It runs in both the compiler and JVM-generics batches, and it joins
`scripts/ilverify-selfhosted.sh` phase 4 with `impl_method_self_test`, which
now verifies clean. docs/09 §11.2 records the ABI.
