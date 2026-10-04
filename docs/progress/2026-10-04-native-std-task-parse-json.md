# Native `Std.Task`, `Std.Parse`, `Std.SecureRandom` and `Std.Json`; `lyric-ui` builds natively

Follow-ups #8135 and #7856 to the native lyric-web / lyric-ws work
(2026-10-04-native-web-ws-groundwork.md).

## Shipped

- **`Std.Task` on native** (`_kernel_native/task.l`, #8135, unblocks #7990): cancellation
  sources and tokens, scopes over detached `pthread` threads, the ambient token,
  `runActionWithin`/`runWithin`. Semantics under "no unwinding" are in
  docs/01 §7.4 and book chapter 10. `lyric-rt` gained `lyric_global_lock/unlock` (a short
  critical section for stdlib kernels that keep no module state), a per-thread retained
  reference slot (`lyric_thread_ref_*`, an owned-reference getter) and
  `lyric_secure_random_list`.
- **`Std.Parse` on native** (`_kernel_native/parse_host.l`, #7856): `parseOptDouble` and
  `parseOptBool` with the .NET acceptance rules (the grammar is checked in Lyric, then
  `strtod`).
- **`Std.SecureRandom` on native** (`_kernel_native/secure_random_host.l`): OS entropy with
  rejection-sampled ranges.
- **`Std.Json` on native**: `tryParseJson` goes through a new non-panicking
  `hostTryParseJson` seam on all three `Std.JsonHost` kernels, so the shared module needs no
  try/catch. `Std.JsonValue` (51 tests) and a new document-API suite pass on native.
- **`lyric-ui`** lowers on native up to the external `libwebview` link
  (`scripts/ci/install-webview.sh`): a per-target `Ui.Kernel.Guard` package (try/catch on the
  managed targets, direct calls on native) and a `[features]` table.

## Native compiler fixes found on the way

Bare sibling calls inside protected bodies; protected-member and record-method reachability;
`r.f(args)` on a function-typed record field; lambda fields of generic records and lambda
bodies inside generic instantiations resolved against their type arguments; explicit type
arguments on generic calls (`f[T](x)`, including reachability of stdlib generics called that
way); generic case constructions as arguments to generic calls; cross-package generic
functions between a project's packages (each package keeps its visible generics for codegen);
package-qualified module values; module-global ensure functions in a library build;
closure-typed arguments binding a generic's type parameters; `Char`-returning calls rendered
as characters; same-named functions of several packages in one import closure; and positions
on the lambda, indirect-call, generic-type, mixed-operand and constructor-pattern diagnostics.

## Known gaps

- `examples/ui-customers` does not yet build natively: `constructor pattern 'EditCustomer'
  matched against a non-union value`, and the desktop host needs the external
  `libwebview` link (tracked in #8155).
- Condition variables and protected-type `when:` barriers are not available on native
  (D-N-017), so `Std.Task` waits poll at one-millisecond steps (tracked in #8154).
- `Std.Task` native tests cannot assert panics; `task_tests.l` stays the dotnet/JVM suite.
