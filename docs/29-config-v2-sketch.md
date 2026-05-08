# 29 — Config v2: file-based source + layered precedence (sketch)

**Status:** Specced.  This sketch is the source-of-truth design
for the v2 config surface; the four §9 "before-implementation"
tensions plus §3.4 are settled in **D048** (decision log).
Implementation gates on M5.2 stage 3+ (the AST→MSIL bridge in
the self-hosted compiler).
**Builds on:** D046 (env-only, read-once, fail-fast),
Q-config-004 (`Lyric.BuildInfo` records names + types + defaults
+ `@sensitive`).
**Decision-log entry:** **D048** — Config v2 semantics
(file source + layered precedence).

---

## 1. Motivation

D046 ships an env-var-only config story.  That works for
container-platform deployment (Heroku, k8s, Fly) where ops sets
`LYRIC_CONFIG_*` and the binary fail-fasts on missing required
values.  It breaks down for:

- **Local development** — engineers want a `config/local.toml`
  rather than scripted env-var dances.
- **Multi-environment workflows** — `config/prod.toml`,
  `config/staging.toml`, `config/dev.toml` selected via a
  single env var.
- **Repository-default convention** — many repos check in
  defaults that ops then overrides per environment.
- **Layered overrides** — defaults → file → env → CLI flags
  is the canonical precedence; v1 only does defaults → env.
- **Self-documenting defaults** — a TOML file is more
  discoverable than a list of `LYRIC_CONFIG_*` env vars
  scattered across a deployment manifest.

The two open questions (Q-config-001 file source,
Q-config-002 layering) are tightly coupled — the layering
precedence is meaningful only once a non-env source exists,
and the file source needs precedence rules to be useful.
This sketch addresses both together.

Hot reload (Q-config-003) is **explicitly out of scope** —
read-once-at-startup remains the rule, even for files.

---

## 2. The layered model

Active config = `merge(defaults, file?, env?, cli?)` with
**later layers overriding earlier ones** at field granularity:

```
        ┌──────────────────────────────────────────┐
        │  CLI flags        (highest precedence)   │  layer 4
        ├──────────────────────────────────────────┤
        │  Environment variables                   │  layer 3
        ├──────────────────────────────────────────┤
        │  File source(s)                          │  layer 2
        ├──────────────────────────────────────────┤
        │  Defaults from `config { ... }` block    │  layer 1 (lowest)
        └──────────────────────────────────────────┘
```

**Resolution per field, at startup:**

1. Walk the layers top-down (CLI → env → file → default).
2. First layer to provide a value wins.
3. If no layer provides a value and the field is required
   (no `=` default), abort with exit code 78.
4. Type-check the resolved value against the field's declared
   type; abort if it doesn't parse.

Layer 1 is exactly what D046 does today.  Layers 2-4 are new.
Layer 4 (CLI flags) is the simplest extension — just thread
`--config <name>=<value>` to `lyric run` / `lyric build`'s
runtime args.  Layer 2 (file) is the substantive design.

---

## 3. File-source schema

### 3.1 Default file location

A consumer with `config Settings { … }` blocks can declare a
default config-file path either:

- **Implicit:** the runtime looks for `lyric.config.toml` in
  the binary's working directory if the env var
  `LYRIC_CONFIG_FILE` is unset.  Cleanest convention, but
  fragile if the cwd is wrong.
- **Explicit:** the runtime looks **only** at
  `LYRIC_CONFIG_FILE`; if unset, no file source is loaded
  (defaults → env → CLI as before).  More predictable.

I lean **explicit** — the `LYRIC_CONFIG_FILE` env var is the
single source of truth for "what file" and the binary doesn't
search.  Aligns with Lyric's "no implicit IO" stance.

### 3.2 File format: TOML primary, no others in v2

TOML matches the existing `lyric.toml` manifest format and
maps cleanly to D046's typed fields (Bool / Int / String /
ranges / enums / lists).  Skip JSON, YAML, env-files in v2.

```toml
# config/prod.toml — example

[Http]
port = 8443
host = "0.0.0.0"

[Database]
url               = "postgres://prod-db/checkout"
poolSize          = 50
connectTimeoutMs  = 3000
# password intentionally omitted — comes from env (sensitive)

[Features]
newCheckout = true
partners    = ["acme", "initech"]
```

Each `[Section]` corresponds to a `config Section { ... }`
block in the consumer's package.  Field names map 1:1.

### 3.3 What about cross-package config in a file?

D046 §2.2 makes config blocks package-private.  Should a file
be allowed to contain config sections for multiple consumer
packages?  Two options:

- **One file per consumer** — `LYRIC_CONFIG_FILE` is
  per-binary; each binary's file has its own sections.
  Simple.  v2 default.
- **Cross-package via prefixed sections** — `[MyApp.Server.Http]`
  vs. `[MyApp.Worker.Http]`.  More flexible but requires
  package-name disambiguation that v2 doesn't otherwise need.
  Defer.

Lean: one file per binary, sections match the binary's
declared blocks.

### 3.4 Sensitive fields in file sources

`@sensitive` fields can appear in a file source — but the
common idiom is *not* to put secrets in a checked-in TOML file.
Convention:

- File source supplies non-sensitive fields.
- Env var supplies sensitive fields.
- The `@sensitive` marker is purely advisory at the language
  level; the runtime trusts the layer.

For audit-grade deployments, ops can opt to refuse `@sensitive`
fields in file sources (env-only) via a **CLI / build-time
flag**, not in-file metadata:

```sh
# Deployment-time refusal of file-source @sensitive values:
lyric run app.l --config-sensitive-env-only
# Or pinned in lyric.toml:
[build]
config_sensitive_env_only = true
```

When set, any `@sensitive` field whose **TOML key is present in
the file source** is rejected loudly with exit code 78 and a
diagnostic naming the offending field — even if env / CLI
would override it (presence in the file is what's audited, not
which layer "wins").  Silent ignoring was considered but
rejected: typo'd or accidentally-checked-in secrets in a TOML
file are exactly the kind of audit-grade failure the marker is
meant to surface; silent ignore would mask the very bug.

Earlier drafts of this sketch put the flag in a magic
`[__lyric_meta]` TOML section — withdrawn because (a) it
breaks §3.2's clean 1:1 mapping between TOML sections and
declared `config { … }` blocks, (b) it pushes a deployment
policy into application source / config files where it
doesn't belong, and (c) it would collide if any consumer
ever declared `config __lyric_meta { … }`.  CLI / build-flag
is the cleaner shape.

---

## 4. CLI flag layer

```
lyric run app.l --config Http.port=9090 \
               --config Features.newCheckout=true \
               --config-file config/dev.toml
```

`--config <Block>.<field>=<value>` overrides individual
fields.  Repeatable.  Highest precedence.  String values are
parsed against the field's declared type (same parser as
the env-var path).

`--config-file` overrides `LYRIC_CONFIG_FILE` for the run,
consistent with the layer ordering in §2 (CLI > env).  In
practice, the env var is what container platforms set, and
the flag is the CI / local-dev override — but the precedence
is just CLI > env, no inversion.

---

## 5. Resolution example

Three layers contribute values for `Http.port`:

| Layer | Value | Source |
|---|---|---|
| Default | `8080` | `config Http { port: Int = 8080 }` |
| File | `8443` | `config/prod.toml: [Http].port = 8443` |
| Env | unset | — |
| CLI | `9090` | `--config Http.port=9090` |

Result: `9090` (CLI wins).  With CLI unset, `8443` (file
wins, since env is unset).  With CLI and file both unset,
env would be next; here env is also unset, so the default
`8080` applies.

For a required field (`@sensitive password: String`):

| Layer | Value | Source |
|---|---|---|
| Default | — (no default) | `config Database { @sensitive password: String }` |
| File | absent | (intentionally not in TOML) |
| Env | `LYRIC_CONFIG_DATABASE_PASSWORD=<secret>` | layer 3 |
| CLI | unset | — |

Resolution: `<secret>` from env.  If env weren't set, exit
code 78 with diagnostic:

```
lyric: required config 'Database.password' not provided.
       Searched (in order):
         CLI:  --config Database.password=… (not set)
         Env:  LYRIC_CONFIG_DATABASE_PASSWORD (not set)
         File: config/prod.toml [Database].password (absent)
         Default: <none>
       Set one of the above (env recommended for @sensitive).
```

The error message names every layer searched — better than
v1's terse "not set" by virtue of having layers to enumerate.

---

## 6. Interactions with v1

### 6.1 D046 §4.1 — defaults must be compile-time constants

Unchanged.  Compile-time constants are still required; file
and env values are *runtime* overrides of those constants.

### 6.2 D046 §6 — read-once-at-startup

Unchanged.  All layers resolve once, before `main` runs.
Hot reload remains explicitly out of scope.

### 6.3 Q-config-004 — `Lyric.BuildInfo` recording

Extends naturally: the published config schema (names + types
+ defaults + `@sensitive`) describes what the binary's
config surface looks like.  The actual file path / env vars
/ CLI flags are *runtime resolution* and aren't recorded.

### 6.4 D047 aspect runtime config (`config { ... }` inside an aspect)

A `pub aspect Logging { config { … } }` library aspect's
config block is materialised at the consumer's `use` site.
The consumer's compiler synthesises a hidden config block
(per D047 §8), which then participates in the layering
exactly like any other config block — file source can
populate `[RequestLog].level = "Debug"` for an aspect aliased
as `RequestLog`.

This is automatic; no extra spec work.  The library / consumer
split (27 §2) ensures aspect config blocks belong to the
consumer for layering purposes.

---

## 7. Tensions surfaced

### 7.1 — Layering vs. fail-fast: a v1→v2 breaking contract shift

> **⚠ Top-priority tension.**  This is the only finding in this
> sketch that's a *behavioural* break from v1, not just an
> additive feature.  A decision-log entry must land **before**
> any v2 implementation work begins, not "on adoption."

D046 §4 says a required field with no default must be
provided at startup or the process aborts.  In a layered
world, "provided" is satisfied if **any** layer provides
the field.  So:

- Required field with no default: at least one layer
  (file / env / CLI) must supply it.  Otherwise exit 78.
- Required field with default in `config { ... }` block: not
  required at all — the default is its value if nothing
  overrides.  This is just D046's existing rule.

The v1→v2 shift:

- **v1 contract:** "required = env var must be set."  Operators
  enumerate `LYRIC_CONFIG_*` in deployment manifests; an
  unset env var fail-fasts the process.
- **v2 contract:** "required = some layer must supply a
  value."  A checked-in `config/dev.toml` with a value for a
  required field will now satisfy the requirement, even when
  ops thought they were running with env-only config.

Concrete risk: a `config { @sensitive password: String }`
that was env-driven in v1 may pick up a value from a
`config/dev.toml` accidentally bundled into a prod build,
without the process fail-fasting.  v1's env-only path was
implicitly audit-auditable (`LYRIC_CONFIG_*` is enumerable);
v2's file layer is harder to enumerate inside a running
container.  The §3.4 `--config-sensitive-env-only` flag is
the partial mitigation, but the *contract change itself*
needs explicit acknowledgement before implementation lands.

### 7.2 — Type coercion across layers

File values are typed by TOML (bool / int / float / string
/ array).  Env / CLI values are strings, parsed against the
field's declared type.  What if the file has the wrong type?

```toml
[Http]
port = "8080"        # string, but field is `Int`
```

Lean: **strict at parse time**.  TOML supplied a string but
the field expects Int → reject with `G0014: file source
provides Http.port as String, declared as Int`.  No coercion.

**Range subtypes** (e.g. `port: Int range 1 ..= 65535`) are
checked at the **same** config-resolution phase, not deferred
to first use.  A TOML value of `port = 0` is a valid TOML
integer but an out-of-range Lyric value; it fails the same
way a type mismatch does (exit 78, diagnostic naming the
field, the source layer, and the failing range).  This
matches §2's step 4 ("type-check the resolved value against
the field's declared type") and keeps the fail-fast
guarantee tight across env / CLI / file alike.

### 7.3 — File vs. env conflict diagnostics

If both file and env provide `Http.port`, env wins per the
layer ordering — but should we *warn* at startup that two
layers disagreed?  Useful in dev (someone forgot to update
prod.toml), noisy in prod (env is the canonical override).

Lean: silent override by default.  Add `LYRIC_CONFIG_VERBOSE=1`
opt-in that prints the layer trail at startup for diagnosis.

### 7.4 — Multi-file composition

Some real-world deployments want multiple files merged:
`config/base.toml` + `config/prod.toml`, where `prod.toml`
overrides individual keys.  v1 of this sketch supports a
single file (`LYRIC_CONFIG_FILE` is one path).  Multi-file
is a v2.x extension — `LYRIC_CONFIG_FILES=base.toml,prod.toml`
with later files overriding earlier.  Defer to a future
sketch.

### 7.5 — `@cfg(feature = "X")` interaction

A `config { ... }` block gated by `@cfg(feature = "logging")`
and a file source for that feature: if the feature is off
at compile time, the field doesn't exist; the file source's
TOML key is silently ignored.  Should that be an error
(`F0014: file source mentions config Logging.level but
feature 'logging' is off`)?  Plausibly yes — typos in file
sources are easy.  Lean: warn, don't error, because production
configs need to span environments where features differ.

### 7.6 — Cross-package config sections in one file

D046 §2.2 makes config blocks package-private.  But a multi-
package project (`docs/20-project-as-dll.md`) bundles
multiple packages into one DLL.  Should the file source
recognise per-package sections?

```toml
[MyApp.Server.Http]
port = 8080

[MyApp.Worker.Db]
url = "postgres://..."
```

Lean: yes for project bundles, no for stand-alone packages.
Distinguish by the consumer's `lyric.toml` manifest shape.

---

## 8. What this sketch confirms

- **Read-once-at-startup is the right v2 default.**  Even
  with file sources, the runtime resolves all layers once
  before `main` runs.  No file watching, no SIGHUP handling
  in v2.
- **TOML maps cleanly** to D046's typed-field set.  No
  format wrangling.
- **Layer ordering** (CLI > env > file > defaults) matches
  every other tool in the space (Cargo, Spring, Rails);
  no need to invent new precedence semantics.
- **Q-config-004's `Lyric.BuildInfo` recording extends
  naturally** — it describes the schema, not the runtime
  resolution, so layering doesn't change what's recorded.
- **Aspect runtime config** (D047 §8) inherits the layered
  semantics for free via the consumer's synthesised
  `config { ... }` block — no extra spec work.

---

## 9. What this sketch wants nailed down before v2 implementation

- **§7.1 "missing" semantics with layers** — confirm that a
  required field is satisfied if any layer provides it; that
  this is the right v2 contract change from v1's "default
  or env."
- **§7.2 Type coercion strictness** — confirm "TOML type
  must match declared type, no coercion."
- **§7.3 File-env conflict diagnostics** — confirm silent
  override by default + opt-in verbose mode.
- **§7.5 `@cfg` × file source mismatch** — warn or error?
- **§7.6 Cross-package sections in project bundles** —
  worth pinning when D046 + `docs/20` (project-as-DLL)
  meet a real consumer.

The §3.1 implicit-vs-explicit file location, §3.3 file
scoping, and §3.4 sensitive-field policy are mostly
documentation choices and don't need pre-implementation
resolution.

---

## 10. Out of scope (still)

- **Hot reload** (Q-config-003) — a v3+ topic, almost
  certainly never.  File watching introduces dynamic state
  that breaks the verifier and `Lyric.BuildInfo`'s
  static-schema promise.
- **Multi-file composition** (§7.4) — deferred to v2.x.
- **Non-TOML formats** — TOML is sufficient for v2.  YAML /
  JSON / env-file support is a v3 conversation.
- **Config UI / validators** beyond range subtypes — v3+.
- **Environment-pinned files** (e.g.
  `LYRIC_ENV=prod` automatically picks
  `config/prod.toml`) — application-side pattern, not a
  language feature.

---

## 11. References

- `docs/25-config-blocks.md` (D046) — base config-block
  spec that this sketch extends.
- `docs/24-build-features.md` (D045) — `@cfg` gating that
  interacts with file sources.
- `docs/20-project-as-dll.md` — multi-package project
  layout that affects §7.6.
- Cargo's profile / `[features]` precedence model.
- Spring `application.properties` / `application-{profile}.properties`.
- Rails `config/environments/{env}.rb`.
