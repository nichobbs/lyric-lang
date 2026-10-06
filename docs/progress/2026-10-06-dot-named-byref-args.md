# Dot-named methods' `out`/`inout` arguments, verified on every target; native interface dispatch and aliased borrows (#8183)

#8183 reported that a dot-named method called with method syntax
(`a.into(y, 3)` on `func Acc.into(self: in Acc, x: inout Int, j: in Int)`)
passed its `inout` argument by value: InvalidProgramException on dotnet,
VerifyError on the JVM. #8224 fixed that call by rewriting every call that
resolves to a dot-named function with an `out`/`inout` parameter into a plain
call of the function (`Lyric.Pipeline.rewriteByRefDotCalls`). This entry
records the check of the shapes around that call on dotnet, the JVM and
native (every dotnet DLL `ilverify`-clean), and the one shape that was still
broken.

Working on every target, now under test:

- method syntax and the type-qualified call, `out` and `inout`, positional
  and named arguments in and out of order, the receiver and arguments
  evaluated in source order (D171), an argument reading the by-reference
  place before the call;
- every place: a local, a field and a nested field (of a `var` or a `val`),
  an array element with a computed index (D179), the caller's own `inout`
  parameter, a dot-named method passing its `inout` parameter on with either
  call form. A captured `var` passed by reference inside a closure works on
  dotnet and the JVM only: native rejects it (see below);
- an `inout` receiver (record-body or dot-named) beside an `inout` or `out`
  argument, including receiver and argument that are fields or elements of
  one value;
- generic dot-named functions at `Int`, `String` and record types, and a
  generic record's `inout` receiver beside an `inout T` argument;
- a union receiver; a call's value in expression position, in an `if`
  branch and a `match` arm, nested in another call's arguments, and as a
  `?` operand when it returns `Result`;
- another package's dot-named functions, generic or not, with method syntax,
  through the type and through its package, from a sibling project package
  and from a restored dependency.

Broken, and fixed: **an `out`/`inout` parameter of an interface method,
called through an interface value, on `--target native`.** The vtable slot
types and the dispatch ignored parameter modes: the slot declared the
parameter by value and `lowerIfaceDispatch` passed the argument's value,
while the implementing method takes a pointer, so the call wrote through the
integer it was given (a segmentation fault, or silent corruption). dotnet and
the JVM were correct. `registerInterfaceTypes` now types an `out`/`inout`
parameter's slot as a pointer to its type (`NIfaceInfo.methodParamByRef`),
`lowerIfaceDispatch` passes the argument's place through `lowerByRefArg`, as
a direct call does, and a by-value implementer's vtable thunk forwards the
pointer unchanged. Fields, array elements (copy in and copy out) and named
arguments in source order work through the interface as they do in a direct
call; an AddressSanitizer build of a `String` `inout` through both a heap and
a by-value implementer runs clean.

Also broken on native, before and after the interface fix: **one value
passed both as a borrowed `in` argument (or the receiver) and as the
by-reference place of the same call** (`swap(k, k)`, `k.swapD(k)`,
`k.swapI(k)` through an interface). An `in` argument is a borrow (Rule 5,
no retain), so the callee's write to the place released the value the borrow
still pointed at: a heap use-after-free under ASan. A call with any
by-reference parameter now retains each reference it passes `in`, and its
receiver (the interface box, for a call through an interface), and releases
it with the statement's temporaries (`pinBorrowForByRefCall`, in
`bindCallArgs`, `lowerCallArgsWithReceiver`, native's own generic
instantiation calls and `lowerIfaceDispatch`). A call without a by-reference
parameter is unchanged.

An `out`/`inout` **`Self`** parameter of an interface method keeps its erased
slot: passing an interface value's place to it needs the box unwrapped into a
cell the implementing method writes and a new box built afterwards. Native
does not lower that yet (#8252). A call through an interface value is now
`N0023`, reported at the argument, instead of a call that passed the object
where the method writes through a pointer; the by-value implementer's thunk
for that slot only traps, so its IR stays well-typed. The rejection is made
at the call rather than in a pre-pass over the interface declarations like
`N0006`'s, since only the receiver's static type tells the call through the
interface from the same call on the implementing type, which works as before
(`inout_self_param_self_test.l`, now also run on native). docs/01 (native
supported surface), book chapter 04 and appendix B say so.

Native also mishandled **a variable a closure captures, passed by reference
from inside the closure** (`{ -> reset(k) }`). Native closures capture a
variable's value (#7891), and the closure body passed its own unretained
copy of that value: the callee's write released a value the closure's
environment still owned (a heap use-after-free when the closure outlives the
variable's function) and the new value was neither seen by the variable nor
released (`orig2` where dotnet prints `new1`, and a leak). Until #7891 lets
captured variables share one cell, native rejects the call with `N0024` at
the argument. A variable declared inside the closure, and a field of a
captured record, can still be passed.

The native message for a by-reference argument codegen does not address no
longer says index/element expressions are unsupported: an array element is
copied in and out before codegen (D179) and a `List`/`Map`/slice element is
not a place (T0085).

Tests: `dot_named_byref_self_test.l` (22 cases, dotnet, JVM, native), wired
into the compiler, JVM-generics and native batches and the ilverify consumer
list; `llvm_inout_self_test.l` gains, under AddressSanitizer, `out`/`inout`
`String` and record parameters through a heap and a by-value implementer,
the four aliasing forms (plain, dot-named, through an interface, generic),
the positioned `N0023` (an `inout Self` positional argument, and an
`out Self` named one on a heap implementer) with the same call on the
implementing type running, and the positioned `N0024` with a closure-local
variable and a captured record's field still passed; a closure case in `inout_receiver_closure_self_test.l` (dotnet, JVM);
`scripts/ci/inout-receiver-e2e.sh` gains another package's dot-named
functions with `inout`/`out` arguments, generic or not, on all three targets,
from a sibling package and a restored dependency.

Not covered here:

- `async` functions with `out`/`inout` parameters are #8229 (dotnet never
  writes the argument back, native rejects them with N0007). An `async`
  dot-named function is separately broken on dotnet even without by-reference
  parameters: `self` in its state machine reads the state machine, and an
  `await` of a call of one inside an `async` caller is not counted by the
  await pre-scan (T0120).
- A dot-named method called with method syntax on an enum receiver
  (`red.code(c)`) fails on every backend whether or not it has an
  `out`/`inout` parameter; the type-qualified call works.
- A protected type's interface method with an `inout` parameter is #8184 on
  dotnet and N0007 on native.
