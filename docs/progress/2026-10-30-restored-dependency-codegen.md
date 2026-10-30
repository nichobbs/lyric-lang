# Erased receivers, `?` and function values in another package's code (#8358, #8337, #8329, #7776)

Three bugs in code that reaches a package from another package (a restored
dependency, or a sibling package of the same project) are fixed. A fourth
report (#7776) does not reproduce.

**Member access on an erased receiver (#8358, dotnet).** The type checker
records the nominal class of every field-access receiver
(`SymbolTable.memberRecvClasses`), and the JVM backend narrowed an erased
receiver with it, but the MSIL backend collected the record and never read it:
`bx.pick(Pt(x = 3)).x`, where `pick` is a method-level generic on a generic
record, resolved `.x` only among the current package's fields and failed with
T0121. The MSIL bridge now hands the record to the code generator per package
(`CodegenCtx.memberRecvClasses`, like `methodCallArities`), asks the pipeline
for the receiver classes of other packages' specialised generics too
(`foreignRecvClasses`), and the erased-receiver arm of the member read casts
to the recorded class and loads its field through the registered field token,
a restored dependency's class included. A generic class, or one with no such
field, keeps the existing path.

**`?` in another package's generic (#8337, dotnet and JVM).** `?` is lowered to
a `match` and an early return in `pipeCheckAndMono`, for the package's own
code. A generic of another package reaches a consumer as written (a sibling's
parsed source, a restored package's contract body), so its `?` arrived
unlowered and compiled as the operand itself: an `InvalidProgramException` on
dotnet and a `ClassCastException` (`Result$Ok` to `Integer`) on the JVM. The
issue's restored case and the same program as sibling packages both failed.
`foreignPropagateSites` now checks each specialisation of such a generic in the
scope of its package (as the other foreign passes do) and
`lowerForeignPropagate` lowers its `?` with what that check recorded: error
widenings, direct async calls and explicit type-argument callees. A package
that cannot be checked is lowered without them.

**Function value in another package's generic (#8329, dotnet).** A bare
reference to the declaring package's own function (`[ping, pong]` inside
`mkHooks[T]`) failed with T0115 in the specialisation: the thunk standing for
it exists only in the declaring package. The type checker records such a
reference (`SymbolTable.ownFuncValueSites`, never a call callee, only a
function a forwarding lambda can stand for) and `foreignFuncValueSites` /
`rewriteForeignFuncValues` replace it in the specialisation with the
forwarding lambda a cross-package function value already gets
(`funcRefLambdaMono`, D-progress-963).

**Not reproducible (#7776).** A restored dependency's interface is registered
in the type-name table like a source one (`registerTypeFqnCandidate` in the
bridge), so the branch-join downcast covers it. Branches of two library
records joined as the library's interface, as `Result[I, String]` and
`Option[I]`, in a return, argument, binding, assignment and record field, run
correctly on both targets and verify with `ilverify`; the cases are kept in the
new e2e script as a regression test.

**Verified by** `scripts/ci/restored-dependency-codegen-e2e.sh` (added to
`compiler-self-tests-batch.sh`): each case as a restored dependency and as
sibling packages, on dotnet and the JVM.

**Not fixed.** #8261 (a `pub protected type` from a restored dependency) needs
the protected type's members exported in the contract metadata, the parser to
accept the body-less member heads, the checker to build the type from them, and
the MSIL and JVM restored-type registration to bind its constructor, entries
and funcs; it is left open. #7783 is down to the array-typed slice-element
family, which needs the canonical slice representation decision of #7806.
