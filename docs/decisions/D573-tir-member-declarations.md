# D573 - Methods, impl members and protected members are TFnDecls with a receiver (docs/70 phase 3a, #8613)

**Status:** shipped; extends D553, D564 and D570.

## Context

`buildPackage` (D570) built top-level functions only. A record method, an `impl` member and a protected
type's `func` or entry had no declaration in the package, so a backend consuming TIR had no body to lower
for them and the census never saw them.

## Decision

`build_members.l` walks a file's record methods, `impl` members and protected `func`s and entries and
`buildPackage` builds each as a `TFnDecl` in `pkg.funcs`:

- The receiver is the first parameter, `self`, passed `in`. A method that declares `self: in T` already has
  it; a protected member and an `impl` member that leave it implicit get a leading `self` local of the
  owner's type, declared by `buildFnCore` from `BuildEnv.recvTy`.
- The symbol is the resolver's method id (`symTableMethodDeclId`), given to `buildFnCore` as
  `BuildEnv.symOverride`; an `impl` member passes its impl's owner key so the stub impl a `@stubbable`
  interface synthesizes (which shares the span of the member it stands for) is told apart.
- An entry's `when:` clause is built with its parameters in scope and becomes `TFnDecl.barrier`; its symbol
  entry has kind `TSkEntry`, the others `TSkFunc`.
- `ESelf` reads the local named `self`. The checker's `self.field` shortcut (`checkExpr` of an `EMember`
  on `ESelf`) returned without recording the receiver node's type; it now records `sc.selfType`.
- A member of a generic record, protected type or `impl` is not built: it is listed in
  `PackageBuild.failed` under the uncovered kind "a method of a generic type". A member's `failed` name is
  qualified (`Owner.f`, `impl.f`).

## Measured

`tir_build_self_test.l` (132 cases): a record method with an explicit receiver, a protected entry with a
`when:` barrier (two parameters, a barrier, an `TSkEntry` symbol, verified), and a member of a generic
record listed as failed. `tir-census.sh --wide`, before and after (bodies built / total): stdlib tests
1082/1165 -> 1130/1240, I0003 0; compiler 11071/12380 -> 11183/12518, I0003 27 (unchanged, not members);
ecosystem I0003 0. So the members add 75 bodies to the stdlib census (48 built, 27 not) and 138 to the
compiler's (112 built, 26 not). The new unbuilt bodies are mostly protected members reading a field by its
bare name (`a name that is not a local` 26 -> 40 in the stdlib tests), which needs the field-of-self
resolution a protected member's body uses; that and the generic-owner members are the next slices.
