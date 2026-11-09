# Release hygiene: channel status, stdlib stability walk, tracker cleanup (stream S6)

No compiler change.  Part of the v1.0 exit checklist (docs/12, stream S6).

- `docs/01` gains section 0.1, the channel-status table: `--target dotnet` is the
  SemVer channel, `--target jvm` is supported with no v1.0 SemVer guarantee
  (G1, D-progress-620), and the native and wasm32 lines are marked pending the
  project-lead decision rather than invented.  The book mirrors it in
  `01-getting-started.md`.  `docs/01` section 13.5 and book chapters 6 and 20
  described `lyric public-api-diff <git-ref>`; the command takes two DLLs, and
  they now say so.
- `lyric-stdlib/STABILITY.md` was rewritten from a walk of every
  `lyric-stdlib/std/*.l`: it had omitted about 30 modules and listed kernel files
  that no longer exist.  Every `pub` item (other than `pub use` re-exports) now
  carries `@stable(since="1.0")` or `@experimental`: 127 annotations were added
  (107 `@experimental`, 91 of them in `Std.Linalg`; 20 `@stable`) and every `since` of
  `0.x`, `1.1` or `1.2` became `1.0`, since nothing has been released.  Four
  packages in `_kernel/` that programs import (`Std.Task`, `Std.HttpServer`,
  `Std.TcpHost`, `Std.Jvm`) have no tier and are listed as an open decision.
  The annotated files pass `lyric fmt --check` and a build importing the changed
  modules.
- `docs/22` section 5.3 documents how the `public-api-diff` baseline is cut at
  the tag.  Verified limit: the command reads only the bare `Lyric.Contract`
  resource of single-package assemblies, so `Lyric.Stdlib.dll` and any
  multi-package library cannot be diffed (`has no Lyric.Contract resource`,
  checked with lyric 0.7.12); the compiler needs to walk the per-package
  `Lyric.Contract.<Pkg>` resources first.
- `docs/12` header counts and tracker-hygiene notes, `docs/36` (G1, G3 and R1
  statuses) and `docs/05` (two stale F# stage notes) were brought in line with
  the shipped state.
- Tracker: the ten review-finding doc issues (#6982, #6999, #7066, #7068,
  #7070, #7073-#7077) were already closed and were verified fixed on `main`;
  32 open issues received an existing `group:*` label; #4601 and #2280 received
  status comments and stay open.
