# A `for` over a call decides "generator" from the callee it binds, not its name (#7771)

Since #7750 a `for` whose iterator is a generator call takes the call's type
(the generator's element type) as the loop variable's type, whatever that type
is. The type checker decided whether the iterator *was* a generator call with
`forIterIsGeneratorCall`, which looked the callee's bare name and argument
count up in the signature map. Any non-generator reached under a generator's
name and arity was therefore misread as the generator, and its result type
became the loop variable's type:

- a method (`impl` block or record/interface method) or type-associated
  function (`func Bag.each(self: in Bag, n: in Int)`) named like a top-level
  generator;
- a local function value shadowing the generator (`val each = { ... }`);
- another package's function called qualified (`Lists.each(xs)`) while the
  current package declares a generator of the same name and arity.

In each case `for v in <call>` over a `List[Int]`/`slice[Int]` result typed `v`
as the whole collection (`T0031 arithmetic operands must have the same type
(got Int and List[Int])` on `s + v`). In the other direction, a type-associated
generator called method-style (`b.values()`) was not recognised at all: its
element type was read as an iterable and the loop variable degraded to the
lenient error type, so a mistyped binding of it went unreported.

The `ECall` arm now records, per call site, whether the signature the call
actually binds to (the direct signature, or the method pick when the call
resolves through the receiver's method space) is a generator:
`SymbolTable.generatorCallSites`, keyed by `recordCopySiteKey` of the call's
span and cleared on every inference of the call, so a function value, a
constructor, or an unresolved callee is never a generator call.
`forIterIsGeneratorCall` reads that table after the iterator is inferred. The
same predicate still supplies the `inTuple` flag of the loop variable's
`tuplePatternBindingSites` entry, so `Lyric.Mono` now binds the loop variable
through a generator-element local exactly when the call is really a generator
call. Both backends already pick the iteration protocol from the lowered
callee itself (MSIL: the call's `MIAsyncEnumerable` return type; JVM:
`Iterable.iterator()` for any non-list iterable), so they agree with the
checker.

Verified by four new `typechecker_self_test.l` cases (a qualified
non-generator beside a local generator, an impl method and a type-associated
function named like a generator, a shadowing local function value, and a
method-style type-associated generator) and one sanity case (a package-local
non-generator beside an imported generator), plus the new dual-target runtime
test `generator_callee_resolution_self_test.l` (4 cases: the generator itself,
a type-associated function, an impl method, and a shadowing lambda), wired into
both `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`. Before the fix, 4 of the
checker cases and 3 of the 4 runtime cases failed (runtime: `T0031` at compile
time on both `--target dotnet` and `--target jvm`).

Noted while here, not changed: `Msil.Codegen`'s list-collector `yield`
lowering (the `fctx.yieldSlots` branch of the `EYield` arm) is unreachable.
`FuncCtx.yieldSlots` is only ever created empty and nothing adds to it, and a
`yield` outside an `async func` is rejected by the checker (`T0094`), so every
reachable `yield` goes through the lazy generator-class path.
