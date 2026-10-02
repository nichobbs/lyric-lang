# A parameter or field given more than once is a compile error (#7846)

A call that supplied the same parameter twice type-checked silently, and the
backends then disagreed on what it did.

- **The bug.** For `func f(a: Int, b: Int = 0)`, `f(a = 1, a = 2)` was
  accepted: the checker's pairing (`argIndicesInParamOrder`) let the last
  `a` win. `f(1, a = 2)` was accepted too, with the positional `1` moved
  over to `b`. The shared codegen helper `Lyric.Parser.argsWithDefaults`
  (#7820) could not pair the first call and fell back to the raw argument
  list, so each backend lowered it differently.
- **Calls.** A function, method, `impl` or interface member, dot-named or
  `extern func` call that gives a parameter twice is now **T0042**
  ("parameter 'a' is given more than once"), reported at the repeated
  argument. That covers a name given twice, and a name given for a
  parameter that a positional argument before the first named one has
  already taken. Positional arguments after a named one still fill the free
  parameters left to right, so `f(b = 2, 1)` is unchanged. A call with no
  declared signature to pair against (a function value, a lenient member
  call) still rejects a name given twice.
- **Constructors.** A record, exposed-record, opaque or union-case
  constructor that gives a field twice in the same two ways is **T0104**, the
  constructor-argument code. Constructors already report argument problems
  in the T01xx family (T0101, T0104, T0105), not T0042.
- **Codegen.** `argsWithDefaults` now returns the filled list instead of an
  `Option`. Its fallback to the raw arguments is gone: every call it can
  fail to pair is one the checker rejects, so it panics as an internal
  compiler error. The MSIL and JVM callers no longer keep a fallback either.
  The weaver's synthesized `proceed` forwarding call passes every parameter
  positionally, so it cannot reach the panic.
- **JVM sig registry.** The panic found three JVM registrations, for
  derive-synthesised, aspect-woven and mono-specialised functions, that
  recorded parameter names but no defaults. Every call to them took the old
  fallback, which ignored argument names. They now record each parameter's
  default, so `pick(b = 5, a = 6)` and `pick(1, 2)` against
  `func pick[T](a: in T, b: in T, first: in Bool = true)` pair the same way
  on the JVM as on dotnet.
- **JVM qualified calls inside methods.** The panic also found a latent JVM
  miscompile in `lyric-mail`. In `NativeSenderJvm.send`, the qualified call
  `MailKernelJvm.send(self.handle, json)` was lowered as a call to the
  record's own `send` method: `aload_0; invokevirtual` with the other
  function's two arguments, which fails verification. The bare-sibling arm
  of `lowerGeneralStaticCall` now applies only to unqualified calls, as
  MSIL's `bareSiblingHit` gate already did (#6489).
  `self_method_call_jvm_self_test.l` pins it: `Str.repeat(self.word, n)`
  inside a `repeat` method, and `Str.trim(s)` inside a `trim` method, which
  used to recurse into itself.
- **Internal-error messages.** `argsWithDefaults` takes the callee's name
  (`tokKey` or dispatch key on MSIL, `owner.method` on the JVM), so the
  panic names the function the backend resolved the call to.
- **Docs.** docs/01 §"Default arguments" and the union-case construction
  paragraph; book chapter 4 and the T0042 and T0104 rows of appendix B.
- **Tests.** Two new `typechecker_self_test.l` cases. They cover a function,
  a record method, an `impl` method, an interface member and an `extern
  func` (T0042), and a non-generic record, a generic record and a union case
  (T0104), each with both duplicate forms. They also check that the
  accepted orderings stay clean. Stage 2 and the full CI sweep compile the
  stdlib, every ecosystem library, the examples and the compiler itself
  under the new check.
