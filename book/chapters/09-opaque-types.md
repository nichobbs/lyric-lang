# Opaque Types and Encapsulation

Good object-oriented design separates what a type does from how it does it. In Java or C#, you enforce this by marking fields `private` and providing methods — but the barrier is advisory. Any code with a reference to the object can call `GetType().GetField("balance", BindingFlags.NonPublic | BindingFlags.Instance)` and read or write the field directly. Third-party libraries do this routinely: serializers, ORMs, debugging tools, test frameworks. The `private` keyword tells other developers not to reach in; it does not physically stop them.

Lyric enforces this separation structurally. An opaque type's representation is not just hidden by convention — it is physically inaccessible outside its package, including by .NET reflection. The compiler emits the type in a form that has no public properties, no exposed constructor, and no fields visible to reflection. There is nothing to reach in and grab. This chapter covers opaque types, their relationship to `exposed` records, and the `@projectable` mechanism for crossing the boundary safely when you need to serialize or log an opaque value.

## §9.1 Opaque types

An `opaque type` declaration has a body — fields and optionally an `invariant:` clause — but that body is only visible inside the declaring package:

```lyric
opaque type AccountId {
  value: Guid
}

opaque type Account {
  id: AccountId
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}
```

From outside the `Account` package:

- You can declare variables of type `Account`, pass them to functions, store them in collections, return them from functions.
- You cannot read `account.balance`, cannot write `account.balance`, and cannot construct `Account(id = ..., balance = ...)` directly.
- .NET reflection cannot enumerate the fields. The type is sealed at the metadata level.
- The compiler can reason about the invariant — it is part of the type's public contract even though the representation is not.

From inside the `Account` package, an opaque type is an ordinary record. You read and write fields with the same syntax you would use anywhere else.

The only way to create a valid `Account` from outside the package is through a constructor function you provide:

```lyric
pub func make(id: in AccountId, initialBalance: in Cents): Result[Account, AccountError]
  requires: initialBalance >= 0
{
  return Ok(Account(id = id, balance = initialBalance))
}
```

The caller gets an `Account` value or an error. They cannot manufacture one themselves. This is the core guarantee opaque types provide: every `Account` in existence was created through code you control, which means every `Account` satisfies whatever invariants your constructor enforces.

## §9.2 Why opaque types?

Consider an `Amount` type representing a positive monetary value. Without opaque types, you might write:

```lyric
record Amount {
  value: Cents
}
```

You can document that `value` must be positive. You can write a constructor function that validates it. But a caller can still write `Amount(value = -50)` and bypass the constructor entirely. The constraint is cultural, not structural.

You can tighten this by making `Amount` a package with private internals in other languages, but you are working against the grain of the type system. In Java, `private` fields are still accessible via reflection. In C#, the same. The moment a serialization library, an ORM, or a test framework touches your type, the guarantee erodes.

`opaque` closes this loop structurally. There is no direct construction syntax available outside the package. There is no reflection surface to exploit. The invariant holds because the type system enforces it, not because every developer who ever touches the codebase agrees to a convention.

The comparison to Java or C# `private` is instructive. `private` is enforced by the compiler — you cannot write `account.balance` in another class and have it compile. But it is not enforced by the runtime. Reflection bypasses the compiler check. Lyric's opaque types are enforced at both levels: the compiler rejects direct field access, and the emitted .NET type has no reflection surface to bypass.

::: sidebar
**No reflection.** Lyric programs cannot use reflection at all. This is not an accident — it is the consequence of taking opaque types seriously. If the compiler allowed `typeof(Account).GetField("balance")`, the opaque guarantee would be fictional. Any library that wanted to crack open your domain types could do so. The decision to exclude reflection (D006 in the decision log) is what makes the opaque guarantee real. The cost is that reflection-driven .NET libraries — some serializers, some ORMs, most mocking frameworks — cannot work with Lyric types directly. Source generators (`@derive(Json)`, `@derive(Sql)`) are the compile-time substitute for serialization; `@projectable` is the substitute for reflection-based projection; `@stubbable` interfaces replace mocking frameworks. These are all better tools for their respective jobs — the no-reflection constraint forced the language to provide them.
:::

## §9.3 Exposed records

Where opaque types hide everything, `exposed` records reveal everything. An exposed record is flat, host-visible, and reflection-friendly. It compiles to a plain .NET `record class` with public properties:

```lyric
pub exposed record TransferRequest @derive(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
}
```

`@derive(Json)` invokes a source generator that emits a JSON serializer at compile time. No runtime reflection library needed — the serializer is generated code that references the fields directly.

Exposed records are the right type for:

- DTOs (data transfer objects) at API boundaries
- Wire formats (HTTP request and response bodies)
- Log payloads
- Configuration records read from files or environment variables
- Any value that external tools need to inspect or serialize

Exposed records cannot have `invariant:` clauses. This is intentional: an invariant on an exposed record would be checkable only by code you control, but the whole point of an exposed record is that external code (a JSON deserializer, a database driver) constructs values of the type. You cannot guarantee the invariant holds for values you did not construct. If you need an invariant, convert to an opaque type at the boundary.

An exposed record may hold a field of an opaque type, but only as an opaque handle — the inner representation stays hidden. An opaque type may not hold an exposed field (it would create a public leak of the opaque type's internals).

## §9.4 The domain boundary pattern

The most practically useful pattern in Lyric combines exposed records and opaque types at the system boundary. External data comes in as exposed records — flat, unconstrained, whatever the wire format provided. You validate once, converting to opaque types. From that point on, the types carry their own validity.

The configuration example from the worked examples shows this clearly:

```lyric
pub exposed record RawConfig @derive(Json) {
  databaseUrl: String
  databasePoolSize: Long
  redisUrl: String
  metricsPort: Long
}

pub opaque type AppConfig @projectable {
  dbUrl: Url
  dbPoolSize: Nat range 1 ..= 100
  redisUrl: Url
  metricsPort: Nat range 1 ..= 65_535
}

pub func load(raw: in RawConfig): Result[AppConfig, ConfigError] {
  val dbUrl = Url.tryFrom(raw.databaseUrl)
      .mapErr { _ -> InvalidUrl("databaseUrl", raw.databaseUrl) }?
  val poolSize = (Nat range 1 ..= 100).tryFrom(raw.databasePoolSize)
      .mapErr { _ -> OutOfRange("databasePoolSize", raw.databasePoolSize.toString(), "1-100") }?
  return Ok(AppConfig(
    dbUrl = dbUrl,
    dbPoolSize = poolSize,
    ...
  ))
}
```

The flow is:

```
JSON file → RawConfig (exposed record, unconstrained)
                ↓  load()  validates once
           AppConfig (opaque type, all fields valid by construction)
                ↓  flows through the application
          every function that receives AppConfig knows its fields are valid
```

Once you have an `AppConfig`, the pool size is in `[1, 100]`, the URLs are valid, the port is in range. Downstream functions do not re-validate. The code that would otherwise be scattered across dozens of call sites — `if poolSize < 1 || poolSize > 100 { ... }` — lives in exactly one place: the `load` function.

This pattern applies everywhere external data enters the application: HTTP request bodies, database rows, queue messages, command-line arguments. Parse once at the boundary, convert to opaque types, let the type system carry the guarantee forward.

## §9.5 `@projectable` opaque types

Opaque types create a problem at output boundaries. If you need to serialize an `Account` to JSON for an API response, or write a `User` to a log, you cannot use a general-purpose reflection-based serializer — there is nothing for it to reflect on. You need to produce a flat, serializable representation.

`@projectable` automates this. Annotating an opaque type with `@projectable` directs the compiler to generate a sibling `exposed record` and the conversion functions between them:

```lyric
pub opaque type User @projectable {
  id: UserId
  email: Email
  createdAt: Instant
  passwordHash: PasswordHash @hidden
  invariant: email.isVerified or createdAt > now() - days(7)
}
```

The `@hidden` annotation on `passwordHash` tells the compiler to exclude that field from the projection. The compiler generates:

- `exposed record UserView { id: Guid; email: String; createdAt: String }` — the non-hidden fields, with opaque field types projected to their view counterparts (a `UserId` becomes a `Guid` because `UserId` is itself `@projectable` with a `Guid` field)
- `func User.toView(self: in User): UserView` — projects a `User` to its view
- `func UserView.tryInto(self: in UserView): Result[User, ContractViolation]` — reconstructs a `User` from a view, running the `invariant:` clause on the way in

Using them:

```lyric
val view: UserView = user.toView()     // safe: excludes passwordHash
val roundTripped = view.tryInto()?     // validated reconstruction
```

`toView()` is always safe — it only moves data outward, and `@hidden` fields never appear in the result. `tryInto()` is fallible — the invariant might not hold for arbitrary `UserView` data, so it returns `Result`.

The generated `UserView` automatically gets `@derive(Json)`, so serialization works without any additional code.

::: note
**Note:** The `@projectable` annotation generates code at compile time. If you add a field to the opaque type, the view type gains the field automatically, and `toView()` and `tryInto()` are updated. If you add a `@hidden` field, it is automatically excluded from the view. Field drift between the opaque type and its view is not possible — the compiler maintains the relationship.
:::

## §9.6 `@projectionBoundary` for cycles

When `@projectable` types refer to each other, the projection graph can cycle. Consider a `User` who belongs to a `Team`, and a `Team` that has a list of `User` members. If both types are `@projectable`, generating `UserView` requires generating `TeamView` (for `User.team`), which requires generating `UserView` (for `Team.members`), which requires generating `TeamView`, and so on.

The compiler detects this cycle and requires you to break it explicitly with `@projectionBoundary`:

```lyric
pub opaque type Team @projectable {
  id: TeamId
  name: String
  members: slice[User] @projectionBoundary(asId)
}

pub opaque type User @projectable {
  id: UserId
  email: String
  team: Team? @projectionBoundary(asId)
}
```

The `@projectionBoundary(asId)` annotation tells the compiler: at this field, cut the projection cycle. Instead of recursively projecting the referenced type, emit the ID of the referenced value. The generated views become:

```lyric
exposed record TeamView @derive(Json) {
  id: Guid
  name: String
  memberIds: slice[Guid]    // not slice[UserView]
}

exposed record UserView @derive(Json) {
  id: Guid
  email: String
  teamId: Guid?             // not TeamView?
}
```

The cycle is broken. The view types are finite. The trade-off is explicit: you get serializable views, but round-tripping `TeamView.tryInto()` cannot reconstruct the full `members` slice from `memberIds` alone — the compiler generates a fallible overload that requires the resolved values as additional arguments:

```lyric
pub func TeamView.tryInto(self: in TeamView, members: in slice[User])
  : Result[Team, ContractViolation]
```

If you try to use `@projectable` on mutually-referencing types without the annotation, the compiler reports the cycle with both sides named and refuses to guess a default:

```
directory.l:12:1: error E0501: projection cycle detected
  Team.members (type: slice[User]) → User.team (type: Team?) → Team.members
  break the cycle by adding @projectionBoundary to one of the fields above
```

The error is precise enough to act on immediately. Per the decision log (D026), the compiler requiring an explicit annotation is intentional: silent defaults would produce a wire shape that surprises callers, and making the trade-off visible in the type declaration is the right place for it.

## Exercises

1. Create an opaque type `Password` that stores a bcrypt hash. Provide a `pub func hash(plaintext: in String): Password` constructor. Then, from outside the package, attempt to read the inner hash field — observe the compile error. Can you construct a `Password` value directly without going through `hash`?

2. Write a `pub exposed record ApiUser @derive(Json)` and an `opaque type User` with a `@hidden` field (for example, `roles: slice[String] @hidden`). Add `@projectable` to `User` and generate the view. Verify that the `roles` field is absent from `UserView`. What does `toView()` return for the hidden field — is it present as a default, or absent entirely?

3. Build the validate-at-the-boundary pattern: define a `RawInvoice` exposed record with `String` amounts, and an `Invoice` opaque type with `Cents` amounts and an `invariant: total > 0`. Write a `parse(raw: in RawInvoice): Result[Invoice, ValidationError]` function. Return a precise error for each possible validation failure.

4. Create two mutually referential `@projectable` types without `@projectionBoundary`. Read the error message the compiler produces. Then add `@projectionBoundary(asId)` to one field in each type and verify the compilation succeeds. Inspect the generated view types — are the ID fields named the way you expect?

5. Mark an opaque type field `@hidden`. Use `toView()` and verify the hidden field does not appear in the result. Then call `tryInto()` with a view that was produced by `toView()` — does the round-trip succeed? Now construct a `UserView` value manually (without going through `toView()`) and call `tryInto()` — if the invariant involves the hidden field, what happens?
