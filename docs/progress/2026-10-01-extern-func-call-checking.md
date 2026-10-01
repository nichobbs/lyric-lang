# Calls to an `extern func` are type-checked against its signature (#7921)

The type checker registered every `extern func` (D-N-007) as a symbol but
never gave it a signature: `addSigsFromItems` handled `IFunc` items only. A
call to an `extern func` therefore found no signature, typed as `TyError`, and
none of its arguments were checked. A wrong argument type or count reached the
native backend (where it surfaced, at best, as an `N0007` coercion failure) and
the call's `TyError` result silenced any later mismatch that depended on it.

`addSigsFromItems` now registers each `extern func` through the same path as a
Lyric function (`addFuncSig`), built from the same `FunctionDecl` view the
symbol table already used (`externFuncAsFunctionDecl`). The signature is marked
`isExternFunc`. Calls are checked for arity (`T0042`), argument types (`T0043`)
and named arguments, the declared result type flows on, and a parameter
default's type is checked like a Lyric function's.

The native extern-call argument adaptation the backend implements (N4.5,
`Lyric.LlvmCodegen.externAdaptArg`) is now part of the check, for extern
signatures only (`argSatisfiesExternParam`):

- a callback parameter `(P1, …, Pk, NativePtr[Byte]) -> R` takes a closure of
  type `(P1, …, Pk) -> R`, the shape the trampoline calls; a closure of the full
  C signature is rejected with a `T0043` that names the closure type it takes,
  and a closure literal is inferred against the reduced type;
- a closure value is accepted for a `NativePtr[Byte]` parameter, where it passes
  as its own pointer (the userdata a callback API receives).

The backend also passed a `List`/`Map` value for a `NativePtr[Byte]` parameter.
The checker does not admit that: the four kernel declarations that relied on it
now declare the parameter with its real type, `List[String]` (the `LyricList*`
the C side reads):

- `_kernel_native/process_host.l`: `rtProcessRunInherited`
- `_kernel_native/process_capture_host.l`: `rtProcessRun`, `rtProcessStart`
- `_kernel_native/process_piped_host.l`: `rtPipedSpawn`

The second fix flagged by the new check, in `_kernel_native/http_server.l`, was
the `pthreadCreate(…, worker, worker)` callback idiom, which the adaptation
rules above now accept.

`@externTarget` functions were already checked (they are ordinary body-less
`IFunc` items); the new tests cover them as a regression guard. `extern type`
/ `import extern` member calls are resolved by each backend from reference
metadata, not through the checker's signatures, and are unchanged.

`nativeWeakUpgradeType` (#7910) now returns `None` when `Std.Core.Option` is not
resolvable, deferring to the general member path like its siblings, instead of
returning a `TyError` that would unify with anything.

docs/01 §11.6 describes the check and the adaptation rules, and corrects the
stale claim that an `extern func` is inert on the managed targets (both managed
backends reject it with a diagnostic). Verified by 12 new
`typechecker_self_test.l` cases (correct call, wrong type, wrong arity, unknown
named argument, result flowing into a binding and a later expression, default
type, `NativePtr` parameters in a native check, an imported package's extern,
`@externTarget`, and the callback/userdata adaptation); 8 of them fail against
the previous compiler.
