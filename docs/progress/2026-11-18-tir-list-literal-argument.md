# docs/70 phase 3a: a list literal where a List is wanted builds, and a built-in member's arguments are settled by its parameters (D426)

A bracket literal given to a `List[T]` field or a collection member's parameter builds as a `List`, and `newList()` passed to a map's `add` takes the map's value type, so the bodies using them are no longer counted (I0002).
