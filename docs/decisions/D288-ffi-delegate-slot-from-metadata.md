# D288 - Read the bridged FFI delegate's type from the BCL member's metadata (#5525, #5800, #5947)

**Status:** shipped (`--target dotnet`)

## Context

D122 (docs/50) binds a lambda passed to an `@externTarget` function's
function-typed parameter to a real closed `System.Func`/`System.Action`. It
decided the delegate from the Lyric function type alone, which failed in two
ways:

- A member of a generic BCL type is called through the `<object,...>`-erased
  instantiation (`emitGenericExternMember`), so `List<object>.ForEach` wants
  `Action<object>` while the lambda was built as `Action<Int32>`. Delegates
  are contravariant, so the cast `Action<Int32>` to `Action<Object>` fails at
  run time (#5525, #5800).
- A parameter the BCL types with a delegate it declares itself
  (`RemoteCertificateValidationCallback`, `Predicate<T>`, `ThreadStart`) was
  still given a `Func`/`Action`, and the call failed with
  `MissingMethodException` (#5947).

## Decision

One resolution per bridged parameter, `externDelegateSlotMsil`
(`lyric-compiler/msil/codegen.l`), reads the member's metadata signature and
every site that needs the delegate type uses its answer: registration
(`addPackageTokens`), the wrapper's own signature, the extern body, and
lambda construction.

1. The overload is chosen among the member's overloads as the one whose
   parameter at that position is a delegate taking as many arguments as the
   Lyric function type, with the other parameters scored against the declared
   types. Method-generic members are not handled.
2. A parameter that is a delegate other than `Func`/`Action` is a named
   delegate: the lambda is built with `newobj <Delegate>::.ctor(object, native
   int)` (`buildNamedDelegateCtorTok`) and the wrapper's parameter has that
   type. A delegate that is the receiver of its own `Invoke` is handled the
   same way.
3. When the declaring type's arguments are erased (no bracketed target, and
   the receiver or constructed value carries no closed instantiation, the same
   test `emitGenericExternMember` applies), each delegate position that the BCL
   signature spells `!N` is an `object` in the delegate, in the wrapper's
   parameter and in the lifted lambda's signature. The lambda keeps its
   declared parameter types and unboxes its arguments through the existing
   boxed-parameter path, and its result is boxed. Positions the BCL fixes keep
   their real type.
4. `scoreSigType` ranks a closed argument that instantiates the same generic
   type as an open-generic parameter above the bare type-variable tier, so a
   `Func<..>` argument selects `GetOrAdd(K, Func<K,V>)` over `GetOrAdd(K, V)`.

## Consequences

The Unix-socket TLS gate in `Std.Http` (docs/61 section 3.2) can now be
lifted; that is separate work under #5947. The JVM has no equivalent: a Lyric
function value is already a functional-interface instance there.
