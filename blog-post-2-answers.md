# Blog post 2 — draft answers

---

## Q1. Did you direct Claude Code toward Phase 4, or did it propose it?

I directed it. For weeks every significant implementation decision came back with the same framing: "Bootstrap-grade scope (shipped). Phase N target (future)." Generic constraints lowered to monomorphised call-site checks instead of CLR generics — bootstrap-grade. Async lowered to `.GetAwaiter().GetResult()` — bootstrap-grade. The proof system? Decision log entry D035 was literally titled "M1.4 proof-obligation deferral." The plan document for Phase 4 had a banner that read "post-v1.0; nothing in this plan blocks v1.0."

I decided to call the bluff. The first verifier commit landed on 2026-05-03. All three milestones — M4.1, M4.2, M4.3, originally scoped at months 39–57 — shipped inside two weeks.

**What `lyric prove` can discharge right now:**

```lyric
// Trivial discharger — no Z3 needed:
pub func id(x: Int): Int
  ensures: result == x
  = x

// Loop invariant + cross-call rule — also no Z3:
pub func pageStart(page: Int, size: Int): Int
  requires: page >= 0
  requires: size  > 0
  ensures:  result >= 0
{
  var start: Int = 0
  var i: Int = 0
  while i < page
    invariant: i >= 0
    invariant: start >= 0
  { start = start + size; i = i + 1 }
  return start
}
```

**What requires Z3:**

```lyric
// Arithmetic — Unknown without Z3, proves with it:
pub func bumped(x: Int): Int
  requires: x >= 0
  ensures: result > x
  = x + 1
```

**What Z3 rejects with a counterexample:**

```lyric
// Z3 produces: x = 0, result = 0, expected result < 0
pub func broken(x: Int): Int
  requires: x >= 0
  ensures: result < x
  = x * x
```

---

## Q2. Where did it push back hardest?

The "Bootstrap-grade scope" pattern was everywhere, but the most persistent form was deferral through naming. Every time I pushed on a principled implementation, the response was to propose a thin shim, name it something like "bootstrap-grade lowering," and point to a Phase N document as the place where it would eventually be done properly. The effect was that each individual deferral seemed reasonable in isolation — the problem only became visible in aggregate, when I noticed the Phase 4 work was perpetually "not blocking v1.0."

The clearest textual evidence is `docs/09-msil-emission.md` §9.4, which we rewrote together. The original described the constraint (`where T: Hash`) check as "interface dispatch" — a description of a future Phase 5 lowering that hadn't been built yet. The actual implementation was a three-path lookup at monomorphisation call sites. The spec had been written for the planned version, not the shipped version, and that kind of drift was endemic across the documentation.

---

## Q3. A concrete override moment

The `pageCount` proof in `examples/pagination.l`. The function uses early `return` inside each if-branch:

```lyric
if remaining <= 0 {
  return 0
} else if remaining < size {
  return remaining
} else {
  return size
}
```

The VCGen's if-expression translator was hitting an `EOBBlock` branch and falling back to `Term.trueT` — Bool — for every branch value. The generated SMT looked like:

```smt2
(>= (ite (<= remaining 0) true
         (ite (< remaining size) true true)) 0)
```

Applying `>=` to `Bool` is a sort mismatch. The goal went Unknown.

The proposed fix was to rewrite `pageCount` to avoid early `return` — use trailing expressions instead — and note the limitation in a comment. My override: fix the VCGen. The actual fix was six lines: when an `EOBBlock` branch has a single trailing `SExpr` or `SReturn`, extract that value instead of substituting `true`. The SMT became correct:

```smt2
(>= (ite (<= remaining 0) 0
         (ite (< remaining size) remaining size)) 0)
```

All four goals discharged. The fix also meant any future Lyric programmer writing natural early-return style in a `@proof_required` function would get correct VCs rather than silent unsoundness. The commit is `6f7ca89`; there is now a regression test.

The pattern here is representative: the proposed workaround would have papered over a language-level correctness issue to preserve a local implementation convenience. Fixing it properly took minutes.

---

## Q4. How does `lyric prove` work end-to-end?

The verifier is about 4,000 lines of F# in `compiler/src/Lyric.Verifier/`. The pipeline:

1. **Mode** — reads the package-level annotation (`@runtime_checked`, `@proof_required`, `@axiom`).
2. **ModeCheck** — enforces call-graph constraints: proof-required code may only call proof-required, axiom, or compiler primitives. Also catches loops without invariants, unbounded quantifier domains.
3. **VCGen** — runs weakest-precondition calculus over the imperative fragment: `let`/`val` bindings, `return`, `if`/`else`, `match` (wildcard, literal, bare-binding patterns), `assert φ`, `while` with `invariant:`, variable SSA via forward substitution, one-level `@pure` callee unfold, and the Hoare call rule — which lets a caller's proof use a callee's `ensures` contract without knowing its body.
4. **Vcir / Theory** — solver-agnostic IR. Range subtypes (`Int range 0 ..= 150`) lift to `SInt` plus a closed-range hypothesis.
5. **Smt** — emits SMT-LIB v2.6.
6. **Solver** — two paths:
   - *Trivial syntactic discharger*: closes `true`, `P ⇒ P`, reflexive comparisons, hypothesis matches, and conjunctions thereof. No external process.
   - *Z3 shell-out*: resolved via `LYRIC_Z3` env var or `$PATH`. Persistent session with a goal cache.
7. **Counterexamples** — Z3's `(get-model)` output is parsed into `name : sort = value` bindings and shown inline.

**Z3 is optional.** Identity goals, tautologies, loop-invariant establishment, and many cross-call goals discharge on the trivial path alone. Arithmetic obligations need Z3, and degrade to `V0007 Unknown` without it. `--allow-unverified` downgrades Unknown to a warning so CI stays green on a machine without Z3. `V0008 Counterexample` — Z3 actually produced a model refuting the goal — is always a hard error regardless.

---

## Q5. Current test count

| Suite | Tests |
|---|---:|
| Lyric.Lexer.Tests | 123 |
| Lyric.Parser.Tests | 311 |
| Lyric.TypeChecker.Tests | 137 |
| Lyric.Emitter.Tests | 478 |
| Lyric.Lsp.Tests | 25 |
| Lyric.Cli.Tests | 76 |
| Lyric.Verifier.Tests | 242 |
| **Total** | **1,392** |

Up from **690** at the first post — **+702 tests** in two weeks. The Verifier, LSP, and CLI suites are entirely new. The Emitter suite roughly doubled. Bootstrap-progress entries: **D-progress-092** (was 032 at the first post — 60 new entries).

The headline: Phase 4 was scoped for months 39–57. M4.1 through M4.3 shipped in 14 days, with 242 tests covering the proof system.
