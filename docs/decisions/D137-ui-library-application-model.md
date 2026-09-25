# D137 — UI library: one model-view-update application model for desktop and web

**Status:** accepted

**Sketch:** `docs/65-ui-library-sketch.md` (source of truth for the design).

## Context

Lyric had no way to build an interactive user interface. The first audience is
line-of-business applications (forms, lists, dashboards) that must run both as
desktop applications and in a browser from one codebase, with native and MSIL
as the priority targets and JVM later. A native look and feel is desirable but
not required.

## Decision

1. **Programming model.** Model-view-update: `Model`, `Msg`, a pure
   `update(Model, Msg): Step[Model, Effect]` and a pure `view(Model):
   View[Msg]`. Effects are returned as **data** (an `Effect` union per
   screen) and run by a separate interpreter, so screen logic is fully
   testable with `lyric test` and a recorded message list replays a session
   exactly.
2. **Enforced separation.** View code and functionality are separated by a
   general **`[layers]` language feature** (package-to-layer mapping in
   `lyric.toml` or `@layer`, an import/async matrix per layer, `Y000x`
   diagnostics) shipped with a `ui` preset. The standard library is
   classified `@pure` / `@io` (per function where a module is mixed) so pure
   layers cannot reach nondeterministic or I/O functions.
3. **Rendering.** HTML/CSS through a small host runtime. Application code
   targets a closed vocabulary of **semantic widgets** (button, text input,
   table, dialog...) rather than HTML elements, keeping non-HTML hosts
   possible; a `raw` escape hatch exists for web hosts only.
4. **Hosts.** Server-driven web first (patches over `lyric-ws`), desktop
   webview second (same protocol in process), client-side WASM through the
   native backend later. Application code is identical across hosts.
5. **TypeScript runtime.** The browser/webview patch applier and widget
   renderer is a small, audited TypeScript runtime in `lyric-ui/runtime/`,
   the one accepted non-Lyric component of the UI stack. It carries no
   application logic.
6. **Composition.** Reusable components with business logic nest
   **explicitly** (parent wraps child messages and effects, child returns
   outcomes). `@generate(Embed)` is deferred until the explicit pattern has
   been used in real applications.
7. **Forms.** A pure `lyric-forms` library owns field errors, form schemas
   and parsers so domain packages can depend on it without depending on the
   UI. `@generate(Forms.Derive)` will derive drafts, schemas and validation
   (including invariants as form-level messages) from domain types.

## Consequences

- Phases U1–U7 in docs/65 §14. U1 (pure core, `lyric-forms`, example) lands
  first; the layer checker (U3) and generators (U4) are separate compiler
  work.
- The TypeScript runtime is an explicit, bounded exception to the all-Lyric
  rule in `CLAUDE.md`, scoped to `lyric-ui/runtime/`.
- Open questions Q-UI-001 to Q-UI-011 live in docs/65 §16; implementation
  findings in §15. The compiler gaps the first implementation hit were fixed
  in the compiler (#7215, #7250, D-progress-970) rather than worked around,
  resolving Q-UI-011.
