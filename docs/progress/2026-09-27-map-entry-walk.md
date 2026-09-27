# Collections: `mapForEach`/`mapEntries` walk entries without a lookup per key (#7282)

`mapForEach` and `mapEntries` enumerated a map's keys and then looked each one
up again, which cost a second hash probe per entry. Each collections kernel now
provides `dictForEachEntry(m, action)`, which pairs keys with values directly:

- **dotnet and native** zip the key enumeration with a values snapshot sized to
  the map. `Dictionary<K, V>.Keys` and `.Values` enumerate in the same order (a
  documented .NET guarantee), and on native both snapshots walk the same table
  slots.
- **JVM** walks `entrySet()`, since `HashMap` does not promise that `keySet()`
  and `values()` iterate in the same order.

Making this work on native needed one more codegen change: a lambda passed to a
generic function (`mapForEach(m, { k, v -> ... })`) now takes its function type
from the parameter type under the type arguments the other arguments bind. The
lambda is lowered in argument order when the arguments before it bind those
parameters, and after the others only when it needs a later one.

`collections_tests.l` gains `mapForEach`/`mapEntries` cases (500 and 300
entries, every key checked against its value) and now runs on native in
`scripts/ci/native-target-smoke-test.sh`; `llvm_heap_self_test.l` covers both
lambda orderings under AddressSanitizer. `msil_project_bridge_self_test.l`
also covers the #7422 unknown-method build error for `Map` and `Set`
receivers.
