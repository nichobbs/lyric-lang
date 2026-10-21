# Planning docs audit and refresh (2026-10-21)

- Audited `docs/05`, `06`, `12`, `33`, `35`, `36`, `41`, `44`, `57`, `59`, `67`, `68`,
  `native/plan/08-work-items.md` and the live sections of `docs/10-bootstrap-progress.md`
  against `docs/progress/` (313 entries), `docs/decisions/` (to D200) and the 379 open issues.
- `docs/12-todo-plan.md` rewritten as the live tracker (it was stamped 2026-06-12): shipped
  summary, then Tier 1 (silent miscompiles and unsoundness, by `group:*` cluster) through
  Tier 6, plus issue-tracker hygiene. Band F is closed out (F2, F3, F7, F10 shipped; F4, F5,
  F6, F9, F11 obsolete; F1, F8 still open).
- Status headers added to `docs/33` (historical), `41` (historical; table rows reconciled
  with its section 10), `44` (J0-J6 shipped), `57`, `59` (partly implemented), `35`, `67`
  (G0-G6 done, G7-G10 not started) and `native/plan/08`. `docs/36` R7 marked closed.
  `docs/05` and `docs/10` lose present-tense F# statements. `docs/06` fixes Q-JS, Q-W, Q-SG
  and Q47/Q48 status.
- Diagnostic collision fixed: `docs/68` and `docs/01` assigned `V0035` to the handle-escape
  rule, but the verifier already uses `V0035` (precondition can never hold) and `V0036`. The
  escape rule is now `V0037`. D166 is frozen and still says `V0035` for it; this entry
  supersedes that one reference.
- Not changed: `CLAUDE.md` still lists "43 ordered work items" for the native plan (actual 48
  base items plus N8 and N9) and still describes `bootstrap/tests/` and F# shims that no longer
  exist; `docs/44` section 1-3 prose is only annotated, not rewritten.
