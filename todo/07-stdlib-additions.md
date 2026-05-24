# Tier 7 — Stdlib Additions

## Issues
- **#1024** — Add `System.Reflection` kernel externs for DLL inspection (required by lyric-health, contract-meta, source generators)
- **#684** — Stdlib: add immutable persistent collection variants (`Std.Collections.Persistent`)
- **#679** — `lyric-health`: implement DLL-reflection dispatcher so registered checks are actually called

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else, then read `docs/14-native-stdlib-plan.md` for the kernel boundary contract.

Your task is to implement three stdlib additions. Work on a new branch named `feat/tier7-stdlib-additions`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

All code goes in `.l` files. No new F# domain logic. The only acceptable F# changes are existing shim corrections in `bootstrap/src/` host projects that are required to make new Lyric kernel externs callable, and these must be thin BCL pass-through shims with zero business logic.

---

### #1024 — `System.Reflection` kernel externs

Three features need the ability to inspect loaded .NET assemblies at runtime: `lyric-health` (#679), `Lyric.ContractMeta` (`lyric-compiler/lyric/contract_meta.l`), and the source-generator runtime (#686). All three are currently blocked on missing kernel externs.

**Implement `lyric-stdlib/std/_kernel/reflection_host.l`:**

```lyric
package Std.ReflectionHost

// Opaque handle types
pub extern type AssemblyHandle
pub extern type TypeHandle
pub extern type MethodHandle
pub extern type AttributeHandle

// Assembly loading
@axiom("System.Reflection.Assembly.GetExecutingAssembly")
pub extern func assemblyGetCurrent(): AssemblyHandle = ()

@axiom("System.Reflection.Assembly.LoadFrom(String)")
pub extern func assemblyLoad(path: in String): Result[AssemblyHandle, String] = Err("")

// Type enumeration
@axiom("System.Reflection.Assembly.GetTypes()")
pub extern func assemblyGetTypes(asm: in AssemblyHandle): slice[TypeHandle] = []

@axiom("System.Reflection.Type.FullName")
pub extern func typeFullName(t: in TypeHandle): String = ""

// Method enumeration
@axiom("System.Reflection.Type.GetMethods()")
pub extern func typeGetMethods(t: in TypeHandle): slice[MethodHandle] = []

@axiom("System.Reflection.MemberInfo.Name")
pub extern func methodName(m: in MethodHandle): String = ""

// Invocation
@axiom("System.Reflection.MethodInfo.Invoke(Object, Object[])")
pub extern func methodInvoke(m: in MethodHandle, target: in Any, args: in slice[Any]): Result[Any, String] = Err("")

// Attribute inspection
@axiom("System.Reflection.MemberInfo.GetCustomAttributes(Boolean)")
pub extern func methodGetAttributes(m: in MethodHandle): slice[AttributeHandle] = []

@axiom("System.Type.FullName (via GetType())")
pub extern func attributeTypeName(a: in AttributeHandle): String = ""
```

**Do not create `ReflectionHost.fs`.** Bind directly to BCL reflection types from Lyric using `extern type` declarations. All try/catch wrapping for fallible calls goes in the public `reflection.l` layer using Lyric's own `try/catch` — no F# shims at all.

Replace the `@axiom`/`@externTarget` approach in `reflection_host.l` with `extern type` bindings on the BCL types directly:

```lyric
extern type System.Reflection.Assembly {
  static func GetExecutingAssembly(): System.Reflection.Assembly
  static func LoadFrom(assemblyFile: String): System.Reflection.Assembly
  func GetTypes(): slice[System.Type]
}

extern type System.Type {
  prop FullName: String { get }
  func GetMethods(): slice[System.Reflection.MethodInfo]
}

extern type System.Reflection.MethodInfo {
  prop Name: String { get }
  func Invoke(obj: Any, parameters: slice[Any]): Any
  func GetCustomAttributes(inherit: Bool): slice[Any]
}
```

The opaque handle types (`AssemblyHandle`, `TypeHandle`, etc.) declared in `reflection_host.l` become type aliases over the `extern type` values — or are replaced directly by the BCL type references if the Lyric type system supports that. The public `reflection.l` wrapper wraps the fallible BCL calls (`LoadFrom`, `Invoke`) in `try { } catch (e: Exception) { Err(e.Message) }` to produce `Result[T, String]`.

**Implement `lyric-stdlib/std/reflection.l`** — the public Lyric wrapper:

```lyric
pub func loadAssembly(path: String): Result[AssemblyHandle, String]
pub func currentAssembly(): AssemblyHandle
pub func getTypes(asm: AssemblyHandle): slice[TypeHandle]
pub func getMethods(t: TypeHandle): slice[MethodHandle]
pub func invokeMethod(m: MethodHandle, args: slice[Any]): Result[Any, String]
pub func hasAttribute(m: MethodHandle, attributeFullName: String): Bool
pub func typeFullName(t: TypeHandle): String
pub func methodName(m: MethodHandle): String
```

Mark as `@stable(since="1.0")` once the API is reviewed.

**JVM equivalents** in `lyric-stdlib/std/_kernel_jvm/reflection_host.l` — bind `java.lang.Class.forName`, `Class.getMethods()`, `Method.invoke()`, `Method.getAnnotations()`. Add a `KNOWN GAP` comment if the JVM shim is deferred to Phase 6.

**Tests:** `lyric-stdlib/tests/reflection_tests.l` covering:
- `currentAssembly()` returns a non-null handle
- `getTypes` on the current assembly returns at least one type
- `hasAttribute` returns false for an attribute name that doesn't exist
- `invokeMethod` on a known method returns the expected result

---

### #684 — `Std.Collections.Persistent`

Add purely-functional, structurally-sharing persistent collections to `lyric-stdlib/std/collections_persistent.l`. This is a pure Lyric implementation — no BCL dependency — so contracts and proofs apply throughout.

**Required types and operations:**

```lyric
// Persistent singly-linked list
pub union PList[T] {
  case PNil
  case PCons(head: T, tail: PList[T])
}

pub func cons[T](x: T, xs: PList[T]): PList[T]
pub func head[T](xs: PList[T]): Option[T]
pub func tail[T](xs: PList[T]): PList[T]
pub func isEmpty[T](xs: PList[T]): Bool
pub func length[T](xs: PList[T]): Int
pub func toList[T](xs: PList[T]): List[T]      // converts to mutable Std.Collections.List
pub func fromList[T](xs: List[T]): PList[T]
pub func map[T, U](xs: PList[T], f: T -> U): PList[U]
pub func filter[T](xs: PList[T], pred: T -> Bool): PList[T]
pub func foldLeft[T, U](xs: PList[T], init: U, f: (U, T) -> U): U

// Persistent sorted map (AVL tree or HAMT)
pub union PMap[K, V] {
  case PMapEmpty
  case PMapNode(key: K, value: V, left: PMap[K, V], right: PMap[K, V], height: Int)
}

pub func pMapEmpty[K, V](): PMap[K, V]
// `K: Ord` (or whatever comparable constraint the trait system spells)
// is the intended bound; the exact `where`-clause syntax depends on the
// constraint design (see Q-collections-001 in docs/06-open-questions.md).
// Until that resolves, implement via a comparison helper threaded into
// the call site rather than a `requires:` clause.
pub func pMapInsert[K, V](m: PMap[K, V], key: K, value: V): PMap[K, V]
pub func pMapLookup[K, V](m: PMap[K, V], key: K): Option[V]
pub func pMapDelete[K, V](m: PMap[K, V], key: K): PMap[K, V]
pub func pMapToList[K, V](m: PMap[K, V]): List[(K, V)]   // in-order
pub func pMapFromList[K, V](pairs: List[(K, V)]): PMap[K, V]
pub func pMapSize[K, V](m: PMap[K, V]): Int
```

Add `requires:` contracts on functions where invariants can be expressed (e.g. `head` requires non-empty list, AVL balance invariants). Mark the module `@stable(since="1.0")` after review.

**Tests:** `lyric-stdlib/tests/persistent_collections_tests.l` covering:
- `cons`/`head`/`tail` round-trip
- `map`/`filter`/`foldLeft` correctness
- `toList`/`fromList` round-trip
- `pMapInsert`/`pMapLookup` round-trip
- `pMapDelete` removes key; subsequent lookup returns `None`
- `pMapToList` produces keys in sorted order
- Structural sharing: inserting into a `PList` does not mutate the original (verify by checking both the old and new list)

---

### #679 — `lyric-health` DLL-reflection dispatcher

`Health.registerRoutes` installs `/health/live` and `/health/ready` endpoints. Currently both unconditionally return `{"status":"ok"}` regardless of what checks are registered. The check functions registered via `Health.addLivenessCheck` / `Health.addReadinessCheck` are never called.

**This is blocked on #1024.** Complete #1024 first, then implement this.

**Implementation in `lyric-health/src/health.l`:**

1. At startup (`Health.registerRoutes`), call `Std.Reflection.currentAssembly()` and `getTypes` to scan the compiled app DLL for functions annotated with `@lyric_health_check`.
2. For each annotated function, store its `MethodHandle` in a registry keyed by check name.
3. At `/health/live` and `/health/ready` request time, iterate the registry, invoke each check via `Std.Reflection.invokeMethod`, and map the `Result[Unit, String]` return to the JSON health response:
   - All checks return `Ok(())` → `{"status":"ok"}`
   - Any check returns `Err(msg)` → `{"status":"unhealthy","reason":"<msg>"}` with HTTP 503

**Tests:** `lyric-health/tests/health_tests.l` (runnable via `lyric test --manifest lyric-health/lyric.toml`) covering:
- No checks registered → `/health/live` returns `{"status":"ok"}`
- One liveness check returning `Ok(())` → `{"status":"ok"}`
- One liveness check returning `Err("db connection failed")` → `{"status":"unhealthy","reason":"db connection failed"}`
- Multiple checks: one passes, one fails → unhealthy with the failing check's reason

---

## Acceptance Criteria

- [ ] `lyric-stdlib/std/_kernel/reflection_host.l` uses `extern type System.Reflection.Assembly`, `System.Type`, `System.Reflection.MethodInfo` bindings — no `@externTarget` pointing to F# shims
- [ ] No `bootstrap/src/Lyric.Reflection.Host/` project created; all BCL access is via `extern type` in `.l` files
- [ ] All try/catch wrapping for `LoadFrom` and `Invoke` is in Lyric (`reflection.l`), not in F#
- [ ] `lyric-stdlib/std/reflection.l` public wrapper compiles and exports all specified functions
- [ ] `reflection_tests.l` passes via `lyric test --manifest lyric-stdlib/lyric.toml`
- [ ] JVM kernel externs declared (even if with `KNOWN GAP` for Phase 6 Java shim)
- [ ] `Std.Collections.Persistent` — `PList` type with all specified operations
- [ ] `Std.Collections.Persistent` — `PMap` type with all specified operations (balanced AVL or HAMT)
- [ ] `requires:` contract on `head` (non-empty); `pMapInsert` defers a `where K: Ord`-style constraint until the trait-system design (Q-collections-001) lands — see comment in §#684 spec
- [ ] `persistent_collections_tests.l` passes; structural sharing verified
- [ ] `lyric-health` dispatcher calls registered check functions via `Std.Reflection` at request time
- [ ] `/health/live` returns `{"status":"unhealthy"}` with HTTP 503 when any liveness check returns `Err`
- [ ] `health_tests.l` passes via `lyric test --manifest lyric-health/lyric.toml`
- [ ] No new F# domain logic (Std.Reflection binds BCL types directly via `extern type`; no `ReflectionHost.fs` exists)
- [ ] All existing tests pass
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
