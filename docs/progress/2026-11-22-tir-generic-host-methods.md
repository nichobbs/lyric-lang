# A generic host method carries its type arguments (D766)

The host metadata resolver keeps generic method overloads with their own type parameters (`EIEMArg`), the typed IR builder infers the type arguments from the call's argument types and records them in `HostMemberRef.typeArgs` (format version 7), and `Array.IndexOf<T>` and `ValueTuple.Create<T1, T2>` build with no I0002. The JVM reads erased descriptors, so it has none.
