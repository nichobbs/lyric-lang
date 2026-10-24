# D231 - The private non-generic helpers of a pub generic are copied with it, when a copy is the same function

**Status:** shipped (#8427, non-generic helpers); extends D215, which carried the private generic helpers; the helpers a copy would change the meaning of stay T0123, tracked in #8546

## Context

A generic function's body is compiled into each package that calls it. On `--target dotnet` and `--target jvm` the
body lands in the caller's assembly or class, where a private function of the declaring package cannot be bound
(`T0123`, docs/01 section 3.3). D215 solved this for private *generic* helpers by copying them under package-unique
names; the private *non-generic* helper (`func plainHelper(n: Int): Int`) was left open because the two obvious
answers have different costs:

- **(a) Copy the helper into the specialising package**, like a generic with no type parameters. It changes
  nothing outside the compiler's middle end, and works for in-bundle packages, for the contract metadata of a built
  dependency, and for a JVM source dependency alike. It is wrong for a helper with state: a copy would hold its own
  instance of anything the helper reads or writes at module level.
- **(b) Export the helper** with assembly visibility (MSIL `internal`) or package-private/public visibility (JVM) and
  carry its signature in contract metadata (docs/45), so the specialised body binds the real method. It keeps one
  instance of module state. For a built dependency the CLR needs the method `public` (an `internal` method of
  another assembly cannot be bound), so every reached private helper would become public API of the emitted
  assembly; the type checker and the code generator both have to learn to bind a name that no `pub` declaration
  introduced; and the helper's signature may name private types that the consumer cannot reference.

## Decision

1. **Hybrid, by what the copy would change.** A private non-generic helper a `pub` generic reaches (directly, through
   other helpers, or from a lambda, to a fixpoint) is **copied** (a) when the copy is the same function: it is
   self-contained. Otherwise it stays as D204 left it, `T0123`, and (b) is the plan for exactly those helpers
   (#8546). (a) first because it needs no change to emitted assemblies and gives the right semantics for the large
   class of pure helpers; (b) is rejected for now because it widens the emitted assembly's public surface and needs
   a new binding path in both code generators and in contract metadata for every helper, when only the stateful
   ones need it.
2. **Self-contained** (`Lyric.ContractElaborator.plainCopyable`) means the helper:
   - has a body and is not `@externTarget`, `@axiom` or `@test`;
   - has no contract clause (`requires:`/`ensures:`) and no default argument, whose expressions the call rewrite does
     not reach;
   - carries no annotation other than `@pure` and `@io`;
   - shares its name with no other function of the package (a bare-name rewrite cannot tell overloads apart);
   - mentions, in its signature or body and not shadowed by a local binding, no private module-level `val` or
     `const`, no private type, and no case of a private union or enum. A `pub` value or type of its own package is
     fine: it resolves as it does for the `pub` generic itself.
3. **Same machinery as D215.** `carryPrivateGenerics` returns the copies next to the private generics, named
   `__priv_<Pkg>_<name>` (a name that already starts `__priv_`, read back from a restored package, keeps it); the
   calls in the carried bodies are rewritten; a name bound locally is not a call. `Lyric.Mono` treats a copy
   (`isCarriedPlainMono`: no type parameters, a body, a `__priv_` name, an origin package) as a generic with no
   type parameters: the first call from a carried body requests one specialisation, named `<name>__copy`, in the
   calling package, which is checked and lowered like any other specialisation of a foreign generic. The suffix keeps
   it apart from the bodyless signature a restored package synthesises under the carried name.
4. **Where.** In-bundle packages on `--target dotnet` (`pipeAddGenericFuncs`, `requirePub`); the contract metadata of
   a built dependency (`buildContractFromFile`, the copy recorded `internal` with its body, the file as written
   before the middle end: `pipePrivatePlainFuncItems` in the `Msil.Bridge` and `Jvm.Bridge` contract builders); and
   the source dependencies of a `--target jvm` build (`pipeAddGenericFuncs` with `carryPlainHelpers`, every package
   but `Std.*`, whose generics are collected as before). `--target native` is untouched: the whole program is one
   module there and a private helper already resolves.
5. **The diagnostic stays.** An unresolved call from a specialised body to a helper that is not copied is still
   `T0123` on both backends; the message now says when a private helper is copied.

| | private generic helper | private non-generic helper |
| --- | --- | --- |
| `--target native` | works | works (one module) |
| `--target jvm` | works | works when self-contained, else T0123 |
| `--target dotnet` | works | works when self-contained, else T0123 |

## Limits

- Shadowing is scope-insensitive: a name bound anywhere in a body (parameter, `val`, pattern, lambda parameter)
  suppresses the rename and the reach for that name in the whole body. A helper that a generic also calls where no
  such binding is in scope is therefore not copied, and the call is T0123 (conservative, never a wrong binding).
- A copied helper's reference to a `pub` sibling of its package resolves in the consuming package as the `pub`
  generic's own references do, so only if the consumer imports the library unaliased and wholesale.

- The test sees the whole package: a package that spans several files is merged into one unit before any backend
  runs (`Lyric.PackageMerge`, docs/19), so a private value or type declared in a sibling file is seen too.
- A copied helper that calls a helper which is not copied (a stateful one) is reported as T0123 naming the inner
  helper and the copy it was called from, not the function the user's generic called.

- Aspects are not applied to a copy, as for a `pub` generic specialised into another package. A helper that a
  `matches:` aspect weaves in its own package runs unwoven in the copy.
- A copy has its own identity: a private helper that returns a fresh object is unaffected, but two functions that
  compare helper function values by reference see different values in different packages. A helper that reads module
  state is not copied for the same reason.
- Restored (JAR) dependencies on `--target jvm`: a restored generic cannot be called at all (#8089), so the JVM
  carry is covered for source dependencies only.
