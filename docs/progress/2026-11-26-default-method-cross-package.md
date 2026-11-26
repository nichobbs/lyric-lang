# Default methods of another package's interface on a concrete implementor (#9428)

Decision: D861.

## What shipped

- JVM: `registerHeadOnlyImplsJvm` also runs for the user package and the bundle's source packages and registers the interface's methods on every impl of an interface declared elsewhere.
- dotnet: a call on a type that does not declare the method dispatches on the slot of an interface the type implements (`interfaceDefaultOwnerMsil`).
- `default_method_cross_package_self_test.l`: both targets (a restored DLL on dotnet).

## Remaining

A default method of a generic interface from another package called on a concrete implementor (D861).
