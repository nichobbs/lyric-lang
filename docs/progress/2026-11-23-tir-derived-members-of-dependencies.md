# The checker sees a project dependency's derived members (D777)

An importing package reads a project dependency's items after its derives are expanded (`pipeDerivedItemView`), so `Xp.Api.Person.fromJson(body)` and `address.toJson()` across packages are typed by the checker and build under the TIR gate, on dotnet and the JVM.
