# D861: a default method of another package's interface is callable on a concrete implementor

Status: accepted (#9428).

## Decision

`Lyric.ImplDefaults` copies an interface's default methods into an impl that omits them, but it sees one file, so for an interface declared in another package the concrete type had no such method and a call on it (`L(s = "x").tagged(2)`, not through the interface) failed at run time: `NoSuchMethodError` on the JVM, an unsupported-method error on dotnet.

- **JVM:** `registerHeadOnlyImplsJvm` registers the interface's methods on the implementing class for every impl of an interface declared elsewhere, not only for a head-only impl, so the call is an `invokevirtual` on the class, which the JVM resolves to the inherited default method. A method the type declares is kept.
- **dotnet:** a call on a type that declares no method of that name dispatches on the slot of an interface the type implements (`interfaceDefaultOwnerMsil`), a `callvirt` of the interface's method on the receiver.
- `default_method_cross_package_self_test.l` runs it on both targets (a restored DLL on dotnet).

## Not done

A default method of a *generic* interface from another package, called on a concrete implementor, still fails at run time (the dotnet slot needs the impl's interface arguments; D860). Through the interface type it works.
