# Auto-FFI direct property assignment now binds a closed-generic-instantiation setter (#7444, D-progress-1005)

`o.ApplicationProtocols = l` (`l: List<SslApplicationProtocol>`, no
`@externTarget` wrapper) used to panic at compile time
(`panicExternSetterUnresolved`) even though the explicit-wrapper form
(`@externTarget("...set_ApplicationProtocols")`, fixed in D-progress-999)
already worked. Four coordinated fixes in `lyric-compiler/msil/`:

- `argTyToSig` gained `MGenericInst`/`MValueTypeGenericInst` arms so a closed
  generic instantiation can be *described* as a `SigType` for overload
  lookup at all.
- `Mdr.scoreSigType`'s `STNamedGenericInst` arm gained a genuine structural
  match: an argument that is the exact same closed instantiation (same head
  type, same value/reference kind, every type argument an exact match) now
  scores 3 (exact), instead of the previous unconditional reject for any
  closed instantiation — without reopening the D-progress-934 `ValueTask`
  ctor-ambiguity regression that reject existed to fix (a wrapped-open-VAR
  parameter is caught by an earlier, untouched branch).
- `argCoercionInsns` gained a matching arm: an exact structural match needs
  zero coercion instructions (CLR generics are invariant, same as arrays).
- `externSetterCoercion`'s `castclass` fallback (for when the assigned
  value's tracked type is a general `MObject` rather than already the exact
  generic instantiation — the common case for an untyped local) now uses
  `MCastclassGeneric` instead of `MCastclassByName`, so the narrowing check
  targets the real closed TypeSpec instead of silently dropping to `object`.

New self-test: `lyric-compiler/lyric/auto_ffi_generic_setter_self_test.l`.
Full FFI/generic-extern regression sweep unchanged, including the two tests
that guard the regressions this fix must not reopen
(`auto_ffi_self_test`'s Extends-chain test, `typed_ffi_delegate_self_test`'s
`ValueTask` ctor-disambiguation tests).

See `docs/decisions/D-progress-1005-auto-ffi-closed-generic-setter-binding.md`
for the full four-gap breakdown (the fourth, `externSetterCoercion`'s
fallback, was only discovered while implementing the fix — not part of the
issue's original diagnosis).
