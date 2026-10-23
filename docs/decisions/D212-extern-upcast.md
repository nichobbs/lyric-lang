# D212 — `externAsObject`: the explicit extern upcast, scoped to the extern boundary

**Status:** accepted

Closes #7975 and #7976.

## Context

Extern types are nominal and unrelated to each other: a `JClassLoader` is not a
`JObject`, although `java.lang.ClassLoader` extends `java.lang.Object`. A
kernel that keeps extern values in a `List[JObject]`, or passes one to an
`Object`-typed parameter, therefore has no well-typed way to say so
(`_kernel_jvm/http_host.l` adds a `JClassLoader` and a `JInvocationHandler` to
a `List[JObject]`). Since #7969 the element-type check reports that as `T0043`,
so the file is ill-typed. It only built because `Jvm.Bridge` did not make
type errors in bundled stdlib packages fatal (#7976, the JVM counterpart of
#7933).

Three designs were weighed in #7975: implicit widening of every extern type to
the root object, an explicit upcast, and general extern subtyping from
metadata. The owner chose an explicit upcast limited to the extern boundary.

## Decision

1. **A built-in `externAsObject(x)`** takes an extern-typed operand and returns
   the root extern type, whichever of `extern type X = "java.lang.Object"` /
   `"System.Object"` is in scope. It is a reserved built-in name (`T0140` for a
   user `func` of that name), like `println` and `panic`.
2. **It is the only upcast.** There is no implicit conversion between extern
   types, no upcast to any type but the root, and no downcast. The root is
   the one supertype every host reference type is guaranteed to have, so no
   metadata lookup is needed and the operation cannot be wrong. Subtyping among
   named extern types from class metadata stays a possible later design; it
   would not change this form.
3. **Diagnostics.** `T0205`: the operand is not an extern type. `T0206`: no
   root object extern type is declared in the compilation, or the target is
   `--target native`, which has no host object type. `N0103` (mode checker):
   the call is outside the extern boundary, which is a file annotated
   `@unsafe_ffi` at file level or a function annotated `@unsafe_ffi`. Bundled
   stdlib packages are mode-checked like any other, so a kernel function that
   upcasts carries the annotation. The file-level gate is the one
   `foreign record` uses (`N0101`).
4. **Lowering.** On the JVM every extern type is a reference, so the upcast is
   the operand itself and its static type becomes `java/lang/Object`. On
   dotnet a reference operand needs no code and a value-typed extern operand
   (`System.TimeSpan`) is boxed.
5. **`Jvm.Bridge` type-checks every bundled stdlib package** and a type error
   there stops the build, as on native (#7933) and for a project package.
   `http_host.l` uses `externAsObject` where it stores extern values in a
   `List[JObject]`.

## Alternatives rejected

- **Implicit widening to the root.** It would make every `T0043` that names an
  extern type silently succeed in user code, and an `Object` parameter would
  accept any extern value without the author saying so. The explicit form keeps
  the conversion visible at the one place a kernel needs it.
- **A method form (`x.asObject()`).** Extern members resolve against host
  metadata, so a Lyric-defined method name on an extern value would collide
  with a host method of the same name.
- **A type-argument form (`upcast[JObject](x)`).** Only the root is allowed, so
  the target carries no information, and `f[T](x)` parses as an index
  expression that every consumer would have to reinterpret as a type.

## Consequences

- `docs/01` §11 documents the form, `T0205`/`T0206`/`N0103`, and the Bridge
  gate; the book's appendix B lists the codes.
- Native has no extern types and rejects the call (`T0206`); this is a design
  fact rather than a gap.
- Ecosystem libraries that need the upcast annotate the file `@unsafe_ffi`.
- Turning the gate on exposed three more ill-typed JVM kernels (`path_host.l`,
  `string_host.l`, `regex_host.l`). Each is typed at the host boundary through
  `java.lang.String.valueOf`, whose extern result unifies with the position's
  declared type, rather than by widening the language.
- The gate covers every package `Jvm.Bridge` compiles from source, which now
  includes a path or workspace dependency's packages: a type error in one is a
  fatal build error on `--target jvm`, as in a project's own packages.
