# Native: methods on field chains, paths through a `pub use` facade, defaults in the declaring package, located `try` refusal (#9136)

Four gaps met while building the pure-Lyric `storage-s3` and `mq-sqs`
libraries for `--target native`. Each program type-checked and ran on dotnet;
the native project build stopped with `N0007`, or built and ran the wrong
function. They are the family of #9088: the native backend resolved a name
from the calling package's point of view only.

## A method call whose receiver is a field chain

`client.retry.decide(n, true)`, with `RetryPolicy.decide` declared by a
dependency, failed with "method '.decide' on this receiver is not yet supported
(no matching function 'decide/3' in the bundled import closure)". Binding the
field to a local first worked.

The code generator was not at fault: it resolves the method from the IR type
of the receiver it has lowered. The function was missing from the build. A
dependency package is lowered by reachability (#8429), and the walk
(`Lyric.LlvmBridge.collectCallKeys`) keyed the call as the dotted path
`client.retry.decide/2`, as it keys a package-qualified call, which names
nothing; only a single lower-case identifier receiver also got the bare
`decide/3` key.

- The walk now takes the type checker's class of the receiver
  (`SymbolTable.memberRecvClasses`, #8413) as the statement that the callee is
  a method: when the checker recorded one for the receiver's span, the call
  gets the member key with that class, whatever the receiver's shape (a chain
  of any depth, a module-level `val` at its head).
- A bundled standard library package has no receiver classes, so there a
  chain on a lower-case head is treated as the single identifier already was.

A receiver that is a call or an index result has no dotted key and was already
traced.

## A path written through a facade

`Lib` has `pub use Lib.Client`; a caller with `import Lib as L` calls
`L.configFromEnv(...)`: "cannot resolve call target 'Lib.configFromEnv/1'".
The registries key a declaration by its declaring package, and the path names
the facade.

- `CodegenUnit.reexports` carries each package's whole re-exports, and
  `Lyric.LlvmCodegen.buildReexportAlias` maps `<facade>.<name>` to
  `<declaring package>.<name>` for every top-level name a facade re-exports,
  through any chain of `pub use`: functions (dot-named ones included),
  records, unions and their cases, enums and their cases, distinct types,
  interfaces, protected types and module values. A name the facade declares
  itself stays the facade's, and a nearer re-export wins over a further one.
- A dotted path is spelled through that map (`canonReexport`, longest prefix
  first) wherever the code generator joins one before a lookup: call keys,
  constructor names, type references and generic heads (the by-value
  classifier included), enum and union cases, pattern heads, explicit generic
  calls, function references.
- The reachability walk resolves a facade-qualified call key the same way
  (`reexportedTarget`), so a re-exported function of a dependency is linked.

Alias keys in the registries were considered and dropped: a generic
declaration's key is its identity, so an alias would instantiate
`Lib.Box[Int]` and `Lib.Client.Box[Int]` as two types.

Through a facade's alias the native build now takes a function, a record and
its type, a dot-named function, a method, an enum case, a union case with
fields, a generic function, and declarations two re-exports away. Three forms
are refused before any backend runs and are not changed here: a module value
or a nullary union case read through the facade (`L.MAX`, `L.Dot`: I0001 from
the type checker), and a pattern qualified by the facade (T0122). On dotnet a
generic function called through the facade is T0123 and a method of a
re-exported type called on a value fails at run time; both work on native.

## A default expression means the declaring package's names

`record Client { retry: RetryPolicy = standardRetry() }` in a package that
imports `standardRetry`, built by a package that does not: "cannot resolve
call target 'standardRetry/0'". Two causes.

- Nothing traced a field default of a fully lowered package (a default is no
  function's body), so a function only a default calls was never linked. This
  also failed in a single file: `record R { t: String = Str.toUpper("abc") }`.
  `seedFieldDefaults` now gives the walk the call keys of the field defaults of
  every record, opaque type and protected type of a fully lowered package and
  of the bundled standard library, in the declaring package; a dependency's
  opaque types, which are not a pruned group, are covered the same way.
- A default was lowered as the package that built the record. With the
  function linked, the build resolved the default's names in the caller's
  scope: where the caller declared a function of the same name, the build
  succeeded and called the caller's (`label: String = tag("x")` produced
  `c:x`, not `a:x`). `enterDeclaringPkg` / `leaveDeclaringPkg` make the
  declaring package the current one while a default is lowered: field defaults
  of records, generic records and protected types (`NRecInfo.declPkg`), and
  parameter defaults of functions, generic functions and interface methods.
  Parameter defaults had their callees package-qualified since #8850; a
  constructor, case or module value in a default now resolves in the declaring
  package as well.

A default is still evaluated among the caller's local variables, on native as
on dotnet: `func plus(x: in Int, y: in Int = base)` called where a local
`base` is in scope takes the local. That is the same on both targets and is
not changed here.

## `try`/`catch` refused with a location

`cache-redis`, `session-redis` and `cache-memcached` stopped with "try/catch
is not supported for --target native" and no position, although none of them
has a `try` outside its dotnet and JVM kernel files. The `try` is in
`Std.Testing.assertPanics`, which their tests call: no gated code reaches
native lowering, and the compiler was right to refuse. The diagnostic now says
where: `error[N0007] 107:18: try/catch is not supported for --target native
(D-N-003: no unwinding), in function 'assertPanics' of package 'Std.Testing'`
(`unsupportedAt`, `Ctx.curFn`; the same for `throw`). The language reference
and the book say that `assertPanics` and `assertPanicsWith` build for dotnet
and the JVM only.

## Tests

`llvm_project_self_test.l` gains seven tests (ASan, each project built in
several package orders, the library packages as dependencies where pruning
matters): methods on field chains of a dependency's types; a re-exported
function through the facade's alias; every kind of declaration through a
two-step `pub use` chain, beside a package that declares the same names; a
field default that alone calls a dependency's function, and one that alone
calls a standard library function; defaults of records, a generic record, a
protected type, an opaque type, an interface method, a function and a generic
function, built by a package that declares the same names; the located `try`
refusal. On the
compiler before this change all seven fail: five with the errors quoted above,
the defaults test by printing the caller's values, the last with the
unlocated message.

Left open, found on the way: names read through a facade alias in the type
checker and on dotnet, defaults evaluated among the caller's locals, and
`Std.Testing.assertPanics` on native (#9141).
