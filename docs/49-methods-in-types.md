# 49 — Methods Inside Type Definitions (sketch)

**Status:** Unbacked sketch. Significant design implications; see §3 for tensions.

**Builds on:** `docs/01-language-reference.md` §2 (type system, UFCS).

**Decision-log entry:** to follow if consensus forms on design direction.

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

## 2. Design space

### Option A: Methods inside type definitions

```lyric
pub opaque type Config {
  handle: HostConfig

  /// Create a Config from a URI.
  pub func create(uri: in String): Config {
    Config(handle = hostNewConfig(uri))
  }

  /// Establish a connection using this Config.
  pub func connect(self: in Config): Client {
    Client(handle = hostCreateClient(self.handle))
  }
}
```

**Semantics:**
- Methods are grouped at the type definition.
- The receiver parameter (`self: in Config`) is explicit (no implicit `this`).
- Methods are syntactic sugar for the same underlying free function
  (the type checker transforms them to `pub func Config.create(...)`).

**Pros:**
- Methods grouped with the type they operate on.
- Familiar to developers from imperative languages.
- Still explicit about the receiver (no magic `this`).

**Cons:**
- Parser must distinguish method blocks from nested scopes (adds complexity).
- Breaks the "all methods are free functions" principle.
- Requires a new grammar rule for method declarations inside types.

### Option B: Impl blocks (like Rust)

```lyric
pub opaque type Config {
  handle: HostConfig
}

impl Config {
  pub func create(uri: in String): Config {
    Config(handle = hostNewConfig(uri))
  }

  pub func connect(self: in Config): Client {
    Client(handle = hostCreateClient(self.handle))
  }
}
```

**Pros:**
- Familiar to Rust developers.
- Impl blocks can be defined in a separate file (logical grouping without
  modifying the type definition).
- Can have multiple impl blocks for the same type.

**Cons:**
- More verbose (extra `impl` blocks).
- Further departs from "all methods are free functions" principle.
- Requires significant parser/checker changes.

### Option C: Keep UFCS (status quo)

```lyric
pub opaque type Config { handle: HostConfig }

pub func Config.create(uri: in String): Config { ... }
pub func Config.connect(cfg: in Config): Client { ... }
```

**Pros:**
- All methods are free functions (no special syntax).
- Already implemented; no parser/checker changes.
- Forces explicit receiver, preventing implicit-`this` bugs.

**Cons:**
- Methods scattered after the type definition.
- Less familiar to imperative-language developers.

---

## 3. Design tensions

### T1: Principle vs. pragmatism

**Tension:** Lyric's design philosophy treats all methods as free functions
(D029, D032 decision log entries on associated functions). This enforces
explicitness: the receiver is never implicit. But this comes at the cost of
ergonomics — methods are scattered.

**Resolution options:**
- **Conservative:** Keep UFCS. Lean into explicitness as a feature, not a bug.
  Educate users that scattered methods are acceptable (and arguable preferable
  for clarity).
- **Pragmatic:** Allow methods inside types (Option A) but maintain that they
  are syntactic sugar for free functions (to preserve the principle at the
  semantic level).
- **Radical:** Embrace impl blocks (Option B), accept that "all methods are
  free functions" becomes a compiler-level detail, not a language-level one.

### T2: Parser simplicity

**Tension:** Adding methods inside types requires the parser to distinguish
method declarations from nested scopes and fields. This adds complexity.

**Resolution options:**
- **Conservative:** Keep UFCS; no parser changes.
- **Pragmatic:** Add a simple grammar rule for methods (receiver param + body)
  inside type definitions only. Limit to methods; no nested types.
- **Radical:** Full impl blocks with arbitrary nesting; full parser complexity.

### T3: Compatibility with existing code

**Tension:** If methods-inside-types is added, should old UFCS-style declarations
still work in the same file?

**Resolution:** Yes, with a deprecation path. Both styles can coexist; linters
can warn on scattered methods.

---

## 4. Recommendation (soft)

**For Phase 1–v1.0:**

Keep UFCS (Option C). The benefits of methods-inside-types are ergonomic; the
costs are parser complexity and a departure from the "explicit receiver"
principle. For v1.0, prioritize shipped-software philosophy.

**For v1.1 or later:**

Revisit once:
1. `import extern` (docs/47) and constructor shorthand (docs/48) ship, reducing
   the number of methods users write.
2. Real-world usage shows whether scattered methods are actually a pain point.

If Option A (methods inside types) gains consensus, it can be added with a
straightforward parser change (1–2 weeks) that treats method definitions as
syntactic sugar for the current free-function form.

---

## 5. Example ergonomics comparison

### Status quo (UFCS)

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

### With methods inside types (Option A)

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

## 6. References

- `docs/01-language-reference.md` §2 (types and UFCS).
- Decision log entries D029 (associated functions), D032 (method syntax).
- Rust's `impl` blocks (precedent for methods-inside-types with explicit receiver).
- Go's receiver syntax (another precedent).
