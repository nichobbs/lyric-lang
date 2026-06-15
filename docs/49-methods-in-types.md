# 49 — Methods Inside Type Definitions (Specced in D037)

**Status:** Specced in D037 (accepted 2026-04-30). The design is shipped — methods inside type bodies desugar to UFCS-style free functions with explicit receiver (`self: in Type`).

**Builds on:** `docs/01-language-reference.md` §2 (type system), `docs/03-decision-log.md` D036–D037 (UFCS dispatch and method hoisting).

**Decision-log entry:** D037 (methods in type body desugar to UFCS-style functions).

**Goal:** Explore whether Lyric should support declaring methods inside type
definitions (records, unions, opaque types) vs. the current UFCS model where
all methods are free functions.

---

## 1. Motivation

Lyric currently uses UFCS (User Function Call Syntax): all methods are free
functions with an explicit receiver parameter, and method-call syntax is sugar.

```lyric
pub opaque type Config {
  handle: HostConfig
}

// Method defined outside the type
pub func Config.create(uri: in String): Config {
  Config(handle = hostNewConfig(uri))
}

// Called as method syntax
val cfg = Config.create(uri)
```

**Developer experience pain points:**

1. **Scattered definitions** — related methods appear after the type declaration,
   not grouped with it. For a type with 5 methods, you must read 5 separate
   declarations.

2. **Grouping ambiguity** — when scrolling a file, it's not immediately clear
   which functions belong to which types (especially in large files with many
   types).

3. **Familiarity gap** — developers from Rust, Go, Kotlin, Java expect methods
   grouped inside types. The UFCS model is less familiar outside FP communities.

**Contrary observation:** The explicit receiver parameter makes the sender
obvious (no implicit `this`), and all methods look identical — no "member
function" vs. "static method" distinction.

---

## 2. Shipped design (D037)

### Methods inside type definitions — hoisted to UFCS-style functions

**Decision (D037):** Methods inside type bodies are pure syntactic sugar hoisted to top-level functions.

```lyric
record Point {
  x: Int
  y: Int

  func length(self: in Point): Int =
    self.x * self.x + self.y * self.y
}

// Desugars to:
// pub func Point.length(self: in Point): Int = ...
```

**Semantics (shipped):**
- Methods are grouped at the type definition (syntactic convenience).
- The receiver parameter (`self: in <Type>`) is **explicit** (no implicit `this`).
- The parser hoists each method to a top-level function named `<TypeName>.<methodName>`.
- Codegen uses the existing UFCS dispatch (D036) — no new dispatch path.
- Methods see the same type-checker, emitter, and proof system as hand-written UFCS functions.

**Implementation:**
- Parser desugars during AST construction (one pass, zero downstream changes).
- No new semantic surface area; existing UFCS infrastructure handles the call.
- Works for `record`, `opaque type`, `exposed record`, and `union` types.

### Design rationale (from D037)

**Why hoisting?** The parser hoist approach was chosen because:
- Technically clean: the type checker, emitter, and proof system see the same
  UFCS-style functions they already understand.
- No new dispatch path, no new metadata, no new semantic surface area.
- Methods inside types remain pure syntactic sugar; implementation complexity
  stays in the parser (one pass, zero downstream changes).

**Explicit receiver:** The receiver parameter must be named `self` and typed
against the enclosing type:
```lyric
func length(self: in Point): Int
```

Implicit `self` injection (so users can write `func length(): Int = self.x * …`)
was deferred as a follow-up needing AST rewriting of `self` references inside
the method body.

**Rationale for this design:**

From D037's rationale:
- C# / Kotlin / Swift / Rust all support data + behaviour at one declaration site.
- Lyric's split between `record` and `impl` is technically clean but cognitively
  noisy for the common case of "this function operates on this type."
- Pure syntactic sugar means the type checker, emitter, and proof system see the
  same UFCS-style functions they already understand.
- `impl` blocks remain canonical for interface satisfaction; inline methods are
  inherent only.

---

## 3. Follow-ups (open after D037 shipped)

D037 deferred two follow-ups:

**Implicit `self` injection:** After methods-in-types landed, add an AST pass
that rewrites `self` inside hoisted methods to a parameter named "self", and
inject the parameter automatically when the user omits it. This would allow:
```lyric
func length(): Int = self.x * self.x + self.y * self.y  // self injected implicitly
```

**`opaque type` and `exposed record` bodies:** Once method hoisting is stable,
extend the syntax to `opaque type` and `exposed record` bodies; the parser
already handles all three through `parseRecordMembers`.

---

## 4. Example ergonomics (before and after D037)

### Before D037: scattered UFCS methods

```lyric
package Lyric.Docker

import Std.DockerKernel

pub opaque type Config {
  handle: HostConfig
}

pub func Config.create(uri: in String): Result[Config, ConfigError] {
  // validation and construction
}

pub func Config.withTimeout(cfg: in Config, ms: in Int): Config {
  // ...
}

pub opaque type Client {
  handle: HostClient
}

pub func Client.connect(cfg: in Config): Result[Client, ConnectError] {
  // ...
}
```

### After D037: methods inside type definition

```lyric
package Lyric.Docker

import Std.DockerKernel

pub opaque type Config {
  handle: HostConfig

  pub func create(uri: in String): Result[Config, ConfigError] {
    // validation and construction
  }

  pub func withTimeout(self: in Config, ms: in Int): Config {
    // ...
  }
}

pub opaque type Client {
  handle: HostClient

  pub func connect(cfg: in Config): Result[Client, ConnectError] {
    // ...
  }
}
```

The ergonomic win is modest in this example (12 lines → 12 lines), but clarity
improves: related methods are grouped at the type definition.

---

## 5. References

- **`docs/03-decision-log.md` D036** (UFCS dispatch via dotted-name lookups).
- **`docs/03-decision-log.md` D037** (methods in type body desugar to UFCS-style functions — the shipped decision).
- `docs/01-language-reference.md` §2.3 / §2.5 / §2.10 (inline-method syntax in type definitions).
- Rust's `impl` blocks (precedent for methods-inside-types with explicit receiver).
- Go's receiver syntax (another precedent).
