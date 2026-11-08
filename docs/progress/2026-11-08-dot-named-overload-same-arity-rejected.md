# Two dot-named functions of one name and arity are T0001 (#8897)

`func Seed.base(x: in String)` and `func Seed.base(x: in Int)` in one package are the
duplicate name `T0001` (as is a generic `func Seed.base[T](x: in T)` beside a
`func Seed.base(x: in Int)` of the same arity), so the backends' count-keyed registries
(`Pkg.name/<parameter count>`) never see two same-arity declarations of one package.
`testdata/reject/dot_named_overload_same_arity` pins it on dotnet and the JVM. A census of
every `.l` file in the repository found no such pair; the only repeats are the
`_kernel` and `_kernel_native` twins, which are never compiled together. Overloads that
differ in parameter count (generic ones, language reference "overloading") stay legal and
are keyed apart by the count.
