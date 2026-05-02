---
name: disk-cleanup
description: Recover the lyric-lang dev environment from a full disk (ENOSPC) without losing the session. Use when Bash commands fail with `ENOSPC: no space left on device` (typically while initializing `/root/.claude/session-env/...`) or when `df -h /` shows the root filesystem at 100%.
level: 2
---

# Disk Cleanup (ENOSPC recovery)

The lyric-lang bootstrap compiler accumulates large `bin/` and `obj/`
directories under `compiler/` (each emitter test materialises a
fresh assembly cache).  Combined with `~/.claude/projects/`'s JSONL
session logs, the root filesystem can fill up mid-session.  When
that happens `Bash` itself fails to start because the harness can't
write its session-env file, leaving the agent unable to run *any*
shell command — including the cleanup commands.

This skill encodes the unblock sequence so the recovery doesn't
have to be re-derived from scratch.

## Trigger symptoms

Use this skill when one of these appears:

- `ENOSPC: no space left on device, mkdir '/root/.claude/session-env/...'`
  bubbling out of a Bash tool invocation (the canonical "the harness
  can't even open a shell" failure).
- A bare `Bash` call returns the same error before the requested
  command runs.
- `df -h /` shows the root filesystem at 100% use.

If only `compiler/**/{bin,obj}` looks bloated and Bash still works,
skip this skill and just run the compiler-cleanup `find` directly.

## Recovery sequence

### Phase 1 — break the deadlock (no Bash available)

Bash is wedged because the session-env mkdir failed.  Use the
**Read** then **Write** tools to truncate the largest text files
*by name* — Write with empty content overwrites the file in place,
freeing space without needing a shell.  Pick targets in this
order; you only need to truncate enough to let the next phase's
Bash commands initialise (a few MB is plenty):

1. **Build artefacts under `compiler/`** — large but non-essential
   text files:
   - `compiler/src/Lyric.<X>/obj/Debug/net9.0/project.assets.json`
   - `compiler/src/Lyric.<X>/obj/Debug/net9.0/Lyric.<X>.deps.json`
   - `compiler/tests/Lyric.<X>.Tests/obj/.../*.deps.json`
   - The `.csproj.FileListAbsolute.txt` files under any `obj/`.
   These all regenerate on the next `dotnet build`.
2. **Stale Claude session logs** — sometimes hundreds of MB of
   JSONL:
   - `/root/.claude/projects/-home-user-lyric-lang/*.jsonl`
   These are agent transcript caches; truncating them loses
   navigable history but does not affect the live session.

For each chosen file: call `Read` first (the harness requires it),
then call `Write` with `content: ""`.  Repeat until Bash starts
working again (i.e. a tiny `Bash` smoke test like `echo ok` runs
without the `ENOSPC` error).

### Phase 2 — bulk reclaim with Bash

Once Bash initialises, run the two commands that actually free
material space:

```bash
find compiler -type d \( -name bin -o -name obj \) -exec rm -rf {} +
```

`bin/` and `obj/` together are typically the largest single
contributor; `dotnet build Lyric.sln` repopulates them on demand.

If the JSONL logs are still bloated, also run:

```bash
find /root/.claude/projects/-home-user-lyric-lang -name '*.jsonl' -size +50M -delete
```

The `-size +50M` filter avoids removing the active session's own
log when the harness is mid-write.

### Phase 3 — confirm the recovery

```bash
df -h /
```

Expect `Use%` back below 50%.  Then re-run whatever build / test
step ENOSPC interrupted; the regenerated `bin/`/`obj/` will be
fresh artefacts, not stale ones.

## Out of scope

- **Don't touch `compiler/lyric/std/*.l`** — those are the in-tree
  stdlib *sources*, not generated artefacts.  Truncating them
  destroys real work.
- **Don't truncate live JSONL session logs**.  The active session
  log is the most-recently-modified `.jsonl` under
  `/root/.claude/projects/-home-user-lyric-lang/`; leave it alone.
- **Don't modify `~/.dotnet/`** — re-downloading the .NET 10 SDK
  takes ~3 minutes and 240 MB of bandwidth.  Build outputs are
  the right cleanup target, the SDK is not.
- **Disk pressure unrelated to lyric-lang** (e.g. `/var/log` blow-
  up) is outside this skill's scope; investigate the actual heavy
  directory first via `du -sh /home /root /var /tmp 2>/dev/null`.

## Why this exists

The Read+Write-as-truncation trick isn't obvious — most agents
default to `> file` via Bash, which is exactly what's broken.
Codifying the workaround means the next session can recover in
two tool calls instead of re-discovering the deadlock and the
escape hatch under time pressure.
